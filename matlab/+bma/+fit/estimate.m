function fr = estimate(mOrSpec, dataIn, opts)
%ESTIMATE 非线性最小二乘参数估计（有界多起点 lsqnonlin，失败退 fmincon）。
%   fr = bma.fit.estimate(m, data, opts)
%
% 输入：
%   m       bma.model.build 返回的模型结构（也接受 modelSpec，内部构建）
%   data    数据 struct / CSV 路径 / dispatch 的 loadDataset 结果；
%           规范形式见 bma.fit.normalizeData
%   opts    选项（§4.4 通用字段 + 拟合扩展）：
%           params_to_fit  参与拟合的参数 id（cellstr / 逗号分隔 char），
%                          缺省为 spec 中 estimate:true 的参数
%           multistart     多起点个数（默认 8）
%           seed           随机种子（默认 42，保证可复现）
%           max_iter       单次局部优化最大迭代（默认 400）
%           solver/rtol/atol   ODE 求解设置（默认 ode15s / 1e-6 / 1e-9）
%           weights        观测权重（标量 / 每列 / n×p 矩阵）
%           p0             初值覆盖（struct: 参数 id→值，或数值向量）
%           fixed          固定参数覆盖（struct: 参数 id→值）
%           param_overrides  参数覆盖（同 fixed；用于情景）
%           time_end / initial_overrides  透传给模型仿真
%           work_dir / run_dir / fit_dir / fit_id  产物目录
%           save_artifacts 是否写文件（默认 true）
%
% 输出 fr（关键字段，json-safe）：
%   params       struct array {id,name,unit,value,se,ci_low,ci_high,fixed,...}
%   p, p0, pnames, p_all, param_ids
%   metrics      {r2,rmse,nrmse,aicc,bic,loglik,n,k,sse,...}
%   residuals    {values,summary}
%   pred         {t,colIds,colNames,Y,Yhat}
%   fittedSpec   参数已写回的模型规格
%   fit_id/fit_dir/predictions_path/residuals_path/fit_result_path/figure
%   method/solver_info/warnings/converged
%
% 算法：目标为加权残差平方和；以有界 lsqnonlin（trust-region-reflective）
% 从多个起点求解，任一起点失败时退 fmincon，仍失败退 fminsearch+罚函数；
% 取 SSE 最小者为最优解。协方差由最优点的残差雅可比估计：
%   Cov = sigma^2 * pinv(J'WJ)，sigma^2 = SSE/(n-k)。

if nargin < 3 || isempty(opts)
    opts = struct();
end
opts = mergeNestedOptions(opts);
if nargin < 2 || isempty(dataIn)
    error('bma:fit:noData', 'bma.fit.estimate 需要数据（struct 或 CSV 路径）。');
end

[m, spec] = bma.fit.resolveModel(mOrSpec);
workDir = '';
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
    workDir = char(opts.work_dir);
else
    workDir = bma.util.projectRoot();
end
workDir = ensureAbsDir(workDir);
saveArtifacts = true;
if isfield(opts, 'save_artifacts') && ~isempty(opts.save_artifacts)
    saveArtifacts = logical(opts.save_artifacts);
end
makeFigure = saveArtifacts;
if isfield(opts, 'make_figure') && ~isempty(opts.make_figure)
    makeFigure = logical(opts.make_figure) && saveArtifacts;
end
[runDirAbs, fitId, fitDirAbs] = resolveFitDir(workDir, opts);
if saveArtifacts
    bma.util.ensureDir(fitDirAbs);
end

% ---------------- 数据与参数准备 ----------------
data = bma.fit.normalizeData(dataIn, m, opts);
params = specParameterTable(spec, m);
allNames = cellstr(m.params);
baseAll = paramValues(params);

fitNames = determineFitNames(params, opts);
[fixedVals, warnings] = collectFixed(params, opts);
warnExtra = {};
[fitNames, fixedVals, w] = dropFixedFromFit(fitNames, fixedVals);
warnings = [warnings, w];

[lp, up] = boundsFor(params, fitNames, m);
p0Fit = buildInitial(params, fitNames, opts, lp, up);
seed = getNum(opts, 'seed', 42);
nStarts = max(1, round(getNum(opts, 'multistart', 8)));
solverName = 'ode15s';
if isfield(opts, 'solver') && ~isempty(opts.solver)
    solverName = char(opts.solver);
end
simOpts = struct('solver', solverName);
if isfield(opts, 'rtol'), simOpts.rtol = opts.rtol; end
if isfield(opts, 'atol'), simOpts.atol = opts.atol; end
if isfield(opts, 'n') && ~isempty(opts.n), simOpts.n = opts.n; end
if isfield(opts, 'time_end') && ~isempty(opts.time_end), simOpts.time_end = opts.time_end; end
if isfield(opts, 'initial_overrides') && ~isempty(opts.initial_overrides)
    simOpts.initial_overrides = opts.initial_overrides;
end

optOpts = struct('max_iter', getNum(opts, 'max_iter', 400), ...
    'lb', lp, 'ub', up, 'solver', solverName);
if isfield(opts, 'max_fe') && ~isempty(opts.max_fe)
    optOpts.max_fe = double(opts.max_fe);
end
if isfield(opts, 'rtol'), optOpts.rtol = opts.rtol; end
if isfield(opts, 'atol'), optOpts.atol = opts.atol; end
if isfield(opts, 'n') && ~isempty(opts.n), optOpts.n = opts.n; end
if isfield(opts, 'time_end') && ~isempty(opts.time_end), optOpts.time_end = opts.time_end; end
if isfield(simOpts, 'initial_overrides')
    optOpts.initial_overrides = simOpts.initial_overrides;
end

% ---------------- 多起点拟合 ----------------
rng(seed, 'twister');
pNominal = nominalFitVector(params, fitNames);
starts = generateStarts(p0Fit, pNominal, lp, up, nStarts);
solverInfo = struct('start', {}, 'solver', {}, 'sse', {}, 'exitflag', {}, ...
    'iterations', {}, 'converged', {}, 'message', {}, 'n_evaluations', {}, ...
    'n_failures', {}, 'seconds', {}, 'start_kind', {});
best = [];
nFitted = numel(fitNames);
totalFailures = 0;
timeouts = 0;
perfectScale = 1e-16 * max(1, sum(abs(data.Y(isfinite(data.Y))).^2));
% 数据总平方和：用于“已找到显著更优解”的提前终止判据
maskAll = isfinite(data.Y);
yAllv = data.Y(maskAll);
dataSst = sum((yAllv - mean(yAllv)) .^ 2);
goodEnoughSse = 1e-3 * max(dataSst, realmin);
earlyStopR2 = getNum(opts, 'early_stop_r2', 0.999);
earlyStopMinStarts = getNum(opts, 'early_stop_min_starts', min(4, nStarts));
earlyStopMinStarts = max(1, round(earlyStopMinStarts));
fitSeconds = getNum(opts, 'fit_seconds', 150);
startSeconds = getNum(opts, 'start_seconds', 45);
fitTimer = tic;
stoppedEarly = '';
for s = 1:nStarts
    tStart = tic;
    remaining = fitSeconds - toc(fitTimer);
    if s > 1 && remaining <= 3
        stoppedEarly = sprintf('时间预算（%.0fs）用尽', fitSeconds);
        break
    end
    optOptsS = optOpts;
    optOptsS.max_seconds = min(startSeconds, max(5, remaining));
    try
        out = bma.fit.optLocal(m, data, starts(s, :).', fitNames, fixedVals, optOptsS);
    catch err
        out = struct('pFit', starts(s, :).', 'pAll', [], 'sse', Inf, ...
            'residual', [], 'jac', zeros(numel(data.Y), nFitted), ...
            'exitflag', -1, 'iterations', 0, 'solver', 'error', ...
            'converged', false, 'message', err.message, 'pred', [], ...
            'nRes', numel(data.Y), 'penalty_used', true, ...
            'n_evaluations', 0, 'n_failures', 1);
    end
    if isfield(out, 'n_failures')
        totalFailures = totalFailures + out.n_failures;
    end
    if isfield(out, 'timed_out') && out.timed_out
        timeouts = timeouts + 1;
    end
    solverInfo(end+1) = struct('start', s, 'solver', out.solver, ...
        'sse', out.sse, 'exitflag', out.exitflag, ...
        'iterations', out.iterations, 'converged', out.converged, ...
        'message', out.message, 'n_evaluations', getNum(out, 'n_evaluations', 0), ...
        'n_failures', getNum(out, 'n_failures', 0), ...
        'seconds', toc(tStart), ...
        'start_kind', startKind(s)); %#ok<AGROW>
    prevBest = best;
    if isempty(best) || out.sse < best.sse
        best = out;
    end
    % 默认允许高优度早停，但至少探索 min(4, multistart) 个起点，避免只
    % 跑 2/12 就下结论（ISSUE-005）；可用 early_stop_r2=Inf 完全关闭。
    if s >= earlyStopMinStarts && best.converged && isfinite(best.sse) && isfinite(earlyStopR2) ...
            && best.sse <= (1 - earlyStopR2) * max(dataSst, realmin)
        stoppedEarly = sprintf('已找到 R²>=%.4f 的解（至少 %d 起点）', earlyStopR2, earlyStopMinStarts);
        break
    end
    if getNum(opts, 'perfect_early_stop', false) && s >= earlyStopMinStarts ...
            && isfinite(best.sse) && best.sse <= perfectScale && best.converged
        stoppedEarly = '完美拟合';
        break
    end
end
if ~isempty(stoppedEarly)
    warnings{end+1} = sprintf('多起点提前结束（%s）：实际运行 %d/%d 个起点。', ...
        stoppedEarly, numel(solverInfo), nStarts);
end
if timeouts > 0
    warnings{end+1} = sprintf('%d 个起点因单起点时间预算（%ds）被截断。', ...
        timeouts, round(startSeconds));
end
if isempty(best) || ~isfinite(best.sse)
    error('bma:fit:failed', '所有起点拟合失败；请检查模型/数据/参数边界。');
end
if totalFailures > 0
    warnings{end+1} = sprintf(['拟合过程中共 %d 次仿真失败（已用惩罚残差处理），' ...
        '若最优解附近频繁失败，结果可信度会下降。'], totalFailures);
end
if best.penalty_used
    warnings{end+1} = '最优拟合仍含仿真失败点（惩罚残差），结果不可信。';
end
if ~best.converged
    warnings{end+1} = sprintf('最优起点未正常收敛（exitflag=%d）：%s', ...
        best.exitflag, best.message);
end
nonConv = sum(~[solverInfo.converged]);
if nonConv > 0
    warnings{end+1} = sprintf('%d/%d 个起点未收敛（已自动回退 fmincon/fminsearch）。', ...
        nonConv, numel(solverInfo));
end

% ---------------- 参数值组装 ----------------
pAllBest = best.pAll;
if isempty(pAllBest)
    pAllBest = assembleFullParams(best.pFit, fitNames, fixedVals, baseAll, allNames);
end
valuesAll = pAllBest(:);
pFitBest = best.pFit(:);

% ---------------- 协方差 / 标准误 / 置信区间 ----------------
mask = isfinite(data.Y);
[se, ciLow, ciHigh, covInfo] = estimateCovariance(best, mask, nFitted, pFitBest);
if covInfo.rank_deficient
    warnings{end+1} = sprintf( ...
        '参数协方差矩阵秩亏（有效秩 %d/%d），部分参数不可单独辨识，SE/CI 仅供参考。', ...
        covInfo.rank, max(nFitted, 1));
end
if covInfo.zero_residual && nFitted > 0
    warnings{end+1} = '残差≈0（SSE=0）：无法从噪声估计 SE/CI，已置 NaN（并非“极高精度”）。';
end
if covInfo.dof <= 0 && nFitted > 0
    warnings{end+1} = '有效数据点数不大于参数个数，无法估计残差方差（SE/CI 置 NaN）。';
end

% ---------------- 指标 ----------------
yAll = data.Y;
predAll = best.pred;
if isempty(predAll)
    [predAll, simBest] = bma.fit.simulatePredictions(m, data, pAllBest, simOpts);
else
    simBest = [];
end
residMat = yAll - predAll;
yv = yAll(mask);
yhatv = predAll(mask);
wv = data.weights(mask);
wSqrt = sqrt(wv);
metrics = bma.validate.metrics(wSqrt .* yv, wSqrt .* yhatv, nFitted);
metrics.unweighted = bma.validate.metrics(yv, yhatv, nFitted);
metrics.sse = best.sse;
metrics.n_observations = numel(yv);
metrics.n_parameters = nFitted;
metrics.dof = numel(yv) - nFitted;
metrics.aic = -2 * metrics.loglik + 2 * nFitted;
metrics.bic = -2 * metrics.loglik + nFitted * log(max(numel(yv), 2));
metrics.perOutput = struct();
for j = 1:numel(data.colIds)
    cid = sanitizeFieldName(data.colIds{j});
    mj = isfinite(yAll(:, j)) & isfinite(predAll(:, j));
    metrics.perOutput.(cid) = bma.validate.metrics( ...
        yAll(mj, j), predAll(mj, j), nFitted);
end
if isfield(metrics, 'nrmse') && ~isfinite(metrics.nrmse)
    warnings{end+1} = '观测值范围为零，NRMSE 无定义（NaN）。';
end

% ---------------- 残差摘要 ----------------
residValid = residMat(mask);
residSummary = residualSummary(residValid);
if isempty(simBest)
    % 保留接口一致性（simBest 仅用于内部诊断）
    simBest = struct();
end

% ---------------- 参数表 ----------------
paramsTable = buildParamsTable(params, valuesAll, fitNames, fixedVals, ...
    se, ciLow, ciHigh, lp, up);

% ---------------- fitted spec ----------------
fittedSpec = buildFittedSpec(spec, m, valuesAll, fitNames, ...
    struct('fit_id', fitId, 'r2', metrics.r2, 'aicc', metrics.aicc, ...
    'rmse', metrics.rmse, 'n_parameters', nFitted));

% ---------------- 组装 fr ----------------
fr = struct();
fr.schema_version = 'bma.fitResult.v1';
fr.fit_id = fitId;
fr.created_at = bma.util.nowIso();
fr.fit_dir = bma.util.relPath(workDir, fitDirAbs);
fr.run_dir = bma.util.relPath(workDir, runDirAbs);
fr.work_dir = workDir;
fr.spec_name = specName(spec, m);
fr.spec_title = specTitle(spec);
fr.params = paramsTable;
fr.p = pFitBest;
fr.p0 = p0Fit;
fr.pnames = fitNames(:).';
fr.p_all = valuesAll;
fr.param_ids = allNames(:).';
fr.fitted = fitNames(:).';
fr.fixed_params = fixedVals;
fr.metrics = metrics;
fr.residuals = struct('values', residValid, 'summary', residSummary);
fr.pred = struct('t', data.t(:).', 'colIds', {data.colIds(:).'}, ...
    'colNames', {data.colNames(:).'}, 'Y', yAll, 'Yhat', predAll);
fr.fittedSpec = fittedSpec;
fr.method = struct('algorithm', 'lsqnonlin (trust-region-reflective)', ...
    'objective', '加权残差平方和 (weighted SSE)', ...
    'multistart', nStarts, 'seed', seed, ...
    'solver', solverName, 'max_iter', getNum(opts, 'max_iter', 400), ...
    'weights', weightDescription(data.weights), ...
    'criterion', 'SSE', 'fallback', 'fmincon → fminsearch');
fr.solver_info = solverInfo;
fr.multistart_diagnostics = solverInfo;
fr.multistart_used = numel(solverInfo);
fr.converged = best.converged;
fr.message = best.message;
fr.n_observations = metrics.n_observations;
fr.n_parameters = nFitted;
fr.r2 = metrics.r2;
fr.rmse = metrics.rmse;
fr.aicc = metrics.aicc;
fr.bic = metrics.bic;
fr.loglik = metrics.loglik;
fr.warnings = [warnings, warnExtra, data.warnings];
fr.figures = {};
fr.figure = '';
fr.predictions_path = '';
fr.residuals_path = '';
fr.fit_result_path = '';
fr.fitted_spec_path = '';
fr.params_path = '';
fr.sim = struct('solver', solverName, 'used_core', ...
    ~isempty(simBest) && isfield(simBest, 'solver'));

% ---------------- 产物 ----------------
if saveArtifacts
    try
        pPath = writeParamsCsv(fitDirAbs, paramsTable);
        fr.params_path = bma.util.relPath(workDir, pPath);
        pPath = writePredictionsCsv(fitDirAbs, data, predAll);
        fr.predictions_path = bma.util.relPath(workDir, pPath);
        pPath = writeResidualsCsv(fitDirAbs, data, residMat);
        fr.residuals_path = bma.util.relPath(workDir, pPath);
        fsPath = fullfile(fitDirAbs, 'fitted_spec.json');
        bma.util.writeJsonAtomic(fsPath, fittedSpec);
        fr.fitted_spec_path = bma.util.relPath(workDir, fsPath);
        if makeFigure
            try
                figDir = fullfile(fitDirAbs, 'figures');
                figPath = bma.plot.fit(fr, data, struct( ...
                    'out_dir', figDir, 'work_dir', workDir, 'name', 'fit.png'));
                if ischar(figPath) && ~isempty(figPath)
                    fr.figure = figPath;
                    fr.figures = {figPath};
                end
            catch err
                fr.warnings{end+1} = sprintf('拟合图生成失败：%s', err.message);
            end
        end
        fr.fit_result_path = bma.util.relPath(workDir, fullfile(fitDirAbs, 'fit.json'));
        bma.util.writeJsonAtomic(fullfile(fitDirAbs, 'fit.json'), fr);
        try
            save(fullfile(fitDirAbs, 'fit.mat'), 'fr', '-v7');
        catch err
            fr.warnings{end+1} = sprintf('fit.mat 保存失败：%s', err.message);
        end
    catch err
        fr.warnings{end+1} = sprintf('拟合产物写入失败：%s', err.message);
    end
end
end

% ======================================================================
% 局部函数
% ======================================================================
function opts = mergeNestedOptions(opts)
%MERGENESTEDOPTIONS 兼容 dispatch 传入的 struct('k',...,'options',opts)。
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

function p = ensureAbsDir(p)
p = char(p);
if ~isfolder(p)
    bma.util.ensureDir(p);
end
end

function [runDirAbs, fitId, fitDirAbs] = resolveFitDir(workDir, opts)
fitId = bma.util.newId('fit');
if isfield(opts, 'fit_id') && ~isempty(opts.fit_id)
    fitId = char(opts.fit_id);
end
runDirAbs = '';
if isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    runDirAbs = bma.util.absPath(workDir, char(opts.run_dir));
else
    runDirAbs = fullfile(workDir, '.bma', 'runs', bma.util.newId('r'));
end
if isfield(opts, 'fit_dir') && ~isempty(opts.fit_dir)
    fitDirAbs = bma.util.absPath(workDir, char(opts.fit_dir));
else
    fitDirAbs = fullfile(runDirAbs, 'fits', fitId);
end
end

function params = specParameterTable(spec, m)
%SPECPARAMETERTABLE 合并 spec.parameters 与 build 结果的参数信息。
allNames = cellstr(m.params);
params = struct('id', {}, 'name', {}, 'unit', {}, 'value', {}, ...
    'estimate', {}, 'bounds', {}, 'evidence', {});
specNames = {};
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    specNames = arrayfun(@(q) char(q.id), spec.parameters, 'UniformOutput', false);
end
for k = 1:numel(allNames)
    id = allNames{k};
    q = struct('id', id, 'name', id, 'unit', '', 'value', 0, ...
        'estimate', false, 'bounds', [], 'evidence', {{}});
    if isfield(m, 'paramValues') && numel(m.paramValues) == numel(allNames)
        q.value = double(m.paramValues(k));
    end
    if isfield(m, 'paramInfo') && numel(m.paramInfo) >= k ...
            && isfield(m.paramInfo, 'id')
        try
            info = m.paramInfo(k);
            if isfield(info, 'name') && ~isempty(info.name), q.name = char(info.name); end
            if isfield(info, 'unit') && ~isempty(info.unit), q.unit = char(info.unit); end
            if isfield(info, 'value') && ~isempty(info.value), q.value = double(info.value); end
        catch
        end
    end
    idx = find(strcmp(specNames, id), 1);
    if ~isempty(idx)
        sp = spec.parameters(idx);
        if isfield(sp, 'name') && ~isempty(sp.name), q.name = char(sp.name); end
        if isfield(sp, 'unit') && ~isempty(sp.unit), q.unit = char(sp.unit); end
        q.value = paramValue(sp, q.value);
        if isfield(sp, 'estimate') && ~isempty(sp.estimate)
            q.estimate = logical(sp.estimate);
        end
        if isfield(sp, 'bounds') && ~isempty(sp.bounds)
            q.bounds = double(sp.bounds(:).');
        elseif isfield(sp, 'lower') && isfield(sp, 'upper') ...
                && ~isempty(sp.lower) && ~isempty(sp.upper)
            q.bounds = [double(sp.lower), double(sp.upper)];
        end
        if isfield(sp, 'evidence') && ~isempty(sp.evidence)
            q.evidence = sp.evidence;
        end
    end
    % 边界兜底：m.lb/m.ub
    if isempty(q.bounds) && isfield(m, 'lb') && isfield(m, 'ub') ...
            && numel(m.lb) == numel(allNames) && isfinite(m.lb(k)) && isfinite(m.ub(k))
        q.bounds = [double(m.lb(k)), double(m.ub(k))];
    end
    if isempty(q.bounds)
        q.bounds = defaultBounds(q.value);
    end
    % estimate 兜底：m.estimate
    if ~q.estimate && isfield(m, 'estimate') && numel(m.estimate) == numel(allNames)
        q.estimate = logical(m.estimate(k));
    end
    params(k) = q;
end
end

function b = defaultBounds(v)
if v > 0
    b = [max(1e-12, v * 1e-3), max(1e3 * v, 1e-9)];
elseif v < 0
    b = [min(1e3 * v, -1e-9), min(-1e-12, v * 1e-3)];
else
    b = [-1e3, 1e3];
end
end

function v = paramValue(p, default)
v = default;
if isfield(p, 'value') && ~isempty(p.value)
    if isnumeric(p.value) && isscalar(p.value)
        v = double(p.value);
    elseif isstruct(p.value) && isfield(p.value, 'value') && ~isempty(p.value.value)
        v = double(p.value.value);
    end
end
end

function vals = paramValues(params)
vals = zeros(numel(params), 1);
for k = 1:numel(params)
    vals(k) = params(k).value;
end
end

function fitNames = determineFitNames(params, opts)
allNames = {params.id};
fitNames = {};
if isfield(opts, 'params_to_fit') && ~isempty(opts.params_to_fit)
    fitNames = toCellstr(opts.params_to_fit);
    unknown = setdiff(fitNames, allNames);
    if ~isempty(unknown)
        error('bma:fit:unknownParamsToFit', ...
            'params_to_fit 中包含未知参数：%s（可用：%s）。', ...
            strjoin(unknown, ', '), strjoin(allNames, ', '));
    end
else
    fitNames = allNames([params.estimate]);
end
if isempty(fitNames)
    error('bma:fit:noFreeParams', ...
        ['没有需要拟合的参数。请在 spec 中标记 estimate:true，' ...
         '或通过 options.params_to_fit 指定参数 id。']);
end
end

function [fixed, warnings] = collectFixed(params, opts)
fixed = struct();
warnings = {};
allNames = {params.id};
sources = {'fixed', 'param_overrides'};
for s = 1:numel(sources)
    name = sources{s};
    if ~isfield(opts, name) || isempty(opts.(name))
        continue
    end
    v = opts.(name);
    if isa(v, 'containers.Map')
        ks = keys(v);
        for i = 1:numel(ks)
            fixed.(char(ks{i})) = double(v(ks{i}));
        end
    elseif isstruct(v)
        f = fieldnames(v);
        for i = 1:numel(f)
            val = v.(f{i});
            if isstruct(val) && isfield(val, 'value')
                val = val.value;
            end
            if isnumeric(val) && isscalar(val) && isfinite(val)
                fixed.(f{i}) = double(val);
            else
                warnings{end+1} = sprintf('固定参数 %s 的取值非法，已忽略。', f{i}); %#ok<AGROW>
            end
        end
    elseif iscell(v) && size(v, 2) == 2
        for i = 1:size(v, 1)
            fixed.(char(v{i, 1})) = double(v{i, 2});
        end
    else
        warnings{end+1} = sprintf('无法识别的 %s 选项，已忽略。', name); %#ok<AGROW>
    end
end
unknown = setdiff(fieldnames(fixed), allNames);
for k = 1:numel(unknown)
    warnings{end+1} = sprintf('固定参数 "%s" 不在模型中，已忽略。', unknown{k}); %#ok<AGROW>
    fixed = rmfield(fixed, unknown{k});
end
end

function [fitNames, fixed, warnings] = dropFixedFromFit(fitNames, fixed)
warnings = {};
keep = true(1, numel(fitNames));
for k = 1:numel(fitNames)
    if isfield(fixed, fitNames{k})
        warnings{end+1} = sprintf( ...
            '参数 "%s" 同时被指定拟合与固定，按固定处理。', fitNames{k}); %#ok<AGROW>
        keep(k) = false;
    end
end
fitNames = fitNames(keep);
if isempty(fitNames)
    error('bma:fit:noFreeParams', '所有待拟合参数都被固定，无法拟合。');
end
end

function [lb, ub] = boundsFor(params, fitNames, m)
n = numel(fitNames);
lb = zeros(n, 1);
ub = zeros(n, 1);
for k = 1:n
    idx = find(strcmp({params.id}, fitNames{k}), 1);
    b = params(idx).bounds;
    if numel(b) ~= 2 || any(~isfinite(b)) || b(1) >= b(2)
        v = params(idx).value;
        b = defaultBounds(v);
    end
    lb(k) = b(1);
    ub(k) = b(2);
end
if isfield(m, 'lb') && isfield(m, 'ub')
    % 若 build 提供了严格边界，且 spec 边界为兜底默认值，以 build 为准
    for k = 1:n
        idx = find(strcmp(cellstr(m.params), fitNames{k}), 1);
        if ~isempty(idx) && isfinite(m.lb(idx)) && isfinite(m.ub(idx)) ...
                && m.lb(idx) < m.ub(idx)
            isDefault = isequal(params(idx).bounds, defaultBounds(params(idx).value));
            if isDefault
                lb(k) = double(m.lb(idx));
                ub(k) = double(m.ub(idx));
            end
        end
    end
end
end

function p0 = buildInitial(params, fitNames, opts, lb, ub)
k = numel(fitNames);
p0 = zeros(k, 1);
for i = 1:k
    idx = find(strcmp({params.id}, fitNames{i}), 1);
    p0(i) = params(idx).value;
end
if isfield(opts, 'p0') && ~isempty(opts.p0)
    p0 = applyInitialOverride(p0, fitNames, params, opts.p0, lb, ub);
elseif isfield(opts, 'initial') && ~isempty(opts.initial)
    p0 = applyInitialOverride(p0, fitNames, params, opts.initial, lb, ub);
end
for i = 1:k
    p0(i) = putInside(p0(i), lb(i), ub(i));
end
end

function p0 = applyInitialOverride(p0, fitNames, params, override, lb, ub)
k = numel(fitNames);
if isstruct(override)
    for i = 1:k
        if isfield(override, fitNames{i})
            p0(i) = double(override.(fitNames{i}));
        end
    end
elseif isnumeric(override)
    v = double(override(:));
    if numel(v) == k
        p0 = v;
    elseif numel(v) == numel(params)
        for i = 1:k
            idx = find(strcmp({params.id}, fitNames{i}), 1);
            p0(i) = v(idx);
        end
    else
        error('bma:fit:p0Size', ...
            'p0 长度 %d 与待拟合参数个数 %d（或全部参数 %d）不一致。', ...
            numel(v), k, numel(params));
    end
else
    error('bma:fit:p0Type', 'p0 必须是 struct 或数值向量。');
end
if numel(p0) ~= k
    error('bma:fit:p0Size', 'p0 长度与待拟合参数个数不一致。');
end
for i = 1:k
    p0(i) = putInside(p0(i), lb(i), ub(i));
end
end

function x = putInside(x, lo, hi)
if ~isfinite(x)
    x = lo + 0.5 * (hi - lo);
end
if isfinite(lo) && x <= lo
    if isfinite(hi)
        x = lo + 0.02 * (hi - lo);
    else
        x = lo + max(1e-6, abs(lo) * 1e-3);
    end
end
if isfinite(hi) && x >= hi
    if isfinite(lo)
        x = hi - 0.02 * (hi - lo);
    else
        x = hi - max(1e-6, abs(hi) * 1e-3);
    end
end
end

function starts = generateStarts(p0, pNominal, lb, ub, nStarts)
%GENERATESTARTS 混合多起点策略（固定 rng 种子，可复现）：
%   1) 给定初值 p0（调用方可能已做 ±20% 扰动）；
%   2) spec 中的名义参数值 pNominal（文献/领域先验，常见的最佳起点）；
%   3) 若干在 p0/pNominal 附近的对数正态乘性扰动起点；
%   4) 少量全局起点（边界内对数/线性均匀 + 几何中点）。
k = numel(p0);
starts = zeros(nStarts, k);
starts(1, :) = p0(:).';
if nStarts >= 2
    for j = 1:k
        starts(2, j) = putInside(pNominal(j), lb(j), ub(j));
    end
end
nLocal = 0;
nGlobal = 0;
if nStarts > 2
    nLocal = max(1, round(0.4 * (nStarts - 2)));
    nGlobal = nStarts - 2 - nLocal;
end
for s = 3:(2 + nLocal)
    if mod(s, 2) == 0
        center = pNominal(:);
    else
        center = p0(:);
    end
    sigma = 0.15 + 0.35 * rand;
    cand = center;
    for j = 1:k
        cand(j) = perturbParam(center(j), sigma, lb(j), ub(j));
    end
    starts(s, :) = cand.';
end
for s = (3 + nLocal):(2 + nLocal + nGlobal)
    g = s - (3 + nLocal);
    mode = mod(g, 3);
    cand = p0(:);
    for j = 1:k
        switch mode
            case 0
                cand(j) = randomInBounds(lb(j), ub(j));
            case 1
                cand(j) = perturbParam(p0(j), 1.0, lb(j), ub(j));
            otherwise
                if isfinite(lb(j)) && isfinite(ub(j)) && lb(j) < ub(j)
                    if lb(j) > 0 && ub(j) / lb(j) > 2
                        cand(j) = exp(0.5 * (log(lb(j)) + log(ub(j))));
                    else
                        cand(j) = 0.5 * (lb(j) + ub(j));
                    end
                else
                    cand(j) = perturbParam(p0(j), 1.0, lb(j), ub(j));
                end
        end
    end
    starts(s, :) = cand.';
end
for s = 2:nStarts
    for j = 1:k
        starts(s, j) = putInside(starts(s, j), lb(j), ub(j));
    end
end
end

function pNom = nominalFitVector(params, fitNames)
%NOMINALFITVECTOR 取 fitNames 在 spec 中的名义值，作为先验起点。
pNom = zeros(numel(fitNames), 1);
for k = 1:numel(fitNames)
    idx = find(strcmp({params.id}, fitNames{k}), 1);
    if ~isempty(idx)
        pNom(k) = params(idx).value;
    end
end
end

function kind = startKind(s)
%STARTKIND 标记起点类型（写入 solver_info 便于审计）。
switch s
    case 1
        kind = 'given_initial';
    case 2
        kind = 'spec_nominal';
    otherwise
        kind = 'multistart';
end
end

function v = perturbParam(p, sigma, lo, hi)
%PERTURBPARAM 乘性对数正态扰动（对正参数），否则加性扰动。
if p ~= 0
    v = p * exp(sigma * randn);
else
    v = sigma * randn;
end
v = putInside(v, lo, hi);
end

function v = randomInBounds(lo, hi)
%RANDOMINBOUNDS 边界内随机取样（正参数跨度大时用对数均匀）。
if ~isfinite(lo) && ~isfinite(hi)
    v = randn;
    return
end
if ~isfinite(lo)
    lo = hi - max(1, abs(hi));
end
if ~isfinite(hi)
    hi = lo + max(1, abs(lo));
end
if hi <= lo
    v = lo;
elseif lo > 0 && hi / lo > 2
    v = exp(log(lo) + (log(hi) - log(lo)) * rand);
else
    v = lo + (hi - lo) * rand;
end
end

function [se, ciLow, ciHigh, info] = estimateCovariance(best, mask, nFit, pFit)
%ESTIMATECOVARIANCE 由残差雅可比估计协方差、标准误和置信区间。
info = struct('rank', 0, 'rank_deficient', false, 'dof', 0, ...
    'sigma2', NaN, 'corr', [], 'zero_residual', false);
se = NaN(nFit, 1);
ciLow = NaN(nFit, 1);
ciHigh = NaN(nFit, 1);
if nFit == 0
    return
end
% ISSUE-017: residual≈0 (SSE exactly zero) makes sigma^2=0; the resulting
% interval [p,p] is not "very precise" but not estimable from noise.
if isfinite(best.sse) && best.sse <= 1e-16 * max(1, sum(abs(best.pAll).^2))
    info.zero_residual = true;
    return
end
maskVec = mask(:);
nEff = sum(maskVec);
info.dof = nEff - nFit;
J = best.jac;
if isempty(J) || size(J, 2) ~= nFit
    return
end
if issparse(J)
    J = full(J);
end
Jv = J(maskVec, :);
if size(Jv, 1) < 1
    return
end
FIM = full(Jv.' * Jv);
[~, S, V] = svd(FIM);
sv = diag(S);
if isempty(sv) || sv(1) <= 0
    return
end
tol = max(size(FIM)) * eps() * sv(1) * 1e3;
rankF = sum(sv > max(tol, 1e-10 * sv(1)));
info.rank = rankF;
info.rank_deficient = rankF < nFit;
if info.dof > 0
    sigma2 = best.sse / info.dof;
else
    sigma2 = NaN;
end
info.sigma2 = sigma2;
if ~isfinite(sigma2) || sigma2 < 0
    return
end
C = V * diag(1 ./ max(sv, eps())) * V.';
C = sigma2 * C;
se = sqrt(max(diag(C), 0));
tcrit = 1.959963984540054;
if info.dof > 0 && exist('tinv', 'file') == 2
    try
        tcrit = tinv(0.975, info.dof);
    catch
    end
elseif info.dof > 0
    tcrit = 1.959963984540054;
end
ciLow = pFit(:) - tcrit * se;
ciHigh = pFit(:) + tcrit * se;
seMat = se * se.';
R = C ./ max(seMat, eps());
R(~isfinite(R)) = 0;
R(1:nFit + 1:end) = 1;
info.corr = R;
end

function paramsTable = buildParamsTable(params, valuesAll, fitNames, fixedVals, ...
    se, ciLow, ciHigh, lp, up)
%BUILDPARAMSTABLE 组装契约要求的参数结构数组。
n = numel(params);
paramsTable = struct('id', {}, 'name', {}, 'unit', {}, 'value', {}, ...
    'se', {}, 'ci_low', {}, 'ci_high', {}, 'fixed', {}, ...
    'estimate', {}, 'bounds', {}, 'evidence', {}, 'initial', {});
allNames = {params.id};
for k = 1:n
    id = params(k).id;
    p = struct();
    p.id = id;
    p.name = params(k).name;
    p.unit = params(k).unit;
    p.value = valuesAll(k);
    p.initial = params(k).value;
    p.fixed = ~ismember(id, fitNames);
    p.estimate = params(k).estimate;
    idxFit = find(strcmp(fitNames, id), 1);
    if p.fixed
        p.se = 0;
        p.ci_low = p.value;
        p.ci_high = p.value;
        if isfield(fixedVals, id)
            p.fixed_value = fixedVals.(id);
        end
    else
        p.se = se(idxFit);
        p.ci_low = ciLow(idxFit);
        p.ci_high = ciHigh(idxFit);
    end
    idxAll = find(strcmp(allNames, id), 1);
    if numel(lp) == numel(fitNames) && ~isempty(idxFit)
        p.bounds = [lp(idxFit), up(idxFit)];
    else
        p.bounds = params(idxAll).bounds;
    end
    p.evidence = params(k).evidence;
    paramsTable(k) = p;
end
end

function fittedSpec = buildFittedSpec(spec, m, valuesAll, fitNames, fitMeta)
%BUILDFITTEDSPEC 把估计值写回规格，并标注 evidence 来源。
fittedSpec = spec;
allNames = cellstr(m.params);
if ~isfield(fittedSpec, 'parameters') || isempty(fittedSpec.parameters) ...
        || ~isfield(fittedSpec.parameters, 'id')
    fittedSpec.parameters = struct('id', {}, 'value', {});
    for k = 1:numel(allNames)
        fittedSpec.parameters(k) = struct('id', allNames{k}, ...
            'value', struct('value', valuesAll(k), 'note', '默认值'));
    end
else
    names = arrayfun(@(q) char(q.id), fittedSpec.parameters, 'UniformOutput', false);
    for k = 1:numel(fittedSpec.parameters)
        id = names{k};
        idx = find(strcmp(allNames, id), 1);
        if isempty(idx)
            continue
        end
        v = valuesAll(idx);
        if isfield(fittedSpec.parameters, 'value') && isstruct(fittedSpec.parameters(k).value)
            val = fittedSpec.parameters(k).value;
            val.value = v;
            if ismember(id, fitNames)
                val.note = '由数据估计（lsqnonlin 多起点，加权最小二乘）';
            elseif ~isfield(val, 'note') || isempty(val.note)
                val.note = '固定值';
            end
            fittedSpec.parameters(k).value = val;
        else
            fittedSpec.parameters(k).value = struct('value', v, ...
                'note', ternary(ismember(id, fitNames), '由数据估计', '固定值'));
        end
        % 拟合参数若没有证据条目，补充 fitted 类型（不编造文献引文）
        if ismember(id, fitNames)
            if ~isfield(fittedSpec.parameters, 'evidence') ...
                    || isempty(fittedSpec.parameters(k).evidence)
                fittedSpec.parameters(k).evidence = struct( ...
                    'type', 'fitted', 'note', '由本数据拟合得到，无文献直接测量值');
            end
        end
    end
end
if ~isfield(fittedSpec, 'metadata') || isempty(fittedSpec.metadata)
    fittedSpec.metadata = struct();
end
fittedSpec.metadata.fit = fitMeta;
end

function s = ternary(cond, a, b)
if cond
    s = a;
else
    s = b;
end
end

function name = specName(spec, m)
name = 'model';
if isfield(spec, 'name') && ~isempty(spec.name)
    name = char(spec.name);
elseif isstruct(m) && isfield(m, 'spec') && isfield(m.spec, 'name')
    name = char(m.spec.name);
end
end

function t = specTitle(spec)
t = '';
if isfield(spec, 'title') && ~isempty(spec.title)
    t = char(spec.title);
end
end

function s = residualSummary(r)
%RESIDUALSUMMARY 残差的基本统计量。
s = struct('n', numel(r), 'mean', NaN, 'std', NaN, 'skewness', NaN, ...
    'kurtosis', NaN, 'autocorr_lag1', NaN, 'mae', NaN, 'maxabs', NaN);
if isempty(r)
    return
end
r = double(r(:));
s.mean = mean(r);
s.std = std(r);
s.mae = mean(abs(r));
s.maxabs = max(abs(r));
s.m = mean(r);
s.s2 = mean((r - mean(r)).^2);
if s.std > 0
    s.skewness = mean((r - mean(r)).^3) / s.std ^ 3;
    s.kurtosis = mean((r - mean(r)).^4) / s.std ^ 4;
    if numel(r) > 2
        rr = corrcoef(r(1:end - 1), r(2:end));
        s.autocorr_lag1 = rr(1, 2);
    end
else
    s.skewness = 0;
    s.kurtosis = 3;
end
end

function cid = sanitizeFieldName(id)
c = char(id);
c = regexprep(c, '[^A-Za-z0-9_]', '_');
if isempty(c) || ~isletter(c(1))
    c = ['o_' c];
end
cid = c;
end

function path = writeParamsCsv(fitDirAbs, paramsTable)
path = fullfile(fitDirAbs, 'params.csv');
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:fit:csvWrite', '无法写入 %s', path);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, 'id,name,unit,value,se,ci_low,ci_high,fixed,bounds_low,bounds_high,initial\n');
for k = 1:numel(paramsTable)
    p = paramsTable(k);
    bl = NaN;
    bu = NaN;
    if numel(p.bounds) == 2
        bl = p.bounds(1);
        bu = p.bounds(2);
    end
    fprintf(fid, '%s,%s,%s,%.10g,%.10g,%.10g,%.10g,%d,%.10g,%.10g,%.10g\n', ...
        p.id, csvEscape(p.name), csvEscape(p.unit), p.value, p.se, ...
        p.ci_low, p.ci_high, p.fixed, bl, bu, p.initial);
end
end

function path = writePredictionsCsv(fitDirAbs, data, pred)
path = fullfile(fitDirAbs, 'predictions.csv');
n = numel(data.t);
M = NaN(n, 1 + 2 * numel(data.colIds));
header = [{'time'}, cell(1, 2 * numel(data.colIds))];
M(:, 1) = data.t;
for j = 1:numel(data.colIds)
    M(:, 2 * j) = data.Y(:, j);
    M(:, 2 * j + 1) = pred(:, j);
    header{2 * j} = [data.colNames{j} '_obs'];
    header{2 * j + 1} = [data.colNames{j} '_pred'];
end
writeCsvMat(path, header, M);
end

function path = writeResidualsCsv(fitDirAbs, data, residMat)
path = fullfile(fitDirAbs, 'residuals.csv');
M = [data.t(:), residMat];
header = [{'time'}, cellfun(@(c) [c '_resid'], data.colNames, 'UniformOutput', false)];
writeCsvMat(path, header, M);
end

function writeCsvMat(path, header, M)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:fit:csvWrite', '无法写入 %s', path);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', strjoin(header, ','));
fmt = [strjoin(repmat({'%.10g'}, 1, size(M, 2)), ','), '\n'];
fprintf(fid, fmt, M.');
end

function s = weightDescription(w)
if isempty(w)
    s = '等权（默认）';
    return
end
if all(abs(w(:) - 1) < 1e-12)
    s = '等权';
else
    s = '用户自定义权重';
end
end

function c = toCellstr(x)
if isempty(x)
    c = {};
elseif iscell(x)
    c = cellfun(@(s) char(s), x(:).', 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    parts = strtrim(strsplit(x, ','));
    c = parts(~cellfun(@isempty, parts));
else
    error('bma:fit:cellstr', '无法转换为字符串列表：%s', class(x));
end
end

function v = getNum(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
else
    v = default;
end
end

function s = csvEscape(s)
s = char(s);
s = strrep(s, ',', '，');
s = strrep(s, newline, ' ');
end
