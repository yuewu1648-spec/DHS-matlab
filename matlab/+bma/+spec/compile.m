function m = compile(spec)
%COMPILE 将模型规格编译为可计算的 ODE 模型结构（DESIGN §5.2 / §5.3）。
%   m = bma.spec.compile(spec)
%   m = bma.spec.compile(spec_path)
%
% 前提：规格应已通过 bma.spec.validate；本函数不再重复完整校验，
% 但会对编译期无法处理的数据抛 MException('bma:spec:spec_invalid')（中文提示）。
%
% m 的主要字段（契约见 DESIGN §5.3）：
%   .spec/.name/.title/.description/.kind
%   .species/.speciesNames/.speciesUnits/.speciesInitial
%   .params/.paramNames/.paramUnits/.paramValues/.paramEstimate/.paramBounds
%   .lb/.ub                       参数下界/上界（无 bounds 时为 ±Inf）
%   .paramIndex/.speciesIndex     containers.Map（id → 1 基索引）
%   .S                            化学计量矩阵（nSpecies × nReactions）
%   .reactions                    struct array {id,name,kind,stoichiometry,flux,parameter_ids,species_ids}
%   .vfuns                        {@(y,p), ...} 每个反应的通量函数
%   .VF = @(y,p)                 通量向量函数
%   .rhs = @(t,y,p)              ODE 右端函数（返回 nSpecies×1 列向量）
%   .fluxText/.fluxCode/.rateText 人类可读公式 / 生成代码 / 反应速率公式
%   .outputs                      struct array {id,name,unit,expression,code,fh(@(y,p))}
%   .initial/.time/.timeUnit/.compartments
%   .speciesInfo/.paramInfo       struct array（带 index 的元数据）
%   .odeText/.ode_rhs_preview .warnings
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec) || isempty(spec)
    error('bma:spec:spec_invalid', 'bma.spec.compile 需要模型规格结构体');
end
norm = bma.spec.normalize(spec);
if strcmpi(charIf(getField(norm, 'kind', 'ode'), 'ode'), 'dde')
    m = bma.dde.compile(norm);
    m.spec = norm;
    return
end
if strcmpi(charIf(getField(norm, 'kind', 'ode'), 'ode'), 'bvp')
    m = bma.bvp.compile(norm);
    m.spec = norm;
    return
end
if strcmpi(charIf(getField(norm, 'kind', 'ode'), 'ode'), 'dae')
    m = bma.dae.compile(norm);
    m.spec = norm;
    return
end
% PDE spec: expand to an equivalent ODE spec, compile that, then restore the
% PDE-facing metadata. Downstream fit/identifiability/validate/report only see
% the expanded ODE model (the whole point of the MOL compiler).
if strcmpi(charIf(getField(norm, 'kind', 'ode'), 'ode'), 'pde')
    expanded = bma.spec.pde.expand(norm);
    m = bma.spec.compile(expanded);
    m.spec = norm;
    m.kind = 'pde';
    if isfield(expanded, 'metadata') && isfield(expanded.metadata, 'pde')
        m.pde = expanded.metadata.pde;
    else
        m.pde = struct('geometry', 'unknown', 'n', NaN);
    end
    m.warnings = [reshape(m.warnings, 1, []), ...
        {sprintf('PDE spec expanded by %s: %d node states, geometry=%s, n=%d', ...
        m.pde.expander_version, m.n_species, m.pde.geometry, m.pde.n)}];
    return
end
originalSpec = norm;
[norm, auxInfo] = resolveAlgebraic(norm);

vars = itemize(getField(norm, 'variables', []));
params = itemize(getField(norm, 'parameters', []));
comps = itemize(getField(norm, 'compartments', []));
reacs = itemize(getField(norm, 'reactions', []));
outItems = itemize(getField(norm, 'outputs', []));
nS = numel(vars);
nP = numel(params);
nR = numel(reacs);
nC = numel(comps);
nO = numel(outItems);

% ---- 状态变量 ----
species = cell(1, nS);
speciesNames = cell(1, nS);
speciesUnits = cell(1, nS);
speciesComp = cell(1, nS);
speciesInitial = zeros(nS, 1);
for i = 1:nS
    e = vars{i};
    id = charIf(getField(e, 'id', ''), '');
    if isempty(id)
        fail('第 %d 个状态变量缺少 id', i);
    end
    species{i} = id;
    speciesNames{i} = charIf(getField(e, 'name', ''), '');
    speciesUnits{i} = charIf(getField(e, 'unit', ''), '');
    speciesComp{i} = charIf(getField(e, 'compartment', ''), '');
    ini = getField(e, 'initial', struct());
    v = getField(ini, 'value', 0);
    hasParamInit = isfield(ini, 'param') && ~isempty(ini.param);
    hasExprInit = isfield(ini, 'expression') && ~isempty(ini.expression);
    if hasParamInit || hasExprInit
        % Resolved after parameter values are compiled, so initial can refer
        % to a parameter (shooting/BVP models). Do not silently use 0.
        speciesInitial(i) = NaN;
    elseif ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        fail('状态变量 "%s" 的初值必须是有限数值', id);
    else
        speciesInitial(i) = v;
    end
end
speciesIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for i = 1:nS
    speciesIndex(species{i}) = i;
end

% ---- 参数 ----
paramIds = cell(1, nP);
paramNames = cell(1, nP);
paramUnits = cell(1, nP);
paramValues = zeros(nP, 1);
paramEstimate = false(1, nP);
paramBounds = nan(nP, 2);
lb = -inf(nP, 1);
ub = inf(nP, 1);
for j = 1:nP
    e = params{j};
    id = charIf(getField(e, 'id', ''), '');
    if isempty(id)
        fail('第 %d 个参数缺少 id', j);
    end
    paramIds{j} = id;
    paramNames{j} = charIf(getField(e, 'name', ''), '');
    paramUnits{j} = charIf(getField(e, 'unit', ''), '');
    val = getField(e, 'value', struct());
    v = getField(val, 'value', []);
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        fail('参数 "%s" 缺少有效数值 value.value', id);
    end
    paramValues(j) = v;
    est = getField(e, 'estimate', false);
    if islogical(est) && isscalar(est)
        paramEstimate(j) = est;
    end
    b = getField(e, 'bounds', []);
    if isnumeric(b) && numel(b) == 2 && all(isfinite(b))
        paramBounds(j, :) = b(:)';
        lb(j) = b(1);
        ub(j) = b(2);
    end
end
paramIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:nP
    paramIndex(paramIds{j}) = j;
end

% ---- 初值引用参数（Gap A：shooting/BVP 模型） ----
paramRefs = containers.Map('KeyType', 'char', 'ValueType', 'char');
for j = 1:nP
    paramRefs(paramIds{j}) = sprintf('p(%d)', j);
end
for i = 1:nS
    ini = getField(vars{i}, 'initial', struct());
    if isfield(ini, 'param') && ~isempty(ini.param)
        pid = char(ini.param);
        if ~isKey(paramIndex, pid)
            fail('状态变量 "%s" 的 initial.param 引用了不存在的参数 "%s"', species{i}, pid);
        end
        speciesInitial(i) = paramValues(paramIndex(pid));
    elseif isfield(ini, 'expression') && ~isempty(ini.expression)
        expr = char(ini.expression);
        try
            [code, ~] = parseExpression(expr, paramRefs);
            fh = str2func(['@(p) ' code]);
            v = fh(paramValues);
        catch err
            fail('状态变量 "%s" 的 initial.expression 无法编译：%s', species{i}, err.message);
        end
        if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
            fail('状态变量 "%s" 的 initial.expression 必须返回有限标量', species{i});
        end
        speciesInitial(i) = v;
    end
    if ~isfinite(speciesInitial(i))
        fail('状态变量 "%s" 的初值无法解析（NaN/Inf）', species{i});
    end
end

% ---- 隔室 ----
compIds = cell(1, nC);
compVolumes = ones(1, nC);
compUnits = cell(1, nC);
for k = 1:nC
    e = comps{k};
    compIds{k} = charIf(getField(e, 'id', ''), '');
    v = getField(e, 'volume', 1);
    if isnumeric(v) && isscalar(v) && isfinite(v)
        compVolumes(k) = v;
    end
    compUnits{k} = charIf(getField(e, 'unit', ''), '');
end

% ---- 速率编译上下文 ----
ctx = struct( ...
    'speciesIds', {species}, ...
    'paramIds', {paramIds}, ...
    'compartmentIds', {compIds}, ...
    'speciesIndex', speciesIndex, ...
    'paramIndex', paramIndex, ...
    'compartmentVolumes', compVolumes);
refsMap = makeExpressionRefs(ctx);

% ---- 化学计量矩阵 S 与反应 ----
S = zeros(nS, nR);
fluxText = cell(1, nR);
fluxCode = cell(1, nR);
rateText = cell(1, nR);
reactions = repmat(struct('id', '', 'name', '', 'kind', '', ...
    'stoichiometry', struct(), 'flux', '', ...
    'parameter_ids', {{}}, 'species_ids', {{}}), 1, nR);
for r = 1:nR
    e = reacs{r};
    rid = charIf(getField(e, 'id', ''), '');
    if isempty(rid)
        fail('第 %d 个反应缺少 id', r);
    end
    stoich = getField(e, 'stoichiometry', struct());
    if ~isstruct(stoich) || isempty(fieldnames(stoich))
        fail('反应 "%s" 缺少化学计量 stoichiometry', rid);
    end
    fn = fieldnames(stoich);
    for k = 1:numel(fn)
        sid = fn{k};
        if ~isKey(speciesIndex, sid)
            fail('反应 "%s" 的化学计量引用了不存在的物种 "%s"', rid, sid);
        end
        coef = stoich.(sid);
        if ~isnumeric(coef) || ~isscalar(coef) || ~isfinite(coef)
            fail('反应 "%s" 中物种 "%s" 的化学计量系数无效', rid, sid);
        end
        S(speciesIndex(sid), r) = coef;
    end
    rate = getField(e, 'rate', []);
    rp = rateParse(rate, ctx);
    if ~rp.ok
        msgs = cell(1, numel(rp.issues));
        for k = 1:numel(rp.issues)
            msgs{k} = sprintf('[%s] %s（%s）', rp.issues{k}.code, rp.issues{k}.message, rp.issues{k}.hint);
        end
        fail('反应 "%s" 的速率定律无法编译：%s', rid, strjoin(msgs, '；'));
    end
    reactions(r).id = rid;
    reactions(r).name = charIf(getField(e, 'name', ''), '');
    reactions(r).kind = rp.kind;
    reactions(r).stoichiometry = stoich;
    reactions(r).flux = rp.display;
    reactions(r).parameter_ids = rp.params_used;
    reactions(r).species_ids = rp.species_used;
    fluxText{r} = rp.display;
    fluxCode{r} = rp.code;
    rateText{r} = sprintf('v_%s = %s', rid, rp.display);
end

% ---- 通量向量函数 / ODE 右端 ----
parts = cell(1, nR);
for r = 1:nR
    parts{r} = ['(' fluxCode{r} ')'];
end
if nR == 0
    vfCode = 'zeros(0,1)';
else
    vfCode = ['[' strjoin(parts, '; ') ']'];
end
try
    VF = str2func(['@(y,p) ' vfCode]);
    probe = VF(speciesInitial, paramValues);
catch err
    fail('速率表达式编译失败：%s', err.message);
end
if numel(probe) ~= nR || any(~isfinite(probe))
    fail('速率表达式在初始状态下返回了非法值（NaN/Inf），请检查分母/初值');
end
vfuns = cell(1, nR);
for r = 1:nR
    try
        vfuns{r} = str2func(['@(y,p) ' parts{r}]);
        vfuns{r}(speciesInitial, paramValues);
    catch err
        fail('第 %d 个反应的速率函数编译失败：%s', r, err.message);
    end
end
S_ = S;
VF_ = VF;
rhs = @(t, y, p) S_ * VF_(y, p);

% ---- 输出 ----
outputs = repmat(struct('id', '', 'name', '', 'unit', '', ...
    'expression', '', 'code', '', 'fh', []), 1, nO);
for o = 1:nO
    e = outItems{o};
    oid = charIf(getField(e, 'id', ''), '');
    expr = charIf(getField(e, 'expression', ''), '');
    if isempty(strtrim(expr))
        % 归一化阶段已保证；此处兜底：用 id 所指变量
        expr = oid;
    end
    try
        [code, ~] = parseExpression(expr, refsMap);
        fh = str2func(['@(y,p) ' code]);
        probeOut = fh(speciesInitial, paramValues);
    catch err
        fail('输出 "%s" 的表达式无法编译：%s', oid, err.message);
    end
    if ~isnumeric(probeOut) || ~isscalar(probeOut) || ~isfinite(probeOut)
        fail('输出 "%s" 的表达式在初始状态下返回非法值', oid);
    end
    outputs(o).id = oid;
    outputs(o).name = charIf(getField(e, 'name', ''), '');
    outputs(o).unit = charIf(getField(e, 'unit', ''), '');
    outputs(o).expression = expr;
    outputs(o).code = code;
    outputs(o).fh = fh;
end
outputIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for o = 1:nO
    outputIndex(outputs(o).id) = o;
end

% ---- 时间轴 ----
tRaw = getField(norm, 'time', struct());
time = struct();
time.unit = charIf(getField(tRaw, 'unit', 's'), 's');
time.start = getField(tRaw, 'start', 0);
time.end = getField(tRaw, 'end', 100);
time.n = getField(tRaw, 'n', 101);

% ---- 元数据表 ----
speciesInfo = repmat(struct('id', '', 'name', '', 'unit', '', ...
    'initial', 0, 'compartment', '', 'index', 0), 1, nS);
for i = 1:nS
    speciesInfo(i) = struct('id', species{i}, 'name', speciesNames{i}, ...
        'unit', speciesUnits{i}, 'initial', speciesInitial(i), ...
        'compartment', speciesComp{i}, 'index', i);
end
paramInfo = repmat(struct('id', '', 'name', '', 'unit', '', ...
    'value', 0, 'estimate', false, 'bounds', [], 'index', 0), 1, nP);
for j = 1:nP
    paramInfo(j) = struct('id', paramIds{j}, 'name', paramNames{j}, ...
        'unit', paramUnits{j}, 'value', paramValues(j), ...
        'estimate', logical(paramEstimate(j)), ...
        'bounds', paramBounds(j, :), 'index', j);
end
compartmentInfo = repmat(struct('id', '', 'volume', 1, 'unit', ''), 1, nC);
for k = 1:nC
    compartmentInfo(k) = struct('id', compIds{k}, 'volume', compVolumes(k), ...
        'unit', compUnits{k});
end

% ---- ODE 人类可读文本 ----
odeText = cell(1, nS);
for i = 1:nS
    terms = {};
    for r = 1:nR
        c = S(i, r);
        if c == 0
            continue
        end
        flux = fluxText{r};
        if abs(c) == 1
            cStr = '';
        else
            cStr = [formatNumber(abs(c)) '*'];
        end
        term = [cStr '(' flux ')'];
        if isempty(terms)
            if c < 0
                terms{end+1} = ['-' term]; %#ok<AGROW>
            else
                terms{end+1} = term; %#ok<AGROW>
            end
        elseif c < 0
            terms{end+1} = [' - ' term]; %#ok<AGROW>
        else
            terms{end+1} = [' + ' term]; %#ok<AGROW>
        end
    end
    if isempty(terms)
        odeText{i} = sprintf('d%s/dt = 0', species{i});
    else
        odeText{i} = sprintf('d%s/dt = %s', species{i}, strjoin(terms, ''));
    end
end
previewLines = {'动态方程（ODE，d x_i/dt = Σ_r S_ir * v_r）：'};
for i = 1:nS
    previewLines{end+1} = ['  ' odeText{i}]; %#ok<AGROW>
end
previewLines{end+1} = '';
previewLines{end+1} = '反应通量：';
for r = 1:nR
    previewLines{end+1} = ['  ' rateText{r}]; %#ok<AGROW>
end
previewLines{end+1} = '';
previewLines{end+1} = '状态变量（y 索引，按 variables 顺序）：';
for i = 1:nS
    previewLines{end+1} = sprintf('  y(%d) = %-6s %-8s [%s] 初值 = %s', ...
        i, species{i}, speciesNames{i}, speciesUnits{i}, formatNumber(speciesInitial(i))); %#ok<AGROW>
end
previewLines{end+1} = '';
previewLines{end+1} = '参数（p 索引，按 parameters 顺序）：';
for j = 1:nP
    if paramEstimate(j)
        estTag = '估计';
    else
        estTag = '固定';
    end
    if all(isfinite(paramBounds(j, :)))
        bStr = sprintf(' bounds=[%s, %s]', formatNumber(paramBounds(j, 1)), formatNumber(paramBounds(j, 2)));
    else
        bStr = '';
    end
    previewLines{end+1} = sprintf('  p(%d) = %-8s %-8s [%s] 默认值 = %s（%s）%s', ...
        j, paramIds{j}, paramNames{j}, paramUnits{j}, formatNumber(paramValues(j)), estTag, bStr); %#ok<AGROW>
end
odePreview = strjoin(previewLines, sprintf('\n'));

% ---- 组装 ----
m = struct();
m.schema_version = 'bma.model.v1';
m.spec = originalSpec;
m.name = charIf(getField(norm, 'name', ''), '');
m.title = charIf(getField(norm, 'title', ''), '');
m.description = charIf(getField(norm, 'description', ''), '');
m.kind = charIf(getField(norm, 'kind', 'ode'), 'ode');
m.species = species;
m.speciesNames = speciesNames;
m.speciesUnits = speciesUnits;
m.speciesInitial = speciesInitial;
m.speciesCompartment = speciesComp;
m.params = paramIds;
m.paramNames = paramNames;
m.paramUnits = paramUnits;
m.paramValues = paramValues;
m.paramEstimate = logical(paramEstimate);
m.paramBounds = paramBounds;
m.lb = lb;
m.ub = ub;
m.paramIndex = paramIndex;
m.speciesIndex = speciesIndex;
m.outputIndex = outputIndex;
m.S = S;
m.reactions = reactions;
m.vfuns = vfuns;
m.VF = VF;
m.rhs = rhs;
m.fluxText = fluxText;
m.fluxCode = fluxCode;
m.rateText = rateText;
m.outputs = outputs;
m.initial = speciesInitial;
m.time = time;
m.timeUnit = time.unit;
m.compartments = compartmentInfo;
m.compartmentIds = compIds;
m.compartmentVolumes = compVolumes;
m.speciesInfo = speciesInfo;
m.paramInfo = paramInfo;
m.odeText = odeText;
m.ode_rhs_preview = odePreview;
m.n_species = nS;
m.aux = auxInfo;
m.n_algebraic = numel(auxInfo.ids);
m.n_params = nP;
m.n_reactions = nR;
m.n_outputs = nO;
m.n_compartments = nC;
m.warnings = {};
end

% =========================================================================
function [resolved, info] = resolveAlgebraic(spec)
%RESOLVEALGEBRAIC Substitute algebraic helper variables into expressions.
%   Algebraic variables (kind:"algebraic") are not ODE states; they are
%   resolved topologically and textually substituted into reaction/output
%   expressions. This keeps the compiled RHS in terms of states+parameters and
%   lets thermodynamic/equilibrium models express their algebra without hitting
%   MATLAB's 32-level nested-expression limit (ISS-03).
vars = itemize(getField(spec, 'variables', []));
isAlg = false(1, numel(vars));
for i = 1:numel(vars)
    isAlg(i) = localIsAlg(vars{i});
end
auxItems = vars(isAlg);
stateItems = vars(~isAlg);
resolved = spec;
if isempty(stateItems)
    resolved.variables = struct('id', {});
else
    resolved.variables = [stateItems{:}];
end
info = struct('ids', {{}}, 'expressions', {{}}, 'units', {{}}, 'notes', '');
if isempty(auxItems)
    return
end
ids = cell(1, numel(auxItems));
exprs = cell(1, numel(auxItems));
units = cell(1, numel(auxItems));
for i = 1:numel(auxItems)
    ids{i} = charIf(getField(auxItems{i}, 'id', ''), '');
    exprs{i} = charIf(getField(auxItems{i}, 'expression', ''), '');
    units{i} = charIf(getField(auxItems{i}, 'unit', ''), '');
    if isempty(ids{i}) || isempty(exprs{i})
        fail('代数变量缺少 id 或 expression');
    end
end
resolvedMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
remaining = true(1, numel(ids));
for pass = 1:numel(ids) + 1
    changed = false;
    for i = 1:numel(ids)
        if ~remaining(i), continue; end
        e = exprs{i};
        for j = 1:numel(ids)
            if i == j, continue; end
            if isKey(resolvedMap, ids{j})
                e = substituteId(e, ids{j}, resolvedMap(ids{j}));
            end
        end
        exprs{i} = e;
        deps = unresolvedDeps(e, ids, resolvedMap);
        if isempty(deps)
            if numel(e) > 20000
                fail('代数变量 "%s" 展开后超过 20000 字符，请拆分表达式', ids{i});
            end
            resolvedMap(ids{i}) = e;
            remaining(i) = false;
            changed = true;
        end
    end
    if ~any(remaining), break; end
    if ~changed
        cyc = strjoin(ids(remaining), ', ');
        error('bma:spec:spec_cycle', ...
            '代数变量存在循环依赖或引用了未知 id：%s。请检查 expression。', cyc);
    end
end
if any(remaining)
    error('bma:spec:spec_cycle', '代数变量无法解析：%s', strjoin(ids(remaining), ', '));
end
% substitute into all reaction/output expressions
for r = 1:numel(resolved.reactions)
    if isfield(resolved.reactions(r), 'rate') && isstruct(resolved.reactions(r).rate)
        rate = resolved.reactions(r).rate;
        if isfield(rate, 'expression') && ~isempty(rate.expression)
            e = char(rate.expression);
            ks = resolvedMap.keys;
            for k = 1:numel(ks)
                e = substituteId(e, ks{k}, resolvedMap(ks{k}));
            end
            if numel(e) > 20000
                fail('反应 "%s" 的 expression 展开后超过 20000 字符，请拆分或用更少代数变量', ...
                    char(resolved.reactions(r).id));
            end
            rate.expression = e;
            resolved.reactions(r).rate = rate;
        end
    end
end
for o = 1:numel(resolved.outputs)
    if isfield(resolved.outputs(o), 'expression') && ~isempty(resolved.outputs(o).expression)
        e = char(resolved.outputs(o).expression);
        ks = resolvedMap.keys;
        for k = 1:numel(ks)
            e = substituteId(e, ks{k}, resolvedMap(ks{k}));
        end
        resolved.outputs(o).expression = e;
    end
end
info.ids = ids;
info.expressions = exprs;
info.units = units;
info.notes = '代数变量已在编译期展开为 states/parameters 表达式';
end

function tf = localIsAlg(e)
tf = false;
try
    if isfield(e, 'kind') && strcmpi(charIf(getField(e, 'kind', ''), ''), 'algebraic')
        tf = true;
    elseif isfield(e, 'algebraic') && ~isempty(e.algebraic) && logical(e.algebraic)
        tf = true;
    end
catch
end
end

function out = substituteId(expr, id, replacement)
%SUBSTITUTEID Replace a bare identifier with a parenthesized expression.
pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', id) '(?![A-Za-z0-9_])'];
try
    out = regexprep(expr, pat, ['(' replacement ')']);
catch
    out = strrep(expr, id, ['(' replacement ')']);
end
end

function deps = unresolvedDeps(expr, ids, resolvedMap)
deps = {};
for k = 1:numel(ids)
    if isKey(resolvedMap, ids{k}), continue; end
    pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', ids{k}) '(?![A-Za-z0-9_])'];
    if ~isempty(regexp(expr, pat, 'once'))
        deps{end+1} = ids{k}; %#ok<AGROW>
    end
end
end

% =========================================================================
function refsMap = makeExpressionRefs(ctx)
refsMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
for i = 1:numel(ctx.speciesIds)
    refsMap(ctx.speciesIds{i}) = sprintf('y(%d)', i);
end
for j = 1:numel(ctx.paramIds)
    refsMap(ctx.paramIds{j}) = sprintf('p(%d)', j);
end
for k = 1:numel(ctx.compartmentIds)
    refsMap(ctx.compartmentIds{k}) = sprintf('%.17g', ctx.compartmentVolumes(k));
end
end

function c = charIf(v, default)
if ischar(v)
    c = v;
elseif isstring(v) && isscalar(v)
    c = char(v);
else
    c = default;
end
end

function fail(fmt, varargin)
error('bma:spec:spec_invalid', ['模型规格编译失败：' sprintf(fmt, varargin{:})]);
end
