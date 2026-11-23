% test_flex_extensions.m — 扩展性：kind="matlab" 自定义速率 + 非零 Neumann / Robin 边界
%
% 覆盖：
%   1) kind="matlab" 走与内建速率相同的编译链（vfuns/rhs/仿真/解析解对照）
%   2) 声明单位必填（缺 unit 判无效）
%   3) 函数不在路径上 → BMA_RATE_INVALID
%   4) 声明单位产生 BMA_RATE_DECLARED_UNIT 警告（如实标注“声明而非推导”）
%   5) 原生 PDE：非零 Neumann flux / Robin 通过校验并真实求解
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
addpath(fullfile(root, 'matlab'));

tmp = tempname;
mkdir(tmp);
cleaner = onCleanup(@() cleanupTmp(tmp)); %#ok<NASGU>

% =====================================================================
% 1) 自定义速率函数：v = k*S（一阶衰减，有解析解）
% =====================================================================
fid = fopen(fullfile(tmp, 'bma_test_linear_rate.m'), 'w');
fprintf(fid, 'function v = bma_test_linear_rate(S, k)\n');
fprintf(fid, '%% 测试用自定义速率定律：一阶\n');
fprintf(fid, 'v = k .* S;\n');
fprintf(fid, 'end\n');
fclose(fid);
addpath(tmp);
rehash;

vars = [mkVar('S', '底物', 'uM', 2), mkVar('P', '产物', 'uM', 0)];
pars = mkParam('k', '速率常数', '1/s', 0.3, false);
rate = struct('kind', 'matlab');
rate = setfield(rate, 'function', 'bma_test_linear_rate'); %#ok<SFLD>
rate.file = fullfile(tmp, 'bma_test_linear_rate.m');
rate.arguments = {'S', 'k'};
rate.unit = 'uM/s';
rate.display = 'k*S';
spec = makeSpec(rate, vars, pars, struct('S', -1, 'P', 1), 'S');
report = bma.spec.validate(spec);
assert(report.valid, 'kind=matlab 规格应通过校验：%s', firstErrors(report));
assert(findCode(report, 'BMA_RATE_DECLARED_UNIT'), ...
    '声明单位应产生 BMA_RATE_DECLARED_UNIT 警告（不得静默当作“已推导”）');

m = bma.model.build(spec);
v = m.vfuns{1}([2; 0], 0.3);
assert(abs(v - 0.6) < 1e-12, sprintf('自定义速率取值错误：%g', v));
assert(isfield(m, 'rate_functions') && numel(m.rate_functions) == 1, ...
    '编译结果应记录外部速率函数（模型卡/代码生成需要）');
rf = m.rate_functions{1};
assert(strcmp(getfield(rf, 'function'), 'bma_test_linear_rate'), ...
    'rate_functions.function 记录错误');

res = bma.model.simulate(m, struct('solver', 'ode45', 'tspan', [0 5]));
assert(res.success, '自定义速率模型仿真失败');
S_end = res.Y(end, 1);
expect = 2 * exp(-0.3 * 5);
assert(abs(S_end - expect) / expect < 1e-6, ...
    sprintf('自定义速率仿真与解析解不符：%.6g vs %.6g', S_end, expect));

% 代码生成：产物必须调用外部函数，并提示“该 .m 需在路径上”
runTmp = fullfile(tmp, 'codegen_run');
mkdir(runTmp);
mGen = bma.model.build(spec, struct('run_dir', runTmp));
genTxt = fileread(mGen.rhs_function_path);
assert(contains(genTxt, 'bma_test_linear_rate'), '生成代码应调用外部速率函数');
assert(contains(genTxt, '必须保持在 MATLAB 路径上'), '生成代码应提示外部函数路径要求');

% =====================================================================
% 2) 缺 unit → 判无效（函数体量纲无法静态推导）
% =====================================================================
rateNoUnit = rmfield(rate, 'unit');
rep2 = bma.spec.validate(makeSpec(rateNoUnit, vars, pars, struct('S', -1, 'P', 1), 'S'));
assert(~rep2.valid, '缺 unit 的 kind=matlab 应判无效');
assert(findCode(rep2, 'BMA_SPEC_MISSING_FIELD'), '应给出 BMA_SPEC_MISSING_FIELD');

% =====================================================================
% 3) 函数不在路径上 → BMA_RATE_INVALID
% =====================================================================
rateGhost = rate;
rateGhost = setfield(rateGhost, 'function', 'bma_gs_ghost_rate_xyz'); %#ok<SFLD>
rateGhost = rmfield(rateGhost, 'file');
rep3 = bma.spec.validate(makeSpec(rateGhost, vars, pars, struct('S', -1, 'P', 1), 'S'));
assert(~rep3.valid, '未知函数应判无效');
assert(findCode(rep3, 'BMA_RATE_INVALID'), '应给出 BMA_RATE_INVALID');

% =====================================================================
% 4) 原生 PDE：非零 Neumann / Robin 边界
% =====================================================================
specN = basePde();
specN.pde.bc = {struct('edge', 'all', 'type', 'neumann', 'flux', 0.5)};
vn = bma.spec.validate(specN);
assert(vn.valid, '非零 Neumann flux 应通过校验：%s', firstErrors(vn));

specR = basePde();
specR.pde.bc = {struct('edge', 'all', 'type', 'robin', 'q', 1, 'g', 0)};
vr = bma.spec.validate(specR);
assert(vr.valid, 'Robin 边界应通过校验：%s', firstErrors(vr));

specBad = basePde();
specBad.pde.bc = {struct('edge', 'all', 'type', 'flux_weird')};
assert(~bma.spec.validate(specBad).valid, '未知边界类型应判无效');

rP = bma.pde.simulate(specN, struct('run_dir', fullfile(tmp, 'pde_neumann'), ...
    'work_dir', root, 'max_dof', 50000));
assert(rP.success, '非零 Neumann 的 2D 求解失败');
vals = rP.probes{1}.values;
assert(all(isfinite(vals)), 'probe 含 NaN/Inf');
assert(vals(end) > vals(1), '非零通量边界应向域内注入质量（probe 应上升）');

fprintf(['[test_flex_extensions] 全部通过（kind=matlab 自定义速率 + 非零 Neumann/Robin；' ...
    'pde probe %.4g -> %.4g）\n'], vals(1), vals(end));

% =====================================================================
% 辅助
% =====================================================================
function spec = basePde()
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'pde_bc_case';
spec.title = '边界条件测试';
spec.kind = 'pde';
spec.time = struct('unit', 's', 'start', 0, 'end', 0.2, 'n', 5);
spec.variables = {struct('id', 'A', 'unit', '1', 'initial', struct('value', 0))};
spec.parameters = {struct('id', 'Da', 'unit', 'um^2/s', 'value', struct('value', 0.1)), ...
    struct('id', 'kdecay', 'unit', '1/s', 'value', struct('value', 0))};
spec.pde = struct();
spec.pde.dim = 2;
spec.pde.solver = 'toolbox';
spec.pde.domain = struct('geometry', 'rectangle', 'size', [1 1], ...
    'mesh', struct('hmax', 0.35));
spec.pde.diffusion = {struct('species', 'A', 'coeff', 'Da')};
spec.pde.bc = {struct('edge', 'all', 'type', 'dirichlet', 'value', 0)};
spec.pde.probes = {struct('id', 'A_center', 'species', 'A', 'x', 0.5, 'y', 0.5)};
spec.reactions = {struct('id', 'decay', 'stoichiometry', struct('A', -1), ...
    'rate', struct('kind', 'expression', 'expression', 'kdecay*A'))};
spec.assumptions = {'边界条件单元测试'};
end

function spec = makeSpec(rate, variables, parameters, stoich, outputExpr)
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'matlab_rate_case';
spec.title = '自定义速率单元测试';
spec.description = '';
spec.kind = 'ode';
spec.time = struct('unit', 's', 'start', 0, 'end', 5, 'n', 11);
spec.variables = variables;
spec.parameters = parameters;
spec.outputs = struct('id', 'o1', 'name', '输出', 'unit', variables(1).unit, ...
    'expression', outputExpr);
spec.reactions = struct('id', 'r1', 'name', '反应', ...
    'stoichiometry', stoich, 'rate', rate);
spec.assumptions = {'单元测试'};
end

function v = mkVar(id, name, unit, initial)
v = struct('id', id, 'name', name, 'unit', unit, ...
    'initial', struct('value', initial));
end

function p = mkParam(id, name, unit, value, estimate)
p = struct('id', id, 'name', name, 'unit', unit, ...
    'value', struct('value', value), 'estimate', estimate, 'bounds', []);
end

function tf = findCode(report, code)
tf = false;
for k = 1:numel(report.errors)
    if strcmp(report.errors{k}.code, code)
        tf = true;
        return
    end
end
for k = 1:numel(report.warnings)
    if strcmp(report.warnings{k}.code, code)
        tf = true;
        return
    end
end
end

function s = firstErrors(report)
s = '';
for k = 1:min(5, numel(report.errors))
    s = [s sprintf('[%s] %s: %s; ', report.errors{k}.code, ...
        report.errors{k}.path, report.errors{k}.message)]; %#ok<AGROW>
end
end

function cleanupTmp(tmp)
try
    rmpath(tmp);
catch
end
try
    if isfolder(tmp)
        rmdir(tmp, 's');
    end
catch
end
end
