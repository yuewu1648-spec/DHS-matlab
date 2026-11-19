% test_model_codegen.m — bma.codegen.model 生成独立可运行代码 + model_card（DESIGN §4.4）
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录');
addpath(fullfile(root, 'matlab'));
tmp = fullfile(root, '.bma', 'test_tmp', 'model_codegen');
if isfolder(tmp)
    rmdir(tmp, 's');
end
addedPaths = {};

% =====================================================================
% 1. enzyme_mm：生成文件、独立调用、模型卡
% =====================================================================
specPath = fullfile(root, 'spec', 'examples', 'enzyme_mm.json');
spec = bma.spec.load(specPath);
m = bma.model.build(spec);
r = bma.codegen.model(specPath, tmp);
assert(r.ok, 'codegen 应成功');
assert(isfile(r.m_file), sprintf('ODE 文件未生成：%s', r.m_file));
assert(isfile(r.run_file), 'run 文件未生成');
assert(isfile(r.model_card_path), 'model_card 未生成');
assert(contains(r.function_name, 'enzyme_mm'), 'function_name 应包含模型名');
assert(numel(r.parameter_order) == m.n_params, 'parameter_order 长度错误');
assert(numel(r.species_order) == m.n_species, 'species_order 长度错误');
% 生成的 .m 文本：中文注释、函数签名、参数索引说明
codeTxt = bma.util.readText(r.m_file);
assert(contains(codeTxt, ['function dydt = ' r.function_name]), 'ODE 文件函数签名错误');
assert(contains(codeTxt, 'dydt'), 'ODE 文件应含 dydt');
assert(contains(codeTxt, '参数向量索引'), 'ODE 文件应含参数索引说明');
assert(contains(codeTxt, '状态变量索引'), 'ODE 文件应含状态变量索引说明');
assert(contains(codeTxt, '游离酶'), 'ODE 文件应保留中文名称');
runTxt = bma.util.readText(r.run_file);
assert(contains(runTxt, ['function [t, Y, out] = ' r.run_function_name]), 'run 文件函数签名错误');
% model_card 内容
card = bma.util.readJson(r.model_card_path);
assert(isfield(card, 'name') && strcmp(card.name, 'enzyme_mm'), 'model_card.name 错误');
assert(numel(card.parameters) == m.n_params, 'model_card 参数数量错误');
assert(numel(card.species) == m.n_species, 'model_card 物种数量错误');
assert(numel(card.equations) == m.n_species, 'model_card 方程数量错误');
assert(~isempty(card.assumptions), 'model_card 应包含假设');
% 独立运行：addpath 后直接调用生成的 ODE 函数
addpath(r.code_dir);
addedPaths{end+1} = r.code_dir;
odeFh = str2func(r.function_name);
dGen = odeFh(0, m.initial, m.paramValues);
dRef = m.rhs(0, m.initial, m.paramValues);
assert(max(abs(dGen - dRef)) < 1e-12 * max(1, max(abs(dRef))), '生成 ODE 与 bma.rhs 不一致');
% 独立运行包装函数：与 bma.model.simulate 一致（enzyme 全程稳定，可逐点比较）
runFh = str2func(r.run_function_name);
[tG, YG, outG] = runFh(m.paramValues, [m.time.start, m.time.end], m.initial, struct());
res = bma.model.simulate(m);
assert(max(abs(tG(:) - res.t(:))) < 1e-12, '生成 run 的时间网格与 simulate 不一致');
scale = max(1, max(abs(res.Y(:))));
assert(max(abs(YG(:) - res.Y(:))) / scale < 1e-5, '生成 run 的状态轨迹与 simulate 不一致');
for o = 1:numel(m.outputs)
    oid = m.outputs(o).id;
    assert(isfield(outG, oid), sprintf('生成 run 缺少输出 %s', oid));
    finalG = outG.(oid)(end);
    finalRef = res.outputSummary.(oid).final;
    assert(abs(finalG - finalRef) < 1e-5 * max(1, abs(finalRef)), ...
        sprintf('生成 run 的输出 %s 与 simulate 不一致', oid));
end

% =====================================================================
% 2. goodwin：生成代码可运行（短线比较，避免极限环相位漂移）
% =====================================================================
rG = bma.codegen.model(fullfile(root, 'spec', 'examples', 'goodwin.json'), tmp);
assert(rG.ok && isfile(rG.m_file), 'goodwin codegen 失败');
addpath(rG.code_dir);
addedPaths{end+1} = rG.code_dir;
mG = bma.model.build(fullfile(root, 'spec', 'examples', 'goodwin.json'));
odeG = str2func(rG.function_name);
dGen = odeG(0, mG.initial, mG.paramValues);
dRef = mG.rhs(0, mG.initial, mG.paramValues);
assert(max(abs(dGen - dRef)) < 1e-12 * max(1, max(abs(dRef))), 'goodwin 生成 ODE 与 m.rhs 不一致');
runG = str2func(rG.run_function_name);
[tShort, YShort] = runG(mG.paramValues, [0, 30], mG.initial, struct());
resG = bma.model.simulate(mG, struct('time_end', 30));
scale = max(1, max(abs(resG.Y(:))));
assert(max(abs(YShort(:) - resG.Y(:))) / scale < 1e-4, 'goodwin 生成 run 与 simulate 短期不一致');

% =====================================================================
% 3. 三种示例都能生成；模型卡可复用
% =====================================================================
card = bma.codegen.modelCard(bma.model.build(specPath));
assert(isstruct(card) && strcmp(card.name, 'enzyme_mm'), 'bma.codegen.modelCard 返回错误');
assert(~isempty(jsonencode(card)), 'model_card 必须可 jsonencode');
% 默认 runDir：不传 runDir 也应生成到 .bma/codegen/<name>
rDefault = bma.codegen.model(specPath);
assert(rDefault.ok && isfile(rDefault.m_file), '缺省 runDir 的 codegen 应成功');

% =====================================================================
% 4. 无效规格应抛 BMA_SPEC_INVALID
% =====================================================================
bad = spec;
bad.parameters(1).unit = '';
threw = false;
try
    bma.codegen.model(bad, tmp);
catch err
    threw = strcmp(err.identifier, 'bma:spec:spec_invalid');
end
assert(threw, '无效规格 codegen 应抛 BMA_SPEC_INVALID');

% 清理 path
for k = 1:numel(addedPaths)
    rmpath(addedPaths{k});
end
fprintf('[test_model_codegen] 全部通过（可独立运行代码 + model_card）\n');
