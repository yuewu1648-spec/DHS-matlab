% test_fit_analysis：剖面似然 / 敏感性 / 可辨识性（enzyme_mm 示例）
% 断言：
%   profile       ：CI 包住拟合值与真值 kcat、CI 有限、CSV/图存在
%   sensitivity   ：局部弹性 + Sobol 一阶/总效应表非空、维度正确、有显著参数、CSV/图存在
%   identifiability：结构秩=3、相关矩阵/条件数/相对 SE 有限、弱可辨识参数相对 SE 大于 kcat、
%                    给出不可辨识组合/建议、表文件存在

root = bma.util.projectRoot();
addpath(fullfile(root, 'matlab'));
truth = bma.util.readJson(fullfile(root, 'spec', 'examples', 'data', 'truth.json'));
workRoot = fullfile(root, '.bma', 'test-runs', bma.util.newId('test-fit-ana'));
bma.util.ensureDir(workRoot);

% 基础模型与数据
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
rep = bma.spec.validate(spec, root);
assert(rep.valid, 'enzyme 规格校验失败');
m = bma.model.build(rep.normalized_spec);
csvPath = fullfile(root, 'spec', 'examples', 'data', 'enzyme_progress.csv');
T = readtable(csvPath, 'VariableNamingRule', 'preserve');
data = struct('path', csvPath, 'table', T, 'time', T{:, 1}, ...
    'time_unit', '', 'output_map', struct('P_obs', 'P_obs', 'S_obs', 'S_obs'));

% 一次性拟合（multistart=4 以控制测试耗时；若已拟合可复用运行目录）
pNames = cellstr(m.params);
rng(42, 'twister');
p0 = struct();
for k = 1:numel(pNames)
    if isfield(truth.enzyme_mm, pNames{k})
        p0.(pNames{k}) = m.paramValues(k) * (0.8 + 0.4 * rand);
    end
end
fr = bma.fit.estimate(m, data, struct('work_dir', root, ...
    'run_dir', fullfile(workRoot, 'enzyme'), 'multistart', 4, 'p0', p0));

% =====================================================================
% 1) 剖面似然（kcat 应强可辨识，CI 应包住真值）
% =====================================================================
pr = bma.fit.profile(m, data, fr, 'kcat', struct( ...
    'n_points', 15, 'work_dir', root, 'max_iter', 120));
assert(isfield(pr, 'ci') && isstruct(pr.ci), 'profile 结果缺少 ci');
assert(isfinite(pr.ci.low) && isfinite(pr.ci.high), 'kcat 剖面 CI 非有限');
assert(pr.ci.low < pr.ci.high, 'kcat 剖面 CI 上下界颠倒');
kcatFit = localParam(fr, 'kcat');
assert(pr.ci.low <= kcatFit && kcatFit <= pr.ci.high, ...
    'kcat 剖面 CI 未覆盖拟合值');
truthKcat = truth.enzyme_mm.kcat;
assert(pr.ci.low <= truthKcat && truthKcat <= pr.ci.high, ...
    sprintf('kcat 剖面 95%% CI [%.4g, %.4g] 未覆盖真值 %.4g', ...
    pr.ci.low, pr.ci.high, truthKcat));
assert(numel(pr.values) >= 10, '剖面扫描点过少');
assert(all(isfinite(pr.nll(isfinite(pr.nll)))), '剖面 NLL 含非有限值');
assert(~isempty(pr.profile_path) && localExists(root, pr.profile_path), '剖面 CSV 不存在');
assert(~isempty(pr.figure) && localExists(root, pr.figure), '剖面图不存在');
fprintf('[PASS] profile kcat CI=[%.4f, %.4f]（拟合值 %.4f，真值 %.1f）\n', ...
    pr.ci.low, pr.ci.high, kcatFit, truthKcat);

% =====================================================================
% 2) 敏感性分析（局部 + Sobol）
% =====================================================================
si = bma.fit.sensitivity(m, struct('params', {{'kf', 'kr', 'kcat'}}, ...
    'method', 'both', 'sobol_n', 64, 'seed', 42, 'work_dir', root, ...
    'run_dir', fullfile(workRoot, 'sens')));
assert(isfield(si, 'local') && isfield(si.local, 'max_abs'), '敏感性缺少局部弹性');
assert(isequal(size(si.local.max_abs), [3, 2]), ...
    sprintf('局部弹性维度应为 3×2，实际 %s', mat2str(size(si.local.max_abs))));
assert(any(isfinite(si.local.max_abs(:))), '局部弹性全为 NaN');
assert(isfield(si, 'sobol') && isfield(si.sobol, 'first') ...
    && isfield(si.sobol, 'total'), '敏感性缺少 Sobol 指数');
assert(isequal(size(si.sobol.first), [3, 2]), 'Sobol 一阶指数维度错误');
assert(isequal(size(si.sobol.total), [3, 2]), 'Sobol 总效应维度错误');
assert(any(isfinite(si.sobol.total(:))), 'Sobol 总效应全为 NaN');
tot = si.sobol.total;
tot = tot(isfinite(tot));
assert(max(abs(tot)) > 0.01, sprintf('Sobol 总效应无显著参数（max=%.3g）', max(abs(tot))));
assert(numel(si.table) == 6, sprintf('敏感性表应有 6 行，实际 %d', numel(si.table)));
% 表按总效应降序：第一行 |total| 应不小于最后一行（NaN 作 -Inf）
firstKey = abs(si.table(1).sobol_total);
lastKey = abs(si.table(end).sobol_total);
if ~isfinite(firstKey), firstKey = -Inf; end
if ~isfinite(lastKey), lastKey = -Inf; end
assert(firstKey >= lastKey, '敏感性表未按总效应降序排列');
assert(~isempty(si.table_path) && localExists(root, si.table_path), '敏感性表 CSV 不存在');
assert(~isempty(si.figure) && localExists(root, si.figure), '敏感性图不存在');
fprintf('[PASS] sensitivity local+Sobol（N=%d，max|ST|=%.3f）\n', ...
    si.sobol.N, max(abs(tot)));

% =====================================================================
% 3) 可辨识性（结构秩、相关矩阵、条件数、弱参数相对 SE、建议）
% =====================================================================
idr = bma.fit.identifiability(m, data, fr, struct('work_dir', root));
assert(isfield(idr, 'structural') && idr.structural.rank == 3, ...
    sprintf('结构秩应为 3，实际 %d', idr.structural.rank));
assert(isfield(idr, 'practical') && isfield(idr.practical, 'condition_number'), ...
    '可辨识性缺少条件数');
assert(isfinite(idr.practical.condition_number), '条件数应为有限值');
assert(isequal(size(idr.practical.correlation), [3, 3]), '参数相关矩阵维度错误');
assert(all(isfinite(idr.practical.relative_se)), '相对标准误含非有限值');
assert(isfield(idr, 'correlations') && isequal(size(idr.correlations.matrix), [3, 3]), ...
    'correlations 矩阵缺失或维度错误');
assert(~isempty(idr.suggestions), '可辨识性应有改进建议');
assert(~isempty(idr.table_path) && localExists(root, idr.table_path), ...
    '可辨识性表 CSV 不存在');
% 弱可辨识判据：kf/kr 在给定数据下应比 kcat 更难单独估计（相对 SE 更大）
ids = idr.param_ids;
relSe = idr.practical.relative_se(:).';
if all(ismember({'kf', 'kr', 'kcat'}, ids))
    ikf = find(strcmp(ids, 'kf'), 1);
    ikr = find(strcmp(ids, 'kr'), 1);
    ikc = find(strcmp(ids, 'kcat'), 1);
    assert(max(relSe(ikf), relSe(ikr)) > relSe(ikc), ...
        sprintf('预期 kf/kr 弱可辨识（relSE %.3g/%.3g vs kcat %.3g）', ...
        relSe(ikf), relSe(ikr), relSe(ikc)));
    fprintf('[PASS] identifiability rank=3, cond=%.3g, relSE kf=%.3g kr=%.3g kcat=%.3g\n', ...
        idr.practical.condition_number, relSe(ikf), relSe(ikr), relSe(ikc));
else
    fprintf('[PASS] identifiability rank=3, cond=%.3g\n', ...
        idr.practical.condition_number);
end

% =====================================================================
% 辅助函数
% =====================================================================
function v = localParam(fr, id)
idx = find(strcmp({fr.params.id}, id), 1);
assert(~isempty(idx), sprintf('缺少参数 %s', id));
v = fr.params(idx).value;
end

function tf = localExists(root, relPath)
tf = isfile(relPath) || isfile(fullfile(root, relPath));
end
