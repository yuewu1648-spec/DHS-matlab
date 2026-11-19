function res = simulate(spec, opts)
%SIMULATE Native 2D PDE Toolbox solver (0.8.0).
%   res = bma.pde.simulate(spec, opts)
%
% This path is for `kind:"pde"` with pde.dim=2 and `pde.solver="toolbox"`
% (or auto when the model is 2D). It builds a real PDE Toolbox model:
%   geometry (rectangle/circle/polygon) -> generateMesh -> specifyCoefficients
%   -> applyBoundaryCondition -> setInitialConditions -> solvepde.
% It is deliberately separate from the MOL path: no node ODE expansion, no
% fit/identifiability state vector. Use it for 2D/irregular fields where MOL
% would be inappropriate or too large.
%
% opts: work_dir, run_dir, steady, n, time_end, max_dof, max_seconds,
%       mesh (struct), probes (cell), name.
if nargin < 2 || isempty(opts)
    opts = struct();
end
t0 = tic;
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec) || isempty(spec)
    error('bma:pdeToolbox:badSpec', 'PDE Toolbox 需要模型规格结构体');
end
spec = bma.spec.normalize(spec);
pde = getF(spec, 'pde', struct());
if ~isstruct(pde) || isempty(pde)
    error('bma:pdeToolbox:missingPde', 'PDE Toolbox 需要 pde 子树');
end
dim = double(getF(pde, 'dim', 2));
if ~any(dim == [2 3])
    error('bma:pdeToolbox:unsupportedDim', ...
        'PDE Toolbox 原生路径支持 pde.dim=2/3；1D 请用 MOL');
end
if license('test', 'PDE_Toolbox') ~= 1
    error('bma:pdeToolbox:noLicense', 'PDE Toolbox 未授权；请改用 MOL（pde.dim=1）或安装授权。');
end
solverName = lower(char(getF(pde, 'solver', 'toolbox')));
if ~any(strcmp(solverName, {'toolbox', 'auto'}))
    error('bma:pdeToolbox:badSolver', 'pde.solver 必须是 "toolbox" 或 "auto"');
end
vars = itemize(getF(spec, 'variables', []));
params = itemize(getF(spec, 'parameters', []));
reacs = itemize(getF(spec, 'reactions', []));
N = numel(vars);
if N < 1
    error('bma:pdeToolbox:noSpecies', 'PDE Toolbox 至少需要一个变量');
end
if isempty(reacs)
    error('bma:pdeToolbox:noReactions', 'PDE Toolbox 至少需要一个反应/源项');
end
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
speciesUnits = cellfun(@(v) char(getF(v, 'unit', '')), vars, 'UniformOutput', false);
parIds = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
parValues = zeros(1, numel(params));
for j = 1:numel(params)
    val = getF(getF(params{j}, 'value', struct()), 'value', []);
    if ~isnumeric(val) || ~isscalar(val) || ~isfinite(val)
        error('bma:pdeToolbox:badParameter', '参数 "%s" 缺少有限数值', parIds{j});
    end
    parValues(j) = double(val);
end
parIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:numel(parIds)
    parIndex(parIds{j}) = j;
end

% ---- geometry + mesh ----
model = createpde(N);
domain = getF(pde, 'domain', struct());
geometry = lower(char(getF(domain, 'geometry', '')));
is3d = dim == 3;
imported = false;
meshProvided = false;
switch geometry
    case 'rectangle'
        sz = getF(domain, 'size', []);
        if isempty(sz)
            ext = getF(domain, 'extent', struct());
            sz = getF(ext, 'value', []);
        end
        if ~isnumeric(sz) || numel(sz) ~= 2 || any(sz <= 0)
            error('bma:pdeToolbox:badGeometry', 'rectangle 需要 domain.size=[width height]（同单位）');
        end
        R1 = [3; 4; 0; sz(1); sz(1); 0; 0; 0; sz(2); sz(2)];
        gd = R1; ns = {'R1'}; geomSpan = max(sz);
    case 'circle'
        r = getF(domain, 'radius', []);
        if isempty(r)
            ext = getF(domain, 'extent', struct());
            r = getF(ext, 'value', []);
        end
        if ~isnumeric(r) || ~isscalar(r) || r <= 0
            error('bma:pdeToolbox:badGeometry', 'circle 需要 domain.radius > 0');
        end
        gd = [1; 0; 0; r]; ns = {'C1'}; geomSpan = 2 * r;
    case 'polygon'
        pts = getF(domain, 'points', []);
        if ~isnumeric(pts) || size(pts, 2) ~= 2 || size(pts, 1) < 3
            error('bma:pdeToolbox:badGeometry', 'polygon 需要 domain.points N×2（N>=3）');
        end
        gd = [2; size(pts, 1); pts(:, 1); pts(:, 2)]; ns = {'P1'};
        geomSpan = max(max(pts) - min(pts));
    case 'box'
        sz = getF(domain, 'size', []);
        if isempty(sz)
            ext = getF(domain, 'extent', struct());
            sz = getF(ext, 'value', []);
        end
        if ~isnumeric(sz) || numel(sz) ~= 3 || any(sz <= 0)
            error('bma:pdeToolbox:badGeometry', 'box 需要 domain.size=[Lx Ly Lz]');
        end
        % A structured tetrahedral mesh is more robust than a hand-written
        % STL and keeps the box boundary associativity for BCs.
        mesh0 = getF(pde, 'mesh', struct());
        h0 = getF(mesh0, 'hmax', []);
        if isstruct(h0), h0 = getF(h0, 'value', []); end
        if isempty(h0) || ~isnumeric(h0) || h0 <= 0
            h0 = max(sz) / 8;
        end
        nPer = max(2, min(18, ceil(max(sz) / h0) + 1));
        [X, Y, Z] = ndgrid(linspace(0, sz(1), nPer), ...
            linspace(0, sz(2), nPer), linspace(0, sz(3), nPer));
        nodes = [X(:).'; Y(:).'; Z(:).'];
        tets = delaunay(nodes(1, :), nodes(2, :), nodes(3, :));
        try
            geometryFromMesh(model, nodes, tets.');
        catch err
            error('bma:pdeToolbox:badGeometry', '3D box 网格几何失败：%s', err.message);
        end
        imported = true; is3d = true; meshProvided = true; geomSpan = max(sz);
    case 'stl'
        file = char(getF(domain, 'file', ''));
        if isempty(file)
            error('bma:pdeToolbox:badGeometry', 'stl 需要 domain.file');
        end
        if ~isfile(file)
            file = bma.util.absPath(char(getF(opts, 'work_dir', bma.util.projectRoot())), file);
        end
        if ~isfile(file)
            error('bma:pdeToolbox:badGeometry', '找不到 STL 文件：%s', file);
        end
        try
            importGeometry(model, file);
        catch err
            error('bma:pdeToolbox:badGeometry', 'STL 导入失败：%s', err.message);
        end
        imported = true; geomSpan = [];
    otherwise
        error('bma:pdeToolbox:badGeometry', ...
            '支持 rectangle/circle/polygon/box/stl，收到 "%s"', geometry);
end
if ~imported
    try
        g = decsg(gd, ns{1}, ns);
        geometryFromEdges(model, g);
    catch err
        error('bma:pdeToolbox:badGeometry', 'PDE Toolbox 几何构建失败：%s', err.message);
    end
end
if is3d
    dim = 3;
end
if isempty(geomSpan) && ~isempty(model.Geometry)
    % Imported STL: estimate a mesh size from the geometry bounding box when
    % available; otherwise let generateMesh choose (hmax empty).
    try
        bb = model.Geometry.BoundingBox;
        geomSpan = max(bb(:, 2) - bb(:, 1));
    catch
        geomSpan = [];
    end
end
mesh = getF(pde, 'mesh', struct());
if isstruct(opts) && isfield(opts, 'mesh') && isstruct(opts.mesh)
    mesh = mergeStruct(mesh, opts.mesh);
end
hmax = getF(mesh, 'hmax', []);
if isstruct(hmax)
    hmax = getF(hmax, 'value', []);
end
hgrad = getF(mesh, 'hgrad', 1.3);
if isempty(hmax) || ~isnumeric(hmax) || ~isscalar(hmax) || hmax <= 0
    if isempty(geomSpan)
        hmax = [];
    else
        hmax = max(geomSpan / 40, 1e-9);
    end
end
try
    if meshProvided
        % geometryFromMesh already supplied a volume mesh.
    elseif isempty(hmax)
        generateMesh(model, 'Hgrad', hgrad);
    else
        generateMesh(model, 'Hmax', hmax, 'Hgrad', hgrad);
    end
catch err
    error('bma:pdeToolbox:meshFailed', 'generateMesh 失败：%s', err.message);
end
nNodes = size(model.Mesh.Nodes, 2);
nElems = size(model.Mesh.Elements, 2);
maxDof = getNum(opts, 'max_dof', 50000);
if nNodes > maxDof
    error('bma:pdeToolbox:budget', ...
        '网格节点数 %d 超过 max_dof=%d；请增大 mesh.hmax 或提高预算。', nNodes, maxDof);
end

% ---- source term f = S*rates ----
[S, rateFuns] = buildSource(spec, vars, params, reacs, species, parValues, parIndex);
fcn = @(location, state) localSource(location, state, S, rateFuns, N);
dcoef = zeros(N, 1);
cvec = zeros(N, 1);
for i = 1:N
    dcoef(i) = 1;
    cvec(i) = 0;
end
% diffusion: one coefficient per component (column vector, tested for N=2)
diff = itemize(getF(pde, 'diffusion', []));
for k = 1:numel(diff)
    sid = char(getF(diff{k}, 'species', ''));
    ci = find(strcmp(species, sid), 1);
    if isempty(ci)
        error('bma:pdeToolbox:badDiffusion', 'diffusion 引用了未知变量 "%s"', sid);
    end
    coeff = getF(diff{k}, 'coeff', []);
    if ~ischar(coeff) || ~isKey(parIndex, coeff)
        error('bma:pdeToolbox:badDiffusion', 'diffusion.coeff 必须是参数 id');
    end
    cvec(ci) = parValues(parIndex(coeff));
end
if all(cvec == 0)
    error('bma:pdeToolbox:noDiffusion', '没有有效的扩散系数（pde.diffusion 为空或全 0）');
end
try
    specifyCoefficients(model, 'm', 0, 'd', dcoef, 'c', cvec, 'a', zeros(N, 1), 'f', fcn);
catch err
    error('bma:pdeToolbox:coefficients', 'specifyCoefficients 失败：%s', err.message);
end

% ---- boundary conditions ----
bc = itemize(getF(pde, 'bc', []));
if is3d
    numB = model.Geometry.NumFaces;
    bField = 'Face';
else
    numB = model.Geometry.NumEdges;
    bField = 'Edge';
end
if isempty(bc)
    applyBoundaryCondition(model, 'neumann', bField, 1:numB, 'q', 0, 'g', 0);
else
    for k = 1:numel(bc)
        b = bc{k};
        edge = getF(b, 'edge', getF(b, 'face', 'all'));
        if ischar(edge) && strcmpi(edge, 'all')
            edge = 1:numB;
        end
        if ~isnumeric(edge) || any(edge < 1) || any(edge > numB)
            error('bma:pdeToolbox:badBC', 'bc[%d] 边界编号越界（1..%d）', k - 1, numB);
        end
        typ = lower(char(getF(b, 'type', '')));
        switch typ
            case 'dirichlet'
                uval = bcVector(getF(b, 'value', []), N, species, parIndex, parValues);
                applyBoundaryCondition(model, 'dirichlet', bField, edge, 'u', uval);
            case 'neumann'
                flux = getF(b, 'flux', 0);
                if ~isnumeric(flux) || ~isscalar(flux) || flux ~= 0
                    error('bma:pdeToolbox:badBC', 'v1 只支持 neumann flux=0；bc[%d]', k - 1);
                end
                applyBoundaryCondition(model, 'neumann', bField, edge, 'q', 0, 'g', 0);
            otherwise
                error('bma:pdeToolbox:badBC', 'bc[%d].type 必须是 dirichlet/neumann', k - 1);
        end
    end
end

% ---- initial condition ----
u0 = zeros(N, 1);
for i = 1:N
    ini = getF(vars{i}, 'initial', struct());
    if isstruct(ini) && isfield(ini, 'param') && ~isempty(ini.param)
        pid = char(ini.param);
        if ~isKey(parIndex, pid)
            error('bma:pdeToolbox:badInitial', 'initial.param "%s" 未定义', pid);
        end
        u0(i) = parValues(parIndex(pid));
    else
        v = getF(ini, 'value', 0);
        if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
            error('bma:pdeToolbox:badInitial', '变量 "%s" 初值无效', species{i});
        end
        u0(i) = v;
    end
end
try
    setInitialConditions(model, u0);
catch err
    error('bma:pdeToolbox:initial', 'setInitialConditions 失败：%s', err.message);
end

% ---- solve ----
tt = getF(spec, 'time', struct());
tStart = double(getF(tt, 'start', 0));
tEnd = double(getF(tt, 'end', 1));
nT = double(getF(tt, 'n', 51));
if isfield(opts, 'time_end') && ~isempty(opts.time_end)
    tEnd = double(opts.time_end);
end
if isfield(opts, 'n') && ~isempty(opts.n)
    nT = double(opts.n);
end
if ~isfinite(tStart) || ~isfinite(tEnd) || tEnd <= tStart || nT < 2
    error('bma:pdeToolbox:badTime', '时间轴无效：start/end/n');
end
steady = false;
if isfield(opts, 'steady') && ~isempty(opts.steady)
    steady = logical(opts.steady);
elseif isfield(pde, 'steady') && ~isempty(pde.steady)
    steady = logical(pde.steady);
end
tvec = linspace(tStart, tEnd, round(nT));
try
    if steady
        sol = solvepde(model);
        tvec = tEnd;
    else
        sol = solvepde(model, tvec);
    end
catch err
    error('bma:pdeToolbox:solveFailed', 'solvepde 失败：%s', err.message);
end
U = sol.NodalSolution;
if ndims(U) == 2
    if N == 1
        % Single-component NodalSolution is [nodes x times].
        U = reshape(U, size(U, 1), 1, size(U, 2));
    else
        U = reshape(U, size(U, 1), size(U, 2), 1);
    end
end
if steady
    tvec = tEnd;
end
% guard: time dimension
if size(U, 3) ~= numel(tvec)
    % solvepde may return an extra initial slice; use the available tail.
    tvec = linspace(tStart, tEnd, size(U, 3));
end
elapsed = toc(t0);
maxSeconds = getNum(opts, 'max_seconds', 300);
warnings = {};
if elapsed > maxSeconds
    warnings{end+1} = sprintf('PDE Toolbox 求解耗时 %.1f s，超过 max_seconds=%.1f s；结果仍返回。', ...
        elapsed, maxSeconds);
end

% ---- probes + field stats ----
probes = itemize(getF(pde, 'probes', []));
if isstruct(opts) && isfield(opts, 'probes') && ~isempty(opts.probes)
    probes = itemize(opts.probes);
end
nodes = model.Mesh.Nodes;
probeOut = {};
for k = 1:numel(probes)
    pr = probes{k};
    sid = char(getF(pr, 'species', ''));
    ci = find(strcmp(species, sid), 1);
    if isempty(ci)
        error('bma:pdeToolbox:badProbe', 'probe 引用了未知变量 "%s"', sid);
    end
    x = double(getF(pr, 'x', 0));
    y = double(getF(pr, 'y', 0));
    if is3d
        z = double(getF(pr, 'z', 0));
        d2 = (nodes(1, :) - x).^2 + (nodes(2, :) - y).^2 + (nodes(3, :) - z).^2;
    else
        z = 0;
        d2 = (nodes(1, :) - x).^2 + (nodes(2, :) - y).^2;
    end
    [~, idx] = min(d2);
    yv = squeeze(U(idx, ci, :));
    probeOut{end+1} = struct('id', char(getF(pr, 'id', sprintf('%s_probe_%d', sid, k))), ...
        'species', sid, 'unit', speciesUnits{ci}, 'x', x, 'y', y, 'z', z, ...
        'nearest_node', idx, 't', tvec, 'values', yv(:)); %#ok<AGROW>
end
fieldStats = struct('species', {}, 'max', {}, 'min', {}, 'mean', {}, 'integral', {}, 'unit', {});
if is3d
    measure = tetraVolumes(model.Mesh.Nodes, model.Mesh.Elements);
else
    measure = triangleAreas(model.Mesh.Nodes, model.Mesh.Elements);
end
measureTotal = sum(measure);
for i = 1:N
    vals = squeeze(U(:, i, :));
    fieldStats(i) = struct('species', species{i}, 'unit', speciesUnits{i}, ...
        'max', max(vals, [], 1), 'min', min(vals, [], 1), ...
        'mean', mean(vals, 1), 'integral', mean(vals, 1) * measureTotal);
end

% ---- artifacts ----
runDir = '';
if isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    runDir = char(opts.run_dir);
end
workDir = '';
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
    workDir = char(opts.work_dir);
end
if isempty(workDir)
    workDir = bma.util.projectRoot();
end
if isempty(runDir)
    runDir = fullfile(workDir, '.bma', 'pde', char(getF(spec, 'name', 'pde')));
end
bma.util.ensureDir(runDir);
csvPath = fullfile(runDir, 'data', [char(getF(spec, 'name', 'pde')) '_pde_timeseries.csv']);
bma.util.ensureDir(fileparts(csvPath));
writeProbeCsv(csvPath, tvec, probeOut, fieldStats);
figs = {};
figDir = fullfile(runDir, 'figures');
bma.util.ensureDir(figDir);
for i = 1:N
    try
        f = figure('Visible', 'off');
        if is3d
            pdeplot3D(model, 'ColorData', U(:, i, end), 'ColorMap', 'parula');
        else
            pdeplot(model, 'XYData', U(:, i, end), 'ColorMap', 'parula');
        end
        title(sprintf('%s: %s (final)', char(getF(spec, 'name', 'pde')), species{i}), 'Interpreter', 'none');
        colorbar;
        fpath = fullfile(figDir, sprintf('pde_%s_final.png', species{i}));
        exportgraphics(f, fpath, 'Resolution', 200);
        close(f);
        figs{end+1} = fpath; %#ok<AGROW>
    catch err
        warnings{end+1} = sprintf('PDE 图输出失败（%s）：%s', species{i}, err.message); %#ok<AGROW>
        try, close(f); catch, end %#ok<TRYNC>
    end
end
meta = struct('solver', 'pde_toolbox', 'dim', dim, 'geometry', geometry, ...
    'nodes', nNodes, 'elements', nElems, 'hmax', hmax, 'hgrad', hgrad, ...
    'steady', steady, 'elapsed_s', elapsed, 'max_dof', maxDof, ...
    'probes', numel(probeOut));
res = struct();
res.success = true;
res.solver = 'pde_toolbox';
res.kind = 'pde';
res.pde = meta;
res.t = tvec;
res.probes = probeOut;
res.field_stats = fieldStats;
res.timeseries_path = csvPath;
res.figures = figs;
res.warnings = warnings;
res.stats = struct('nodes', nNodes, 'elements', nElems, 'elapsed_s', elapsed, ...
    'max_dof', maxDof, 'steady', steady);
res.outputs = {};
for k = 1:numel(probeOut)
    p = probeOut{k};
    res.outputs{k} = struct('id', p.id, 'name', p.id, 'unit', p.unit, ...
        't', p.t, 'y', p.values, 'final', p.values(end), ...
        'min', min(p.values), 'max', max(p.values)); %#ok<AGROW>
end
if isfield(opts, 'work_dir') && ~isempty(workDir)
    try
        res.timeseries_rel = bma.util.relPath(workDir, csvPath);
        res.figures_rel = cellfun(@(p) bma.util.relPath(workDir, p), figs, 'UniformOutput', false);
    catch
    end
end
end

% =========================================================================
function [S, rateFuns] = buildSource(spec, vars, params, reacs, species, parValues, parIndex) %#ok<INUSD>
N = numel(vars);
nR = numel(reacs);
S = zeros(N, nR);
rateFuns = cell(1, nR);
for r = 1:nR
    stoich = getF(reacs{r}, 'stoichiometry', struct());
    fn = fieldnames(stoich);
    for i = 1:numel(fn)
        ci = find(strcmp(species, fn{i}), 1);
        if isempty(ci)
            error('bma:pdeToolbox:badReaction', '反应 "%s" 引用了未知变量 "%s"', ...
                char(getF(reacs{r}, 'id', '')), fn{i});
        end
        S(ci, r) = stoich.(fn{i});
    end
    rateFuns{r} = makeRateFun(getF(reacs{r}, 'rate', struct()), species, parValues, parIndex);
end
end

function fh = makeRateFun(rate, species, parValues, parIndex)
kind = lower(char(getF(rate, 'kind', '')));
switch kind
    case 'expression'
        expr = char(getF(rate, 'expression', ''));
        refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
        for i = 1:numel(species)
            refs(species{i}) = sprintf('u(%d,:)', i);
        end
        % Parameters are substituted as numeric literals; this keeps the
        % native f callback independent of parameter ordering.
        keys = parIndex.keys;
        for j = 1:numel(keys)
            refs(keys{j}) = sprintf('%.17g', parValues(parIndex(keys{j})));
        end
        [code, ~] = bma.spec.expressionCode(expr, refs);
        code = elementwise(code);
        fh = str2func(['@(u) ' code]);
    case 'mass_action'
        k = paramValue(getF(rate, 'parameters', struct()), 'k', parValues, parIndex);
        sp = getF(rate, 'species', struct());
        fn = fieldnames(sp);
        parts = cell(1, numel(fn));
        for i = 1:numel(fn)
            ci = find(strcmp(species, fn{i}), 1);
            order = sp.(fn{i});
            if order == 1
                parts{i} = sprintf('u(%d,:)', ci);
            else
                parts{i} = sprintf('u(%d,:).^%.17g', ci, order);
            end
        end
        fh = str2func(['@(u) ' num2str(k, 17) '.*' strjoin(parts, '.*')]);
    case 'michaelis_menten'
        p = getF(rate, 'parameters', struct());
        vmax = paramValue(p, 'vmax', parValues, parIndex);
        km = paramValue(p, 'km', parValues, parIndex);
        sp = getF(rate, 'species', struct());
        si = find(strcmp(species, sp.substrate), 1);
        expr = sprintf('%.17g.*u(%d,:)./(%.17g + u(%d,:))', vmax, si, km, si);
        if isfield(sp, 'inhibitor') && isstruct(sp.inhibitor) && isfield(sp.inhibitor, 'species')
            ii = find(strcmp(species, sp.inhibitor.species), 1);
            ki = paramValue(sp.inhibitor, 'ki', parValues, parIndex);
            expr = sprintf('%.17g.*u(%d,:)./(%.17g + u(%d,:).*(1+u(%d,:)./%.17g))', ...
                vmax, si, km, si, ii, ki);
        end
        fh = str2func(['@(u) ' expr]);
    case 'hill'
        p = getF(rate, 'parameters', struct());
        vmax = paramValue(p, 'vmax', parValues, parIndex);
        k = paramValue(p, 'k', parValues, parIndex);
        n = paramValue(p, 'n', parValues, parIndex);
        sp = getF(rate, 'species', struct());
        ri = find(strcmp(species, sp.regulator), 1);
        mode = lower(char(getF(rate, 'mode', 'activation')));
        if strcmp(mode, 'repression')
            expr = sprintf('%.17g.*%.17g.^%.17g./(%.17g.^%.17g + u(%d,:).^%.17g)', ...
                vmax, k, n, k, n, ri, n);
        else
            expr = sprintf('%.17g.*u(%d,:).^%.17g./(%.17g.^%.17g + u(%d,:).^%.17g)', ...
                vmax, ri, n, k, n, ri, n);
        end
        fh = str2func(['@(u) ' expr]);
    case 'constant'
        p = getF(rate, 'parameters', struct());
        k = paramValue(p, 'k', parValues, parIndex);
        fh = str2func(sprintf('@(u) %.17g + 0*u(1,:)', k));
    otherwise
        error('bma:pdeToolbox:badRate', 'PDE Toolbox 源项不支持 rate.kind="%s"', kind);
end
end

function f = localSource(location, state, S, rateFuns, N) %#ok<INUSD>
u = state.u;
if size(u, 1) ~= N
    u = reshape(u, N, []);
end
npts = size(u, 2);
rates = zeros(numel(rateFuns), npts);
for r = 1:numel(rateFuns)
    rates(r, :) = rateFuns{r}(u);
end
f = S * rates;
end

function v = paramValue(p, name, parValues, parIndex)
if ~isfield(p, name)
    error('bma:pdeToolbox:badRate', 'rate 缺少参数 "%s"', name);
end
id = char(p.(name));
if ~isKey(parIndex, id)
    error('bma:pdeToolbox:badRate', '参数 "%s" 未定义', id);
end
v = parValues(parIndex(id));
end

function v = bcVector(value, N, species, parIndex, parValues)
if isnumeric(value)
    if isscalar(value)
        v = value * ones(N, 1);
    elseif numel(value) == N
        v = value(:);
    else
        error('bma:pdeToolbox:badBC', 'Dirichlet value 必须是标量或长度 %d 的向量', N);
    end
elseif ischar(value)
    if ~isKey(parIndex, value)
        error('bma:pdeToolbox:badBC', 'Dirichlet value 参数 "%s" 未定义', value);
    end
    v = parValues(parIndex(value)) * ones(N, 1);
elseif isstruct(value)
    v = zeros(N, 1);
    for i = 1:N
        if isfield(value, species{i})
            x = value.(species{i});
            if ischar(x)
                v(i) = parValues(parIndex(x));
            else
                v(i) = double(x);
            end
        else
            error('bma:pdeToolbox:badBC', 'Dirichlet value 缺少物种 "%s"', species{i});
        end
    end
else
    error('bma:pdeToolbox:badBC', 'Dirichlet value 类型不支持');
end
end

function areas = triangleAreas(nodes, elements)
if size(elements, 1) ~= 3
    areas = ones(1, size(elements, 2));
    return
end
x = nodes(1, elements);
y = nodes(2, elements);
areas = 0.5 * abs((x(2,:) - x(1,:)) .* (y(3,:) - y(1,:)) - ...
    (x(3,:) - x(1,:)) .* (y(2,:) - y(1,:)));
end

function vols = tetraVolumes(nodes, elements)
if size(elements, 1) ~= 4
    vols = ones(1, size(elements, 2));
    return
end
p = nodes(:, elements); % 3 x 4 x M
a = p(:, 2, :) - p(:, 1, :);
b = p(:, 3, :) - p(:, 1, :);
c = p(:, 4, :) - p(:, 1, :);
a1 = a(1, 1, :); a2 = a(2, 1, :); a3 = a(3, 1, :);
b1 = b(1, 1, :); b2 = b(2, 1, :); b3 = b(3, 1, :);
c1 = c(1, 1, :); c2 = c(2, 1, :); c3 = c(3, 1, :);
d = a1 .* (b2 .* c3 - b3 .* c2) - a2 .* (b1 .* c3 - b3 .* c1) ...
    + a3 .* (b1 .* c2 - b2 .* c1);
vols = abs(squeeze(d)) / 6;
vols = vols(:).';
end

function writeBoxStl(path, sz)
Lx = sz(1); Ly = sz(2); Lz = sz(3);
V = [0 0 0; Lx 0 0; Lx Ly 0; 0 Ly 0; 0 0 Lz; Lx 0 Lz; Lx Ly Lz; 0 Ly Lz];
F = [1 2 3; 1 3 4; 5 7 6; 5 8 7; 1 6 2; 1 5 6; ...
     2 7 3; 2 6 7; 3 8 4; 3 7 8; 4 5 1; 4 8 5];
fid = fopen(path, 'w');
if fid < 0
    error('bma:pdeToolbox:badGeometry', '无法写入临时 STL：%s', path);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, 'solid bma_box\n');
for k = 1:size(F, 1)
    fprintf(fid, ' facet normal 0 0 0\n  outer loop\n');
    for j = 1:3
        fprintf(fid, '   vertex %.17g %.17g %.17g\n', V(F(k, j), :));
    end
    fprintf(fid, '  endloop\n endfacet\n');
end
fprintf(fid, 'endsolid bma_box\n');
end

function writeProbeCsv(path, tvec, probes, fieldStats)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:pdeToolbox:csv', '无法写入 %s', path);
end
cleaner = onCleanup(@() fclose(fid));
headers = {'time'};
for k = 1:numel(probes)
    headers{end+1} = probes{k}.id; %#ok<AGROW>
end
for k = 1:numel(fieldStats)
    headers{end+1} = sprintf('max_%s', fieldStats(k).species); %#ok<AGROW>
    headers{end+1} = sprintf('mean_%s', fieldStats(k).species); %#ok<AGROW>
end
fprintf(fid, '%s\n', strjoin(headers, ','));
for ti = 1:numel(tvec)
    row = sprintf('%.17g', tvec(ti));
    for k = 1:numel(probes)
        row = [row, sprintf(',%.17g', probes{k}.values(ti))]; %#ok<AGROW>
    end
    for k = 1:numel(fieldStats)
        row = [row, sprintf(',%.17g,%.17g', fieldStats(k).max(ti), fieldStats(k).mean(ti))]; %#ok<AGROW>
    end
    fprintf(fid, '%s\n', row);
end
end

function s = elementwise(code)
s = regexprep(code, '(?<!\.)\*', '.*');
s = regexprep(s, '(?<!\.)/', './');
s = regexprep(s, '(?<!\.)\^', '.^');
end

function s = mergeStruct(a, b)
s = a;
fn = fieldnames(b);
for k = 1:numel(fn)
    s.(fn{k}) = b.(fn{k});
end
end

function v = getNum(s, f, d)
v = d;
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f)) && isscalar(s.(f))
    v = double(s.(f));
end
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
