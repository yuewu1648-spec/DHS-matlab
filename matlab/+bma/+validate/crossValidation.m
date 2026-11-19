function r = crossValidation(mOrSpec, dataIn, opts)
%CROSSVALIDATION k 折时间序列交叉验证。
%   r = bma.validate.crossValidation(m, data, opts)
%
% 折划分：按时间排序后切成 k 个连续块（时序交叉验证，避免用未来预测过去）。
% 每折：用其余块拟合参数 → 在被留出块上计算 test 指标。
%
% opts（也兼容 dispatch 的 struct('k',k,'options',opts)）：
%   k            折数（默认 5）
%   multistart   每折拟合的多起点数（默认 4，省时；可被 options 覆盖）
%   max_iter / seed / solver / rtol / atol / params_to_fit / fixed / weights
%   work_dir / run_dir / out_dir
%
% 输出 r：folds(struct array)、summary、figure(相对路径)、warnings

if nargin < 3 || isempty(opts)
    opts = struct();
end
opts = mergeNestedOptions(opts);
[m, spec] = bma.fit.resolveModel(mOrSpec);
data = bma.fit.normalizeData(dataIn, m, opts);
workDir = absDir(getStr(opts, 'work_dir', bma.util.projectRoot()));
runDirAbs = resolveRunDir(workDir, opts);
nData = numel(data.t);
k = max(2, round(getNum(opts, 'k', 5)));
if nData < 4
    error('bma:validate:cvTooFew', '数据点太少（%d），无法做 %d 折交叉验证。', nData, k);
end
k = min(k, max(2, nData - 2));

% 拟合选项（每折运行，不落盘、不画图）
fitOpts = struct();
if isfield(opts, 'fit_options') && isstruct(opts.fit_options)
    fitOpts = opts.fit_options;
end
copyFields = {'multistart', 'max_iter', 'max_fe', 'seed', 'solver', 'rtol', ...
    'atol', 'params_to_fit', 'fixed', 'weights', 'time_end'};
for c = 1:numel(copyFields)
    f = copyFields{c};
    if isfield(opts, f) && ~isempty(opts.(f))
        fitOpts.(f) = opts.(f);
    end
end
if ~isfield(fitOpts, 'multistart')
    fitOpts.multistart = 4;
end
fitOpts.save_artifacts = false;
fitOpts.make_figure = false;
fitOpts.work_dir = workDir;

simOpts = struct('solver', getStr(opts, 'solver', 'ode15s'));
if isfield(opts, 'rtol'), simOpts.rtol = opts.rtol; end
if isfield(opts, 'atol'), simOpts.atol = opts.atol; end
if isfield(opts, 'time_end') && ~isempty(opts.time_end)
    simOpts.time_end = opts.time_end;
end

edges = round(linspace(0, nData, k + 1));
folds = struct('fold', {}, 'n_train', {}, 'n_test', {}, 'train_r2', {}, ...
    'train_rmse', {}, 'test_r2', {}, 'test_rmse', {}, 'test_nrmse', {}, ...
    'test_mae', {}, 'test_sse', {}, 'params', {}, 'converged', {});
warnings = {};
for f = 1:k
    testIdx = (edges(f) + 1):edges(f + 1);
    trainIdx = setdiff(1:nData, testIdx);
    if numel(testIdx) < 1 || numel(trainIdx) < 2
        warnings{end+1} = sprintf('第 %d 折数据不足，已跳过。', f); %#ok<AGROW>
        continue
    end
    trainData = subsetData(data, trainIdx);
    testData = subsetData(data, testIdx);
    fold = struct('fold', f, 'n_train', numel(trainIdx), ...
        'n_test', numel(testIdx), 'train_r2', NaN, 'train_rmse', NaN, ...
        'test_r2', NaN, 'test_rmse', NaN, 'test_nrmse', NaN, ...
        'test_mae', NaN, 'test_sse', NaN, 'params', struct(), 'converged', false);
    try
        fr = bma.fit.estimate(m, trainData, fitOpts);
        fold.train_r2 = fr.metrics.r2;
        fold.train_rmse = fr.metrics.rmse;
        fold.converged = fr.converged;
        pAll = fr.p_all;
        pred = bma.fit.simulatePredictions(m, testData, pAll, simOpts);
        mt = bma.validate.metrics(testData.Y, pred, numel(fr.pnames));
        fold.test_r2 = mt.r2;
        fold.test_rmse = mt.rmse;
        fold.test_nrmse = mt.nrmse;
        fold.test_mae = mt.mae;
        fold.test_sse = mt.sse;
        fold.params = struct();
        for i = 1:numel(fr.pnames)
            fold.params.(fr.pnames{i}) = fr.p(i);
        end
    catch err
        warnings{end+1} = sprintf('第 %d 折拟合失败：%s', f, err.message); %#ok<AGROW>
    end
    folds(end+1) = fold; %#ok<AGROW>
end
if isempty(folds)
    error('bma:validate:cvFailed', '所有折都失败；请检查模型与数据。');
end

% 汇总
testR2 = [folds.test_r2];
testRmse = [folds.test_rmse];
summary = struct();
summary.k = numel(folds);
summary.n = nData;
summary.mean_test_r2 = meanFinite(testR2);
summary.sd_test_r2 = stdFinite(testR2);
summary.mean_test_rmse = meanFinite(testRmse);
summary.sd_test_rmse = stdFinite(testRmse);
summary.mean_train_r2 = meanFinite([folds.train_r2]);
summary.sd_train_r2 = stdFinite([folds.train_r2]);
if numel(testR2(isfinite(testR2))) >= 2
    summary.generalization_gap = summary.mean_train_r2 - summary.mean_test_r2;
else
    summary.generalization_gap = NaN;
end

% 图
figurePath = '';
try
    figDir = fullfile(runDirAbs, 'figures');
    if isfield(opts, 'out_dir') && ~isempty(opts.out_dir)
        figDir = bma.util.absPath(workDir, char(opts.out_dir));
    end
    bma.util.ensureDir(figDir);
    absPath = fullfile(figDir, 'cross_validation.png');
    figurePath = plotFolds(absPath, folds, summary);
    figurePath = bma.util.relPath(workDir, figurePath);
catch err
    warnings{end+1} = sprintf('交叉验证图生成失败：%s', err.message);
end

r = struct();
r.schema_version = 'bma.validateCrossValidation.v1';
r.folds = folds;
r.summary = summary;
r.figure = figurePath;
r.figure_path = figurePath;
r.warnings = warnings;
end

% ======================================================================
% 局部函数
% ======================================================================
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

function d = subsetData(data, idx)
%SUBSETDATA 取出数据子集（保持列顺序与权重）。
d = data;
d.t = data.t(idx);
d.Y = data.Y(idx, :);
if ~isempty(data.weights)
    if isequal(size(data.weights), size(data.Y))
        d.weights = data.weights(idx, :);
    elseif isvector(data.weights) && numel(data.weights) == size(data.Y, 2)
        d.weights = data.weights;
    end
end
end

function p = plotFolds(absPath, folds, summary)
%PLOTFOLDS 各折 test R² 柱状图（visible off，150dpi）。
fig = figure('Visible', 'off', 'Color', 'w');
cleaner = onCleanup(@() close(fig));
testR2 = [folds.test_r2];
x = 1:numel(folds);
b = bar(x, testR2, 0.6);
b.FaceColor = [0.2 0.55 0.85];
hold on
yline(summary.mean_test_r2, 'r--', 'LineWidth', 1.2);
hold off
grid on
xlabel('折编号');
ylabel('测试集 R^2');
title(sprintf('k 折时序交叉验证（k=%d，测试 R^2 均值 %.3f）', ...
    numel(folds), summary.mean_test_r2));
xticks(x);
set(gca, 'TickLabelInterpreter', 'none');
ylim([min(-0.2, min([-0.1, testR2])) max(1.02, max([1, testR2]))]);
exportgraphics(fig, absPath, 'Resolution', 150);
p = absPath;
end

function v = meanFinite(x)
x = x(isfinite(x));
if isempty(x)
    v = NaN;
else
    v = mean(x);
end
end

function v = stdFinite(x)
x = x(isfinite(x));
if numel(x) < 2
    v = NaN;
else
    v = std(x);
end
end

function runDirAbs = resolveRunDir(workDir, opts)
if isfield(opts, 'run_dir_abs') && ~isempty(opts.run_dir_abs)
    runDirAbs = char(opts.run_dir_abs);
elseif isfield(opts, 'runDirAbs') && ~isempty(opts.runDirAbs)
    runDirAbs = char(opts.runDirAbs);
elseif isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    runDirAbs = bma.util.absPath(workDir, char(opts.run_dir));
else
    runDirAbs = fullfile(workDir, '.bma', 'runs', bma.util.newId('r'));
end
bma.util.ensureDir(runDirAbs);
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

function v = getStr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = char(s.(name));
else
    v = default;
end
end
