% test_model_simulate.m — bma.model.simulate 数值仿真（DESIGN §5.3 / §4.4）
% 断言用 spec/examples/data 的合成数据与物理不变量，不硬编码仿真结果。
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录');
addpath(fullfile(root, 'matlab'));
dataDir = fullfile(root, 'spec', 'examples', 'data');
tmp = fullfile(root, '.bma', 'test_tmp', 'model_simulate');
if isfolder(tmp)
    rmdir(tmp, 's');
end

% =====================================================================
% 1. 三个示例：默认仿真成功，输出结构正确
% =====================================================================
examples = {'enzyme_mm', 'goodwin', 'sir'};
sims = struct();
for e = 1:numel(examples)
    name = examples{e};
    spec = bma.spec.load(fullfile(root, 'spec', 'examples', [name '.json']));
    m = bma.model.build(spec);
    res = bma.model.simulate(m);
    sims.(name) = res;
    assert(res.success, sprintf('%s 仿真应成功，warnings=%s', name, ...
        strjoin(res.warnings, ' | ')));
    assert(numel(res.t) == spec.time.n, sprintf('%s 输出点数应等于 spec.time.n', name));
    assert(abs(res.t(1) - spec.time.start) < 1e-12 && ...
        abs(res.t(end) - spec.time.end) < 1e-12, '时间轴范围错误');
    assert(size(res.Y, 1) == numel(res.t) && size(res.Y, 2) == m.n_species, 'Y 维度错误');
    assert(all(isfinite(res.Y(:))), '仿真结果不应含 NaN/Inf');
    assert(numel(res.outputs) == m.n_outputs, 'outputs 数量错误');
    for o = 1:numel(res.outputs)
        oid = res.outputs(o).id;
        assert(isfield(res.outputSummary, oid), sprintf('outputSummary 缺少 %s', oid));
        assert(isfinite(res.outputs(o).final), '输出终值应有限');
        assert(isfield(res.outputs(o), 'name') && isfield(res.outputs(o), 'unit'), ...
            'outputs 条目应含 name/unit');
    end
    assert(iscell(res.warnings) && all(cellfun(@ischar, res.warnings)), ...
        'res.warnings 应为 cellstr');
    % 初值一致性
    assert(norm(res.Y(1, :).' - m.initial) < 1e-10, '仿真起点应等于初值');
    % 输出终值应等于用 Y 末行直接计算的值（自洽性）
    for o = 1:numel(res.outputs)
        expect = m.outputs(o).fh(res.Y(end, :).', m.paramValues);
        assert(abs(res.outputs(o).final - expect) < 1e-10 * max(1, abs(expect)), ...
            '输出终值与状态不自洽');
    end
end

% =====================================================================
% 2. enzyme_mm：与合成数据对比（CSV 为同模型 + 1% 噪声）
% =====================================================================
csvE = readtable(fullfile(dataDir, 'enzyme_progress.csv'), 'VariableNamingRule', 'preserve');
tE = csvE.time;
Pobs = csvE.P_obs;
Sobs = csvE.S_obs;
resE = sims.enzyme_mm;
mE = bma.model.build(bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json')));
idxP = find(strcmp(mE.species, 'P'), 1);
idxS = find(strcmp(mE.species, 'S'), 1);
idxE = find(strcmp(mE.species, 'E'), 1);
idxES = find(strcmp(mE.species, 'ES'), 1);
% 末点相对误差 < 10%（数据带 1% 噪声 + 采样）
assert(abs(resE.Y(end, idxP) - Pobs(end)) / max(1, Pobs(end)) < 0.10, ...
    '产物终值与合成数据偏差过大');
assert(abs(resE.Y(end, idxS) - Sobs(end)) / max(0.1, Sobs(end)) < 0.30, ...
    '底物终值与合成数据偏差过大');
% 物理不变量：E + ES 守恒、S + ES + P 守恒
tEsim = resE.t;
keep1 = abs((resE.Y(:, idxE) + resE.Y(:, idxES)) - (mE.initial(idxE) + mE.initial(idxES)));
assert(max(keep1) < 1e-5, 'E+ES 守恒误差过大');
keep2 = abs((resE.Y(:, idxS) + resE.Y(:, idxES) + resE.Y(:, idxP)) - ...
    (mE.initial(idxS) + mE.initial(idxES) + mE.initial(idxP)));
assert(max(keep2) < 1e-5, 'S+ES+P 守恒误差过大');
% 趋势：S 单调下降（近似）、P 单调上升（近似）
assert(resE.Y(end, idxS) < resE.Y(1, idxS), '底物应下降');
assert(resE.Y(end, idxP) > resE.Y(1, idxP), '产物应上升');

% =====================================================================
% 3. sir：种群守恒、感染者终值 → 0、数据峰值接近
% =====================================================================
resS = sims.sir;
mS = bma.model.build(bma.spec.load(fullfile(root, 'spec', 'examples', 'sir.json')));
N = mS.paramValues(mS.paramIndex('N'));
total = sum(resS.Y, 2);
assert(max(abs(total - N)) / N < 1e-6, sprintf('SIR 总人口应守恒（最大偏差 %g）', ...
    max(abs(total - N))));
idxI = find(strcmp(mS.species, 'I'), 1);
idxR = find(strcmp(mS.species, 'R'), 1);
assert(resS.Y(end, idxI) < 1e-3 * N, '疫情终末感染者应趋近 0');
assert(all(diff(resS.Y(:, idxR)) > -1e-9), '累计移除人数应单调不减');
csvS = readtable(fullfile(dataDir, 'sir_observations.csv'), 'VariableNamingRule', 'preserve');
Iobs = csvS.I_obs;
assert(abs(max(resS.Y(:, idxI)) - max(Iobs)) / max(Iobs) < 0.15, '感染峰值与合成数据偏差过大');
% 与合成数据同时间网格上的 NRMSE（I_obs）
simI = interp1(resS.t, resS.Y(:, idxI), csvS.time, 'linear', 'extrap');
nrmseI = sqrt(mean((simI - Iobs).^2)) / (max(Iobs) - min(Iobs));
assert(nrmseI < 0.15, sprintf('SIR I_obs 的 NRMSE 过大：%.3f', nrmseI));

% =====================================================================
% 4. goodwin：振荡（峰谷比）与合成数据 NRMSE
% =====================================================================
resG = sims.goodwin;
mG = bma.model.build(bma.spec.load(fullfile(root, 'spec', 'examples', 'goodwin.json')));
idxM = find(strcmp(mG.species, 'm'), 1);
mTrace = resG.Y(:, idxM);
assert(max(mTrace) / max(min(abs(mTrace)), 1e-12) > 10, 'goodwin 应出现明显振荡（峰谷比 >10）');
csvG = readtable(fullfile(dataDir, 'goodwin_timeseries.csv'), 'VariableNamingRule', 'preserve');
simM = interp1(resG.t, mTrace, csvG.time, 'linear', 'extrap');
nrmseM = sqrt(mean((simM - csvG.m_obs).^2)) / (max(csvG.m_obs) - min(csvG.m_obs));
assert(nrmseM < 0.15, sprintf('goodwin mRNA 的 NRMSE 过大：%.3f', nrmseM));

% =====================================================================
% 5. 求解器选项：ode45/ode15s 一致；rtol 生效
% =====================================================================
specE = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
mE = bma.model.build(specE);
r15 = bma.model.simulate(mE, struct('solver', 'ode15s', 'n', 301));
r45 = bma.model.simulate(mE, struct('solver', 'ode45', 'n', 301));
assert(r15.success && r45.success, 'ode15s/ode45 都应成功');
assert(strcmp(r15.solver, 'ode15s') && strcmp(r45.solver, 'ode45'), 'solver 字段应反映实际求解器');
scaleE = max(1, max(abs(r15.Y(:))));
assert(max(abs(r15.Y(:) - r45.Y(:))) / scaleE < 1e-4, 'ode15s 与 ode45 结果应一致');
assert(numel(r15.t) == 301, 'n 选项应生效');

% =====================================================================
% 6. 覆盖初值/参数；未知 id 给出警告
% =====================================================================
resO = bma.model.simulate(mE, struct('initial_overrides', struct('S', 20), ...
    'param_overrides', struct('kcat', 0), 'n', 301));
assert(abs(resO.Y(1, 2) - 20) < 1e-12, 'initial_overrides 应生效（S=20）');
idxP = find(strcmp(mE.species, 'P'), 1);
assert(max(resO.Y(:, idxP)) < 1e-6, 'kcat=0 时不应生成产物');
resW = bma.model.simulate(mE, struct('initial_overrides', struct('no_such', 1), ...
    'param_overrides', struct('also_missing', 2), 'n', 11));
assert(any(contains(resW.warnings, 'no_such')), '未知初值 id 应给出警告');
assert(any(contains(resW.warnings, 'also_missing')), '未知参数 id 应给出警告');
% 负浓度警告（把 P 初值设为负）
resNeg = bma.model.simulate(mE, struct('initial_overrides', struct('P', -1), 'n', 11));
assert(any(contains(resNeg.warnings, '负')), '负浓度应给出警告');

% =====================================================================
% 7. 写时间序列 CSV
% =====================================================================
resCsv = bma.model.simulate(mE, struct('run_dir', tmp, 'write_csv', true, 'n', 51));
assert(isfield(resCsv, 'timeseries_path') && isfile(resCsv.timeseries_path), '应写出时间序列 CSV');
txt = bma.util.readText(resCsv.timeseries_path);
lines = splitlines(txt);
assert(numel(lines) >= 52, 'CSV 行数不足');
assert(contains(lines{1}, 'time'), 'CSV 表头应含 time');
assert(contains(lines{1}, 'P_obs'), 'CSV 表头应含输出列');
vals = str2double(strsplit(lines{2}, ','));
assert(all(isfinite(vals)), 'CSV 首行数据应可解析');
% 显式 timeseries_path（相对 run_dir）
resCsv2 = bma.model.simulate(mE, struct('run_dir', tmp, ...
    'timeseries_path', 'custom/out.csv', 'n', 11));
assert(isfile(fullfile(tmp, 'custom', 'out.csv')), '显式 timeseries_path 应生效');

% =====================================================================
% 8. 失败不抛异常：极端参数导致数值失败
% =====================================================================
resBad = bma.model.simulate(mE, struct('param_overrides', struct('kf', 1e300), ...
    'initial_overrides', struct('E', 1e300, 'S', 1e300), 'n', 11));
assert(~resBad.success, '发散参数应返回 success=false');
assert(~isempty(resBad.warnings), '失败时应给出警告说明');
assert(isfield(resBad, 't') && isfield(resBad, 'Y'), '失败时仍应返回结构完整的结果');

fprintf('[test_model_simulate] 全部通过（3 个示例 + 覆盖/CSV/求解器/失败路径）\n');
