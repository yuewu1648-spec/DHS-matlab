function odeSpec = expand(pdeSpec)
%EXPAND Expand a bma.modelSpec.v1 kind="pde" spec into an equivalent ODE spec.
%   odeSpec = bma.spec.pde.expand(pdeSpec)
%
% v1 supports 1D finite-volume MOL on uniform grids:
%   geometry = slab | cylinder | sphere
%   domain.extent = {value, unit} (length)
%   grid.n >= 2
%   diffusion = [{species, coeff}] where coeff is a parameter id with unit
%               length^2/time
%   bc = two entries (x0,x1): dirichlet{value:param} or neumann{flux:0}
%   reactions.stoichiometry species are local concentrations; reactions are
%   replicated per node. Expression reactions may use indexed parameters such
%   as rho_i; values come from pde.domain.zones[].params or the base parameter.
%   outputs may use C[i], max(C), min(C), mean(C), mean_over_domain(C),
%   integral(C); argmax is not supported in v1.
%
% The returned spec has kind="ode", node species C_1..C_n, a generated dx
% parameter, generated indexed parameters, and a metadata.pde block with
% geometry/grid/BC/expander provenance. The original PDE spec stays in m.spec.
if ischar(pdeSpec) || isstring(pdeSpec)
    pdeSpec = bma.spec.load(char(pdeSpec));
end
if ~isstruct(pdeSpec) || isempty(pdeSpec)
    error('bma:pde:badSpec', 'expand 需要 PDE 规格结构体');
end
if ~isfield(pdeSpec, 'pde') || ~isstruct(pdeSpec.pde) || isempty(pdeSpec.pde)
    error('bma:pde:missingSubtree', 'kind="pde" 规格必须包含 pde 子树');
end
spec = bma.spec.normalize(pdeSpec);
pde = spec.pde;
name = char(getF(spec, 'name', 'pde_model'));
title = char(getF(spec, 'title', name));
time = getF(spec, 'time', struct());
timeUnit = char(getF(time, 'unit', 's'));
vars = itemize(getF(spec, 'variables', []));
params = itemize(getF(spec, 'parameters', []));
reacs = itemize(getF(spec, 'reactions', []));
outs = itemize(getF(spec, 'outputs', []));
nVar = numel(vars);
nPar = numel(params);
nR = numel(reacs);
if nVar < 1
    error('bma:pde:noSpecies', 'PDE 规格至少需要一个变量（场）');
end
if nR < 1
    error('bma:pde:noReactions', 'PDE 规格至少需要一个反应');
end

% ---- domain / geometry ----
domain = getF(pde, 'domain', struct());
geometry = lower(char(getF(domain, 'geometry', '')));
if ~any(strcmp(geometry, {'slab', 'cylinder', 'sphere'}))
    error('bma:pde:badGeometry', 'pde.domain.geometry 必须是 slab/cylinder/sphere（v1 仅 1D）');
end
extent = getF(domain, 'extent', struct());
L = getF(extent, 'value', []);
if ~isnumeric(L) || ~isscalar(L) || ~isfinite(L) || L <= 0
    error('bma:pde:badExtent', 'pde.domain.extent.value 必须是正有限数值');
end
lengthUnit = char(getF(extent, 'unit', ''));
if isempty(lengthUnit)
    error('bma:pde:badExtentUnit', 'pde.domain.extent.unit 缺失（必须是长度单位）');
end
if isfield(pde, 'dim') && ~isempty(pde.dim) && double(pde.dim) ~= 1
    error('bma:pde:unsupportedDim', 'v1 仅支持 pde.dim=1（二维矩形留给后续版本）');
end
grid = getF(pde, 'domain', struct());
grid = getF(grid, 'grid', struct());
gridType = lower(char(getF(grid, 'type', 'uniform')));
if ~strcmp(gridType, 'uniform')
    error('bma:pde:badGrid', 'v1 仅支持 pde.domain.grid.type="uniform"');
end
n = getF(grid, 'n', []);
if ~isnumeric(n) || ~isscalar(n) || ~isfinite(n) || n < 2 || n ~= round(n)
    error('bma:pde:badGrid', 'pde.domain.grid.n 必须是 >=2 的整数');
end
n = double(n);
dx = L / n;
switch geometry
    case 'slab'
        dim = 1;
    case 'cylinder'
        dim = 2;
    case 'sphere'
        dim = 3;
end
ops = bma.spec.pde.fvOps(geometry, n);
approx = char(getF(domain, 'approximation', ''));

% ---- unit helpers ----
u = readUnitRegistry();
lenInfo = unitInfo(u, lengthUnit);
if ~strcmp(lenInfo.dim, 'length')
    error('bma:pde:badExtentUnit', 'extent.unit="%s" 不是长度单位', lengthUnit);
end
timeInfo = unitInfo(u, timeUnit);
if ~strcmp(timeInfo.dim, 'time')
    error('bma:pde:badTimeUnit', 'time.unit="%s" 不是时间单位（PDE 的 time 必须是真实时间）', timeUnit);
end
parIds = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
parIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:nPar
    if isempty(parIds{j})
        error('bma:pde:badParameter', '第 %d 个参数缺少 id', j);
    end
    parIndex(parIds{j}) = j;
end
parValues = zeros(1, nPar);
parUnits = cell(1, nPar);
parNames = cell(1, nPar);
for j = 1:nPar
    val = getF(getF(params{j}, 'value', struct()), 'value', []);
    if ~isnumeric(val) || ~isscalar(val) || ~isfinite(val)
        error('bma:pde:badParameter', '参数 "%s" 缺少有限数值 value.value', parIds{j});
    end
    parValues(j) = double(val);
    parUnits{j} = char(getF(params{j}, 'unit', ''));
    parNames{j} = char(getF(params{j}, 'name', parIds{j}));
end

% ---- diffusion definitions ----
diff = itemize(getF(pde, 'diffusion', []));
if isempty(diff)
    error('bma:pde:noDiffusion', 'pde.diffusion 不能为空（至少一个 {species, coeff}）');
end
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
speciesUnits = cellfun(@(v) char(getF(v, 'unit', '')), vars, 'UniformOutput', false);
for i = 1:nVar
    if isempty(species{i})
        error('bma:pde:badSpecies', '第 %d 个 PDE 变量缺少 id', i);
    end
    if isAlgebraic(vars{i})
        error('bma:pde:unsupportedAlgebraic', ...
            'PDE 变量 "%s" 不能是 algebraic（v1 不支持 PDE+DAE）', species{i});
    end
end
diffCoeff = containers.Map('KeyType', 'char', 'ValueType', 'double');
diffParam = containers.Map('KeyType', 'char', 'ValueType', 'char');
diffConv = containers.Map('KeyType', 'char', 'ValueType', 'double');
for k = 1:numel(diff)
    d = diff{k};
    sid = char(getF(d, 'species', ''));
    coeff = getF(d, 'coeff', []);
    if ~any(strcmp(sid, species))
        error('bma:pde:unknownDiffusionSpecies', 'pde.diffusion 引用了未知变量 "%s"', sid);
    end
    if ~ischar(coeff) || ~isKey(parIndex, coeff)
        error('bma:pde:badDiffusionCoeff', ...
            'pde.diffusion[%d].coeff 必须是已定义参数 id（v1 不支持数值/表达式系数）', k - 1);
    end
    j = parIndex(coeff);
    du = unitInfo(u, parUnits{j});
    if ~strcmp(du.dim, 'diffusion_coefficient')
        error('bma:pde:badDiffusionUnit', ...
            '扩散系数参数 "%s" 的单位 "%s" 必须是 length^2/time', coeff, parUnits{j});
    end
    % Convert from the spec's length^2/time unit to lengthUnit^2/timeUnit.
    conv = du.factor * timeInfo.factor / (lenInfo.factor ^ 2);
    diffCoeff(sid) = parValues(j) * conv;
    diffParam(sid) = coeff;
    diffConv(sid) = conv;
end

% ---- boundary conditions ----
bc = itemize(getF(pde, 'bc', []));
if numel(bc) ~= 2
    error('bma:pde:badBC', 'pde.bc 必须恰好包含两个条目（x0/x1）');
end
bcByFace = struct('x0', [], 'x1', []);
for k = 1:numel(bc)
    face = lower(char(getF(bc{k}, 'face', '')));
    if ~any(strcmp(face, {'x0', 'x1'}))
        error('bma:pde:badBC', 'pde.bc[%d].face 必须是 x0/x1', k - 1);
    end
    typ = lower(char(getF(bc{k}, 'type', '')));
    if ~any(strcmp(typ, {'dirichlet', 'neumann'}))
        error('bma:pde:badBC', 'pde.bc[%d].type 必须是 dirichlet/neumann', k - 1);
    end
    item = struct('face', face, 'type', typ, 'value', '', 'numeric_value', NaN);
    if strcmp(typ, 'dirichlet')
        v = getF(bc{k}, 'value', []);
        if ischar(v) && ~isempty(v)
            if ~isKey(parIndex, v)
                error('bma:pde:badBCValue', 'pde.bc[%d].value 参数 "%s" 未定义', k - 1, v);
            end
            j = parIndex(v);
            if ~isempty(speciesUnits) && ~strcmp(parUnits{j}, speciesUnits{1})
                error('bma:pde:badBCUnit', ...
                    'pde.bc[%d].value 参数 "%s" 的单位必须与场变量一致', k - 1, v);
            end
            item.value = v;
        elseif isnumeric(v) && isscalar(v) && isfinite(v)
            item.numeric_value = double(v);
        else
            error('bma:pde:badBCValue', 'pde.bc[%d].value 必须是参数 id 或有限数值', k - 1);
        end
    else
        flux = getF(bc{k}, 'flux', []);
        if ~isnumeric(flux) || ~isscalar(flux) || flux ~= 0
            error('bma:pde:badBCFlux', 'v1 只支持 neumann flux=0（无通量）；收到 pde.bc[%d]', k - 1);
        end
    end
    bcByFace.(face) = item;
end
if isempty(bcByFace.x0) || isempty(bcByFace.x1)
    error('bma:pde:badBC', 'pde.bc 必须同时给出 x0 与 x1');
end
if strcmp(bcByFace.x0.type, 'dirichlet') && ops.bL <= 0
    error('bma:pde:badBC', '%s 几何的 x0 是零面积中心，不能施加 Dirichlet（请用 neumann flux=0）', geometry);
end

% ---- indexed parameters (rho_i) and zones ----
zones = itemize(getF(domain, 'zones', []));
indexed = collectIndexedTokens(reacs, outs, species, parIds);
indexedMap = containers.Map('KeyType', 'char', 'ValueType', 'char'); % base -> generated prefix
genParams = {};
for k = 1:numel(indexed)
    base = indexed{k};
    if ~isKey(parIndex, base)
        error('bma:pde:badIndexedParam', ...
            '表达式使用了 "%s_i"，但没有定义参数 "%s"', base, base);
    end
    prefix = ['pde_' base '_'];
    indexedMap(base) = prefix;
    j = parIndex(base);
    values = repmat(parValues(j), 1, n);
    for z = 1:numel(zones)
        zz = zones{z};
        range = getF(zz, 'range', []);
        if ~isnumeric(range) || numel(range) ~= 2 || any(range < 1) || any(range > n) || any(range ~= round(range))
            error('bma:pde:badZone', 'pde.domain.zones[%d].range 必须是 [i0,i1]（1..n）', z - 1);
        end
        pmap = getF(zz, 'params', struct());
        if isstruct(pmap) && isfield(pmap, base)
            val = pmap.(base);
            if ~isnumeric(val) || ~isscalar(val) || ~isfinite(val)
                error('bma:pde:badZone', 'zone 参数 "%s" 必须是有限数值', base);
            end
            values(range(1):range(2)) = double(val);
        end
    end
    for i = 1:n
        gid = sprintf('%s%d', prefix, i);
        if any(strcmp(gid, parIds))
            error('bma:pde:idCollision', '生成的参数 id "%s" 与现有参数冲突', gid);
        end
        genParams{end+1} = struct('id', gid, 'name', sprintf('%s（节点 %d）', base, i), ...
            'unit', parUnits{j}, 'value', struct('value', values(i)), ...
            'estimate', false, 'bounds', [], 'evidence', {{}}); %#ok<AGROW>
    end
end

% ---- generated dx parameter ----
dxId = ['pde_' sanitizeId(name) '_dx'];
if any(strcmp(dxId, parIds))
    error('bma:pde:idCollision', '生成的参数 id "%s" 与现有参数冲突', dxId);
end
genParams{end+1} = struct('id', dxId, 'name', 'MOL 网格间距', ...
    'unit', lengthUnit, 'value', struct('value', dx), ...
    'estimate', false, 'bounds', [], 'evidence', {{}});

% ---- node species ----
nodeVars = {};
for i = 1:nVar
    ini = getF(vars{i}, 'initial', struct());
    for k = 1:n
        nodeVars{end+1} = struct('id', sprintf('%s_%d', species{i}, k), ...
            'name', sprintf('%s[%d]', species{i}, k), 'unit', speciesUnits{i}, ...
            'initial', ini, 'compartment', char(getF(vars{i}, 'compartment', '')), ...
            'signed', logical(getF(vars{i}, 'signed', false))); %#ok<AGROW>
    end
end

% ---- node reactions ----
nodeReacs = {};
bcParamFor = containers.Map('KeyType', 'char', 'ValueType', 'char');
for i = 1:nVar
    sid = species{i};
    % Boundary Dirichlet values may be numeric; materialize a parameter so
    % units and reporting stay explicit.
    if strcmp(bcByFace.x0.type, 'dirichlet')
        [nodeReacs, genParams, bcParamFor] = addDirichletParam(nodeReacs, genParams, ...
            bcParamFor, sid, 'x0', bcByFace.x0, speciesUnits{i}, parIds);
    end
    if strcmp(bcByFace.x1.type, 'dirichlet')
        [nodeReacs, genParams, bcParamFor] = addDirichletParam(nodeReacs, genParams, ...
            bcParamFor, sid, 'x1', bcByFace.x1, speciesUnits{i}, parIds);
    end
end
for r = 1:nR
    rid = char(getF(reacs{r}, 'id', ''));
    if isempty(rid)
        error('bma:pde:badReaction', '第 %d 个反应缺少 id', r);
    end
    stoich = getF(reacs{r}, 'stoichiometry', struct());
    if ~isstruct(stoich) || isempty(fieldnames(stoich))
        error('bma:pde:badReaction', '反应 "%s" 缺少 stoichiometry', rid);
    end
    fn = fieldnames(stoich);
    for i = 1:numel(fn)
        if ~any(strcmp(fn{i}, species))
            error('bma:pde:badReaction', '反应 "%s" 的 stoichiometry 引用了非 PDE 变量 "%s"', rid, fn{i});
        end
    end
    for k = 1:n
        st = struct();
        for i = 1:numel(fn)
            st.(sprintf('%s_%d', fn{i}, k)) = stoich.(fn{i});
        end
        rate = nodeRate(getF(reacs{r}, 'rate', struct()), species, k, indexedMap);
        nodeReacs{end+1} = struct('id', sprintf('%s_%d', rid, k), ...
            'name', sprintf('%s（节点 %d）', char(getF(reacs{r}, 'name', rid)), k), ...
            'stoichiometry', st, 'rate', rate); %#ok<AGROW>
    end
end

% ---- diffusion reactions ----
for i = 1:nVar
    sid = species{i};
    if ~isKey(diffCoeff, sid)
        continue
    end
    de = diffParam(sid);
    conv = diffConv(sid);
    for k = 1:n-1
        left = sprintf('%s_%d', sid, k);
        right = sprintf('%s_%d', sid, k + 1);
        % A face flux is divided by each cell's own volume. For slab the two
        % coefficients are equal; cylinder/sphere differ, so write one reaction
        % per cell instead of a single ±1 pair (which would silently make the
        % scheme non-conservative on radial grids).
        exprL = sprintf('(%s*%.17g/%s^2)*%.17g*(%s - %s)', ...
            de, conv, dxId, ops.aR(k), left, right);
        nodeReacs{end+1} = struct('id', sprintf('pde_diff_%s_%d_L', sid, k), ...
            'name', sprintf('扩散 %s 面 %d（左单元）', sid, k), ...
            'stoichiometry', setField(struct(), left, -1), ...
            'rate', struct('kind', 'expression', 'expression', exprL)); %#ok<AGROW>
        exprR = sprintf('(%s*%.17g/%s^2)*%.17g*(%s - %s)', ...
            de, conv, dxId, ops.aL(k + 1), left, right);
        nodeReacs{end+1} = struct('id', sprintf('pde_diff_%s_%d_R', sid, k), ...
            'name', sprintf('扩散 %s 面 %d（右单元）', sid, k), ...
            'stoichiometry', setField(struct(), right, 1), ...
            'rate', struct('kind', 'expression', 'expression', exprR)); %#ok<AGROW>
    end
    if strcmp(bcByFace.x0.type, 'dirichlet') && ops.bL > 0
        left = sprintf('%s_1', sid);
        bc = bcParamFor(sprintf('%s|x0', sid));
        expr = sprintf('(%s*%.17g/%s^2)*%.17g*(%s - %s)', de, conv, dxId, ops.bL, bc, left);
        nodeReacs{end+1} = struct('id', sprintf('pde_bc_%s_x0', sid), ...
            'name', sprintf('Dirichlet x0 %s', sid), ...
            'stoichiometry', setField(struct(), left, 1), ...
            'rate', struct('kind', 'expression', 'expression', expr)); %#ok<AGROW>
    end
    if strcmp(bcByFace.x1.type, 'dirichlet') && ops.bR > 0
        right = sprintf('%s_%d', sid, n);
        bc = bcParamFor(sprintf('%s|x1', sid));
        expr = sprintf('(%s*%.17g/%s^2)*%.17g*(%s - %s)', de, conv, dxId, ops.bR, bc, right);
        nodeReacs{end+1} = struct('id', sprintf('pde_bc_%s_x1', sid), ...
            'name', sprintf('Dirichlet x1 %s', sid), ...
            'stoichiometry', setField(struct(), right, 1), ...
            'rate', struct('kind', 'expression', 'expression', expr)); %#ok<AGROW>
    end
end

% ---- outputs ----
nodeOuts = {};
outOpts = struct('cell_volume', ops.cell_volume, 'dx', dx, 'dim', ops.dim);
for o = 1:numel(outs)
    e = outs{o};
    expr = char(getF(e, 'expression', ''));
    for i = 1:nVar
        expr = bma.spec.pde.rewriteExpression(expr, species{i}, n, outOpts);
    end
    expr = rewriteIndexed(expr, indexedMap, n);
    nodeOuts{end+1} = struct('id', char(getF(e, 'id', '')), ...
        'name', char(getF(e, 'name', '')), 'unit', char(getF(e, 'unit', '')), ...
        'expression', expr, 'note', char(getF(e, 'note', ''))); %#ok<AGROW>
end

% ---- assemble ODE spec ----
odeSpec = spec;
odeSpec.kind = 'ode';
if isfield(odeSpec, 'pde')
    odeSpec = rmfield(odeSpec, 'pde');
end
odeSpec.variables = nodeVars;
odeSpec.parameters = [params(:).', genParams];
odeSpec.reactions = nodeReacs;
odeSpec.outputs = nodeOuts;
odeSpec.assumptions = [cellstr(getF(spec, 'assumptions', {})), ...
    {sprintf('PDE 由一维有限体积 MOL 展开为 %d 个节点（%s，n=%d，dx=%g %s）。', ...
    n, geometry, n, dx, lengthUnit)}];
meta = struct();
meta.schema = 'bma.pde.meta.v1';
meta.geometry = geometry;
meta.dim = ops.dim;
meta.n = n;
meta.dx = dx;
meta.extent = struct('value', L, 'unit', lengthUnit);
meta.faces = struct('x0', bcByFace.x0, 'x1', bcByFace.x1);
meta.approximation = approx;
meta.time_unit = timeUnit;
meta.expander_version = 'bma.spec.pde.expand/v1';
meta.expander_sha256 = sha256Text(jsonencode(pde));
meta.species = species;
meta.node_species = nodeVars;
meta.node_index = struct('species', {species}, 'n', n);
meta.diffusion = cellfun(@(d) struct('species', char(getF(d, 'species', '')), ...
    'coeff', char(getF(d, 'coeff', ''))), diff, 'UniformOutput', false);
meta.bc = {bcByFace.x0, bcByFace.x1};
if ~isempty(approx)
    meta.limitations = {sprintf('PDE 几何为 %s；domain.approximation="%s"，不是任意几何/自由边界。', ...
        geometry, approx)};
end
odeSpec.metadata.pde = meta;
end

% =========================================================================
function rate = nodeRate(rate, species, k, indexedMap)
if ~isstruct(rate) || isempty(rate)
    error('bma:pde:badRate', '反应缺少 rate');
end
rate = rate;
kind = lower(char(getF(rate, 'kind', '')));
switch kind
    case 'mass_action'
        sp = getF(rate, 'species', struct());
        if isstruct(sp)
            fn = fieldnames(sp);
            ns = struct();
            for i = 1:numel(fn)
                ns.(sprintf('%s_%d', fn{i}, k)) = sp.(fn{i});
            end
            rate.species = ns;
        end
    case 'michaelis_menten'
        sp = getF(rate, 'species', struct());
        if isfield(sp, 'substrate')
            sp.substrate = sprintf('%s_%d', sp.substrate, k);
        end
        if isfield(sp, 'inhibitor') && isstruct(sp.inhibitor) && isfield(sp.inhibitor, 'species')
            sp.inhibitor.species = sprintf('%s_%d', sp.inhibitor.species, k);
        end
        rate.species = sp;
    case 'hill'
        sp = getF(rate, 'species', struct());
        if isfield(sp, 'regulator')
            sp.regulator = sprintf('%s_%d', sp.regulator, k);
        end
        rate.species = sp;
    case 'constant'
        % uniform source
    case 'expression'
        expr = char(getF(rate, 'expression', ''));
        for i = 1:numel(species)
            expr = replaceSpecies(expr, species{i}, k);
        end
        expr = replaceIndexedNode(expr, indexedMap, k);
        rate.expression = expr;
    otherwise
        error('bma:pde:badRateKind', 'PDE 反应不支持 rate.kind="%s"', kind);
end
end

function expr = replaceSpecies(expr, sid, k)
pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', sid) '(?![A-Za-z0-9_])'];
expr = regexprep(expr, pat, sprintf('%s_%d', sid, k));
end

function expr = rewriteIndexed(expr, indexedMap, n)
% Replace base_i with generated per-node parameter ids.
if isempty(indexedMap)
    return
end
keys = indexedMap.keys;
for k = 1:numel(keys)
    base = keys{k};
    prefix = indexedMap(base);
    pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', base) '_i(?![A-Za-z0-9_])'];
    if isempty(n) || n < 1
        continue
    end
    % In reaction expressions the caller has already fixed the node via k;
    % this function cannot know it. The node-specific replacement is done by
    % the caller through replaceIndexedNode.
    expr = expr;
end
end

function expr = replaceIndexedNode(expr, indexedMap, k)
keys = indexedMap.keys;
for j = 1:numel(keys)
    base = keys{j};
    pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', base) '_i(?![A-Za-z0-9_])'];
    expr = regexprep(expr, pat, sprintf('%s%d', indexedMap(base), k));
end
end

function [reacs, genParams, map] = addDirichletParam(reacs, genParams, map, sid, face, bc, unitStr, parIndex)
if ischar(bc.value) && ~isempty(bc.value)
    map(sprintf('%s|%s', sid, face)) = bc.value;
    return
end
if ~isnumeric(bc.numeric_value) || ~isfinite(bc.numeric_value)
    error('bma:pde:badBCValue', 'Dirichlet %s 的 value 无效', face);
end
gid = sprintf('pde_bc_%s_%s', sanitizeId(sid), face);
if any(cellfun(@(p) strcmp(char(getF(p, 'id', '')), gid), genParams))
    map(sprintf('%s|%s', sid, face)) = gid;
    return
end
genParams{end+1} = struct('id', gid, 'name', sprintf('Dirichlet %s %s', sid, face), ...
    'unit', unitStr, 'value', struct('value', bc.numeric_value), ...
    'estimate', false, 'bounds', [], 'evidence', {{}});
map(sprintf('%s|%s', sid, face)) = gid;
reacs = reacs;
end

function toks = collectIndexedTokens(reacs, outs, species, parIds)
toks = {};
for r = 1:numel(reacs)
    rate = getF(reacs{r}, 'rate', struct());
    if isfield(rate, 'expression')
        toks = [toks, indexedIn(char(rate.expression), parIds)]; %#ok<AGROW>
    end
end
for o = 1:numel(outs)
    if isfield(outs{o}, 'expression')
        toks = [toks, indexedIn(char(outs{o}.expression), parIds)]; %#ok<AGROW>
    end
end
toks = unique(toks, 'stable');
end

function out = indexedIn(expr, parIds)
out = {};
for j = 1:numel(parIds)
    base = parIds{j};
    pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', base) '_i(?![A-Za-z0-9_])'];
    if ~isempty(regexp(expr, pat, 'once'))
        out{end+1} = base; %#ok<AGROW>
    end
end
end

function info = unitInfo(units, unitStr)
info = struct('dim', '', 'factor', NaN, 'base', '');
for k = 1:numel(units)
    if strcmp(units(k).id, unitStr)
        info.dim = char(units(k).dim);
        info.factor = double(units(k).factor);
        info.base = char(units(k).base);
        return
    end
end
error('bma:pde:unknownUnit', '单位 "%s" 不在 kb/units.json 中', unitStr);
end

function units = readUnitRegistry()
file = fullfile(bma.util.projectRoot(), 'kb', 'units.json');
if ~isfile(file)
    error('bma:pde:unknownUnit', '找不到 kb/units.json');
end
doc = jsondecode(fileread(file));
if isstruct(doc) && isfield(doc, 'units')
    raw = doc.units;
else
    error('bma:pde:unknownUnit', 'kb/units.json 缺少 units 数组');
end
if iscell(raw)
    units = struct('id', {}, 'dim', {}, 'factor', {}, 'base', {}, ...
        'symbol', {}, 'aliases', {}, 'note', {});
    for k = 1:numel(raw)
        e = raw{k};
        units(end+1) = struct('id', char(getF(e, 'id', '')), ...
            'dim', char(getF(e, 'dim', '')), ...
            'factor', double(getF(e, 'factor', 1)), ...
            'base', char(getF(e, 'base', '')), ...
            'symbol', char(getF(e, 'symbol', '')), ...
            'aliases', {getF(e, 'aliases', {})}, ...
            'note', char(getF(e, 'note', ''))); %#ok<AGROW>
    end
else
    units = raw;
end
end

function s = sanitizeId(s)
s = regexprep(char(s), '[^A-Za-z0-9_]', '_');
if isempty(s)
    s = 'pde';
end
end

function st = setField(st, name, value)
st.(name) = value;
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end

function items = itemize(x)
if iscell(x)
    items = x(:).';
elseif isstruct(x)
    items = num2cell(x(:).');
elseif isempty(x)
    items = {};
else
    items = {x};
end
end

function tf = isAlgebraic(e)
tf = false;
try
    if isfield(e, 'kind') && strcmpi(char(getF(e, 'kind', '')), 'algebraic')
        tf = true;
    elseif isfield(e, 'algebraic') && ~isempty(e.algebraic) && logical(e.algebraic)
        tf = true;
    end
catch
end
end

function h = sha256Text(txt)
try
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(uint8(txt));
    digest = typecast(md.digest(), 'uint8');
    h = lower(sprintf('%02x', digest));
catch
    h = '';
end
end
