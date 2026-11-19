function si = sensitivity(mOrSpec, opts)
%SENSITIVITY 参数敏感性分析：局部弹性系数 + Sobol 一阶/总效应。
%   si = bma.fit.sensitivity(m, opts)
%
% 输入 opts（也兼容 RPC params 直传）：
%   params          要分析的参数 id（cellstr / 逗号分隔 char），默认 estimate:true
%   outputs         输出 id 列表，默认模型全部 outputs
%   method          'local' | 'sobol' | 'both'（默认 local；sobol 需显式请求，
%                   刚性模型上 N*(P+2) 次积分可能非常昂贵）
%   sobol_n / n_sobol  Saltelli 基础样本数 N（默认 64，可 16/32/64/128）
%   force           true 时即使预算超限也执行 Sobol（默认 false）
%   budget_seconds  Sobol 预算上限（默认 120 s；超过则跳过并给建议）
%   max_seconds     实际执行的总墙钟上限（默认 300 s，超时返回部分结果）
%   max_sample_seconds 单样本积分墙钟上限（默认 max(5, 30*基准仿真耗时)）
%   progress_path   进度 JSON 落盘路径（默认 <run_dir>/logs/sensitivity_progress.json）
%   rel_step        局部弹性中心差分相对步长（默认 0.05）
%   n / time_end    仿真网格与终点（默认 spec.time）
%   base_params / param_overrides  基准参数覆盖（struct）
%   work_dir / run_dir / table_path / out_dir  产物路径
%
% 输出 si：
%   method, param_ids, output_ids,
%   local {rows(struct array), max_abs(s×o), at_end(s×o)},
%   sobol {N, sampling, first(s×o), total(s×o), first_final, total_final},
%   indices {first, total}（契约兼容别名）, table, table_path, figure, warnings
%
% 实现：
%   - 局部弹性：E(t) = (∂y/∂p)·(p/y)，中心差分、参数正对数尺度；
%   - Sobol（Saltelli 2010 估计器）：在参数边界内用固定种子的分层拉丁超立方
%     （LHS）采样，无需任何工具箱；输出标量取各 output 的时间平均值（另存终值
%     版本）。

if nargin < 2 || isempty(opts)
    opts = struct();
end
opts = mergeNestedOptions(opts);
[m, spec] = bma.fit.resolveModel(mOrSpec);
workDir = absDir(getStr(opts, 'work_dir', bma.util.projectRoot()));
runDirAbs = resolveRunDir(workDir, opts);
allNames = cellstr(m.params);
baseAll = baseParams(spec, m);

% 参数与输出选择
paramIds = selectParams(spec, m, opts, allNames);
outIds = selectOutputs(m, opts);
method = lower(getStr(opts, 'method', 'local'));
doLocal = ismember(method, {'both', 'local', 'elasticity'});
doSobol = ismember(method, {'both', 'sobol', 'sobol_indices'});
if ~doLocal && ~doSobol
    error('bma:fit:sensMethod', '无法识别的 method="%s"（应为 local/sobol/both）。', method);
end

% 仿真网格（模型输出时间序列）
tGrid = simTimeGrid(spec, opts);
d = struct('t', tGrid, 'Y', zeros(numel(tGrid), numel(outIds)), ...
    'colIds', {outIds}, 'colNames', {outIds}, 'weights', []);
simOpts = struct('solver', getStr(opts, 'solver', 'ode15s'), 'n', numel(tGrid));
if isfield(opts, 'rtol'), simOpts.rtol = opts.rtol; end
if isfield(opts, 'atol'), simOpts.atol = opts.atol; end

warnings = {};
tBase = tic;
pred0 = simMatrix(m, d, baseAll, simOpts);
baseSeconds = toc(tBase);
if ~(baseSeconds > 0)
    baseSeconds = 0.01;
end
% 单样本墙钟上限：默认 30 倍基准耗时，至少 5 s；防止坏样本吃掉几分钟
defaultMaxSample = max(5, 30 * baseSeconds);
maxSampleSeconds = getNum(opts, 'max_sample_seconds', defaultMaxSample);
simOpts.max_seconds = maxSampleSeconds;
if any(~isfinite(pred0(:)))
    warnings{end+1} = '基准参数下仿真出现非有限值，敏感性结果可能不可靠。';
end

si = struct();
si.schema_version = 'bma.fitSensitivity.v1';
si.method = ternary(doLocal && doSobol, 'local+sobol', ...
    ternary(doLocal, 'local', 'sobol'));
si.param_ids = paramIds;
si.output_ids = outIds;
si.time_grid = [tGrid(1), tGrid(end)];
si.local = struct('rows', struct('param', {}, 'output', {}, ...
    'max_abs_elasticity', {}, 'elasticity_at_end', {}, 'elast_min', {}, ...
    'elast_max', {}), 'max_abs', [], 'at_end', []);
si.sobol = struct();
si.indices = struct();
si.table = struct('param', {}, 'output', {}, 'sobol_first', {}, ...
    'sobol_total', {}, 'local_max_abs_elasticity', {}, 'local_at_end', {});
si.table_path = '';
si.figure = '';
si.warnings = warnings;

if doLocal
    [rows, maxAbs, atEnd] = localElasticity(m, d, baseAll, paramIds, outIds, ...
        spec, opts, simOpts, pred0);
    si.local = struct('rows', rows, 'max_abs', maxAbs, 'at_end', atEnd);
    % 契约 §4.4：indices 必须非空，局部弹性系数矩阵至少要有
    si.indices = struct('param_ids', {paramIds}, 'output_ids', {outIds}, ...
        'metric', 'local_elasticity', ...
        'local_max_abs', maxAbs, 'local_at_end', atEnd);
end

budget = makeBudget(opts, numel(paramIds), baseSeconds, maxSampleSeconds);
si.budget = budget;
si.skipped = budget.skipped;
if budget.skipped
    warnings{end+1} = sprintf(['Sobol 预算估计约 %.0f s（N=%d × (P+2)=%d 次仿真），' ...
        '超过上限 %.0f s，已跳过以避免卡死。可减小 sobol_n / 减少 params / 缩短 time_end，' ...
        '或传 options.force=true 强制执行。'], ...
        budget.estimated_seconds, budget.sobol_n, budget.sample_count, budget.budget_seconds);
    si.warnings = warnings;
    si.skip_reason = warnings{end};
    si.sobol = struct('skipped', true, 'N', budget.sobol_n, ...
        'estimated_seconds', budget.estimated_seconds, ...
        'reason', warnings{end});
end

if doSobol && ~budget.skipped
    [sob, w, runInfo] = sobolIndices(m, d, baseAll, paramIds, outIds, spec, opts, ...
        simOpts, workDir, runDirAbs, budget);
    si.sobol = sob;
    si.budget = runInfo;
    if isempty(fieldnames(si.indices))
        si.indices = struct('param_ids', {paramIds}, 'output_ids', {outIds}, ...
            'metric', 'time_average');
    end
    if isfield(sob, 'first') && ~isempty(sob.first)
        si.indices.first = sob.first;
        si.indices.total = sob.total;
        si.indices.sobol_N = sob.N;
    end
    si.indices.metric = 'time_average';
    if isfield(runInfo, 'cancelled') && runInfo.cancelled
        si.cancelled = true;
        si.warnings{end+1} = 'Sobol 被主动取消（检测到 cancel.flag）。';
    elseif isfield(runInfo, 'partial') && runInfo.partial
        si.warnings{end+1} = sprintf('Sobol 达到墙钟上限，返回部分结果（完成样本 %d/%d）。', ...
            runInfo.executed_samples, runInfo.sample_count);
    end
    warnings = [warnings, w];
    si.warnings = warnings;
end

% 汇总排序表
table = buildTable(si, paramIds, outIds, doLocal, doSobol);
si.table = table;

% 产物
if ~isempty(runDirAbs)
    sensDir = fullfile(runDirAbs, 'fits', ['sens-' bma.util.newId('x')]);
    if isfield(opts, 'table_path') && ~isempty(opts.table_path)
        csvPath = bma.util.absPath(workDir, char(opts.table_path));
    else
        bma.util.ensureDir(sensDir);
        csvPath = fullfile(sensDir, 'sensitivity.csv');
    end
    try
        bma.util.ensureDir(fileparts(csvPath));
        writeSensitivityCsv(csvPath, table);
        si.table_path = bma.util.relPath(workDir, csvPath);
    catch err
        si.warnings{end+1} = sprintf('敏感性表写入失败：%s', err.message);
    end
    try
        figDir = fullfile(sensDir, 'figures');
        figPath = bma.plot.sensitivity(si, struct('out_dir', figDir, ...
            'work_dir', workDir, 'name', 'sensitivity.png'));
        si.figure = figPath;
    catch err
        si.warnings{end+1} = sprintf('敏感性图生成失败：%s', err.message);
    end
end
end

% ======================================================================
% 局部函数
% ======================================================================
function out = simMatrix(m, d, pAll, simOpts)
%SIMMATRIX 仿真并在伪数据时间点取预测矩阵（失败返回全 NaN）。
try
    pred = bma.fit.simulatePredictions(m, d, pAll, simOpts);
catch
    pred = NaN(numel(d.t), numel(d.colIds));
end
out = pred;
end

function opts = mergeNestedOptions(opts)
if isfield(opts, 'options') && isstruct(opts.options) && ~isempty(opts.options)
    nested = opts.options;
    f = fieldnames(nested);
    for k = 1:numel(f)
        if ~isfield(opts, f{k}) || isempty(opts.(f{k}))
            opts.(f{k}) = nested.(f{k});
        end
    end
end
end

function runDirAbs = resolveRunDir(workDir, opts)
if isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    runDirAbs = bma.util.absPath(workDir, char(opts.run_dir));
else
    runDirAbs = fullfile(workDir, '.bma', 'runs', bma.util.newId('r'));
end
bma.util.ensureDir(runDirAbs);
end

function outIds = selectOutputs(m, opts)
allOut = {};
if isfield(m, 'outputs') && ~isempty(m.outputs)
    if isstruct(m.outputs)
        allOut = arrayfun(@(s) char(s.id), m.outputs, 'UniformOutput', false);
    elseif iscell(m.outputs)
        allOut = cellfun(@(s) char(s.id), m.outputs, 'UniformOutput', false);
    end
end
if isempty(allOut)
    allOut = cellstr(m.species);
end
if isfield(opts, 'outputs') && ~isempty(opts.outputs)
    outIds = toCellstr(opts.outputs);
    bad = setdiff(outIds, allOut);
    if ~isempty(bad)
        error('bma:fit:sensOutputs', '未知 output：%s', strjoin(bad, ', '));
    end
else
    outIds = allOut;
end
outIds = outIds(:).';
end

function paramIds = selectParams(spec, m, opts, allNames)
if isfield(opts, 'params') && ~isempty(opts.params)
    want = toCellstr(opts.params);
    paramIds = allNames(ismember(allNames, want));
    missing = setdiff(want, allNames);
    if ~isempty(missing)
        warning('bma:fit:sensParams', '忽略未知参数：%s', strjoin(missing, ', '));
    end
else
    est = false(numel(allNames), 1);
    if isfield(spec, 'parameters') && ~isempty(spec.parameters)
        for k = 1:numel(spec.parameters)
            id = char(spec.parameters(k).id);
            idx = find(strcmp(allNames, id), 1);
            if ~isempty(idx) && isfield(spec.parameters(k), 'estimate') ...
                    && ~isempty(spec.parameters(k).estimate)
                est(idx) = logical(spec.parameters(k).estimate);
            end
        end
    end
    paramIds = allNames(est);
    if isempty(paramIds)
        paramIds = allNames;
    end
end
paramIds = paramIds(:).';
if isempty(paramIds)
    error('bma:fit:sensNoParams', '没有可分析的参数。');
end
end

function tGrid = simTimeGrid(spec, opts)
t0 = 0;
t1 = 100;
nSpec = 401;
if isfield(spec, 'time') && isstruct(spec.time)
    if isfield(spec.time, 'start') && ~isempty(spec.time.start), t0 = double(spec.time.start); end
    if isfield(spec.time, 'end') && ~isempty(spec.time.end), t1 = double(spec.time.end); end
    if isfield(spec.time, 'n') && ~isempty(spec.time.n), nSpec = double(spec.time.n); end
end
if isfield(opts, 'time_end') && ~isempty(opts.time_end)
    t1 = double(opts.time_end);
end
n = round(getNum(opts, 'n', min(nSpec, 401)));
n = max(51, n);
tGrid = linspace(t0, t1, n).';
end

function baseAll = baseParams(spec, m)
baseAll = zeros(numel(m.params), 1);
for k = 1:numel(m.params)
    baseAll(k) = defaultParamValue(spec, m, m.params{k});
end
end

function v = defaultParamValue(spec, m, id)
v = 0;
idx = find(strcmp(cellstr(m.params), id), 1);
if ~isempty(idx) && isfield(m, 'paramValues') && numel(m.paramValues) >= idx
    v = double(m.paramValues(idx));
end
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    q = find(strcmp({spec.parameters.id}, id), 1);
    if ~isempty(q)
        sp = spec.parameters(q);
        if isfield(sp, 'value') && isstruct(sp.value) && isfield(sp.value, 'value')
            v = double(sp.value.value);
        elseif isfield(sp, 'value') && isnumeric(sp.value)
            v = double(sp.value);
        end
    end
end
end

function [lb, ub] = paramRange(spec, m, id, v)
lb = NaN;
ub = NaN;
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    q = find(strcmp({spec.parameters.id}, id), 1);
    if ~isempty(q) && isfield(spec.parameters(q), 'bounds') ...
            && numel(spec.parameters(q).bounds) == 2
        b = double(spec.parameters(q).bounds(:));
        lb = b(1);
        ub = b(2);
    end
end
if (~isfinite(lb) || ~isfinite(ub)) && isfield(m, 'lb') && isfield(m, 'ub')
    idx = find(strcmp(cellstr(m.params), id), 1);
    if ~isempty(idx) && isfinite(m.lb(idx)) && isfinite(m.ub(idx))
        lb = double(m.lb(idx));
        ub = double(m.ub(idx));
    end
end
if ~isfinite(lb) || ~isfinite(ub) || lb >= ub
    span = max(abs(v), 1);
    lb = v - 0.5 * span;
    ub = v + 0.5 * span;
end
end

function [rows, maxAbs, atEnd] = localElasticity(m, d, baseAll, paramIds, outIds, ...
    spec, opts, simOpts, pred0)
%LOCALELASTICITY 中心差分局部弹性 E(t) = (∂y/∂p)·(p/y)。
s = numel(paramIds);
o = numel(outIds);
maxAbs = NaN(s, o);
atEnd = NaN(s, o);
rows = struct('param', {}, 'output', {}, 'max_abs_elasticity', {}, ...
    'elasticity_at_end', {}, 'elast_min', {}, 'elast_max', {});
rel = getNum(opts, 'rel_step', 0.05);
for i = 1:s
    id = paramIds{i};
    idx = find(strcmp(cellstr(m.params), id), 1);
    p = baseAll(idx);
    [lb, ub] = paramRange(spec, m, id, p);
    h = rel * max(abs(p), (ub - lb) / 100);
    if p + h > ub || p - h < lb
        h = min(ub - p, p - lb) * 0.5;
    end
    if ~(h > 0)
        continue
    end
    pp = baseAll;
    pm = baseAll;
    pp(idx) = p + h;
    pm(idx) = p - h;
    predP = simMatrix(m, d, pp, simOpts);
    predM = simMatrix(m, d, pm, simOpts);
    if any(~isfinite(predP(:))) || any(~isfinite(predM(:)))
        continue
    end
    dY = (predP - predM) / (2 * h);
    scale = p;
    for j = 1:o
        y = pred0(:, j);
        e = dY(:, j) * scale ./ y;
        e(abs(y) < 1e-12) = NaN;
        vals = e(isfinite(e));
        if isempty(vals)
            continue
        end
        maxAbs(i, j) = max(abs(vals));
        if isfinite(e(end)), atEnd(i, j) = e(end); end
        rows(end+1) = struct('param', id, 'output', outIds{j}, ...
            'max_abs_elasticity', maxAbs(i, j), ...
            'elasticity_at_end', atEnd(i, j), ...
            'elast_min', min(vals), 'elast_max', max(vals)); %#ok<AGROW>
    end
end
end

function [sob, warnings, info] = sobolIndices(m, d, baseAll, paramIds, outIds, spec, opts, ...
    simOpts, workDir, runDirAbs, budget)
%SOBOLINDICES Saltelli 一阶/总效应估计（LHS 采样，无工具箱依赖）。
% 预算、墙钟上限、进度心跳与取消检查都在这里执行，保证不会无限期占用 MATLAB。
warnings = {};
s = numel(paramIds);
o = numel(outIds);
N = budget.sobol_n;
seed = getNum(opts, 'seed', 42);
rng(seed, 'twister');
lb = zeros(s, 1);
ub = zeros(s, 1);
for i = 1:s
    idx = find(strcmp(cellstr(m.params), paramIds{i}), 1);
    [lo, hi] = paramRange(spec, m, paramIds{i}, baseAll(idx));
    lb(i) = lo;
    ub(i) = hi;
end
[A, B] = lhsSample(N, lb, ub);
totalSims = N * (s + 2);
ctx = struct('workDir', workDir, 'runDirAbs', runDirAbs, ...
    'progressPath', progressPath(opts, runDirAbs), ...
    'cancelPath', fullfile(workDir, '.bma', 'server', 'cancel.flag'), ...
    'maxSeconds', getNum(opts, 'max_seconds', 300), ...
    'startTic', tic, 'done', 0, 'total', totalSims, ...
    'maxSampleSeconds', budget.max_sample_seconds);
fA = evalMetrics(m, d, baseAll, paramIds, A, simOpts, outIds, ctx);
ctx = updateProgress(ctx);
if cancelled(ctx)
    sob = emptySobol(N, s, o, seed);
    info = finishInfo(ctx, budget, true, true);
    warnings{end+1} = 'Sobol 在第一批样本后被取消。';
    return
end
fB = evalMetrics(m, d, baseAll, paramIds, B, simOpts, outIds, ctx);
ctx = updateProgress(ctx);
if cancelled(ctx)
    sob = emptySobol(N, s, o, seed);
    info = finishInfo(ctx, budget, true, true);
    warnings{end+1} = 'Sobol 在第二批样本后被取消。';
    return
end
if any(~isfinite(fA(:))) || any(~isfinite(fB(:)))
    warnings{end+1} = 'Sobol 基准样本存在仿真失败点，指数估计可能不稳定。';
    fA(~isfinite(fA)) = 0;
    fB(~isfinite(fB)) = 0;
end
nOut = size(fA, 2);
first = NaN(s, nOut);
total = NaN(s, nOut);
varY = var([fA; fB], 0, 1);
partial = false;
for i = 1:s
    if cancelled(ctx)
        partial = true;
        warnings{end+1} = 'Sobol 被主动取消，返回部分结果。';
        break
    end
    if toc(ctx.startTic) > ctx.maxSeconds
        partial = true;
        warnings{end+1} = sprintf('Sobol 达到墙钟上限 %.0f s，返回部分结果。', ctx.maxSeconds);
        break
    end
    AB = A;
    AB(:, i) = B(:, i);
    fAB = evalMetrics(m, d, baseAll, paramIds, AB, simOpts, outIds, ctx);
    if any(~isfinite(fAB(:)))
        warnings{end+1} = sprintf('Sobol 第 %d 维补充样本存在仿真失败点。', i); %#ok<AGROW>
        fAB(~isfinite(fAB)) = 0;
    end
    for j = 1:nOut
        if ~(varY(j) > 0)
            continue
        end
        first(i, j) = mean(fB(:, j) .* (fAB(:, j) - fA(:, j))) / varY(j);
        total(i, j) = 0.5 * mean((fA(:, j) - fAB(:, j)).^2) / varY(j);
    end
end
sob = struct();
sob.N = N;
sob.sampling = '固定种子分层拉丁超立方（正参数且跨度>5 时按对数均匀）';
sob.metric = 'output_time_average';
sob.first = first;
sob.total = total;
sob.var_y = varY;
sob.seed = seed;
info = finishInfo(ctx, budget, partial, false);
info.failed_samples = numel(find(~isfinite(fA(:)))) + numel(find(~isfinite(fB(:))));
end

function sob = emptySobol(N, s, o, seed)
sob = struct('N', N, 'sampling', 'cancelled', 'metric', 'output_time_average', ...
    'first', NaN(s, o), 'total', NaN(s, o), 'var_y', NaN(1, o), 'seed', seed);
end

function ctx = updateProgress(ctx)
%UPDATEPROGRESS 写进度文件（每 8 个样本至少一次），不阻塞主流程。
if ~isfield(ctx, 'done'), ctx.done = 0; end
if ~isfield(ctx, 'lastWrite'), ctx.lastWrite = -Inf; end
ctx.done = ctx.done + 1;
if ctx.done - ctx.lastWrite < 8 && ctx.done < ctx.total
    return
end
ctx.lastWrite = ctx.done;
try
    bma.util.ensureDir(fileparts(ctx.progressPath));
    prog = struct('schema', 'bma.sensitivityProgress.v1', ...
        'done', ctx.done, 'total', ctx.total, ...
        'fraction', ctx.done / max(1, ctx.total), ...
        'elapsed_s', toc(ctx.startTic), ...
        'eta_s', toc(ctx.startTic) * (ctx.total - ctx.done) / max(1, ctx.done), ...
        'updated_at', bma.util.nowIso());
    bma.util.writeJsonAtomic(ctx.progressPath, prog);
catch
end
end

function tf = cancelled(ctx)
%CANCELLED 检查服务器取消标志（每样本一次，代价可忽略）。
tf = isfile(ctx.cancelPath);
if tf
    try
        delete(ctx.cancelPath);
    catch
    end
end
end

function info = finishInfo(ctx, budget, partial, wasCancelled)
info = budget;
info.actual_seconds = toc(ctx.startTic);
info.executed_samples = ctx.done;
info.partial = partial || ctx.done < ctx.total;
info.cancelled = wasCancelled;
info.finished_at = bma.util.nowIso();
end

function p = progressPath(opts, runDirAbs)
p = '';
if isfield(opts, 'progress_path') && ~isempty(opts.progress_path)
    p = char(opts.progress_path);
end
if isempty(p)
    p = fullfile(runDirAbs, 'logs', 'sensitivity_progress.json');
end
end

function b = makeBudget(opts, paramCount, baseSeconds, maxSampleSeconds)
%MAKEBUDGET 估算 Sobol 成本并决定是否跳过（防止刚性模型上的小时级卡死）。
N = max(16, round(getNum(opts, 'sobol_n', getNum(opts, 'n_sobol', 64))));
budgetSeconds = getNum(opts, 'budget_seconds', 120);
force = getBool(opts, 'force', false);
sampleCount = N * (paramCount + 2);
estimated = sampleCount * baseSeconds;
b = struct();
b.sobol_n = N;
b.param_count = paramCount;
b.sample_count = sampleCount;
b.baseline_seconds = baseSeconds;
b.estimated_seconds = estimated;
b.budget_seconds = budgetSeconds;
b.forced = force;
b.skipped = estimated > budgetSeconds && ~force;
b.max_sample_seconds = maxSampleSeconds;
b.suggestion = sprintf(['先在一个“静态/降阶代理模型”上估算成本，或减小 sobol_n（16/32）、' ...
    '减少 params（只选关键参数）、缩短 time_end；确认可接受后用 options.force=true 强制执行。']);
end

function [A, B] = lhsSample(N, lb, ub)
s = numel(lb);
A = zeros(N, s);
B = zeros(N, s);
for i = 1:s
    A(:, i) = mapSample((randperm(N).' - 1 + rand(N, 1)) / N, lb(i), ub(i));
    B(:, i) = mapSample((randperm(N).' - 1 + rand(N, 1)) / N, lb(i), ub(i));
end
end

function v = mapSample(u, lo, hi)
if lo > 0 && hi / lo > 5
    v = exp(log(lo) + (log(hi) - log(lo)) * u);
else
    v = lo + (hi - lo) * u;
end
end

function F = evalMetrics(m, d, baseAll, paramIds, X, simOpts, outIds, ctx)
%EVALMETRICS 批量仿真并返回每个样本的 [时间平均输出] 指标矩阵（N×nOut）。
N = size(X, 1);
nOut = numel(outIds);
F = NaN(N, nOut);
for r = 1:N
    pAll = baseAll;
    for i = 1:numel(paramIds)
        idx = find(strcmp(cellstr(m.params), paramIds{i}), 1);
        pAll(idx) = X(r, i);
    end
    pred = simMatrix(m, d, pAll, simOpts);
    if any(~isfinite(pred(:)))
        ctx = updateProgress(ctx);
        continue
    end
    for j = 1:nOut
        F(r, j) = mean(pred(:, j));
    end
    ctx = updateProgress(ctx);
end
end

function table = buildTable(si, paramIds, outIds, doLocal, doSobol)
rows = struct('param', {}, 'output', {}, 'sobol_first', {}, ...
    'sobol_total', {}, 'local_max_abs_elasticity', {}, 'local_at_end', {});
s = numel(paramIds);
o = numel(outIds);
for i = 1:s
    for j = 1:o
        r = struct('param', paramIds{i}, 'output', outIds{j}, ...
            'sobol_first', NaN, 'sobol_total', NaN, ...
            'local_max_abs_elasticity', NaN, 'local_at_end', NaN);
        if doSobol && isfield(si.sobol, 'first') && ~isempty(si.sobol.first)
            r.sobol_first = si.sobol.first(i, j);
            r.sobol_total = si.sobol.total(i, j);
        end
        if doLocal && ~isempty(si.local.max_abs)
            r.local_max_abs_elasticity = si.local.max_abs(i, j);
            r.local_at_end = si.local.at_end(i, j);
        end
        rows(end+1) = r; %#ok<AGROW>
    end
end
% 按 |总效应| 降序（无 Sobol 时按 |局部弹性|），NaN 排最后
key = NaN(numel(rows), 1);
for k = 1:numel(rows)
    if isfinite(rows(k).sobol_total)
        key(k) = abs(rows(k).sobol_total);
    else
        key(k) = -abs(rows(k).local_max_abs_elasticity);
    end
end
key(~isfinite(key)) = -Inf;
[~, order] = sort(key, 'descend');
table = rows(order);
end

function writeSensitivityCsv(csvPath, table)
fid = fopen(csvPath, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:fit:csvWrite', '无法写入 %s', csvPath);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, 'param,output,sobol_first,sobol_total,local_max_abs_elasticity,local_at_end\n');
for k = 1:numel(table)
    r = table(k);
    fprintf(fid, '%s,%s,%.10g,%.10g,%.10g,%.10g\n', r.param, r.output, ...
        r.sobol_first, r.sobol_total, r.local_max_abs_elasticity, r.local_at_end);
end
end

function c = toCellstr(x)
if iscell(x)
    c = cellfun(@(s) char(s), x(:).', 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    parts = strtrim(strsplit(x, ','));
    c = parts(~cellfun(@isempty, parts));
else
    c = {};
end
end

function r = ternary(cond, a, b)
if cond
    r = a;
else
    r = b;
end
end

function p = absDir(p)
p = char(p);
if ~isfolder(p)
    bma.util.ensureDir(p);
end
end

function v = getNum(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
else
    v = default;
end
end

function v = getBool(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = logical(s.(name));
    if ischar(s.(name)) || isstring(s.(name))
        v = any(strcmpi(char(s.(name)), {'true', '1', 'yes', 'on'}));
    end
else
    v = default;
end
end

function v = getStr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = char(s.(name));
else
    v = default;
end
end
