% test_fit_estimate：参数估计正确性（enzyme/sir/goodwin 真值恢复）
% 断言（任务契约）：
%   enzyme : kcat 相对误差 < 10%；r2 > 0.995；派生 Km=(kr+kcat)/kf 相对误差 < 25%
%            （数据 t>=5s 未覆盖 ~0.2s 结合瞬态，kf/kr 个体弱可辨识：要求真值落在 95% CI 内）
%   sir    : beta/gamma 相对误差 < 15%；r2 > 0.99
%   goodwin: 至少 3/4 个拟合参数相对误差 < 25%，否则用 AICc 模型比较（正确模型必须最优）
% 另断言：契约字段齐全、predictions/residuals CSV 存在、fittedSpec 已写回参数值。

root = bma.util.projectRoot();
addpath(fullfile(root, 'matlab'));
truth = bma.util.readJson(fullfile(root, 'spec', 'examples', 'data', 'truth.json'));
workRoot = fullfile(root, '.bma', 'test-runs', bma.util.newId('test-fit-est'));
bma.util.ensureDir(workRoot);

% =====================================================================
% 1) enzyme_mm
% =====================================================================
[spec, m] = localBuild('enzyme_mm', root);
data = localData('enzyme_progress.csv', ...
    struct('P_obs', 'P_obs', 'S_obs', 'S_obs'), root);
p0 = localPerturb(m, truth.enzyme_mm, 2026);
fr = bma.fit.estimate(m, data, struct('work_dir', root, ...
    'run_dir', fullfile(workRoot, 'enzyme'), 'multistart', 8, 'p0', p0));
assert(fr.converged, 'enzyme 拟合未收敛');
assert(fr.metrics.r2 > 0.995, sprintf('enzyme R² 过低：%.4f', fr.metrics.r2));
assert(isfinite(fr.metrics.aicc) && isfinite(fr.metrics.bic), 'enzyme AICc/BIC 非有限');
assert(fr.metrics.n == 26, sprintf('enzyme 有效观测数应为 26，实际 %d', fr.metrics.n));
kcat = localParam(fr, 'kcat');
relKcat = abs(kcat - truth.enzyme_mm.kcat) / truth.enzyme_mm.kcat;
assert(relKcat < 0.10, sprintf('enzyme kcat 相对误差 %.1f%% >= 10%%', 100 * relKcat));
kf = localParam(fr, 'kf');
kr = localParam(fr, 'kr');
km = (kr + kcat) / kf;
kmTruth = (truth.enzyme_mm.kr + truth.enzyme_mm.kcat) / truth.enzyme_mm.kf;
relKm = abs(km - kmTruth) / kmTruth;
assert(relKm < 0.25, sprintf('enzyme 派生 Km 相对误差 %.1f%% >= 25%%', 100 * relKm));
% kf/kr 个体弱可辨识：95% CI 应覆盖真值
localAssertCiCovers(fr, 'kf', truth.enzyme_mm.kf);
localAssertCiCovers(fr, 'kr', truth.enzyme_mm.kr);
% 契约字段
localAssertFitShape(fr);
assert(isfield(fr, 'fittedSpec') && isstruct(fr.fittedSpec), '缺少 fittedSpec');
assert(isfile(fr.predictions_path) || isfile(fullfile(root, fr.predictions_path)), ...
    'predictions CSV 不存在');
assert(isfile(fr.residuals_path) || isfile(fullfile(root, fr.residuals_path)), ...
    'residuals CSV 不存在');
assert(numel(fr.figures) >= 1, '拟合图缺失');
fprintf('[PASS] enzyme_mm kcat %.2f%%  Km %.2f%%  R2=%.5f\n', ...
    100 * relKcat, 100 * relKm, fr.metrics.r2);

% =====================================================================
% 2) sir
% =====================================================================
[spec, m] = localBuild('sir', root);
data = localData('sir_observations.csv', ...
    struct('I_obs', 'I_obs', 'R_obs', 'R_obs'), root);
p0 = localPerturb(m, truth.sir, 2027);
frS = bma.fit.estimate(m, data, struct('work_dir', root, ...
    'run_dir', fullfile(workRoot, 'sir'), 'multistart', 8, 'p0', p0));
assert(frS.converged, 'sir 拟合未收敛');
assert(frS.metrics.r2 > 0.99, sprintf('sir R² 过低：%.4f', frS.metrics.r2));
beta = localParam(frS, 'beta');
gamma = localParam(frS, 'gamma');
relBeta = abs(beta - truth.sir.beta) / truth.sir.beta;
relGamma = abs(gamma - truth.sir.gamma) / truth.sir.gamma;
assert(relBeta < 0.15, sprintf('sir beta 相对误差 %.1f%% >= 15%%', 100 * relBeta));
assert(relGamma < 0.15, sprintf('sir gamma 相对误差 %.1f%% >= 15%%', 100 * relGamma));
% 固定参数应标记 fixed 且 SE=0
idxN = find(strcmp({frS.params.id}, 'N'), 1);
assert(~isempty(idxN) && logical(frS.params(idxN).fixed), 'sir N 应标记为固定参数');
assert(frS.params(idxN).se == 0, '固定参数 SE 应为 0');
localAssertFitShape(frS);
fprintf('[PASS] sir beta %.2f%%  gamma %.2f%%  R2=%.5f\n', ...
    100 * relBeta, 100 * relGamma, frS.metrics.r2);

% =====================================================================
% 3) goodwin（至少 3/4 参数 <25%，否则要求 AICc 比较正确模型最优）
% =====================================================================
[spec, m] = localBuild('goodwin', root);
data = localData('goodwin_timeseries.csv', ...
    struct('m_obs', 'm_obs', 'p_obs', 'p_obs'), root);
p0 = localPerturb(m, truth.goodwin, 2028);
frG = bma.fit.estimate(m, data, struct('work_dir', root, ...
    'run_dir', fullfile(workRoot, 'goodwin'), 'multistart', 8, 'p0', p0, ...
    'fit_seconds', 150));
assert(frG.converged, 'goodwin 拟合未收敛');
fitIds = frG.pnames;
truthIds = fieldnames(truth.goodwin);
nWithin = 0;
nChecked = 0;
recovered = {};
for k = 1:numel(fitIds)
    id = fitIds{k};
    if isfield(truth.goodwin, id)
        nChecked = nChecked + 1;
        v = localParam(frG, id);
        rel = abs(v - truth.goodwin.(id)) / abs(truth.goodwin.(id));
        if rel < 0.25
            nWithin = nWithin + 1;
            recovered{end+1} = sprintf('%s(%.1f%%)', id, 100 * rel); %#ok<SAGROW>
        end
    end
end
fprintf('[INFO] goodwin 参数相对误差 <25%% 的个数：%d/%d (r2=%.4f, sse=%.4g)\n', ...
    nWithin, nChecked, frG.metrics.r2, frG.metrics.sse);
if nWithin < 3
    % 退化断言：用 AICc 模型比较，正确模型（h 自由）必须优于错误模型（h 固定为 1）
    specWrong = spec;
    for k = 1:numel(specWrong.parameters)
        if strcmp(char(specWrong.parameters(k).id), 'h')
            specWrong.parameters(k).value = struct('value', 1, 'note', '故意错误的固定值');
            specWrong.parameters(k).estimate = false;
            specWrong.parameters(k).bounds = [1, 30];
        end
    end
    mWrong = bma.model.build(specWrong);
    prepared = { ...
        struct('name', 'goodwin_correct', 'model', m, 'data', data, ...
        'options', struct('multistart', 6)), ...
        struct('name', 'goodwin_wrong_h', 'model', mWrong, 'data', data, ...
        'options', struct('multistart', 6))};
    ms = bma.validate.modelSelection(prepared, struct( ...
        'run_dir', fullfile(workRoot, 'goodwin-ms'), 'multistart', 6));
    assert(strcmp(ms.best, 'goodwin_correct'), ...
        sprintf('goodwin AICc 模型比较未选中正确模型（best=%s）', ms.best));
    fprintf('[PASS] goodwin 通过 AICc 模型比较断言（correct 模型最优）\n');
else
    assert(nWithin >= 3, sprintf('goodwin 仅 %d/%d 参数在 25%% 内', nWithin, nChecked));
    fprintf('[PASS] goodwin 3/4 参数恢复：%s\n', strjoin(recovered, ', '));
end
localAssertFitShape(frG);

% =====================================================================
% 辅助函数
% =====================================================================
function [spec, m] = localBuild(name, root)
spec = bma.spec.load(fullfile(root, 'spec', 'examples', [name '.json']));
rep = bma.spec.validate(spec, root);
assert(rep.valid, sprintf('%s 规格校验失败', name));
m = bma.model.build(rep.normalized_spec);
end

function data = localData(csvName, outputMap, root)
csvPath = fullfile(root, 'spec', 'examples', 'data', csvName);
T = readtable(csvPath, 'VariableNamingRule', 'preserve');
data = struct('path', csvPath, 'table', T, 'time', T{:, 1}, ...
    'time_unit', '', 'output_map', outputMap);
end

function p0 = localPerturb(m, truth, seed)
pNames = cellstr(m.params);
rng(seed, 'twister');
p0 = struct();
for k = 1:numel(pNames)
    id = pNames{k};
    if isfield(truth, id) && isfinite(m.paramValues(k)) && m.paramValues(k) ~= 0
        f = 0.8 + 0.4 * rand;   % ±20% 初值扰动
        p0.(id) = m.paramValues(k) * f;
    elseif isfield(m, 'paramValues')
        p0.(id) = m.paramValues(k);
    end
end
end

function v = localParam(fr, id)
idx = find(strcmp({fr.params.id}, id), 1);
assert(~isempty(idx), sprintf('fit 结果中缺少参数 %s', id));
v = fr.params(idx).value;
end

function localAssertCiCovers(fr, id, truthValue)
idx = find(strcmp({fr.params.id}, id), 1);
assert(~isempty(idx), sprintf('缺少参数 %s', id));
p = fr.params(idx);
assert(isfinite(p.ci_low) && isfinite(p.ci_high), sprintf('%s 的 CI 非有限', id));
assert(p.ci_low <= truthValue && truthValue <= p.ci_high, ...
    sprintf('%s 的 95%% CI [%.4g, %.4g] 未覆盖真值 %.4g', ...
    id, p.ci_low, p.ci_high, truthValue));
end

function localAssertFitShape(fr)
required = {'id', 'value', 'se', 'ci_low', 'ci_high', 'fixed'};
for k = 1:numel(fr.params)
    for f = 1:numel(required)
        assert(isfield(fr.params(k), required{f}), ...
            sprintf('参数表缺少字段 %s', required{f}));
    end
end
metricFields = {'r2', 'rmse', 'nrmse', 'aicc', 'bic', 'loglik', 'n'};
for f = 1:numel(metricFields)
    assert(isfield(fr.metrics, metricFields{f}), ...
        sprintf('metrics 缺少字段 %s', metricFields{f}));
end
assert(isfield(fr, 'p') && isfield(fr, 'p0') && isfield(fr, 'fittedSpec'), ...
    'fit 结果缺少 p/p0/fittedSpec');
assert(isfield(fr, 'warnings'), 'fit 结果缺少 warnings');
assert(all(isfinite(fr.p)), '拟合参数向量含非有限值');
end
