function res = simulate(m, varargin)
%SIMULATE 数值求解 ODE 模型（DESIGN §5.3 / §4.4 model.simulate）。
%   res = bma.model.simulate(m)
%   res = bma.model.simulate(m, opts)
%   res = bma.model.simulate(m, 'TimeEnd', 60, 'Solver', 'ode45')
%   res = bma.model.simulate(spec, opts)          % 也接受模型规格
%
% opts 支持（字段名大小写不敏感，未知字段忽略）：
%   solver            'ode15s'（默认）/ 'ode45' / 'ode23s' / 'ode23t' / 'ode113'
%   rtol / atol       相对/绝对容差（默认 1e-6 / 1e-9）
%   time_end          覆盖仿真终止时间
%   n                 输出时间点数量（默认 spec.time.n）
%   tspan             [t0 tEnd] 或自定义时间向量（覆盖 time_end/n）
%   initial_overrides struct：物种 id → 初值（也接受与物种数等长的数值向量）
%   param_overrides   struct：参数 id → 数值（也接受与参数数等长的数值向量）
%   maxstep           最大步长
%   run_dir           给出时把时间序列写入 <run_dir>/data/<name>_simulation.csv
%   timeseries_path   显式指定 CSV 输出路径（相对路径基于 run_dir）
%   work_dir          给出时额外返回相对路径 timeseries_rel
%   write_csv         是否写 CSV（默认 true）
%
% 返回 res（绝不对求解失败抛异常）：
%   .t (N×1)  .Y (N×nSpecies)  .outputs(struct array {id,name,unit,t,y,final,min,max})
%   .outputSummary（struct，字段名=output id → {final,min,max,t,unit}，供 RPC 精简返回）
%   .solver .requested_solver .success .warnings(cellstr) .stats
%   .initial/.paramValues（struct，id→数值）.species/.timeUnit/.tspan
%   .timeseries_path（写 CSV 时，绝对路径）
if nargin < 1 || isempty(m)
    error('bma:model:model_invalid', 'bma.model.simulate 需要模型结构或模型规格');
end
opts = parseOptions(varargin);
if ischar(m) || isstring(m)
    m = bma.model.build(char(m));
end
if isstruct(m) && isfield(m, 'kind') && strcmpi(char(m.kind), 'dde') ...
        && isfield(m, 'delays') && isfield(m, 'history')
    res = bma.dde.simulate(m, opts);
    return
end
if isstruct(m) && isfield(m, 'kind') && strcmpi(char(m.kind), 'bvp') ...
        && isfield(m, 'odefun') && isfield(m, 'bcfun')
    res = bma.bvp.solve(m, opts);
    return
end
if isstruct(m) && isfield(m, 'kind') && strcmpi(char(m.kind), 'dae') ...
        && isfield(m, 'residual') && isfield(m, 'initial_derivative')
    res = bma.dae.simulate(m, opts);
    return
end
if isstruct(m) && isfield(m, 'kind') && ~isfield(m, 'rhs') ...
        && any(strcmpi(char(m.kind), {'dde', 'bvp', 'dae'}))
    m = bma.model.build(m);
    if strcmpi(char(m.kind), 'dde')
        res = bma.dde.simulate(m, opts);
    elseif strcmpi(char(m.kind), 'bvp')
        res = bma.bvp.solve(m, opts);
    else
        res = bma.dae.simulate(m, opts);
    end
    return
end
if ~isstruct(m) || ~isfield(m, 'rhs')
    if isstruct(m) && isfield(m, 'schema_version') && isfield(m, 'variables')
        m = bma.model.build(m);
    else
        error('bma:model:model_invalid', 'bma.model.simulate 需要 bma.model.build 返回的模型结构或模型规格');
    end
end
if isfield(m, 'kind') && strcmpi(char(m.kind), 'dde')
    res = bma.dde.simulate(m, opts);
    return
end
if isfield(m, 'kind') && strcmpi(char(m.kind), 'bvp')
    res = bma.bvp.solve(m, opts);
    return
end
if isfield(m, 'kind') && strcmpi(char(m.kind), 'dae')
    res = bma.dae.simulate(m, opts);
    return
end
if ~isfield(m, 'speciesIndex') || ~isa(m.speciesIndex, 'containers.Map')
    m.speciesIndex = containers.Map(m.species, num2cell(1:numel(m.species)));
end
if ~isfield(m, 'paramIndex') || ~isa(m.paramIndex, 'containers.Map')
    m.paramIndex = containers.Map(m.params, num2cell(1:numel(m.params)));
end
t0Total = tic;
warnings = {};

% ---- 时间网格 ----
tt = m.time;
tSpecStart = numericOr(getFieldLocal(tt, 'start', 0), 0);
tSpecEnd = numericOr(getFieldLocal(tt, 'end', 100), 100);
nSpec = numericOr(getFieldLocal(tt, 'n', 101), 101);
tStart = tSpecStart;
tEnd = tSpecEnd;
tvec = [];
if ~isempty(opts.tspan) && isnumeric(opts.tspan) && numel(opts.tspan) >= 2
    tsp = opts.tspan(:)';
    tStart = tsp(1);
    tEnd = tsp(end);
    if numel(tsp) > 2
        tvec = tsp(:);
    end
end
if ~isempty(opts.time_end)
    tEnd = opts.time_end;
    tvec = [];
end
if isempty(tvec)
    n = nSpec;
    if ~isempty(opts.n)
        n = opts.n;
    end
    if ~isnumeric(n) || ~isscalar(n) || ~isfinite(n) || n < 2
        warnings{end+1} = '输出点数 n 非法，已改为 101';
        n = 101;
    end
    n = round(n);
    tvec = linspace(tStart, tEnd, n)';
else
    tEnd = tvec(end);
end
if ~(isnumeric(tEnd) && isscalar(tEnd) && isfinite(tEnd) && tEnd > tStart)
    error('bma:sim:sim_invalid', '仿真终止时间必须大于起始时间（tStart=%g, tEnd=%g）', tStart, tEnd);
end
if numel(tvec) < 2
    tvec = linspace(tStart, tEnd, 2)';
end

% ---- 初值 / 参数覆盖 ----
y0 = m.initial;
p = m.paramValues;
[y0, w] = applyOverrides(y0, m.speciesIndex, opts.initial_overrides, '初值');
warnings = [warnings, w]; %#ok<AGROW>
[p, w] = applyOverrides(p, m.paramIndex, opts.param_overrides, '参数');
warnings = [warnings, w]; %#ok<AGROW>
if any(~isfinite(y0))
    error('bma:sim:sim_invalid', '初值包含 NaN/Inf，无法仿真');
end
if any(~isfinite(p))
    error('bma:sim:sim_invalid', '参数包含 NaN/Inf，无法仿真');
end

% ---- 求解器 ----
requestedSolver = lower(char(opts.solver));
validSolvers = {'ode15s', 'ode45', 'ode23s', 'ode23t', 'ode23tb', 'ode113', 'ode23'};
if ~any(strcmp(requestedSolver, validSolvers))
    warnings{end+1} = sprintf('未知求解器 "%s"，已使用 ode15s', requestedSolver);
    requestedSolver = 'ode15s';
end
solver = requestedSolver;
solOpts = odeset('RelTol', opts.rtol, 'AbsTol', opts.atol);
if ~isempty(opts.mass_matrix)
    M = opts.mass_matrix;
    if ~isnumeric(M) || size(M, 1) ~= numel(y0) || size(M, 2) ~= numel(y0) ...
            || any(~isfinite(M(:)))
        error('bma:sim:sim_invalid', 'mass_matrix 必须是 %d×%d 的有限数值矩阵', ...
            numel(y0), numel(y0));
    end
    if ~any(strcmp(solver, {'ode15s', 'ode23s', 'ode23t', 'ode23tb'}))
        warnings{end+1} = sprintf('质量矩阵需要隐式 solver；已将 %s 改为 ode15s', solver); %#ok<AGROW>
        solver = 'ode15s';
    end
    singular = rank(M) < numel(y0);
    if singular
        warnings{end+1} = 'mass_matrix 奇异：按线性隐式 DAE 处理；请确保初值满足代数约束。'; %#ok<AGROW>
    end
    if singular
        massSingular = 'maybe';
    else
        massSingular = 'no';
    end
    solOpts = odeset(solOpts, 'Mass', M, 'MassSingular', massSingular);
end
if ~isempty(opts.maxstep)
    solOpts = odeset(solOpts, 'MaxStep', opts.maxstep);
end
solverStart = tic;
timedOut = false;
if isfinite(opts.max_seconds) && opts.max_seconds > 0
    solOpts = odeset(solOpts, 'Events', ...
        @(tt, yy) wallClockEvent(tt, yy, solverStart, opts.max_seconds));
end
odefun = @(t, y) m.rhs(t, y, p);
[t, Y, ok, errMsg, nSteps] = runSolver(solver, odefun, tvec, y0, solOpts);
if ~ok && ~strcmp(solver, 'ode15s')
    warnings{end+1} = sprintf('%s 求解失败（%s），自动回退 ode15s 重试', solver, errMsg);
    [t, Y, ok, errMsg2, nSteps] = runSolver('ode15s', odefun, tvec, y0, solOpts);
    if ok
        solver = 'ode15s';
        warnings{end+1} = 'ode15s 回退成功';
    else
        solver = [solver '→ode15s'];
        errMsg = [errMsg '；' errMsg2];
    end
end
if isfinite(opts.max_seconds) && opts.max_seconds > 0 && toc(solverStart) > 0.98 * opts.max_seconds
    timedOut = true;
    ok = false;
    errMsg = sprintf('仿真超过墙钟上限 %.1f s，已提前终止', opts.max_seconds);
    warnings{end+1} = errMsg;
end
if ok
    % 保证输出严格落在请求的时间网格上
    if numel(t) ~= numel(tvec) || any(abs(t(:) - tvec(:)) > 1e-12)
        try
            Y = interp1(t(:), Y, tvec, 'linear');
            t = tvec;
        catch
            % 插值失败时保留求解器输出（极少发生）
        end
    end
else
    warnings{end+1} = sprintf('数值求解未成功：%s', errMsg);
    t = tvec;
    Y = nan(numel(tvec), numel(y0));
end
nS = numel(y0);

% ---- 数值诊断 ----
if ok && all(isfinite(Y(:)))
    % 负浓度
    negTol = 1e-8 * max(1, max(abs(y0)));
    signedMask = false(1, numel(m.species));
    try
        if isfield(m, 'spec') && isfield(m.spec, 'variables')
            for vk = 1:numel(m.spec.variables)
                if isfield(m.spec.variables(vk), 'signed') && ~isempty(m.spec.variables(vk).signed) ...
                        && logical(m.spec.variables(vk).signed)
                    pos = find(strcmp(cellstr(m.species), char(m.spec.variables(vk).id)), 1);
                    if ~isempty(pos)
                        signedMask(pos) = true;
                    end
                end
            end
        end
    catch
    end
    negIdx = find(min(Y, [], 1) < -negTol & ~signedMask);
    if ~isempty(negIdx)
        parts = cell(1, numel(negIdx));
        for k = 1:numel(negIdx)
            i = negIdx(k);
            parts{k} = sprintf('%s(%g)', m.species{i}, min(Y(:, i)));
        end
        warnings{end+1} = sprintf('出现负浓度（数值误差或模型本身不守恒）：%s。建议检查速率定律、减小步长或改用 ode15s。', ...
            strjoin(parts, ', '));
    end
    % 守恒量漂移（左零空间）
    try
        Z = null(m.S.', 1e-10);
        if ~isempty(Z) && size(Z, 2) > 0
            C = Z.' * Y.';
            scale = max(1, max(abs(C(:))));
            drift = max(abs(C - C(:, 1)), [], 'all') / scale;
            if drift > 1e-4
                warnings{end+1} = sprintf('守恒量在数值解中漂移 %.2e（相对），建议减小容差或改用 ode15s', drift);
            end
        end
    catch
        % 守恒诊断失败不影响主流程
    end
    % 刚性提示（ode45 且特征值时间尺度悬殊）
    if strcmp(solver, 'ode45')
        try
            J0 = numericJacobian(@(yy) m.rhs(0, yy, p), y0);
            lam = eig(J0);
            lam = lam(isfinite(lam));
            if ~isempty(lam) && max(abs(lam)) > 1e3
                warnings{end+1} = sprintf('系统在初始点最大特征值模为 %.3g，可能存在刚性，建议 solver="ode15s"', ...
                    max(abs(lam)));
            end
        catch
        end
    end
end

% ---- 输出量 ----
nO = m.n_outputs;
outputNames = cell(1, nO);
if nO > 0 && isfield(m.outputs, 'id')
    for o = 1:nO
        outputNames{o} = m.outputs(o).id;
    end
end
outputs = repmat(struct('id', '', 'name', '', 'unit', '', 'expression', '', ...
    'final', NaN, 'min', NaN, 'max', NaN), 1, nO);
outVals = cell(1, nO);
summary = struct();
for o = 1:nO
    yv = nan(numel(tvec), 1);
    if ok && all(isfinite(Y(:)))
        try
            fh = m.outputs(o).fh;
            for k = 1:numel(tvec)
                yv(k) = fh(Y(k, :).', p);
            end
        catch
            yv(:) = NaN;
        end
    end
    outVals{o} = yv;
    outputs(o).id = m.outputs(o).id;
    outputs(o).name = m.outputs(o).name;
    outputs(o).unit = m.outputs(o).unit;
    outputs(o).expression = m.outputs(o).expression;
    if any(isfinite(yv))
        outputs(o).final = yv(end);
        outputs(o).min = min(yv, [], 'omitnan');
        outputs(o).max = max(yv, [], 'omitnan');
    end
    entry = struct('final', outputs(o).final, 'min', outputs(o).min, ...
        'max', outputs(o).max, 't', tvec(end), 'unit', m.outputs(o).unit);
    try
        summary.(m.outputs(o).id) = entry;
    catch
        summary.(matlab.lang.makeValidName(m.outputs(o).id)) = entry;
    end
end
% 可选：把每个输出的完整时间序列放进 res.outputSeries（默认关闭，避免 RPC 回传大数组）
outputSeries = {};
if isfield(opts, 'include_series') && opts.include_series
    outputSeries = cell(1, nO);
    for o = 1:nO
        outputSeries{o} = struct('id', m.outputs(o).id, 't', tvec, 'y', outVals{o});
    end
end

% ---- 时间序列 CSV ----
timeseriesPath = '';
if opts.write_csv && (~isempty(opts.timeseries_path) || ~isempty(opts.run_dir))
    try
        timeseriesPath = writeTimeseriesCsv(m, tvec, Y, outVals, opts);
    catch err
        warnings{end+1} = sprintf('写时间序列 CSV 失败：%s', err.message);
    end
end

% ---- 汇总 ----
res = struct();
res.schema_version = 'bma.simulation.v1';
res.name = m.name;
res.success = ok;
res.ok = ok;
res.timed_out = timedOut;
if isfinite(opts.max_seconds) && opts.max_seconds > 0
    res.max_seconds = opts.max_seconds;
end
res.solver = solver;
res.requested_solver = requestedSolver;
res.t = tvec;
res.Y = Y;
res.species = m.species;
res.timeUnit = m.timeUnit;
res.tspan = [tStart, tEnd];
res.initial = vectorToStruct(y0, m.species);
res.paramValues = vectorToStruct(p, m.params);
res.outputs = outputs;
res.outputSummary = summary;
try
    res.oscillation = bma.model.oscillationMetrics(tvec, Y, m.species, opts);
catch err
    res.oscillation_warning = err.message;
end
if ~isempty(outputSeries)
    res.outputSeries = outputSeries;
end
if ok && all(isfinite(Y(:)))
    res.final = vectorToStruct(Y(end, :).', m.species);
else
    res.final = struct();
end
res.warnings = reshape(warnings, 1, []);
res.stats = struct('elapsed_ms', round(toc(t0Total) * 1000), ...
    'n_points', numel(tvec), 'n_solver_steps', nSteps, ...
    'n_species', nS, 'n_reactions', m.n_reactions, 'n_params', m.n_params);
if ~isempty(timeseriesPath)
    res.timeseries_path = timeseriesPath;
    if ~isempty(opts.work_dir)
        try
            res.timeseries_rel = bma.util.relPath(opts.work_dir, timeseriesPath);
        catch
        end
    end
end
end

% =========================================================================
% 选项解析与工具函数
% =========================================================================
function opts = parseOptions(args)
opts = struct();
if isempty(args)
    raw = struct();
elseif numel(args) == 1 && isstruct(args{1})
    raw = args{1};
else
    % name-value 形式
    raw = struct();
    if mod(numel(args), 2) ~= 0
        error('bma:model:model_invalid', 'simulate 的 name-value 参数必须成对出现');
    end
    for k = 1:2:numel(args)
        name = args{k};
        if ~ischar(name) && ~(isstring(name) && isscalar(name))
            error('bma:model:model_invalid', 'simulate 的 name-value 参数名必须是字符串');
        end
        raw.(char(name)) = args{k+1};
    end
end
% 字段名大小写/别名映射
aliases = struct( ...
    'solver', 'solver', ...
    'rtol', 'rtol', 'reltol', 'rtol', 'rel_tol', 'rtol', ...
    'atol', 'atol', 'abstol', 'atol', 'abs_tol', 'atol', ...
    'n', 'n', 'npoints', 'n', 'n_points', 'n', 'points', 'n', ...
    'time_end', 'time_end', 't_end', 'time_end', 'tend', 'time_end', ...
    'end_time', 'time_end', 'tspan', 'tspan', ...
    'initial_overrides', 'initial_overrides', 'initialoverrides', 'initial_overrides', ...
    'param_overrides', 'param_overrides', 'paramoverrides', 'param_overrides', ...
    'run_dir', 'run_dir', 'rundir', 'run_dir', 'runDir', 'run_dir', ...
    'timeseries_path', 'timeseries_path', 'timeseriespath', 'timeseries_path', ...
    'work_dir', 'work_dir', 'workdir', 'work_dir', ...
    'maxstep', 'maxstep', 'max_step', 'maxstep', ...
    'mass_matrix', 'mass_matrix', 'mass', 'mass_matrix', 'massmatrix', 'mass_matrix', ...
    'max_seconds', 'max_seconds', 'maxseconds', 'max_seconds', 'timeout_s', 'max_seconds', ...
    'write_csv', 'write_csv', 'writecsv', 'write_csv', ...
    'include_series', 'include_series', 'includeseries', 'include_series');
fn = fieldnames(raw);
for k = 1:numel(fn)
    key = lower(fn{k});
    if isfield(aliases, key)
        opts.(aliases.(key)) = raw.(fn{k});
    elseif isfield(aliases, fn{k})
        opts.(aliases.(fn{k})) = raw.(fn{k});
    end
    % 未知字段：宽松忽略（RPC options 可能包含其他模块字段）
end
% 缺省值
defaults = struct('solver', 'ode15s', 'rtol', 1e-6, 'atol', 1e-9, ...
    'n', [], 'time_end', [], 'tspan', [], ...
    'initial_overrides', struct(), 'param_overrides', struct(), ...
    'run_dir', '', 'timeseries_path', '', 'work_dir', '', ...
    'maxstep', [], 'max_seconds', Inf, 'write_csv', true, 'include_series', false, ...
    'mass_matrix', []);
fn = fieldnames(defaults);
for k = 1:numel(fn)
    if ~isfield(opts, fn{k})
        opts.(fn{k}) = defaults.(fn{k});
    end
end
if ~isnumeric(opts.rtol) || ~isscalar(opts.rtol) || opts.rtol <= 0
    opts.rtol = 1e-6;
end
if ~isnumeric(opts.atol) || ~isscalar(opts.atol) || opts.atol <= 0
    opts.atol = 1e-9;
end
end

function [v, warnings] = applyOverrides(v, idIndex, ov, label)
warnings = {};
if isempty(ov)
    return
end
if isnumeric(ov) && numel(ov) == numel(v)
    v = ov(:);
    if isempty(warnings)
        warnings = {sprintf('%s覆盖以数值向量给出，已按顺序整体替换', label)};
    end
    return
end
if isa(ov, 'containers.Map')
    keys_ = ov.keys;
    for k = 1:numel(keys_)
        name = char(keys_{k});
        val = ov(keys_{k});
        [v, warnings] = applyOne(v, idIndex, name, val, label, warnings);
    end
elseif isstruct(ov)
    fn = fieldnames(ov);
    for k = 1:numel(fn)
        [v, warnings] = applyOne(v, idIndex, fn{k}, ov.(fn{k}), label, warnings);
    end
else
    warnings{end+1} = sprintf('%s覆盖（%s）类型不支持，已忽略（应为 struct: id→数值）', label, class(ov));
end
end

function [v, warnings] = applyOne(v, idIndex, name, val, label, warnings)
if ~isKey(idIndex, name)
    warnings{end+1} = sprintf('%s覆盖中的 id "%s" 不存在，已忽略', label, name);
    return
end
if ~isnumeric(val) || ~isscalar(val) || ~isfinite(val)
    warnings{end+1} = sprintf('%s覆盖 "%s" 的数值非法，已忽略', label, name);
    return
end
v(idIndex(name)) = val;
end

function [t, Y, ok, msg, nSteps] = runSolver(solverName, odefun, tvec, y0, solOpts)
ok = false;
msg = '';
nSteps = 0;
t = tvec;
Y = nan(numel(tvec), numel(y0));
try
    f = str2func(solverName);
    [t, Y] = f(odefun, tvec, y0, solOpts);
    ok = true;
catch err
    msg = err.message;
    t = tvec;
    Y = nan(numel(tvec), numel(y0));
end
if ok
    nSteps = numel(t);
    if isempty(t) || t(end) < tvec(end) - 1e-9 * max(1, abs(tvec(end)))
        ok = false;
        msg = '求解器未到达终止时间';
    elseif any(~isfinite(Y(:)))
        ok = false;
        msg = '数值解中出现 NaN/Inf（模型可能发散或刚性过强）';
    end
end
end

function J = numericJacobian(fun, x)
n = numel(x);
J = zeros(n, n);
h = 1e-6 * max(1, abs(x(:)));
for j = 1:n
    xp = x; xp(j) = xp(j) + h(j);
    xm = x; xm(j) = xm(j) - h(j);
    J(:, j) = (fun(xp) - fun(xm)) / (2 * h(j));
end
end

function path = writeTimeseriesCsv(m, tvec, Y, outVals, opts)
if ~isempty(opts.timeseries_path)
    raw = char(opts.timeseries_path);
    isAbs = ~isempty(regexp(raw, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'));
    if isAbs
        path = raw;
    else
        base = char(opts.run_dir);
        if isempty(base)
            base = pwd;
        end
        path = fullfile(base, strrep(raw, '/', filesep));
    end
else
    path = fullfile(char(opts.run_dir), 'data', [m.name '_simulation.csv']);
end
bma.util.ensureDir(fileparts(path));
header = {'time'};
cols = {tvec};
for i = 1:numel(m.species)
    header{end+1} = m.species{i}; %#ok<AGROW>
    cols{end+1} = Y(:, i); %#ok<AGROW>
end
for o = 1:m.n_outputs
    oid = m.outputs(o).id;
    if any(strcmp(m.species, oid))
        continue
    end
    header{end+1} = oid; %#ok<AGROW>
    cols{end+1} = outVals{o}; %#ok<AGROW>
end
lines = cell(1, numel(tvec) + 1);
lines{1} = strjoin(header, ',');
for k = 1:numel(tvec)
    parts = cell(1, numel(cols));
    for c = 1:numel(cols)
        val = cols{c}(k);
        if isfinite(val)
            parts{c} = sprintf('%.10g', val);
        else
            parts{c} = 'NaN';
        end
    end
    lines{k+1} = strjoin(parts, ',');
end
bma.util.writeTextAtomic(path, [strjoin(lines, sprintf('\n')) sprintf('\n')]);
end

function s = vectorToStruct(v, ids)
s = struct();
for k = 1:numel(ids)
    if ~isempty(ids{k})
        s.(ids{k}) = v(k);
    end
end
end

function x = numericOr(v, default)
if isnumeric(v) && isscalar(v) && isfinite(v)
    x = v;
else
    x = default;
end
end

function v = getFieldLocal(s, name, default)
if isstruct(s) && isfield(s, name)
    v = s.(name);
else
    v = default;
end
end


% ---------------------------------------------------------------------------
function [value, isterminal, direction] = wallClockEvent(~, ~, startTic, maxSeconds)
%WALLCLOCKEVENT Stop an ODE integration that exceeds a wall-clock budget.
value = double(toc(startTic) > maxSeconds);
isterminal = 1;
direction = 0;
end
