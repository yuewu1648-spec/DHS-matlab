% test_spec_rates.m — 速率定律（mass_action / michaelis_menten / hill / constant /
% expression）与量纲检查的单元测试（DESIGN §3.2 §5.2）。
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录');
addpath(fullfile(root, 'matlab'));

% =====================================================================
% 1. mass_action：v = k * prod(x_i^order_i)
% =====================================================================
vars = [mkVar('S', '底物', 'uM', 2), mkVar('E', '酶', 'uM', 3)];
pars(1) = mkParam('k', '结合速率', '1/(uM*s)', 0.5, false);
rate = struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('S', 1, 'E', 1));
spec = makeSpec(rate, vars, pars, struct('S', -1), 'S');
[m, rep] = buildChecked(spec);
assert(rep.units_check.dimensional_ok, 'mass_action 单位应量纲自洽');
v = m.vfuns{1}([2; 3], 0.5);
assert(abs(v - 0.5 * 2 * 3) < 1e-12, sprintf('mass_action 速率错误：%g', v));

% 二级反应：v = k * S^2（无量纲物种，让量纲自洽）
vars2 = mkVar('S', '底物', '1', 2);
pars2 = mkParam('k', '速率常数', '1/s', 3, false);
rate2 = struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('S', 2));
spec2 = makeSpec(rate2, vars2, pars2, struct('S', -1), 'S');
m2 = buildChecked(spec2);
v2 = m2.vfuns{1}([2], 3);
assert(abs(v2 - 3 * 4) < 1e-12, sprintf('二级 mass_action 速率错误：%g', v2));

% =====================================================================
% 2. michaelis_menten（无抑制 / 竞争 / 非竞争 / 反竞争）
% =====================================================================
vars = [mkVar('S', '底物', 'uM', 3), mkVar('I', '抑制剂', 'uM', 2)];
pars(1) = mkParam('vmax', '最大速率', 'uM/s', 10, false);
pars(2) = mkParam('km', '米氏常数', 'uM', 2, false);
pars(3) = mkParam('ki', '抑制常数', 'uM', 1, false);
rateMM = struct('kind', 'michaelis_menten', ...
    'parameters', struct('vmax', 'vmax', 'km', 'km'), ...
    'species', struct('substrate', 'S'));
specMM = makeSpec(rateMM, vars, pars, struct('S', -1), 'S');
mMM = buildChecked(specMM);
y = [3; 2];   % S=3, I=2
p = [10; 2; 1];
vNo = mMM.vfuns{1}(y, p);
assert(abs(vNo - 10 * 3 / (2 + 3)) < 1e-12, sprintf('米氏速率错误：%g', vNo));

% 竞争性抑制：v = Vmax*S/(Km*(1+I/Ki)+S)
rateC = rateMM;
rateC.inhibitor = struct('species', 'I', 'ki', 'ki', 'type', 'competitive');
mC = buildChecked(makeSpec(rateC, vars, pars, struct('S', -1), 'S'));
vC = mC.vfuns{1}(y, p);
expectC = 10 * 3 / (2 * (1 + 2 / 1) + 3);
assert(abs(vC - expectC) < 1e-12, sprintf('竞争性抑制公式错误：%g vs %g', vC, expectC));
assert(vC < vNo, '竞争性抑制应降低速率');

% 非竞争性抑制：v = Vmax*S/((Km+S)*(1+I/Ki))
rateN = rateMM;
rateN.inhibitor = struct('species', 'I', 'ki', 'ki', 'type', 'noncompetitive');
mN = buildChecked(makeSpec(rateN, vars, pars, struct('S', -1), 'S'));
vN = mN.vfuns{1}(y, p);
expectN = 10 * 3 / ((2 + 3) * (1 + 2 / 1));
assert(abs(vN - expectN) < 1e-12, sprintf('非竞争性抑制公式错误：%g vs %g', vN, expectN));
assert(vN < vC, '非竞争性抑制应比竞争性抑制更强（本参数下）');

% 反竞争性抑制：v = Vmax*S/(Km+S*(1+I/Ki))
rateU = rateMM;
rateU.inhibitor = struct('species', 'I', 'ki', 'ki', 'type', 'uncompetitive');
mU = buildChecked(makeSpec(rateU, vars, pars, struct('S', -1), 'S'));
vU = mU.vfuns{1}(y, p);
expectU = 10 * 3 / (2 + 3 * (1 + 2 / 1));
assert(abs(vU - expectU) < 1e-12, sprintf('反竞争性抑制公式错误：%g vs %g', vU, expectU));

% 非法抑制类型
bad = rateMM;
bad.inhibitor = struct('species', 'I', 'ki', 'ki', 'type', 'magic');
rb = bma.spec.validate(makeSpec(bad, vars, pars, struct('S', -1), 'S'));
assert(~rb.valid, '非法抑制类型应校验失败');
assert(findCode(rb, 'BMA_RATE_INVALID'), '非法抑制类型应返回 BMA_RATE_INVALID');

% =====================================================================
% 3. hill（activation / repression）
% =====================================================================
vars = mkVar('R', '阻遏物', 'nM', 2);
pars(1) = mkParam('vmax', '最大速率', 'nM/min', 10, false);
pars(2) = mkParam('k', '半效浓度', 'nM', 2, false);
pars(3) = mkParam('n', 'Hill 指数', '1', 2, false);
rateHill = struct('kind', 'hill', 'mode', 'activation', ...
    'parameters', struct('vmax', 'vmax', 'k', 'k', 'n', 'n'), ...
    'species', struct('regulator', 'R'));
specHill = makeSpec(rateHill, vars, pars, struct('R', -1), 'R');
specHill.time = struct('unit', 'min', 'start', 0, 'end', 10, 'n', 11);
mH = buildChecked(specHill);
vAct = mH.vfuns{1}(2, [10; 2; 2]);
assert(abs(vAct - 5) < 1e-12, sprintf('Hill 激活公式错误：%g', vAct));
vAct0 = mH.vfuns{1}(0, [10; 2; 2]);
assert(abs(vAct0) < 1e-12, 'Hill 激活在调控物为 0 时速率应为 0');

rateRep = rateHill;
rateRep.mode = 'repression';
specRep = makeSpec(rateRep, vars, pars, struct('R', -1), 'R');
specRep.time = struct('unit', 'min', 'start', 0, 'end', 10, 'n', 11);
mR = buildChecked(specRep);
vRep = mR.vfuns{1}(2, [10; 2; 2]);
assert(abs(vRep - 5) < 1e-12, sprintf('Hill 抑制公式错误：%g', vRep));
vRep0 = mR.vfuns{1}(0, [10; 2; 2]);
assert(abs(vRep0 - 10) < 1e-12, 'Hill 抑制在调控物为 0 时速率应等于 vmax');

% 非法 Hill 模式
bad = rateHill;
bad.mode = 'activation_typo';
rb = bma.spec.validate(makeSpec(bad, vars, pars, struct('R', -1), 'R'));
assert(~rb.valid, 'Hill 模式非法应校验失败');
assert(findCode(rb, 'BMA_RATE_INVALID'), 'Hill 模式非法应返回 BMA_RATE_INVALID');
% 缺 n
bad = rateHill;
bad.parameters = rmfield(bad.parameters, 'n');
rb = bma.spec.validate(makeSpec(bad, vars, pars, struct('R', -1), 'R'));
assert(~rb.valid, 'Hill 缺参数 n 应校验失败');
assert(findCode(rb, 'BMA_SPEC_MISSING_FIELD'), 'Hill 缺参数应返回 BMA_SPEC_MISSING_FIELD');

% =====================================================================
% 4. constant
% =====================================================================
vars = mkVar('X', '变量', 'uM', 1);
pars = mkParam('k0', '恒定速率', 'uM/s', 0.3, false);
rateC = struct('kind', 'constant', 'parameters', struct('k', 'k0'));
specC = makeSpec(rateC, vars, pars, struct('X', 1), 'X');
mC = buildChecked(specC);
v = mC.vfuns{1}(1, 0.3);
assert(abs(v - 0.3) < 1e-12, 'constant 速率错误');

% =====================================================================
% 5. expression（受限表达式；可引用物种/参数/隔室）
% =====================================================================
vars = [mkVar('S', '底物', 'uM', 4), mkVar('E', '酶', 'uM', 1)];
pars(1) = mkParam('kf', '速率常数', '1/s', 0.5, false);
rateE = struct('kind', 'expression', 'expression', 'kf*S/(1+E)');
specE = makeSpec(rateE, vars, pars, struct('S', -1), 'S');
mE = buildChecked(specE);
v = mE.vfuns{1}([4; 1], 0.5);
assert(abs(v - 0.5 * 4 / 2) < 1e-12, sprintf('expression 速率错误：%g', v));

% 引用隔室 id（体积为常数 2）
specE2 = specE;
specE2.compartments = struct('id', 'cell', 'volume', 2, 'unit', 'L');
specE2.reactions = struct('id', 'r1', 'name', '反应', 'stoichiometry', struct('S', -1), ...
    'rate', struct('kind', 'expression', 'expression', 'kf*S*cell/cell'));
specE2.variables(1).compartment = 'cell';
specE2.variables(2).compartment = 'cell';
mE2 = buildChecked(specE2);
v = mE2.vfuns{1}([4; 1], 0.5);
assert(abs(v - 0.5 * 4) < 1e-12, sprintf('expression 引用隔室错误：%g', v));

% 禁用函数 / 语法错误 / 未知 id
for k = 1:3
    switch k
        case 1
            expr = 'abs(S)';
        case 2
            expr = 'evil(S)';
        otherwise
            expr = 'S +';
    end
    bad = struct('kind', 'expression', 'expression', expr);
    rb = bma.spec.validate(makeSpec(bad, vars, pars, struct('S', -1), 'S'));
    assert(~rb.valid, sprintf('表达式 "%s" 应校验失败', expr));
    assert(findCode(rb, 'BMA_RATE_INVALID'), sprintf('表达式 "%s" 应返回 BMA_RATE_INVALID', expr));
end
bad = struct('kind', 'expression', 'expression', 'Q*S');
rb = bma.spec.validate(makeSpec(bad, vars, pars, struct('S', -1), 'S'));
assert(~rb.valid, '未知 id 表达式应校验失败');
assert(findCode(rb, 'BMA_SPEC_UNKNOWN_ID'), '未知 id 表达式应返回 BMA_SPEC_UNKNOWN_ID');

% 白名单函数 exp/log/sqrt/min/max 合法
okExprs = {'exp(-S)', 'log(S+1)', 'sqrt(S+1)', 'min(S,E)', 'max(S,E)', 'kf*exp(-S)'};
for k = 1:numel(okExprs)
    rateOK = struct('kind', 'expression', 'expression', okExprs{k});
    rb = bma.spec.validate(makeSpec(rateOK, vars, pars, struct('S', -1), 'S'));
    assert(rb.valid, sprintf('白名单表达式 "%s" 应合法：%s', okExprs{k}, firstErrors(rb)));
end

% =====================================================================
% 6. 量纲检查
% =====================================================================
examples = {'enzyme_mm', 'goodwin', 'sir'};
for e = 1:numel(examples)
    specX = bma.spec.load(fullfile(root, 'spec', 'examples', [examples{e} '.json']));
    report = bma.spec.validate(specX);
    assert(report.units_check.dimensional_ok, ...
        sprintf('%s 应量纲自洽（dimensional_ok=false 表示存在量纲警告）', examples{e}));
end
% 未知单位 → 错误
specX = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
bad = specX;
bad.variables(1).unit = 'furlong';
rb = bma.spec.validate(bad);
assert(~rb.valid, '未知单位应校验失败');
assert(findCode(rb, 'BMA_UNIT_UNKNOWN'), '未知单位应返回 BMA_UNIT_UNKNOWN');
% 反应通量量纲不一致 → 警告（valid 仍为 true）
bad = specX;
bad.parameters(1).unit = '1/s';   % kf 应为 1/(uM*s)
rb = bma.spec.validate(bad);
assert(rb.valid, '量纲不一致属于警告级，不应使 valid=false');
assert(findCode(rb, 'BMA_UNIT_MISMATCH'), '通量量纲不一致应返回 BMA_UNIT_MISMATCH 警告');
assert(~rb.units_check.dimensional_ok, '通量量纲不一致时 dimensional_ok 应为 false');
assert(~bma.model.checkUnits(bma.model.build(specX)) == false, '示例模型 checkUnits 应为 true');

% =====================================================================
% 7. 中文名称保留 / 参数顺序
% =====================================================================
% 注意：这里必须使用 MM 自己的变量与参数（vmax/km），不能复用前面表达式的 kf，
% 否则速率参数校验会失败（也是 jsondecode/结构体数组的常见陷阱）。
varsMM = mkVar('S', '底物', 'uM', 3);
parsMM = [mkParam('vmax', '最大速率', 'uM/s', 10, false), ...
    mkParam('km', '米氏常数', 'uM', 2, false)];
specCN = makeSpec(rateMM, varsMM, parsMM, struct('S', -1), 'S');
specCN.variables(1).name = '游离底物';
specCN.parameters(2).name = '米氏常数';
mCN = buildChecked(specCN);
assert(strcmp(mCN.speciesNames{1}, '游离底物'), '物种中文名应保留');
assert(strcmp(mCN.paramNames{2}, '米氏常数'), '参数中文名应保留');
assert(strcmp(mCN.params{1}, 'vmax') && strcmp(mCN.params{2}, 'km'), '参数顺序必须与规格一致');
assert(mCN.paramIndex('km') == 2, 'paramIndex 映射错误');
assert(mCN.speciesIndex('S') == 1, 'speciesIndex 映射错误');

fprintf('[test_spec_rates] 全部通过（mass_action/MM 四种/hill 两种/constant/expression + 量纲）\n');

% =====================================================================
% 辅助函数
% =====================================================================
function spec = makeSpec(rate, variables, parameters, stoich, outputExpr)
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'rate_case';
spec.title = '速率定律单元测试';
spec.description = '';
spec.kind = 'ode';
spec.time = struct('unit', 's', 'start', 0, 'end', 10, 'n', 11);
spec.variables = variables;
spec.parameters = parameters;
spec.outputs = struct('id', 'o1', 'name', '输出', 'unit', variables(1).unit, ...
    'expression', outputExpr);
spec.reactions = struct('id', 'r1', 'name', '反应', ...
    'stoichiometry', stoich, 'rate', rate);
spec.assumptions = {'单元测试'};
end

function [m, report] = buildChecked(spec)
report = bma.spec.validate(spec);
assert(report.valid, sprintf('规格应通过校验：%s', firstErrors(report)));
m = bma.model.build(spec);
end

function v = mkVar(id, name, unit, initial)
v = struct('id', id, 'name', name, 'unit', unit, ...
    'initial', struct('value', initial));
end

function p = mkParam(id, name, unit, value, estimate)
p = struct('id', id, 'name', name, 'unit', unit, ...
    'value', struct('value', value), 'estimate', estimate, 'bounds', []);
if estimate
    av = abs(value);
    if av > 0
        p.bounds = [av * 1e-3, av * 1e3];
    else
        p.bounds = [1e-6, 1e6];
    end
end
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
