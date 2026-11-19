% test_model_analyze.m — bma.model.analyze 守恒律/稳态/稳定性/量纲（DESIGN §5.3）
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录');
addpath(fullfile(root, 'matlab'));

% =====================================================================
% 1. enzyme_mm：2 条守恒律（E+ES、S+ES+P），量纲通过，JSON 安全
% =====================================================================
specE = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
mE = bma.model.build(specE);
aE = bma.model.analyze(mE);
assert(aE.dimensional_ok, 'enzyme_mm 量纲检查应通过');
assert(aE.n_conservation_laws >= 2, sprintf('enzyme_mm 应至少 2 个守恒律，实际 %d', ...
    aE.n_conservation_laws));
assert(iscellstr(aE.conservation_laws) && numel(aE.conservation_laws) == aE.n_conservation_laws, ...
    'conservation_laws 应为 cellstr（每条守恒律一个人类可读表达式）');
assert(iscell(aE.conservation_law_details) && ...
    numel(aE.conservation_law_details) == aE.n_conservation_laws, ...
    'conservation_law_details 结构错误');
for k = 1:numel(aE.conservation_laws)
    assert(ischar(aE.conservation_laws{k}) && ~isempty(aE.conservation_laws{k}), ...
        'conservation_laws 元素应为非空字符串');
end
assert(size(aE.conservation_basis, 1) == mE.n_species, 'conservation_basis 维度错误');
y0E = mE.initial;
foundE = false;
foundSub = false;
for k = 1:numel(aE.conservation_law_details)
    law = aE.conservation_law_details{k};
    assert(isfield(law, 'relation') && ~isempty(law.relation), '守恒律应有 relation 表达式');
    assert(isfield(law, 'coefficients') && isstruct(law.coefficients), '守恒律应有系数');
    assert(law.verified, sprintf('守恒律 %d 未通过 Z''*S=0 验证', k));
    assert(abs(law.constant - (law.basis(:).' * y0E)) < 1e-9, '守恒律常数应与初值一致');
    if isfield(law.coefficients, 'E') && isfield(law.coefficients, 'ES')
        foundE = true;
        assert(abs(law.constant - 1) < 1e-6, 'E+ES 的守恒常数应为 1');
    end
    if isfield(law.coefficients, 'S') && isfield(law.coefficients, 'P') && ...
            isfield(law.coefficients, 'ES')
        foundSub = true;
        assert(abs(law.constant - 10) < 1e-6, 'S+ES+P 的守恒常数应为 10');
    end
end
assert(foundE, '应检测到 E + ES 守恒律');
assert(foundSub, '应检测到 S + ES + P 守恒律');
% 守恒律应"好看"：字符串里不应出现双负号或浮点近似系数
for k = 1:numel(aE.conservation_laws)
    s = aE.conservation_laws{k};
    assert(isempty(regexp(s, '- -', 'once')), sprintf('守恒律表达式出现双负号：%s', s));
    assert(isempty(regexp(s, '\d\.\d{3,}', 'once')), sprintf('守恒律表达式出现浮点系数：%s', s));
end
% 物理稳态筛选：enzyme_mm 唯一物理稳态 [E,ES,S,P] = [1,0,0,10]
assert(aE.steady_state_count == 1, sprintf('enzyme_mm 物理稳态应唯一，实际 %d', aE.steady_state_count));
assert(aE.steady_state_total_found >= aE.steady_state_count, 'total_found 应 >= 物理稳态数');
assert(all(aE.steady_states{1}.y >= 0), '物理稳态不应含负值');
idxE = find(strcmp(mE.species, 'E'), 1);
idxES = find(strcmp(mE.species, 'ES'), 1);
idxP = find(strcmp(mE.species, 'P'), 1);
ssE = aE.steady_states{1}.y;
assert(abs(ssE(idxE) - 1) < 1e-5, 'E 的稳态值应为 1（酶守恒）');
assert(abs(ssE(idxES)) < 1e-6, 'ES 的稳态值应为 0');
assert(abs(ssE(idxP) - 10) < 1e-5, 'P 的稳态值应为 10（底物守恒）');
assert(aE.steady_states{1}.residual <= 1e-6, '稳态残差过大');
assert(numel(aE.steady_states) == aE.steady_state_count, 'steady_states 计数不一致');
assert(size(aE.jacobian, 1) == mE.n_species, 'jacobian 维度错误');
assert(~isempty(aE.notes) && all(cellfun(@ischar, aE.notes)), 'notes 应为 cellstr');
assert(~isempty(jsonencode(aE)), 'analysis 必须可 jsonencode');

% =====================================================================
% 2. sir：种群守恒律（系数全 1）+ 稳态
% =====================================================================
specS = bma.spec.load(fullfile(root, 'spec', 'examples', 'sir.json'));
mS = bma.model.build(specS);
aS = bma.model.analyze(mS);
assert(aS.dimensional_ok, 'sir 量纲检查应通过');
assert(aS.n_conservation_laws >= 1, 'sir 应至少 1 个守恒律');
foundTotal = false;
N = mS.paramValues(mS.paramIndex('N'));
for k = 1:numel(aS.conservation_law_details)
    law = aS.conservation_law_details{k};
    if ~isequal(sort(fieldnames(law.coefficients)), sort(mS.species(:)))
        continue
    end
    c = law.basis(:);
    if all(abs(c - 1) < 1e-9)
        foundTotal = true;
        assert(abs(law.constant - N) < 1e-6, sprintf('S+I+R 守恒常数应为 %g', N));
    end
end
assert(foundTotal, '应检测到 S+I+R 守恒律（系数全 1）');
% steady states 中至少有一个非负实解（SIR 的 I=0 族）
assert(numel(aS.steady_states) >= 1, 'sir 应至少找到一个非负稳态');
for k = 1:numel(aS.steady_states)
    ss = aS.steady_states{k};
    assert(all(ss.y >= -1e-8), '稳态不应包含负值');
    assert(ss.residual <= 1e-6, sprintf('稳态残差过大：%g', ss.residual));
    assert(any(strcmp(ss.stability, {'stable', 'unstable', 'marginal'})), '稳定性字段非法');
end
assert(~isempty(jsonencode(aS)), 'sir analysis 必须可 jsonencode');

% =====================================================================
% 3. goodwin：非线性振荡器，稳态应不稳定（h=12 > 8 的经典结论）
% =====================================================================
specG = bma.spec.load(fullfile(root, 'spec', 'examples', 'goodwin.json'));
mG = bma.model.build(specG);
aG = bma.model.analyze(mG);
assert(aG.n_conservation_laws == 0, 'goodwin 不应有线性守恒律');
assert(aG.dimensional_ok, 'goodwin 量纲检查应通过');
assert(numel(aG.steady_states) >= 1, 'goodwin 应找到非负稳态');
unstable = false;
for k = 1:numel(aG.steady_states)
    ss = aG.steady_states{k};
    assert(all(ss.y >= -1e-8), 'goodwin 稳态不应含负值');
    assert(ss.residual <= 1e-6, sprintf('goodwin 稳态残差过大：%g', ss.residual));
    assert(numel(ss.eigenvalues_re) == numel(ss.eigenvalues_im), '特征值实部/虚部长度不一致');
    assert(isfinite(ss.max_real_eig), '最大特征值实部应有限');
    if strcmp(ss.stability, 'unstable') || ss.max_real_eig > 1e-8
        unstable = true;
    end
end
assert(unstable, 'goodwin (h=12) 的非负稳态应不稳定（正实部特征值）');
assert(~isempty(jsonencode(aG)), 'goodwin analysis 必须可 jsonencode');

% =====================================================================
% 4. analyze 接受 spec；opts.run_dir 写 analysis.json
% =====================================================================
aFromSpec = bma.model.analyze(specE);
assert(aFromSpec.n_conservation_laws == aE.n_conservation_laws, 'analyze(spec) 与 analyze(m) 结果应一致');
tmp = fullfile(root, '.bma', 'test_tmp', 'model_analyze');
if isfolder(tmp)
    rmdir(tmp, 's');
end
aOut = bma.model.analyze(mE, struct('run_dir', tmp));
assert(isfield(aOut, 'analysis_path') && isfile(aOut.analysis_path), '应写出 analysis.json');
loaded = bma.util.readJson(aOut.analysis_path);
assert(isfield(loaded, 'conservation_laws') && iscellstr(loaded.conservation_laws), ...
    'analysis.json 中 conservation_laws 应为字符串数组');
assert(isfield(loaded, 'steady_states'), 'analysis.json 缺少 steady_states');
assert(isfield(loaded, 'dimensional_ok'), 'analysis.json 缺少 dimensional_ok');

% =====================================================================
% 5. 线性模型稳态的符号解（简单 1 物种线性模型）
% =====================================================================
linSpec = struct();
linSpec.schema_version = 'bma.modelSpec.v1';
linSpec.name = 'linear_decay';
linSpec.kind = 'ode';
linSpec.time = struct('unit', 's', 'start', 0, 'end', 10, 'n', 11);
linSpec.variables = struct('id', 'X', 'name', '变量', 'unit', 'uM', 'initial', struct('value', 1));
linSpec.parameters = struct('id', 'k', 'name', '速率', 'unit', '1/s', ...
    'value', struct('value', 2), 'estimate', false);
linSpec.reactions = struct('id', 'decay', 'name', '降解', 'stoichiometry', struct('X', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('X', 1)));
linSpec.assumptions = {'线性降解'};
aLin = bma.model.analyze(bma.model.build(linSpec));
assert(numel(aLin.steady_states) >= 1, '线性模型应找到稳态 X=0');
ss0 = aLin.steady_states{1};
assert(abs(ss0.values.X) < 1e-8, '线性降解稳态应为 X=0');
assert(strcmp(ss0.stability, 'stable'), '线性降解稳态应稳定');

fprintf('[test_model_analyze] 全部通过（守恒律/稳态/稳定性/量纲/JSON 安全）\n');
