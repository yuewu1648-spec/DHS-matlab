function report = validate(spec, workDir)
%VALIDATE 校验 bma.modelSpec.v1 模型规格（DESIGN §3 §4.4 §5.2）。
%   report = bma.spec.validate(spec)
%   report = bma.spec.validate(spec_path)
%   report = bma.spec.validate(spec, workDir)
%
% 输入 spec 可以是已解析的结构体，也可以是 JSON 文件路径；workDir 仅用于报错上下文
% 与相对路径显示（可缺省）。
%
% 返回 report（JSON 可编码）：
%   .valid            逻辑值，是否通过校验
%   .ok               同 .valid
%   .errors           cell，每项 {code,path,message,hint,severity}
%   .warnings         cell，同上（severity='warning'）
%   .n_errors/.n_warnings
%   .error_codes/.warning_codes : 去重后的错误码/警告码（cellstr）
%   .normalized_spec  归一化后的规格（可用 bma.spec.save 回写）
%   .summary          规格摘要（计数/时间轴/速率类型/估计参数清单）
%   .units_check      量纲检查结果（ok/dimensional_ok/issues/n_units_checked）
%   .conservation     守恒律概要（n_laws/stoich_rank/note；详细表达式由 model.analyze 给出）
%   .name             模型名
%   .elapsed_ms       耗时
%
% 错误码（节选）：BMA_SPEC_INVALID / BMA_SPEC_MISSING_FIELD / BMA_SPEC_INVALID_ID /
%   BMA_SPEC_DUPLICATE_ID / BMA_SPEC_UNKNOWN_ID / BMA_RATE_INVALID / BMA_STOICH_INVALID /
%   BMA_BOUNDS_INVALID / BMA_EVIDENCE_INVALID / BMA_OUTPUT_INVALID / BMA_DATASET_INVALID /
%   BMA_UNIT_MISSING（缺单位为 BMA_SPEC_MISSING_FIELD）/ BMA_UNIT_UNKNOWN / BMA_UNIT_MISMATCH（警告）。
%
% 本函数对“规格不合法”不抛异常，而是返回结构化错误，便于 agent 自纠错。
if nargin < 1
    spec = [];
end
t0 = tic;
if nargin < 2 || isempty(workDir)
    workDir = pwd; %#ok<NASGU>
end
errors = {};
warnings = {};
raw = spec;

% =========================================================================
% 1. 读取 / 基本类型
% =========================================================================
if ischar(raw) || isstring(raw)
    path = char(raw);
    if ~isfile(path)
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'spec', ...
            sprintf('无法读取模型规格文件：%s', path), ...
            '请确认文件路径是否存在（支持绝对路径或相对当前工作目录）。');
        report = buildReport(errors, warnings, struct(), emptyUnits(), emptyConservation(), '', t0);
        return
    end
    try
        raw = bma.spec.load(path);
    catch err
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'spec', ...
            ['JSON 解析失败：' err.message], ...
            '请检查 JSON 语法：引号/逗号/括号是否配对，文件编码应为 UTF-8（无 BOM）。');
        report = buildReport(errors, warnings, struct(), emptyUnits(), emptyConservation(), '', t0);
        return
    end
end
if ~isstruct(raw) || isempty(raw)
    errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'spec', ...
        '模型规格必须是非空 JSON 对象（结构体）', ...
        '请按 DESIGN §3 编写 bma.modelSpec.v1 规格：{"schema_version":"bma.modelSpec.v1","name":...}。');
    report = buildReport(errors, warnings, struct(), emptyUnits(), emptyConservation(), '', t0);
    return
end
if numel(raw) > 1
    errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'spec', ...
        '模型规格必须是单个对象，不能是数组', ...
        '请传入一个 bma.modelSpec.v1 对象。');
    report = buildReport(errors, warnings, struct(), emptyUnits(), emptyConservation(), '', t0);
    return
end

% =========================================================================
% 2. 顶层必填字段（在原始规格上检查，避免归一化掩盖缺失）
% =========================================================================
requiredTop = {'schema_version', 'name', 'kind', 'time', 'variables', 'parameters', 'reactions'};
for k = 1:numel(requiredTop)
    f = requiredTop{k};
    if strcmp(f, 'time') && isfield(raw, 'kind') && strcmpi(char(raw.kind), 'bvp') ...
            && isfield(raw, 'domain')
        % BVP uses a spatial domain instead of the IVP time axis.
        continue
    end
    if strcmp(f, 'reactions') && isfield(raw, 'kind') && strcmpi(char(raw.kind), 'dae')
        % DAE is specified by dae.residuals, not reaction stoichiometry.
        continue
    end
    if ~isfield(raw, f)
        errors{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', f, ...
            sprintf('缺少必填字段 "%s"', f), ...
            requiredHint(f)); %#ok<AGROW>
    end
end

% schema_version
if isfield(raw, 'schema_version')
    sv = raw.schema_version;
    if ~ischar(sv) || ~strcmp(sv, 'bma.modelSpec.v1')
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'schema_version', ...
            sprintf('不支持的 schema_version（应为 "bma.modelSpec.v1"，实际为 %s）', ...
                describeValue(sv)), ...
            'v1 只支持 "bma.modelSpec.v1"；请检查是否拼写错误或使用了更新版本。');
    end
end

% name
if isfield(raw, 'name')
    nm = raw.name;
    if ~ischar(nm) || isempty(nm)
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'name', ...
            '模型 name 必须是非空字符串', ...
            'name 用作目录名与代码函数名前缀，例如 "enzyme_mm"。');
    elseif isempty(regexp(nm, '^[A-Za-z][A-Za-z0-9_]*$', 'once'))
        errors{end+1} = makeIssue('BMA_SPEC_INVALID_ID', 'name', ...
            sprintf('模型 name "%s" 不是合法标识符', nm), ...
            'name 必须匹配 [A-Za-z][A-Za-z0-9_]*（以字母开头，仅字母/数字/下划线）。');
    end
end

% kind
isPde = false;
isDde = false;
isBvp = false;
isDae = false;
if isfield(raw, 'kind')
    kd = raw.kind;
    if ~ischar(kd) || isempty(kd)
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'kind', ...
            'kind 必须是非空字符串', '支持 "ode"、"pde"、"dde"、"bvp" 与 "dae"。');
    elseif ~any(strcmp(kd, {'ode', 'pde', 'dde', 'bvp', 'dae'}))
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'kind', ...
            sprintf('不支持的模型类型 kind="%s"', kd), ...
            '支持 "ode" / "pde" / "dde" / "bvp" / "dae"。');
    else
        isPde = strcmp(kd, 'pde');
        isDde = strcmp(kd, 'dde');
        isBvp = strcmp(kd, 'bvp');
        isDae = strcmp(kd, 'dae');
    end
end

% time
if isfield(raw, 'time')
    t = raw.time;
    if ~isstruct(t)
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'time', ...
            'time 必须是对象 {unit,start,end,n}', '例如 {"unit":"s","start":0,"end":60,"n":601}。');
    else
        tUnit = getField(t, 'unit', '');
        if ~ischar(tUnit) || isempty(strtrim(tUnit))
            errors{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', 'time.unit', ...
                'time.unit 缺失', '请补充时间单位，例如 "s" / "min" / "h" / "day"。');
        end
        [okStart, msgStart] = checkNumericScalar(getField(t, 'start', []));
        [okEnd, msgEnd] = checkNumericScalar(getField(t, 'end', []));
        [okN, msgN] = checkNumericScalar(getField(t, 'n', []));
        if ~okStart
            errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'time.start', ['time.start ' msgStart], ...
                '起始时间必须是数值，例如 0。');
        end
        if ~okEnd
            errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'time.end', ['time.end ' msgEnd], ...
                '终止时间必须是数值且大于起始时间，例如 60。');
        end
        if ~okN
            errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'time.n', ['time.n ' msgN], ...
                '采样点数必须是 >= 2 的整数，例如 601。');
        end
        if okStart && okEnd && t.start >= t.end
            errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'time', ...
                sprintf('time.start（%g）必须小于 time.end（%g）', t.start, t.end), ...
                '请调整时间轴范围。');
        end
        if okN && (t.n < 2 || t.n ~= round(t.n))
            errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'time.n', ...
                'time.n 必须是 >= 2 的整数', '建议取 101~2001，用于输出时间网格。');
        end
    end
end

% =========================================================================
% 3. 归一化
% =========================================================================
try
    norm = bma.spec.normalize(raw);
catch err
    errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'spec', ...
        ['规格归一化失败：' err.message], '请检查字段类型是否符合 DESIGN §3。');
    norm = struct();
    report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), '', t0);
    return
end

% -------------------------------------------------------------------------
% DAE：ode15i/decic 编译；残差数量必须等于状态数。
% -------------------------------------------------------------------------
if isDae
    try
        m = bma.dae.compile(norm);
    catch err
        errors{end+1} = makeIssue('BMA_DAE_INVALID', 'dae', ...
            ['DAE 编译失败：' err.message], ...
            '检查 dae.residuals（数量=变量数，导数写成 xdot）、初值与 time。');
        report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
            charIf(getField(norm, 'name', ''), ''), t0);
        return
    end
    report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
        charIf(getField(norm, 'name', ''), ''), t0);
    report.kind = 'dae';
    report.is_dae = true;
    report.dae = struct('n_residuals', m.n_residuals);
    report.normalized_spec = norm;
    if isfield(report, 'summary') && isstruct(report.summary)
        report.summary.kind = 'dae';
        report.summary.n_residuals = m.n_residuals;
        report.summary.solver = 'ode15i';
    end
    return
end

% -------------------------------------------------------------------------
% BVP：bvp4c 编译；domain/bc 在 bma.bvp.compile 中校验。
% -------------------------------------------------------------------------
if isBvp
    try
        m = bma.bvp.compile(norm);
    catch err
        errors{end+1} = makeIssue('BMA_BVP_INVALID', 'bvp', ...
            ['BVP 编译失败：' err.message], ...
            '检查 domain:{x0,x1,n}、bc（数量=变量数，side=left/right）与 expression 速率。');
        report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
            charIf(getField(norm, 'name', ''), ''), t0);
        return
    end
    report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
        charIf(getField(norm, 'name', ''), ''), t0);
    report.kind = 'bvp';
    report.is_bvp = true;
    report.bvp = struct('x0', m.domain.x0, 'x1', m.domain.x1, 'n', m.domain.n);
    report.normalized_spec = norm;
    if isfield(report, 'summary') && isstruct(report.summary)
        report.summary.kind = 'bvp';
        report.summary.domain = [m.domain.x0 m.domain.x1];
        report.summary.solver = 'bvp4c';
    end
    return
end

% -------------------------------------------------------------------------
% DDE：先尝试 dde23 编译；DDE 的表达式/延迟声明在 bma.dde.compile 中校验。
% -------------------------------------------------------------------------
if isDde
    try
        m = bma.dde.compile(norm);
    catch err
        errors{end+1} = makeIssue('BMA_DDE_INVALID', 'dde', ...
            ['DDE 编译失败：' err.message], ...
            '检查 delays:[{id,lag,unit}]、delay(S,tau) 表达式、time.unit 与变量/参数。');
        report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
            charIf(getField(norm, 'name', ''), ''), t0);
        return
    end
    report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
        charIf(getField(norm, 'name', ''), ''), t0);
    report.kind = 'dde';
    report.is_dde = true;
    report.dde = struct('delays', m.delays, 'delay_ids', {m.delay_ids}, ...
        'mode', m.mode);
    report.normalized_spec = norm;
    % ISSUE-007: do not present "skipped" as ok=false/checked=0. Report
    % applicable=false with an explicit reason; delay/unit structure has
    % already been checked by bma.dde.compile.
    report.units_check = bma.spec.checkUnits(norm);
    if isfield(report, 'summary') && isstruct(report.summary)
        report.summary.kind = 'dde';
        report.summary.n_delays = numel(m.delay_ids);
        if strcmp(m.mode, 'constant')
            report.summary.solver = 'dde23';
        elseif strcmp(m.mode, 'neutral')
            report.summary.solver = 'ddensd';
        else
            report.summary.solver = 'ddesd';
        end
    end
    return
end

% -------------------------------------------------------------------------
% PDE：先展开为等价 ODE，再复用完整的 ODE 校验/量纲/守恒检查。
% 返回的 normalized_spec 仍是 PDE 规格（下游 compile 会再次展开）。
% -------------------------------------------------------------------------
if isPde
    if ~isfield(norm, 'pde') || ~isstruct(norm.pde) || isempty(norm.pde)
        errors{end+1} = makeIssue('BMA_PDE_INVALID', 'pde', ...
            'kind="pde" 规格必须包含 pde 子树', ...
            '请按 {dim:1, domain:{geometry,extent,grid}, diffusion, bc, discretization} 编写。');
        report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
            charIf(getField(norm, 'name', ''), ''), t0);
        return
    end
    nativeDim = getField(norm.pde, 'dim', 1);
    nativeSolver = lower(charIf(getField(norm.pde, 'solver', ''), ''));
    if (isnumeric(nativeDim) && nativeDim >= 2) || strcmp(nativeSolver, 'toolbox')
        % 2D native PDE Toolbox path: no MOL expansion; validate its own
        % geometry/mesh/bc/coefficient surface. Simulation goes through
        % bma.pde.simulate (bma_pde_simulate tool).
        report = bma.pde.validate(norm);
        report.normalized_spec = norm;
        return
    end
    try
        expanded = bma.spec.pde.expand(norm);
    catch err
        errors{end+1} = makeIssue(pdeErrorCode(err), 'pde', ...
            ['PDE 展开失败：' err.message], ...
            '检查 geometry/extent/grid/diffusion/bc/outputs 的 C[i] 与统计量语法；v1 仅 1D slab/cylinder/sphere。');
        report = buildReport(errors, warnings, norm, emptyUnits(), emptyConservation(), ...
            charIf(getField(norm, 'name', ''), ''), t0);
        return
    end
    rep = bma.spec.validate(expanded, workDir);
    rep.normalized_spec = norm;
    rep.kind = 'pde';
    rep.pde = norm.pde;
    rep.is_pde = true;
    if isfield(expanded, 'metadata') && isfield(expanded.metadata, 'pde')
        rep.pde_meta = expanded.metadata.pde;
        if isfield(expanded.metadata.pde, 'n')
            rep.n_species_pde = numel(norm.variables);
            rep.n_nodes = expanded.metadata.pde.n;
        end
    end
    if isstruct(rep.summary)
        rep.summary.kind = 'pde';
        rep.summary.n_pde_species = numel(norm.variables);
        if isfield(expanded, 'metadata') && isfield(expanded.metadata, 'pde')
            rep.summary.pde_geometry = expanded.metadata.pde.geometry;
            rep.summary.pde_n = expanded.metadata.pde.n;
        end
    end
    report = rep;
    return
end

varItems = itemize(getField(norm, 'variables', []));
parItems = itemize(getField(norm, 'parameters', []));
compItems = itemize(getField(norm, 'compartments', []));
reacItems = itemize(getField(norm, 'reactions', []));
outItems = itemize(getField(norm, 'outputs', []));
rawVars = itemize(getField(raw, 'variables', []));
rawParams = itemize(getField(raw, 'parameters', []));

if isempty(varItems)
    if isfield(raw, 'variables')
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'variables', ...
            'variables 不能为空', '至少定义一个状态变量（物种），例如 {"id":"S","name":"底物","unit":"uM","initial":{"value":10}}。');
    end
end
if isempty(reacItems) && isfield(raw, 'reactions')
    errors{end+1} = makeIssue('BMA_SPEC_INVALID', 'reactions', ...
        'reactions 不能为空', '至少定义一个反应（通量），例如 mass_action 结合反应。');
end
if isfield(raw, 'parameters') && isempty(parItems)
    warnings{end+1} = makeIssue('BMA_SPEC_WARN_NO_PARAMS', 'parameters', ...
        '模型没有任何参数（parameters 为空）', ...
        '若速率定律中需要参数，请补充 parameters 并在 rate.parameters 中引用。', 'warning');
end

% =========================================================================
% 4. 全局 id 合法性 / 唯一性
% =========================================================================
idMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
[idMap, errors] = checkIdList(varItems, 'variables', idMap, errors);
[idMap, errors] = checkIdList(parItems, 'parameters', idMap, errors);
[idMap, errors] = checkIdList(compItems, 'compartments', idMap, errors);
varIds = entityIds(varItems);
parIds = entityIds(parItems);
compIds = entityIds(compItems);

varIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for i = 1:numel(varIds)
    if ~isempty(varIds{i})
        varIndex(varIds{i}) = i;
    end
end
parIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:numel(parIds)
    if ~isempty(parIds{j})
        parIndex(parIds{j}) = j;
    end
end

% =========================================================================
% 5. 变量检查
% =========================================================================
for i = 1:numel(varItems)
    e = varItems{i};
    id = charIf(getField(e, 'id', ''), '');
    p0 = sprintf('variables[%d]', i-1);
    isAlg = isAlgebraicVar(e);
    if isAlg
        expr = charIf(getField(e, 'expression', ''), '');
        if isempty(expr)
            errors{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', [p0 '.expression'], ...
                sprintf('代数变量 "%s" 缺少 expression', id), ...
                '代数变量必须写成 {"id":"...","kind":"algebraic","unit":"...","expression":"..."}；只引用 states/params/其他代数变量。'); %#ok<AGROW>
        end
        if isfield(e, 'initial') && isfield(e.initial, 'value') && ~isempty(e.initial.value)
            warnings{end+1} = makeIssue('BMA_SPEC_WARN_ALG_INITIAL', [p0 '.initial'], ...
                sprintf('代数变量 "%s" 的 initial 不会参与求解，已忽略', id), ...
                '代数变量由 expression 决定，不是 ODE 状态。', 'warning'); %#ok<AGROW>
        end
        continue
    end
    ini = getField(e, 'initial', struct());
    rawHasInitial = (i <= numel(rawVars)) && isstruct(rawVars{i}) && isfield(rawVars{i}, 'initial');
    if ~rawHasInitial
        warnings{end+1} = makeIssue('BMA_SPEC_WARN_NO_INITIAL', [p0 '.initial'], ...
            sprintf('变量 "%s" 未提供初值，已按 0 处理', id), ...
            '建议显式给出 initial.value（如 {"value":10}），便于拟合与报告追溯。', 'warning'); %#ok<AGROW>
    end
    v = [];
    if isstruct(ini)
        v = getField(ini, 'value', []);
    end
    if isstruct(ini) && isfield(ini, 'param') && ~isempty(ini.param)
        pid = charIf(ini.param, '');
        if isempty(pid) || ~isKey(parIndex, pid)
            errors{end+1} = makeIssue('BMA_SPEC_UNKNOWN_ID', [p0 '.initial.param'], ...
                sprintf('变量 "%s" 的 initial.param 引用了未定义参数 "%s"', id, pid), ...
                'initial 可以写 {"param":"<parameters[].id>"} 或 {"expression":"..."}。'); %#ok<AGROW>
        end
    elseif isstruct(ini) && isfield(ini, 'expression') && ~isempty(ini.expression)
        try
            parseExpression(char(ini.expression), makeParamRefs(parIds));
        catch err
            errors{end+1} = makeIssue('BMA_SPEC_INVALID', [p0 '.initial.expression'], ...
                sprintf('变量 "%s" 的 initial.expression 无法编译：%s', id, err.message), ...
                'initial.expression 只能引用 parameters（不能引用状态变量）。'); %#ok<AGROW>
        end
    elseif isempty(v)
        if rawHasInitial
            errors{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', [p0 '.initial.value'], ...
                sprintf('变量 "%s" 的 initial 缺少 value 数值（或 param/expression）', id), ...
                '请写成 {"initial":{"value":10}} 或 {"initial":{"param":"p0"}}。'); %#ok<AGROW>
        end
    elseif ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', [p0 '.initial.value'], ...
            sprintf('变量 "%s" 的初值必须是有限数值', id), ...
            '例如 {"initial":{"value":10}}。'); %#ok<AGROW>
    end
    comp = charIf(getField(e, 'compartment', ''), '');
    if ~isempty(comp) && ~any(strcmp(compIds, comp))
        errors{end+1} = makeIssue('BMA_SPEC_UNKNOWN_ID', [p0 '.compartment'], ...
            sprintf('变量 "%s" 引用了不存在的隔室 "%s"', id, comp), ...
            sprintf('可用隔室 id：%s。请检查拼写或在 compartments 中补定义。', shortList(compIds))); %#ok<AGROW>
    end
end

% =========================================================================
% 6. 参数检查
% =========================================================================
topEvidence = getField(norm, 'evidence', []);
hasTopEvidence = ~isempty(itemize(topEvidence));
for j = 1:numel(parItems)
    e = parItems{j};
    id = charIf(getField(e, 'id', ''), '');
    p0 = sprintf('parameters[%d]', j-1);
    val = getField(e, 'value', struct());
    v = getField(val, 'value', []);
    valueOk = isnumeric(v) && isscalar(v) && isfinite(v);
    if isempty(v)
        errors{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', [p0 '.value'], ...
            sprintf('参数 "%s" 缺少 value.value 数值', id), ...
            '请写成 {"value":{"value":0.5}}（或省略外层，直接给数值）。'); %#ok<AGROW>
    elseif ~valueOk
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', [p0 '.value.value'], ...
            sprintf('参数 "%s" 的 value.value 必须是有限数值', id), ...
            '例如 {"value":{"value":0.5}}。'); %#ok<AGROW>
    end
    est = getField(e, 'estimate', false);
    if ~islogical(est) || ~isscalar(est)
        errors{end+1} = makeIssue('BMA_SPEC_INVALID', [p0 '.estimate'], ...
            sprintf('参数 "%s" 的 estimate 必须是 true/false', id), ...
            'estimate 表示是否参与参数估计；不需要拟合的固定参数写 false 或省略。'); %#ok<AGROW>
        est = false;
    end
    b = getField(e, 'bounds', []);
    boundsOk = true;
    if ~isempty(b)
        if ~isnumeric(b) || numel(b) ~= 2 || ~all(isfinite(b))
            errors{end+1} = makeIssue('BMA_BOUNDS_INVALID', [p0 '.bounds'], ...
                sprintf('参数 "%s" 的 bounds 必须是两个有限数值 [lb, ub]', id), ...
                '例如 {"bounds":[0.001,100]}。'); %#ok<AGROW>
            boundsOk = false;
        elseif b(1) >= b(2)
            errors{end+1} = makeIssue('BMA_BOUNDS_INVALID', [p0 '.bounds'], ...
                sprintf('参数 "%s" 的 bounds 下界必须小于上界（当前 [%g, %g]）', id, b(1), b(2)), ...
                '例如 {"bounds":[0.001,100]}。'); %#ok<AGROW>
            boundsOk = false;
        elseif valueOk && (v < b(1) || v > b(2))
            errors{end+1} = makeIssue('BMA_BOUNDS_INVALID', [p0], ...
                sprintf('参数 "%s" 的当前值 %g 不在 bounds [%g, %g] 之内', id, v, b(1), b(2)), ...
                '请调整初值或 bounds，使其覆盖初值（拟合起点必须可行）。'); %#ok<AGROW>
        end
    end
    if ~isempty(b) && ~est
        warnings{end+1} = makeIssue('BMA_SPEC_WARN_BOUNDS_UNUSED', [p0 '.bounds'], ...
            sprintf('参数 "%s" 的 estimate=false：bounds 不参与拟合，但仍会作为敏感性/Sobol 抽样范围', id), ...
            '需要参与拟合时设 estimate:true；作为固定参数保留 bounds 是有意义的（全局敏感性需要）。', 'warning'); %#ok<AGROW>
    end
    if est && valueOk && j <= numel(rawParams) && ~isfield(rawParams{j}, 'bounds')
        defaultB = getField(e, 'bounds', []);
        if numel(defaultB) == 2
            warnings{end+1} = makeIssue('BMA_SPEC_WARN_NO_BOUNDS', [p0 '.bounds'], ...
                sprintf('估计参数 "%s" 未提供 bounds，已使用默认范围 [%g, %g]', ...
                    id, defaultB(1), defaultB(2)), ...
                '建议显式给出物理合理的参数范围，例如 {"bounds":[0.001,100]}。', 'warning'); %#ok<AGROW>
        end
    end
    % 证据
    ev = getField(e, 'evidence', []);
    [eErr, eWarn] = checkEvidenceList(ev, [p0 '.evidence']);
    errors = [errors, eErr]; %#ok<AGROW>
    warnings = [warnings, eWarn]; %#ok<AGROW>
    if est && isempty(itemize(ev)) && ~hasTopEvidence
        warnings{end+1} = makeIssue('BMA_SPEC_WARN_NO_EVIDENCE', p0, ...
            sprintf('估计参数 "%s" 没有任何证据（evidence）', id), ...
            '请在参数上补 evidence（type/quote），类型取 measured/estimated/assumed/fitted；文献证据是溯源硬约束。', 'warning'); %#ok<AGROW>
    end
end

% =========================================================================
% 7. 反应检查（化学计量 + 速率定律）
% =========================================================================
ctx = struct( ...
    'speciesIds', {varIds}, ...
    'paramIds', {parIds}, ...
    'compartmentIds', {compIds}, ...
    'speciesIndex', varIndex, ...
    'paramIndex', parIndex, ...
    'compartmentVolumes', compartmentVolumes(compItems));
rateKinds = {};
for i = 1:numel(reacItems)
    e = reacItems{i};
    rid = charIf(getField(e, 'id', ''), '');
    p0 = sprintf('reactions[%d]', i-1);
    stoich = getField(e, 'stoichiometry', struct());
    if ~isstruct(stoich) || isempty(fieldnames(stoich))
        errors{end+1} = makeIssue('BMA_STOICH_INVALID', [p0 '.stoichiometry'], ...
            sprintf('反应 "%s" 缺少化学计量 stoichiometry', rid), ...
            '请写成物种 id → 系数（产物为正、反应物为负），例如 {"E":-1,"S":-1,"ES":1}。'); %#ok<AGROW>
    else
        fn = fieldnames(stoich);
        for k = 1:numel(fn)
            sid = fn{k};
            coef = stoich.(sid);
            if ~isKey(varIndex, sid)
                errors{end+1} = makeIssue('BMA_SPEC_UNKNOWN_ID', [p0 '.stoichiometry.' sid], ...
                    sprintf('反应 "%s" 的化学计量引用了不存在的物种 "%s"', rid, sid), ...
                    sprintf('可用物种 id：%s。请检查拼写或在 variables 中补定义。', shortList(varIds))); %#ok<AGROW>
                continue
            end
            if ~isnumeric(coef) || ~isscalar(coef) || ~isfinite(coef) || coef == 0
                errors{end+1} = makeIssue('BMA_STOICH_INVALID', [p0 '.stoichiometry.' sid], ...
                    sprintf('反应 "%s" 中物种 "%s" 的化学计量系数必须是非零有限数值', rid, sid), ...
                    '反应物用负数、产物用正数，例如 -1、1、2。'); %#ok<AGROW>
            end
        end
    end
    % 速率定律
    rate = getField(e, 'rate', []);
    r = rateParse(rate, ctx);
    if ~isempty(r.kind)
        rateKinds{end+1} = r.kind; %#ok<AGROW>
    end
    for k = 1:numel(r.issues)
        iss = r.issues{k};
        path = [p0 '.rate'];
        if isfield(iss, 'subpath') && ~isempty(iss.subpath)
            path = [path '.' iss.subpath];
        end
        errors{end+1} = makeIssue(iss.code, path, iss.message, iss.hint); %#ok<AGROW>
    end
    for k = 1:numel(r.warnings)
        iss = r.warnings{k};
        path = [p0 '.rate'];
        if isfield(iss, 'subpath') && ~isempty(iss.subpath)
            path = [path '.' iss.subpath];
        end
        warnings{end+1} = makeIssue(iss.code, path, iss.message, iss.hint, 'warning'); %#ok<AGROW>
    end
end

% =========================================================================
% 8. 输出检查
% =========================================================================
rawOutputs = getField(raw, 'outputs', []);
if isempty(rawOutputs)
    warnings{end+1} = makeIssue('BMA_SPEC_WARN_NO_OUTPUTS', 'outputs', ...
        '未提供 outputs，已自动用 variables 作为观测量', ...
        '建议显式定义 outputs（拟合与报告需要），例如 {"id":"P_obs","unit":"uM","expression":"P"}。', 'warning');
end
refsMap = makeExpressionRefs(ctx);
outIds = {};
for o = 1:numel(outItems)
    e = outItems{o};
    oid = charIf(getField(e, 'id', ''), '');
    p0 = sprintf('outputs[%d]', o-1);
    if any(strcmp(outIds, oid))
        errors{end+1} = makeIssue('BMA_SPEC_DUPLICATE_ID', [p0 '.id'], ...
            sprintf('输出 id "%s" 重复', oid), ...
            '同一规格内 outputs[].id 必须唯一。'); %#ok<AGROW>
    end
    outIds{end+1} = oid; %#ok<AGROW>
    if isempty(oid) || isempty(regexp(oid, '^[A-Za-z][A-Za-z0-9_]*$', 'once'))
        errors{end+1} = makeIssue('BMA_SPEC_INVALID_ID', [p0 '.id'], ...
            sprintf('输出 id "%s" 不是合法标识符', oid), ...
            '输出 id 必须匹配 [A-Za-z][A-Za-z0-9_]*。'); %#ok<AGROW>
    end
    expr = charIf(getField(e, 'expression', ''), '');
    if isempty(strtrim(expr))
        errors{end+1} = makeIssue('BMA_OUTPUT_INVALID', [p0 '.expression'], ...
            sprintf('输出 "%s" 缺少 expression', oid), ...
            'expression 可以是变量 id（如 "P"）或受限表达式（如 "S+ES+P"）。'); %#ok<AGROW>
    else
        try
            parseExpression(expr, refsMap);
        catch err
            [codeId, msg, hint] = mapOutputExprError(err);
            errors{end+1} = makeIssue(codeId, [p0 '.expression'], msg, hint); %#ok<AGROW>
        end
    end
end

% =========================================================================
% 9. 数据集检查
% =========================================================================
dsItems = itemize(getField(norm, 'datasets', []));
for i = 1:numel(dsItems)
    e = dsItems{i};
    did = charIf(getField(e, 'id', ''), '');
    p0 = sprintf('datasets[%d]', i-1);
    tvec = getField(e, 'time', []);
    if ~isnumeric(tvec) || isempty(tvec) || any(~isfinite(tvec))
        errors{end+1} = makeIssue('BMA_DATASET_INVALID', [p0 '.time'], ...
            sprintf('数据集 "%s" 的 time 必须是非空有限数值向量', did), ...
            'time 为时间列（数值），其长度应与 columns 中各列一致。'); %#ok<AGROW>
        continue
    end
    cols = getField(e, 'columns', struct());
    if ~isstruct(cols) || isempty(fieldnames(cols))
        errors{end+1} = makeIssue('BMA_DATASET_INVALID', [p0 '.columns'], ...
            sprintf('数据集 "%s" 缺少 columns', did), ...
            'columns 形如 {"P_obs":[0,1.2,...]}，键应引用 outputs 的 id。'); %#ok<AGROW>
        continue
    end
    fn = fieldnames(cols);
    for k = 1:numel(fn)
        name = fn{k};
        col = cols.(name);
        if ~isnumeric(col)
            errors{end+1} = makeIssue('BMA_DATASET_INVALID', [p0 '.columns.' name], ...
                sprintf('数据集 "%s" 的列 "%s" 必须是数值向量', did, name), ...
                'CSV/内联数据列应为数值（缺失值用 NaN）。'); %#ok<AGROW>
        elseif numel(col) ~= numel(tvec)
            errors{end+1} = makeIssue('BMA_DATASET_INVALID', [p0 '.columns.' name], ...
                sprintf('数据集 "%s" 的列 "%s" 长度（%d）与 time 长度（%d）不一致', ...
                    did, name, numel(col), numel(tvec)), ...
                '请对齐时间列与数据列的长度。'); %#ok<AGROW>
        end
        if ~any(strcmp(outIds, name)) && ~isKey(varIndex, name)
            warnings{end+1} = makeIssue('BMA_DATASET_INVALID', [p0 '.columns.' name], ...
                sprintf('数据集列 "%s" 未对应任何 output 或变量 id', name), ...
                '建议列名与 outputs[].id 一致，便于 fit 使用 output_map 匹配。', 'warning'); %#ok<AGROW>
        end
    end
end

% =========================================================================
% 10. 假设 / 顶层证据 / metadata
% =========================================================================
assumptions = getField(norm, 'assumptions', {});
if isempty(itemize(assumptions)) && isempty(assumptions)
    warnings{end+1} = makeIssue('BMA_SPEC_WARN_NO_ASSUMPTIONS', 'assumptions', ...
        '未提供建模假设 assumptions', ...
        '报告会强制列出假设，建议补充中文建模假设（充分混合、恒温恒容、准稳态近似等）。', 'warning');
else
    as = toCellstr(assumptions);
    for k = 1:numel(as)
        if isempty(strtrim(as{k}))
            warnings{end+1} = makeIssue('BMA_SPEC_WARN_EMPTY_ASSUMPTION', sprintf('assumptions[%d]', k-1), ...
                '存在空的建模假设条目', '请填写具体假设内容或删除该条目。', 'warning'); %#ok<AGROW>
        end
    end
end
[eErr, eWarn] = checkEvidenceList(topEvidence, 'evidence');
errors = [errors, eErr]; %#ok<AGROW>
warnings = [warnings, eWarn]; %#ok<AGROW>
md = getField(norm, 'metadata', struct());
if ~isstruct(md)
    warnings{end+1} = makeIssue('BMA_SPEC_WARN_METADATA', 'metadata', ...
        'metadata 应为对象', 'metadata 可放 source_docs、agent_notes 等自由字段。', 'warning');
end

% =========================================================================
% 11. 量纲检查
% =========================================================================
uc = emptyUnits();
try
    uc = checkUnitsCore(norm);
catch err
    warnings{end+1} = makeIssue('BMA_SPEC_WARN_UNIT_CHECK_FAILED', 'units', ...
        ['量纲检查执行失败：' err.message], ...
        '请检查单位字符串是否合法；该失败不影响其他校验项。', 'warning');
end
if ~isempty(uc.errors)
    errors = [errors, uc.errors]; %#ok<AGROW>
end
if ~isempty(uc.warnings)
    warnings = [warnings, uc.warnings]; %#ok<AGROW>
end

% =========================================================================
% 12. 守恒律概要（详细表达式由 bma.model.analyze 给出）
% =========================================================================
cons = emptyConservation();
try
    cons = conservationSummary(varIds, reacItems);
catch
    cons = emptyConservation();
end

% =========================================================================
% 13. 汇总
% =========================================================================
name = '';
if isfield(norm, 'name') && ischar(norm.name)
    name = norm.name;
end
report = buildReport(errors, warnings, norm, uc, cons, name, t0);
end

% =========================================================================
% 报告构建与辅助函数
% =========================================================================
function report = buildReport(errors, warnings, norm, uc, cons, name, t0)
report = struct();
report.schema_version = 'bma.spec.validation.v1';
report.valid = isempty(errors);
report.ok = report.valid;
report.name = name;
report.n_errors = numel(errors);
report.n_warnings = numel(warnings);
report.errors = shapeIssues(errors);
report.warnings = shapeIssues(warnings);
report.error_codes = uniqueCodes(errors);
report.warning_codes = uniqueCodes(warnings);
report.normalized_spec = norm;
report.summary = summarizeSpec(norm);
report.units_check = uc;
report.conservation = cons;
report.elapsed_ms = round(toc(t0) * 1000);
end

function items = shapeIssues(items)
if isempty(items)
    items = {};
else
    items = reshape(items, 1, []);
end
end

function codes = uniqueCodes(items)
codes = {};
for k = 1:numel(items)
    codes{end+1} = items{k}.code; %#ok<AGROW>
end
codes = unique(codes, 'stable');
end

function uc = emptyUnits()
uc = struct('checked', false, 'ok', false, 'dimensional_ok', false, ...
    'n_units_checked', 0, 'issues', {{}}, 'errors', {{}}, 'warnings', {{}}, ...
    'n_errors', 0, 'n_warnings', 0, ...
    'note', '量纲检查未执行（规格结构不完整）。');
end

function cons = emptyConservation()
cons = struct('n_laws', 0, 'stoich_rank', 0, ...
    'note', '守恒律检查未执行或化学计量不完整。');
end

function cons = conservationSummary(varIds, reacItems)
nS = numel(varIds);
nR = numel(reacItems);
S = zeros(nS, nR);
for r = 1:nR
    stoich = getField(reacItems{r}, 'stoichiometry', struct());
    if ~isstruct(stoich)
        continue
    end
    fn = fieldnames(stoich);
    for k = 1:numel(fn)
        idx = find(strcmp(varIds, fn{k}), 1);
        coef = stoich.(fn{k});
        if ~isempty(idx) && isnumeric(coef) && isscalar(coef) && isfinite(coef)
            S(idx, r) = coef;
        end
    end
end
r = rank(S);
cons = struct();
cons.n_laws = max(0, nS - r);
cons.stoich_rank = r;
cons.n_species = nS;
cons.n_reactions = nR;
if cons.n_laws > 0
    cons.note = sprintf('检测到 %d 个独立守恒律（S 矩阵秩 %d，物种数 %d）。守恒量表达式请调用 bma.model.analyze。', ...
        cons.n_laws, r, nS);
else
    cons.note = '未检测到线性守恒律（或化学计量信息不足）。';
end
end

function s = summarizeSpec(norm)
s = struct();
s.schema_version = '';
s.name = '';
s.title = '';
s.kind = '';
s.n_species = 0;
s.n_parameters = 0;
s.n_estimated_parameters = 0;
s.n_reactions = 0;
s.n_outputs = 0;
s.n_compartments = 0;
s.n_assumptions = 0;
s.n_evidence = 0;
s.state_dim = 0;
s.time = struct('unit', '', 'start', [], 'end', [], 'n', []);
s.species = {{}};
s.parameters = {{}};
s.estimated = {{}};
s.outputs = {{}};
s.compartments = {{}};
s.rate_kinds = {{}};
s.has_datasets = false;
s.has_evidence = false;
if ~isstruct(norm) || isempty(norm)
    return
end
s.schema_version = charIf(getField(norm, 'schema_version', ''), '');
s.name = charIf(getField(norm, 'name', ''), '');
s.title = charIf(getField(norm, 'title', ''), '');
s.kind = charIf(getField(norm, 'kind', ''), '');
vars = itemize(getField(norm, 'variables', []));
pars = itemize(getField(norm, 'parameters', []));
reacs = itemize(getField(norm, 'reactions', []));
comps = itemize(getField(norm, 'compartments', []));
outs = itemize(getField(norm, 'outputs', []));
s.n_species = 0;
s.n_algebraic = 0;
isAlgFlags = false(1, numel(vars));
for vi = 1:numel(vars)
    isAlgFlags(vi) = isAlgebraicVar(vars{vi});
end
s.n_species = sum(~isAlgFlags);
s.n_algebraic = sum(isAlgFlags);
s.n_parameters = numel(pars);
s.n_reactions = numel(reacs);
s.n_outputs = numel(outs);
s.n_compartments = numel(comps);
s.state_dim = s.n_species;
s.n_assumptions = numel(toCellstr(getField(norm, 'assumptions', {})));
s.n_evidence = numel(itemize(getField(norm, 'evidence', [])));
s.species = entityIds(vars);
s.parameters = entityIds(pars);
s.outputs = entityIds(outs);
s.compartments = entityIds(comps);
est = {};
kinds = {};
for j = 1:numel(pars)
    e = pars{j};
    if islogical(getField(e, 'estimate', false)) && getField(e, 'estimate', false)
        est{end+1} = charIf(getField(e, 'id', ''), ''); %#ok<AGROW>
    end
    ev = itemize(getField(e, 'evidence', []));
    s.n_evidence = s.n_evidence + numel(ev);
end
for r = 1:numel(reacs)
    rk = charIf(getField(getField(reacs{r}, 'rate', struct()), 'kind', ''), '');
    if ~isempty(rk)
        kinds{end+1} = lower(rk); %#ok<AGROW>
    end
end
s.estimated = est;
s.rate_kinds = unique(kinds);
s.n_estimated_parameters = numel(est);
t = getField(norm, 'time', struct());
s.time = struct('unit', charIf(getField(t, 'unit', ''), ''), ...
    'start', getField(t, 'start', []), 'end', getField(t, 'end', []), ...
    'n', getField(t, 'n', []));
ds = itemize(getField(norm, 'datasets', []));
s.has_datasets = ~isempty(ds);
s.has_evidence = s.n_evidence > 0;
end

function [idMap, errors] = checkIdList(items, prefix, idMap, errors)
for i = 1:numel(items)
    e = items{i};
    id = charIf(getField(e, 'id', ''), '');
    p0 = sprintf('%s[%d]', prefix, i-1);
    if isempty(id)
        errors{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', [p0 '.id'], ...
            sprintf('%s[%d] 缺少 id', prefix, i-1), ...
            '每个实体必须有合法 id（字母开头，仅字母/数字/下划线）。'); %#ok<AGROW>
        continue
    end
    if isempty(regexp(id, '^[A-Za-z][A-Za-z0-9_]*$', 'once'))
        errors{end+1} = makeIssue('BMA_SPEC_INVALID_ID', [p0 '.id'], ...
            sprintf('%s id "%s" 不是合法标识符', prefix, id), ...
            'id 必须匹配 [A-Za-z][A-Za-z0-9_]*（字母开头，仅字母/数字/下划线），用作 MATLAB 变量/表达式标识符。'); %#ok<AGROW>
    end
    if isKey(idMap, id)
        errors{end+1} = makeIssue('BMA_SPEC_DUPLICATE_ID', [p0 '.id'], ...
            sprintf('id "%s" 重复（已被 %s 使用）', id, idMap(id)), ...
            'variables / parameters / compartments 的 id 必须全局唯一，避免速率表达式歧义。'); %#ok<AGROW>
    else
        idMap(id) = sprintf('%s[%d]', prefix, i-1);
    end
end
end

function ids = entityIds(items)
ids = cell(1, numel(items));
for i = 1:numel(items)
    ids{i} = charIf(getField(items{i}, 'id', ''), '');
end
end

function vols = compartmentVolumes(items)
vols = nan(1, numel(items));
for i = 1:numel(items)
    v = getField(items{i}, 'volume', 1);
    if isnumeric(v) && isscalar(v)
        vols(i) = v;
    end
end
end

function code = pdeErrorCode(err)
code = 'BMA_PDE_INVALID';
id = '';
try
    if isa(err, 'MException')
        id = char(err.identifier);
    elseif isfield(err, 'identifier')
        id = char(err.identifier);
    end
catch
end
if startsWith(id, 'bma:pde:')
    code = ['BMA_PDE_' upper(regexprep(id(numel('bma:pde:') + 1:end), '[^A-Za-z0-9_]', '_'))];
end
end

function refs = makeParamRefs(parIds)
refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
for j = 1:numel(parIds)
    if ~isempty(parIds{j})
        refs(parIds{j}) = sprintf('p(%d)', j);
    end
end
end

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

function [eErr, eWarn] = checkEvidenceList(ev, basePath)
eErr = {};
eWarn = {};
items = itemize(ev);
allowed = {'measured', 'estimated', 'assumed', 'fitted'};
for k = 1:numel(items)
    e = items{k};
    p0 = sprintf('%s[%d]', basePath, k-1);
    if ~isstruct(e)
        eErr{end+1} = makeIssue('BMA_EVIDENCE_INVALID', p0, ...
            '证据条目必须是对象 {type,quote,...}', ...
            '例如 {"type":"measured","quote":"Km = 12.5 µM","section_id":"s3","source":"Fig.2"}。'); %#ok<AGROW>
        continue
    end
    typ = charIf(getField(e, 'type', ''), '');
    if isempty(typ)
        eErr{end+1} = makeIssue('BMA_EVIDENCE_INVALID', [p0 '.type'], ...
            '证据条目缺少 type', ...
            'type 取 measured（实测）/ estimated（文献估计）/ assumed（假设）/ fitted（拟合）。'); %#ok<AGROW>
    elseif ~any(strcmp(typ, allowed))
        eErr{end+1} = makeIssue('BMA_EVIDENCE_INVALID', [p0 '.type'], ...
            sprintf('证据类型 "%s" 不合法', typ), ...
            'type 只能是 measured / estimated / assumed / fitted。'); %#ok<AGROW>
    end
    quote = charIf(getField(e, 'quote', ''), '');
    if isempty(strtrim(quote))
        eErr{end+1} = makeIssue('BMA_EVIDENCE_INVALID', [p0 '.quote'], ...
            '证据条目缺少 quote（原文引文）', ...
            '溯源是硬约束：请填写文献原文片段，并给出 section_id/source。'); %#ok<AGROW>
    end
    if ~isempty(getField(e, 'section_id', '')) && ~ischar(getField(e, 'section_id', ''))
        eWarn{end+1} = makeIssue('BMA_EVIDENCE_INVALID', [p0 '.section_id'], ...
            'section_id 应为字符串', '例如 "s3" 或 "Methods"。', 'warning'); %#ok<AGROW>
    end
    if ~isempty(getField(e, 'source', '')) && ~ischar(getField(e, 'source', ''))
        eWarn{end+1} = makeIssue('BMA_EVIDENCE_INVALID', [p0 '.source'], ...
            'source 应为字符串', '例如 "Fig. 2" 或文献标题。', 'warning'); %#ok<AGROW>
    end
end
end

function hint = requiredHint(field)
switch field
    case 'schema_version'
        hint = '请写 "schema_version": "bma.modelSpec.v1"。';
    case 'name'
        hint = '提供英文模型 id，例如 "name": "enzyme_mm"（字母开头，仅字母/数字/下划线）。';
    case 'kind'
        hint = 'v1 仅支持 "kind": "ode"。';
    case 'time'
        hint = '提供仿真时间轴，例如 {"unit":"s","start":0,"end":60,"n":601}。';
    case 'variables'
        hint = '至少定义一个状态变量，例如 {"id":"S","name":"底物","unit":"uM","initial":{"value":10}}。';
    case 'parameters'
        hint = '提供参数列表（可以为空数组 []），例如 [{"id":"kf","name":"结合速率","unit":"1/(uM*s)","value":{"value":0.5},"estimate":true,"bounds":[0.001,100]}]。';
    case 'reactions'
        hint = '至少定义一个反应，例如 {"id":"bind","stoichiometry":{"E":-1,"S":-1,"ES":1},"rate":{"kind":"mass_action","parameters":{"k":"kf"},"species":{"E":1,"S":1}}}。';
    otherwise
        hint = '请参考 docs/DESIGN.md §3 的 bma.modelSpec.v1 字段说明。';
end
end

function [ok, msg] = checkNumericScalar(v)
ok = isnumeric(v) && isscalar(v) && isfinite(v);
if ok
    msg = '';
    return
end
if isempty(v)
    msg = '缺失';
else
    msg = '必须是有限数值';
end
end

function s = describeValue(v)
if ischar(v)
    s = ['"' v '"'];
else
    try
        s = char(jsonencode(v));
    catch
        s = class(v);
    end
end
end

function [codeId, msg, hint] = mapOutputExprError(err)
if strcmp(err.identifier, 'bma:expr:unknown_id')
    codeId = 'BMA_SPEC_UNKNOWN_ID';
    msg = err.message;
    hint = '输出表达式只能引用 variables / parameters / compartments 的 id。';
elseif strcmp(err.identifier, 'bma:expr:forbidden')
    codeId = 'BMA_OUTPUT_INVALID';
    msg = err.message;
    hint = '只允许 + - * / ^ 与 exp/log/sqrt/min/max。';
else
    codeId = 'BMA_OUTPUT_INVALID';
    msg = ['输出表达式语法错误：' err.message];
    hint = '请检查括号、运算符与数字格式，例如 "S+ES+P"。';
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

function s = shortList(ids)
if isempty(ids)
    s = '（无）';
elseif numel(ids) <= 12
    s = strjoin(ids, ', ');
else
    s = [strjoin(ids(1:12), ', ') ', ...'];
end
end


% =========================================================================
function tf = isAlgebraicVar(e)
%ISALGEBRAICVAR True for a helper/algebraic variable (not an ODE state).
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
