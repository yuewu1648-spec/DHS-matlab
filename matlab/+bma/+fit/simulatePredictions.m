function [pred, sim, info] = simulatePredictions(m, data, pVec, opts)
%SIMULATEPREDICTIONS 仿真模型并在数据时间点上取各 output 的预测值。
%   [pred, sim, info] = bma.fit.simulatePredictions(m, data, pVec, opts)
%
% 输入：
%   m      bma.model.build 返回的模型结构（也可由 bma.fit.resolveModel 得到）
%   data   bma.fit.normalizeData 返回的规范数据（需含 t / colIds）
%   pVec   完整参数向量（按 m.params 顺序，double），或 struct（参数字段→值）
%   opts   仿真选项：solver / rtol / atol / n / time_end / param_overrides /
%          initial_overrides
% 输出：
%   pred   numel(data.t)×numel(data.colIds)，模型在观测时间点的预测
%   sim    规范化的仿真结果：t / Y / series(struct，字段为 output id) / p / solver
%   info   solver 名称、warnings 等
%
% 说明：
%   优先调用 bma.model.simulate（core 契约）；当 core 尚未就绪（或调用失败、
%   模型未提供 outputs 函数）时，退化为使用 m.rhs 的内置 ODE 积分路径，
%   以保证 fit 模块在缺少 core 时仍可自测。积分后用 m.outputs(j).fh(y,p)
%   求输出，避免依赖 simulate 返回值中 outputs 的具体形状。

if nargin < 4 || isempty(opts)
    opts = struct();
end
if isempty(data) || ~isfield(data, 't') || isempty(data.t)
    error('bma:fit:simNoData', 'bma.fit.simulatePredictions 需要带时间点的数据。');
end

spec = modelSpec(m);
tData = double(data.t(:));
tEnd = max(tData);
tStart = simulationStart(spec, tData);
nGrid = simGridSize(spec, tData, opts);

% 完整的参数覆盖结构（参数 id → 数值）
pStruct = paramsToStruct(m, pVec);
if isfield(opts, 'param_overrides') && isstruct(opts.param_overrides)
    names = fieldnames(opts.param_overrides);
    for k = 1:numel(names)
        pStruct.(names{k}) = double(opts.param_overrides.(names{k}));
    end
end
pVecFull = structToParams(m, pStruct);

solver = 'ode15s';
if isfield(opts, 'solver') && ~isempty(opts.solver)
    solver = char(opts.solver);
end
rtol = 1e-6;
if isfield(opts, 'rtol') && ~isempty(opts.rtol), rtol = double(opts.rtol); end
atol = 1e-9;
if isfield(opts, 'atol') && ~isempty(opts.atol), atol = double(opts.atol); end

info = struct('solver', solver, 'warnings', {{}}, 'used_core_simulate', false, ...
    'n_grid', nGrid, 't_start', tStart, 't_end', tEnd);

% ------------------------------------------------------------------
% 1) 仿真：优先 core，失败则内置积分
% ------------------------------------------------------------------
% 把观测时间点并入输出网格：若 core 支持 opts.tspan，则观测时刻可直接命中，
% 无需插值；否则在较密的网格上插值。
tCoarse = linspace(tStart, tEnd, nGrid).';
tSpan = unique([tCoarse; tData]);
tSpan = sort(tSpan(:));
res = [];
maxSeconds = Inf;
coreAvailable = true;
if coreAvailable
    simOpts = struct();
    simOpts.time_end = tEnd;
    simOpts.n = numel(tSpan);
    simOpts.tspan = tSpan;
    simOpts.solver = solver;
    simOpts.rtol = rtol;
    simOpts.atol = atol;
    simOpts.param_overrides = pStruct;
    if isfield(opts, 'mass_matrix') && ~isempty(opts.mass_matrix)
        simOpts.mass_matrix = opts.mass_matrix;
    end
    if isfield(opts, 'initial_overrides') && ~isempty(opts.initial_overrides)
        simOpts.initial_overrides = opts.initial_overrides;
    end
    if isfield(opts, 'max_seconds') && ~isempty(opts.max_seconds)
        maxSeconds = double(opts.max_seconds);
        simOpts.max_seconds = maxSeconds;
    end
    try
        res = bma.model.simulate(m, simOpts);
        info.used_core_simulate = true;
        if isfield(res, 'timed_out') && res.timed_out
            error('bma:fit:simTimeout', '仿真超过单样本墙钟上限 %.1f s，判定该样本失败。', maxSeconds);
        end
    catch err
        if isfield(m, 'kind') && any(strcmpi(char(m.kind), {'dde', 'bvp', 'dae'}))
            rethrow(err);
        end
        info.warnings{end+1} = sprintf('core 仿真失败，改用内置积分：%s', err.message);
        res = [];
        if strcmp(err.identifier, 'bma:fit:simTimeout')
            rethrow(err);
        end
    end
end
if isempty(res)
    [simT, simY] = localIntegrate(m, spec, pVecFull, tSpan, solver, rtol, atol, maxSeconds);
else
    [simT, simY] = normalizeCoreResult(res);
    % core 返回非有限解时，用内置积分再试一次（更可控的容差与降级）。
    if any(~isfinite(simY(:)))
        info.warnings{end+1} = 'core 仿真结果含非有限值，改用内置积分重算。';
        try
            [simT2, simY2] = localIntegrate(m, spec, pVecFull, tSpan, solver, rtol, atol, maxSeconds);
            if all(isfinite(simY2(:)))
                simT = simT2;
                simY = simY2;
            end
        catch err
            info.warnings{end+1} = sprintf('内置积分重算失败：%s', err.message);
        end
    end
end

if isempty(simT) || isempty(simY)
    error('bma:fit:simFailed', '仿真失败：未得到有效时间序列。');
end
if numel(simT) ~= size(simY, 1)
    error('bma:fit:simShape', '仿真结果形状异常：t=%d，Y=%d×%d。', ...
        numel(simT), size(simY, 1), size(simY, 2));
end
simT = simT(:);
if any(~isfinite(simY(:)))
    info.warnings{end+1} = '仿真输出包含非有限值（NaN/Inf），拟合将施加惩罚。';
end

% ------------------------------------------------------------------
% 2) 求 output 时间序列
% ------------------------------------------------------------------
series = struct();
if exist('res', 'var') && isstruct(res)
    series = seriesFromCore(res, simT);
end
if isempty(fieldnames(series))
    series = evalOutputs(m, spec, simT, simY, pVecFull, info);
end

% ------------------------------------------------------------------
% 3) 按数据时间点取样
% ------------------------------------------------------------------
ids = data.colIds;
if isfield(data, 'outputMapIds') && ~isempty(data.outputMapIds)
    ids = data.outputMapIds;
end
pred = NaN(numel(tData), numel(ids));
for j = 1:numel(ids)
    id = char(ids{j});
    if ~isfield(series, id)
        error('bma:fit:outputMissing', ...
            '仿真结果中缺少 output "%s"（模型 outputs: %s）。', ...
            id, strjoin(fieldnames(series).', ', '));
    end
    vals = series.(id)(:);
    if numel(vals) ~= numel(simT)
        error('bma:fit:seriesLength', 'output "%s" 长度 %d 与时间点 %d 不一致。', ...
            id, numel(vals), numel(simT));
    end
    % 若观测时刻恰好落在输出网格上（tspan 并入了数据时间），直接取值。
    [hit, loc] = matchTimes(simT, tData);
    if hit
        pred(:, j) = vals(loc);
    else
        pred(:, j) = interp1(simT, vals, tData, 'linear', NaN);
    end
end

sim = struct('t', simT, 'Y', simY, 'series', series, 'p', pVecFull, ...
    'solver', solver, 'warnings', {info.warnings});
end

% ======================================================================
% 局部函数
% ======================================================================
function spec = modelSpec(m)
if isstruct(m) && isfield(m, 'spec') && ~isempty(m.spec)
    spec = m.spec;
else
    error('bma:fit:noSpec', '模型结构缺少 m.spec，无法确定时间轴与参数。');
end
end

function tStart = simulationStart(spec, tData)
tStart = min(tData);
if isfield(spec, 'time') && isstruct(spec.time) && isfield(spec.time, 'start') ...
        && ~isempty(spec.time.start)
    tStart = min(tStart, double(spec.time.start));
end
end

function n = simGridSize(spec, tData, opts)
%SIMGRIDSIZE 选择仿真输出网格点数：覆盖数据分辨率，同时控制计算量。
% 观测时刻会并入 tspan，故网格只需保证时间轴覆盖与求解器精度，无需过密。
nData = numel(tData);
n = max(201, 2 * nData + 1);
n = min(n, 4001);
if isfield(opts, 'n') && ~isempty(opts.n)
    n = double(opts.n);
end
n = max(2, round(n));
end

function [hit, loc] = matchTimes(simT, tData)
%MATCHTIMES 判断数据时刻是否都精确落在仿真输出网格上；是则返回索引。
hit = false;
loc = zeros(numel(tData), 1);
simT = simT(:);
for k = 1:numel(tData)
    [d, idx] = min(abs(simT - tData(k)));
    tol = 1e-9 * max(1, abs(tData(k)));
    if isempty(d) || d > tol
        loc = [];
        return
    end
    loc(k) = idx;
end
hit = true;
end

function pStruct = paramsToStruct(m, pVec)
%PARAMSTOSTRUCT 参数向量/struct → 字段名=参数 id 的 struct。
names = m.params;
if isstruct(pVec)
    pStruct = struct();
    for k = 1:numel(names)
        if isfield(pVec, names{k})
            pStruct.(names{k}) = double(pVec.(names{k}));
        end
    end
    return
end
pVec = double(pVec(:));
if numel(pVec) ~= numel(names)
    error('bma:fit:paramLength', '参数向量长度 %d 与模型参数个数 %d 不一致。', ...
        numel(pVec), numel(names));
end
pStruct = struct();
for k = 1:numel(names)
    pStruct.(names{k}) = pVec(k);
end
end

function pVec = structToParams(m, pStruct)
names = m.params;
pVec = zeros(numel(names), 1);
for k = 1:numel(names)
    if ~isfield(pStruct, names{k})
        error('bma:fit:paramMissing', '参数字段缺失：%s', names{k});
    end
    pVec(k) = double(pStruct.(names{k}));
end
end

function [t, Y] = localIntegrate(m, spec, pVec, tSpan, solver, rtol, atol, maxSeconds)
%LOCALINTEGRATE 使用 m.rhs 直接积分（core 缺失时的降级路径）。
t = [];
Y = [];
if ~isfield(m, 'rhs') || isempty(m.rhs)
    error('bma:fit:noRhs', '模型结构缺少 m.rhs，无法进行内置积分。');
end
y0 = initialVector(m, spec);
rhs = @(tt, yy) m.rhs(tt, yy(:), pVec);
odeOpts = odeset('RelTol', rtol, 'AbsTol', atol, 'MaxStep', max(tSpan(end) - tSpan(1), eps) / 5);
solverName = lower(strrep(solver, 'ode', 'ode'));
candidates = {solverName, 'ode15s', 'ode45', 'ode23s'};
lastErr = [];
for k = 1:numel(candidates)
    try
        [t, Y] = feval(candidates{k}, rhs, tSpan, y0, odeOpts);
        if ~isempty(t) && all(isfinite(Y(:)))
            return
        end
        lastErr = sprintf('%s 返回非有限解', candidates{k});
    catch err
        lastErr = err.message;
    end
end
error('bma:fit:integrateFailed', '内置 ODE 积分失败：%s', lastErr);
end

function y0 = initialVector(m, spec)
%INITIALVECTOR 按 m.species 顺序组装初值。
if isfield(m, 'species') && ~isempty(m.species)
    species = cellstr(m.species);
elseif isfield(spec, 'variables') && ~isempty(spec.variables)
    species = arrayfun(@(v) char(v.id), spec.variables, 'UniformOutput', false);
else
    error('bma:fit:noSpecies', '无法确定状态变量顺序（m.species 为空）。');
end
y0 = zeros(numel(species), 1);
if isfield(spec, 'variables') && ~isempty(spec.variables)
    for k = 1:numel(spec.variables)
        v = spec.variables(k);
        idx = find(strcmp(species, char(v.id)), 1);
        if isempty(idx)
            continue
        end
        if isfield(v, 'initial') && isstruct(v.initial) && isfield(v.initial, 'value') ...
                && ~isempty(v.initial.value)
            y0(idx) = double(v.initial.value);
        end
    end
end
if isfield(m, 'spec') && isfield(m.spec, 'variables')
    % 以 m.spec 为准（build 阶段可能已归一化）
    vars = m.spec.variables;
    for k = 1:numel(vars)
        v = vars(k);
        idx = find(strcmp(species, char(v.id)), 1);
        if isempty(idx)
            continue
        end
        if isfield(v, 'initial') && isstruct(v.initial) && isfield(v.initial, 'value') ...
                && ~isempty(v.initial.value)
            y0(idx) = double(v.initial.value);
        end
    end
end
end

function series = seriesFromCore(res, simT)
%SERIESFROMCORE Use res.outputs (BVP/DDE already evaluate their output
%expressions at their own grid) and interpolate to the fit grid.
series = struct();
if ~isfield(res, 'outputs') || isempty(res.outputs)
    return
end
outs = res.outputs;
if ~isstruct(outs) || ~isfield(outs, 'id')
    return
end
for j = 1:numel(outs)
    id = char(outs(j).id);
    yy = [];
    if isfield(outs(j), 'y') && ~isempty(outs(j).y)
        yy = double(outs(j).y(:));
    elseif isfield(outs(j), 'values') && ~isempty(outs(j).values)
        yy = double(outs(j).values(:));
    end
    if isempty(yy), continue; end
    tt = simT;
    if isfield(outs(j), 't') && ~isempty(outs(j).t)
        to = double(outs(j).t(:));
        if numel(to) == numel(yy) && numel(to) ~= numel(simT)
            yy = interp1(to, yy, simT, 'linear', NaN);
        end
    end
    if numel(yy) == numel(tt)
        series.(id) = yy;
    end
end
end

function [t, Y] = normalizeCoreResult(res)
t = [];
Y = [];
if isstruct(res)
    if isfield(res, 't') && ~isempty(res.t)
        t = double(res.t(:));
    elseif isfield(res, 'times') && ~isempty(res.times)
        t = double(res.times(:));
    elseif isfield(res, 'time') && isnumeric(res.time) && numel(res.time) > 1
        t = double(res.time(:));
    end
    if isfield(res, 'Y') && ~isempty(res.Y)
        Y = double(res.Y);
    end
end
if ~isempty(t) && ~isempty(Y) && size(Y, 1) ~= numel(t) && size(Y, 2) == numel(t)
    Y = Y.';
end
end

function series = evalOutputs(m, spec, t, Y, pVec, info)
%EVALOUTPUTS 用 m.outputs(j).fh(y,p) 计算各 output 时间序列。
series = struct();
outs = [];
if isfield(m, 'outputs') && ~isempty(m.outputs)
    outs = m.outputs;
end
outIds = {};
if isstruct(outs)
    if isfield(outs, 'id')
        outIds = arrayfun(@(s) char(s.id), outs, 'UniformOutput', false);
    else
        outIds = fieldnames(outs).';
    end
elseif iscell(outs)
    outIds = cellfun(@(s) char(s.id), outs, 'UniformOutput', false);
end
if isempty(outIds) && isfield(spec, 'outputs') && ~isempty(spec.outputs)
    outIds = arrayfun(@(s) char(s.id), spec.outputs, 'UniformOutput', false);
end
if isempty(outIds)
    outIds = cellstr(m.species);
    series = statesAsSeries(m, Y);
    return
end

for j = 1:numel(outIds)
    id = outIds{j};
    fh = [];
    if isstruct(outs) && numel(outs) >= j
        if isfield(outs, 'fh') && ~isempty(outs(j).fh)
            fh = outs(j).fh;
        elseif isfield(outs, 'fun') && ~isempty(outs(j).fun)
            fh = outs(j).fun;
        end
    end
    if ~isempty(fh)
        series.(id) = applyOutputFcn(fh, Y, pVec);
    else
        % 位置回退：output id 与 species 同名 → 取状态列
        sidx = find(strcmp(cellstr(m.species), id), 1);
        if ~isempty(sidx)
            series.(id) = Y(:, sidx);
        else
            info.warnings{end+1} = sprintf( ...
                'output "%s" 没有可用的求值函数 fh，已用 NaN 填充。', id);
            series.(id) = NaN(size(Y, 1), 1);
        end
    end
end
end

function vals = applyOutputFcn(fh, Y, pVec)
%APPLYOUTPUTFCN 统一 fh(y,p) 的调用方式（向量化失败则逐点调用）。
n = size(Y, 1);
try
    v = fh(Y.', pVec);
    if isnumeric(v)
        v = double(v);
        if numel(v) == n
            vals = v(:);
            return
        end
    end
catch
end
vals = zeros(n, 1);
for k = 1:n
    yCol = Y(k, :).';
    v = [];
    try
        v = fh(yCol, pVec);
    catch
        try
            v = fh(Y(k, :), pVec);
        catch
            try
                v = fh(yCol);
            catch
                v = NaN;
            end
        end
    end
    if isempty(v)
        vals(k) = NaN;
    else
        v = double(v);
        vals(k) = v(1);
    end
end
end

function series = statesAsSeries(m, Y)
series = struct();
species = cellstr(m.species);
for k = 1:min(numel(species), size(Y, 2))
    series.(species{k}) = Y(:, k);
end
end


% ---------------------------------------------------------------------------
function [value, isterminal, direction] = wallClockEventFit(~, ~, startTic, maxSeconds)
%WALLCLOCKEVENTFIT Stop an internal ODE integration over its wall-clock budget.
value = double(toc(startTic) > maxSeconds);
isterminal = 1;
direction = 0;
end
