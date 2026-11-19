% test_validate：指标 / 模型选择(AICc) / 时序交叉验证 / 残差诊断
% 断言：
%   metrics      ：R²/RMSE/NRMSE/AICc/BIC 与手算公式一致，NaN 剔除正确
%   modelSelection：候选为 dispatch 预处理格式 {name, model, data, options}；
%                   AICc 权重和为 1、正确模型最优
%   crossValidation：k 折、folds 字段齐全、summary 有限、图存在
%   residuals    ：正态性/自相关/异方差字段齐全、图存在

root = bma.util.projectRoot();
addpath(fullfile(root, 'matlab'));
workRoot = fullfile(root, '.bma', 'test-runs', bma.util.newId('test-validate'));
bma.util.ensureDir(workRoot);

% =====================================================================
% 1) metrics 公式核对（含 NaN 剔除）
% =====================================================================
y = (1:10).';
yhat = y + 0.5;
s = bma.validate.metrics(y, yhat, 1);
sse = sum((y - yhat).^2);
sst = sum((y - mean(y)).^2);
assert(abs(s.sse - sse) < 1e-12, 'metrics SSE 计算错误');
assert(abs(s.r2 - (1 - sse / sst)) < 1e-12, 'metrics R² 计算错误');
assert(abs(s.rmse - sqrt(sse / 10)) < 1e-12, 'metrics RMSE 计算错误');
assert(abs(s.nrmse - sqrt(sse / 10) / (max(y) - min(y))) < 1e-12, 'metrics NRMSE 计算错误');
loglik = -0.5 * 10 * (log(2 * pi * sse / 10) + 1);
assert(abs(s.loglik - loglik) < 1e-10, 'metrics loglik 计算错误');
assert(abs(s.aicc - (-2 * loglik + 2 + 2 * 1 * 2 / (10 - 1 - 1))) < 1e-10, ...
    'metrics AICc 计算错误');
assert(abs(s.bic - (-2 * loglik + 1 * log(10))) < 1e-10, 'metrics BIC 计算错误');
yNaN = y;
yNaN(3) = NaN;
s2 = bma.validate.metrics(yNaN, yhat, 1);
assert(s2.n == 9, sprintf('NaN 应被剔除，n 应为 9，实际 %d', s2.n));
fprintf('[PASS] metrics 公式核对（R²=%.4f, AICc=%.3f, NaN 剔除正确）\n', s.r2, s.aicc);

% =====================================================================
% 2) 模型选择：正确模型 vs 错误固定 kcat 模型（dispatch 预处理格式）
% =====================================================================
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
rep = bma.spec.validate(spec, root);
mCorrect = bma.model.build(rep.normalized_spec);
specWrong = rep.normalized_spec;
for k = 1:numel(specWrong.parameters)
    if strcmp(char(specWrong.parameters(k).id), 'kcat')
        specWrong.parameters(k).value = struct('value', 0.2, 'note', '故意错误的固定值');
        specWrong.parameters(k).estimate = false;
        specWrong.parameters(k).bounds = [0.0001, 1000];
    end
end
mWrong = bma.model.build(specWrong);
csvPath = fullfile(root, 'spec', 'examples', 'data', 'enzyme_progress.csv');
T = readtable(csvPath, 'VariableNamingRule', 'preserve');
data = struct('path', csvPath, 'table', T, 'time', T{:, 1}, ...
    'time_unit', '', 'output_map', struct('P_obs', 'P_obs', 'S_obs', 'S_obs'));
prepared = { ...
    struct('name', 'enzyme_correct', 'model', mCorrect, 'data', data, ...
    'options', struct('multistart', 4)), ...
    struct('name', 'enzyme_wrong_kcat', 'model', mWrong, 'data', data, ...
    'options', struct('multistart', 4))};
ms = bma.validate.modelSelection(prepared, struct( ...
    'run_dir', fullfile(workRoot, 'model-selection'), 'multistart', 4));
assert(numel(ms.table) == 2, '模型选择表应有 2 个候选');
assert(strcmp(ms.best, 'enzyme_correct'), ...
    sprintf('AICc 应选中正确模型，实际 best=%s', ms.best));
weights = [ms.table.aicc_weight];
assert(abs(sum(weights) - 1) < 1e-6, sprintf('AICc 权重和应为 1，实际 %.6f', sum(weights)));
assert(all(weights >= 0 & weights <= 1), 'AICc 权重应在 [0,1]');
assert(ms.table(1).aicc <= ms.table(2).aicc, '模型选择表未按 AICc 升序');
assert(~isempty(ms.table_path) && localExists(root, ms.table_path), '模型选择表 CSV 不存在');
fprintf('[PASS] modelSelection best=%s, w(sum)=%.4f\n', ms.best, sum(weights));

% =====================================================================
% 3) 交叉验证（dispatch 传入 struct('k',k,'options',opts)）
% =====================================================================
cv = bma.validate.crossValidation(mCorrect, data, struct('k', 3, ...
    'run_dir', fullfile(workRoot, 'cv'), ...
    'options', struct('multistart', 3)));
assert(numel(cv.folds) == 3, sprintf('应有 3 折，实际 %d', numel(cv.folds)));
for k = 1:numel(cv.folds)
    f = cv.folds(k);
    assert(isfield(f, 'train_r2') && isfield(f, 'test_r2') && isfield(f, 'test_rmse'), ...
        'fold 缺少 train_r2/test_r2/test_rmse');
    assert(isfinite(f.test_rmse), 'test RMSE 非有限');
end
assert(isfield(cv, 'summary') && isfinite(cv.summary.mean_test_rmse), ...
    'CV summary 缺少有限 mean_test_rmse');
assert(isfinite(cv.summary.mean_test_r2), 'CV mean_test_r2 非有限');
assert(~isempty(cv.figure) && localExists(root, cv.figure), '交叉验证图不存在');
fprintf('[PASS] crossValidation k=3, mean_test_r2=%.4f, mean_test_rmse=%.4g\n', ...
    cv.summary.mean_test_r2, cv.summary.mean_test_rmse);

% =====================================================================
% 4) 残差诊断
% =====================================================================
rng(99, 'twister');
p0 = struct();
pNames = cellstr(mCorrect.params);
for k = 1:numel(pNames)
    p0.(pNames{k}) = mCorrect.paramValues(k) * (0.85 + 0.3 * rand);
end
fr = bma.fit.estimate(mCorrect, data, struct('work_dir', root, ...
    'run_dir', fullfile(workRoot, 'fit'), 'multistart', 4, 'p0', p0));
rs = bma.validate.residuals(fr);
d = rs.diagnostics;
assert(d.n > 0, '残差样本数为 0');
assert(isfinite(d.normality_p), '正态性 p 值非有限');
assert(isfinite(d.autocorr_lag1), '滞后自相关非有限');
assert(isfield(d, 'heteroscedastic') && isstruct(d.heteroscedastic) ...
    && isfield(d.heteroscedastic, 'flag'), '缺少异方差诊断');
assert(isfield(d, 'skewness') && isfinite(d.skewness), '缺少偏度');
assert(isfield(d, 'kurtosis') && isfinite(d.kurtosis), '缺少峰度');
assert(isfield(d, 'durbin_watson') && isfinite(d.durbin_watson), '缺少 Durbin-Watson');
assert(~isempty(rs.figure) && localExists(root, rs.figure), '残差诊断图不存在');
fprintf('[PASS] residuals n=%d, normality p=%.3f(%s), lag1=%.3f, hetero=%d\n', ...
    d.n, d.normality_p, d.normality_method, d.autocorr_lag1, ...
    logical(d.heteroscedastic.flag));

% =====================================================================
% 辅助函数
% =====================================================================
function tf = localExists(root, relPath)
tf = isfile(relPath) || isfile(fullfile(root, relPath));
end
