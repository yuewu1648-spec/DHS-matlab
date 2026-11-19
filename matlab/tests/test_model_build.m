% test_model_build.m — bma.model.build 构建 ODE 模型（DESIGN §5.3）
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录');
addpath(fullfile(root, 'matlab'));
examples = {'enzyme_mm', 'goodwin', 'sir'};

for e = 1:numel(examples)
    name = examples{e};
    specPath = fullfile(root, 'spec', 'examples', [name '.json']);
    spec = bma.spec.load(specPath);
    % build 应同时接受 spec 结构体与 spec 路径
    m = bma.model.build(spec);
    m2 = bma.model.build(specPath);
    assert(isequal(m.species, m2.species), 'build 接受路径与结构体结果应一致');
    nS = numel(m.species);
    nR = numel(m.reactions);
    % 字段与契约
    assert(isnumeric(m.S) && size(m.S, 1) == nS && size(m.S, 2) == nR, 'S 矩阵维度错误');
    assert(isa(m.rhs, 'function_handle'), 'm.rhs 必须是函数句柄');
    assert(isa(m.VF, 'function_handle'), 'm.VF 必须是函数句柄');
    assert(iscell(m.vfuns) && numel(m.vfuns) == nR, 'm.vfuns 必须是每反应一个函数句柄');
    assert(isa(m.paramIndex, 'containers.Map'), 'paramIndex 必须是 containers.Map');
    assert(isa(m.speciesIndex, 'containers.Map'), 'speciesIndex 必须是 containers.Map');
    assert(numel(m.initial) == nS && numel(m.paramValues) == m.n_params, 'initial/paramValues 维度错误');
    assert(numel(m.lb) == m.n_params && numel(m.ub) == m.n_params, 'lb/ub 维度错误');
    assert(islogical(m.paramEstimate) && numel(m.paramEstimate) == m.n_params, 'paramEstimate 应为 logical');
    assert(numel(m.outputs) == numel(m.spec.outputs), 'outputs 数量与规格不一致');
    % rhs 与 S*vfuns 自洽
    y0 = m.initial;
    p0 = m.paramValues;
    dydt = m.rhs(0, y0, p0);
    assert(isnumeric(dydt) && numel(dydt) == nS, 'rhs 返回值维度错误');
    assert(all(isfinite(dydt)), 'rhs 在初始点应返回有限值');
    flux = zeros(nR, 1);
    for r = 1:nR
        fr = m.vfuns{r}(y0, p0);
        assert(isscalar(fr) && isfinite(fr), 'vfuns 应返回有限标量');
        flux(r) = fr;
    end
    assert(norm(dydt - m.S * flux) < 1e-12 * max(1, norm(dydt)), ...
        sprintf('%s：rhs 与 S*vfuns 不一致', name));
    % 输出函数：裸物种 id 输出应等于对应状态
    for o = 1:numel(m.outputs)
        val = m.outputs(o).fh(y0, p0);
        assert(isscalar(val) && isfinite(val), 'output fh 应返回有限标量');
        outExpr = m.outputs(o).expression;
        idx = find(strcmp(m.species, outExpr), 1);
        if ~isempty(idx)
            assert(abs(val - y0(idx)) < 1e-12, '裸物种输出应等于对应状态值');
        end
        assert(~isempty(m.outputs(o).unit), '输出应有单位');
    end
    % 参数/物种索引映射
    for i = 1:nS
        assert(m.speciesIndex(m.species{i}) == i, 'speciesIndex 值错误');
    end
    for j = 1:m.n_params
        assert(m.paramIndex(m.params{j}) == j, 'paramIndex 值错误');
    end
    % 中文 name 保留
    if strcmp(name, 'enzyme_mm')
        idxE = find(strcmp(m.species, 'E'), 1);
        assert(strcmp(m.speciesNames{idxE}, '游离酶'), '中文物种名应保留');
        assert(strcmp(m.paramNames{1}, '结合速率常数'), '中文参数名应保留');
        assert(contains(m.ode_rhs_preview, '游离酶'), 'ODE 预览应包含中文名');
        assert(~isempty(m.odeText) && numel(m.odeText) == nS, 'odeText 数量错误');
    end
    % 守恒结构自检：SIR 全网络守恒（1^T S = 0）
    if strcmp(name, 'sir')
        assert(norm(ones(1, nS) * m.S) < 1e-12, 'SIR 的 1^T*S 应为零（种群守恒）');
    end
    if strcmp(name, 'enzyme_mm')
        % E + ES 与 S + ES + P 是守恒量
        idx = @(id) find(strcmp(m.species, id), 1);
        v1 = zeros(1, nS);
        v1([idx('E'), idx('ES')]) = 1;
        assert(norm(v1 * m.S) < 1e-12, 'enzyme_mm 的 E+ES 应守恒');
        v2 = zeros(1, nS);
        v2([idx('S'), idx('ES'), idx('P')]) = 1;
        assert(norm(v2 * m.S) < 1e-12, 'enzyme_mm 的 S+ES+P 应守恒');
    end
    assert(~isempty(jsonencode(m.spec)), 'm.spec 应可 jsonencode');
end

% build 对无效规格应抛出 BMA_SPEC_INVALID，而不是静默成功
bad = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
bad.parameters(1).unit = '';
ok = false;
try
    bma.model.build(bad);
catch err
    ok = strcmp(err.identifier, 'bma:spec:spec_invalid');
    assert(contains(err.message, 'BMA_SPEC') || contains(err.message, '单位'), ...
        '无效规格的错误消息应包含结构化提示');
end
assert(ok, '无效规格必须抛出 BMA_SPEC_INVALID');

% opts.run_dir：写产物（规格/归一化/代码/模型卡）
tmp = fullfile(root, '.bma', 'test_tmp', 'model_build');
if isfolder(tmp)
    rmdir(tmp, 's');
end
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
m = bma.model.build(spec, struct('run_dir', tmp));
assert(isfolder(m.model_dir), 'model_dir 未创建');
assert(isfile(m.spec_path) && isfile(m.normalized_spec_path), 'spec/normalized 未写入');
assert(isfile(m.rhs_function_path), 'rhs_function_path 未写入');
assert(isfile(m.run_function_path), 'run_function_path 未写入');
assert(isfile(m.model_card_path), 'model_card 未写入');
code = bma.util.readText(m.rhs_function_path);
assert(contains(code, 'function') && contains(code, 'dydt'), '生成的 ODE 文件内容异常');
assert(contains(code, 'enzyme_mm_ode'), '生成的函数名应包含模型名');
card = bma.util.readJson(m.model_card_path);
assert(isfield(card, 'parameters') && numel(card.parameters) == m.n_params, 'model_card 参数表错误');
assert(isfield(card, 'species') && numel(card.species) == m.n_species, 'model_card 物种表错误');

fprintf('[test_model_build] 全部通过（3 个示例 + 错误路径 + 产物写入）\n');
