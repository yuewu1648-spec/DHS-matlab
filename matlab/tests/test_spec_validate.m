% test_spec_validate.m — 校验 bma.spec.validate / normalize / load / save（DESIGN §3 §5.2）
% 独立脚本：失败即抛错。使用 projectRoot 定位文件，不依赖 pwd。
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录（spec/examples）');
addpath(fullfile(root, 'matlab'));
examples = {'enzyme_mm', 'goodwin', 'sir'};
tmpRoot = fullfile(root, '.bma', 'test_tmp', 'spec_validate');
if isfolder(tmpRoot)
    rmdir(tmpRoot, 's');
end
bma.util.ensureDir(tmpRoot);

% =====================================================================
% 1. 三个示例规格：valid、无错误、normalized 可 JSON 回写、roundtrip 再校验
% =====================================================================
for e = 1:numel(examples)
    name = examples{e};
    spec = bma.spec.load(fullfile(root, 'spec', 'examples', [name '.json']));
    report = bma.spec.validate(spec);
    assert(report.valid, sprintf('%s 应通过校验，错误：%s', name, errorSummary(report)));
    assert(isempty(report.errors), sprintf('%s 不应有错误', name));
    assert(iscell(report.errors) && iscell(report.warnings), 'errors/warnings 必须是 cell');
    % normalized 规格字段完整、可 JSON 序列化
    norm = report.normalized_spec;
    assert(isstruct(norm) && numel(norm) == 1, 'normalized_spec 必须是单个结构体');
    assert(numel(norm.compartments) >= 1, 'normalized 应至少有默认隔室');
    assert(numel(norm.outputs) >= 1, 'normalized 应至少有一个输出（显式 outputs 或由 variables 生成）');
    if ~isfield(spec, 'outputs') || isempty(spec.outputs)
        assert(numel(norm.outputs) == numel(norm.variables), ...
            'outputs 缺省时应等于 variables');
    end
    assert(~isempty(jsonencode(norm)), 'normalized_spec 必须可 jsonencode');
    % 估计参数应有 bounds 且初值落在范围内
    pars = norm.parameters;
    if iscell(pars)
        for k = 1:numel(pars)
            assertEstimatedBounds(pars{k});
        end
    else
        for k = 1:numel(pars)
            assertEstimatedBounds(pars(k));
        end
    end
    % summary 计数与规格一致
    s = report.summary;
    assert(s.n_species == numel(norm.variables), 'summary.n_species 不一致');
    assert(s.n_reactions == numel(norm.reactions), 'summary.n_reactions 不一致');
    assert(s.n_parameters == numel(norm.parameters), 'summary.n_parameters 不一致');
    assert(~isempty(s.rate_kinds), 'summary.rate_kinds 不应为空');
    assert(strcmp(s.name, name), 'summary.name 不一致');
    % units_check / conservation 结构存在
    assert(isfield(report, 'units_check') && report.units_check.ok, ...
        sprintf('%s 单位应可解析', name));
    assert(isfield(report, 'conservation') && report.conservation.n_laws >= 0, ...
        'conservation 字段缺失');
    % 保存 → 重新读取 → 再次校验必须 valid（normalized 可保存回 JSON）
    outPath = fullfile(tmpRoot, [name '_normalized.json']);
    saved = bma.spec.save(norm, outPath);
    assert(isfile(outPath), 'bma.spec.save 未生成文件');
    assert(isstruct(saved), 'bma.spec.save 应返回规格结构体');
    reloaded = bma.spec.load(outPath);
    report2 = bma.spec.validate(reloaded);
    assert(report2.valid, sprintf('%s normalized 回写后应仍合法：%s', name, errorSummary(report2)));
    % validate 接受 spec 路径
    report3 = bma.spec.validate(fullfile(root, 'spec', 'examples', [name '.json']));
    assert(report3.valid, 'validate 应接受 spec 文件路径');
end

% 示例的守恒律计数符合模型结构（enzyme 2 个、sir 1 个、goodwin 0 个）
specEnz = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
rEnz = bma.spec.validate(specEnz);
assert(rEnz.conservation.n_laws >= 2, 'enzyme_mm 应至少有 2 个守恒律');
specSir = bma.spec.load(fullfile(root, 'spec', 'examples', 'sir.json'));
rSir = bma.spec.validate(specSir);
assert(rSir.conservation.n_laws >= 1, 'sir 应至少有 1 个守恒律');
specGd = bma.spec.load(fullfile(root, 'spec', 'examples', 'goodwin.json'));
rGd = bma.spec.validate(specGd);
assert(rGd.conservation.n_laws == 0, 'goodwin 不应有线性守恒律');

% =====================================================================
% 2. 最小规格：normalize 补默认字段并给出警告（初值/默认 bounds/输出）
% =====================================================================
minSpec = struct();
minSpec.schema_version = 'bma.modelSpec.v1';
minSpec.name = 'mini_decay';
minSpec.kind = 'ode';
minSpec.time = struct('unit', 's', 'start', 0, 'end', 10, 'n', 11);
minSpec.variables = struct('id', 'X', 'name', '底物', 'unit', 'uM');
minSpec.parameters = struct('id', 'k', 'name', '降解速率', 'unit', '1/s', ...
    'value', struct('value', 1), 'estimate', true);
minSpec.reactions = struct('id', 'decay', 'name', '降解', ...
    'stoichiometry', struct('X', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('X', 1)));
minSpec.assumptions = {'充分混合'};
rMin = bma.spec.validate(minSpec);
assert(rMin.valid, sprintf('最小规格应合法（仅警告）：%s', errorSummary(rMin)));
mn = rMin.normalized_spec;
assert(numel(mn.compartments) == 1, '应补默认单室');
assert(strcmp(mn.variables(1).compartment, mn.compartments(1).id), '变量应指向默认隔室');
assert(mn.variables(1).initial.value == 0, '缺少 initial 时应补 0');
assert(numel(mn.outputs) == 1 && strcmp(mn.outputs(1).expression, 'X'), 'outputs 缺省应等于 variables');
assert(numel(mn.parameters(1).bounds) == 2, '估计参数缺少 bounds 时应给默认范围');
assert(hasWarningCode(rMin, 'BMA_SPEC_WARN_NO_INITIAL'), '应警告缺少 initial');
assert(hasWarningCode(rMin, 'BMA_SPEC_WARN_NO_BOUNDS'), '应警告缺少 bounds');
assert(hasWarningCode(rMin, 'BMA_SPEC_WARN_NO_OUTPUTS'), '应警告缺少 outputs');
mn2 = bma.spec.normalize(mn);
assert(isequal(jsonencode(mn), jsonencode(mn2)), 'normalize 应幂等（JSON 表示一致）');

% =====================================================================
% 3. 错误用例：未知速率参数 / 缺单位 / 错 stoichiometry / 坏表达式 /
%    Hill 模式非法 / bounds 非法 / 未知 schema_version / 重复 id
% =====================================================================
% 3.1 未知速率参数
bad = setRateParam(specEnz, 1, 'k', 'no_such_param');
rb = bma.spec.validate(bad);
assert(~rb.valid, '未知速率参数应校验失败');
[ok, item] = findCode(rb.errors, 'BMA_SPEC_UNKNOWN_ID');
assert(ok, '未知速率参数应返回 BMA_SPEC_UNKNOWN_ID');
assert(contains(item.path, 'reactions[0]'), sprintf('错误 path 应指向 reactions[0]，实际：%s', item.path));

% 3.2 缺单位
bad = setVariableField(specEnz, 2, 'unit', '');
rb = bma.spec.validate(bad);
assert(~rb.valid, '缺单位应校验失败');
[ok, item] = findCode(rb.errors, 'BMA_SPEC_MISSING_FIELD');
assert(ok, '缺单位应返回 BMA_SPEC_MISSING_FIELD');
assert(contains(item.path, 'variables[1].unit'), sprintf('缺单位 path 应指向 variables[1].unit，实际：%s', item.path));
assert(contains(item.hint, '单位'), '缺单位 hint 应提示补单位');

% 3.3 错 stoichiometry（引用不存在的物种）
bad = specEnz;
if iscell(bad.reactions)
    e = bad.reactions{1};
    e.stoichiometry.no_such_species = 1;
    bad.reactions{1} = e;
else
    bad.reactions(1).stoichiometry.no_such_species = 1;
end
rb = bma.spec.validate(bad);
assert(~rb.valid, '错 stoichiometry 应校验失败');
[ok, item] = findCode(rb.errors, 'BMA_SPEC_UNKNOWN_ID');
assert(ok, '错 stoichiometry 应返回 BMA_SPEC_UNKNOWN_ID');
assert(contains(item.path, 'stoichiometry'), 'stoichiometry 错误 path 应指向 stoichiometry');

% 3.4 坏表达式（括号不配对）
specSir = bma.spec.load(fullfile(root, 'spec', 'examples', 'sir.json'));
bad = setRateField(specSir, 1, 'expression', 'beta*S*I/N + )');
rb = bma.spec.validate(bad);
assert(~rb.valid, '坏表达式应校验失败');
[ok, item] = findCode(rb.errors, 'BMA_RATE_INVALID');
assert(ok, '坏表达式应返回 BMA_RATE_INVALID');
assert(contains(item.path, 'expression'), '表达式错误 path 应指向 expression');

% 3.5 Hill 模式非法
specGd = bma.spec.load(fullfile(root, 'spec', 'examples', 'goodwin.json'));
bad = setRateField(specGd, 1, 'mode', 'sideways');
rb = bma.spec.validate(bad);
assert(~rb.valid, 'Hill 模式非法应校验失败');
[ok, item] = findCode(rb.errors, 'BMA_RATE_INVALID');
assert(ok, 'Hill 模式非法应返回 BMA_RATE_INVALID');
assert(contains(item.message, 'Hill') || contains(item.message, 'mode'), 'Hill 模式错误消息应说明 mode');

% 3.6 bounds 非法（下界 >= 上界）
bad = setParamBounds(specEnz, 1, [10, 1]);
rb = bma.spec.validate(bad);
assert(~rb.valid, 'bounds 非法应校验失败');
[ok, ~] = findCode(rb.errors, 'BMA_BOUNDS_INVALID');
assert(ok, 'bounds 非法应返回 BMA_BOUNDS_INVALID');

% 3.7 初值超出 bounds
bad = setParamBounds(specEnz, 1, [1, 2]);   % kf 初值 0.5 不在 [1,2]
rb = bma.spec.validate(bad);
assert(~rb.valid, '初值超出 bounds 应校验失败');
[ok, ~] = findCode(rb.errors, 'BMA_BOUNDS_INVALID');
assert(ok, '初值超出 bounds 应返回 BMA_BOUNDS_INVALID');

% 3.8 未知 schema_version
bad = specEnz;
bad.schema_version = 'bma.modelSpec.v99';
rb = bma.spec.validate(bad);
assert(~rb.valid, '未知 schema_version 应校验失败');
[ok, ~] = findCode(rb.errors, 'BMA_SPEC_INVALID');
assert(ok, '未知 schema_version 应返回 BMA_SPEC_INVALID');

% 3.9 重复 id
bad = specEnz;
if isstruct(bad.variables)
    bad.variables(1).id = 'S';   % 与 variables(2).id 冲突
else
    e = bad.variables{1}; e.id = 'S'; bad.variables{1} = e;
end
rb = bma.spec.validate(bad);
assert(~rb.valid, '重复 id 应校验失败');
[ok, ~] = findCode(rb.errors, 'BMA_SPEC_DUPLICATE_ID');
assert(ok, '重复 id 应返回 BMA_SPEC_DUPLICATE_ID');

% 3.10 缺少顶层必填字段
bad = rmfield(specEnz, 'reactions');
rb = bma.spec.validate(bad);
assert(~rb.valid, '缺 reactions 应校验失败');
[ok, ~] = findCode(rb.errors, 'BMA_SPEC_MISSING_FIELD');
assert(ok, '缺 reactions 应返回 BMA_SPEC_MISSING_FIELD');

% 3.11 非法路径
rb = bma.spec.validate(fullfile(root, 'no_such_spec.json'));
assert(~rb.valid, '不存在的 spec 路径应返回 invalid 而非抛错');
[ok, ~] = findCode(rb.errors, 'BMA_SPEC_INVALID');
assert(ok, '不存在的 spec 路径应返回 BMA_SPEC_INVALID');

% 3.12 所有错误项结构完整、report 可 JSON 编码
rb = bma.spec.validate(setRateParam(specEnz, 1, 'k', 'nope'));
assert(~isempty(rb.errors));
for k = 1:numel(rb.errors)
    e = rb.errors{k};
    assert(all(isfield(e, {'code', 'path', 'message', 'hint'})), '错误项必须包含 code/path/message/hint');
    assert(~isempty(e.code) && ~isempty(e.message) && ~isempty(e.hint), '错误项字段不应为空');
end
assert(~isempty(jsonencode(rb)), 'validate report 必须可 jsonencode');
assert(~isempty(jsonencode(rb.warnings)), 'warnings 必须可 jsonencode');

fprintf('[test_spec_validate] 全部通过（3 个示例 + 最小规格 + 12 个错误用例）\n');

% =====================================================================
% 辅助函数
% =====================================================================
function s = errorSummary(report)
s = '';
for k = 1:min(8, numel(report.errors))
    s = [s sprintf('[%s] %s; ', report.errors{k}.code, report.errors{k}.path)]; %#ok<AGROW>
end
if numel(report.errors) > 8
    s = [s '...'];
end
end

function assertEstimatedBounds(p)
if isfield(p, 'estimate') && islogical(p.estimate) && isscalar(p.estimate) && p.estimate
    b = p.bounds;
    assert(isnumeric(b) && numel(b) == 2 && b(1) < b(2), '估计参数 bounds 非法');
    v = p.value.value;
    assert(v >= b(1) && v <= b(2), '估计参数初值应在 bounds 内');
end
end

function tf = hasWarningCode(report, code)
tf = false;
for k = 1:numel(report.warnings)
    if strcmp(report.warnings{k}.code, code)
        tf = true;
        return
    end
end
end

function [found, item] = findCode(items, code)
found = false;
item = struct('code', '', 'path', '', 'message', '', 'hint', '');
for k = 1:numel(items)
    if strcmp(items{k}.code, code)
        found = true;
        item = items{k};
        return
    end
end
end

function spec = setVariableField(spec, idx, field, value)
if iscell(spec.variables)
    e = spec.variables{idx};
    e.(field) = value;
    spec.variables{idx} = e;
else
    spec.variables(idx).(field) = value;
end
end

function spec = setParamBounds(spec, idx, bounds)
if iscell(spec.parameters)
    e = spec.parameters{idx};
    e.bounds = bounds;
    spec.parameters{idx} = e;
else
    spec.parameters(idx).bounds = bounds;
end
end

function spec = setRateParam(spec, idx, paramName, value)
if iscell(spec.reactions)
    e = spec.reactions{idx};
    e.rate.parameters.(paramName) = value;
    spec.reactions{idx} = e;
else
    spec.reactions(idx).rate.parameters.(paramName) = value;
end
end

function spec = setRateField(spec, idx, field, value)
if iscell(spec.reactions)
    e = spec.reactions{idx};
    e.rate.(field) = value;
    spec.reactions{idx} = e;
else
    spec.reactions(idx).rate.(field) = value;
end
end
