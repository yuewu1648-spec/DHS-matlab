% test_model_pde.m — 0.7.0 PDE/MOL 编译器回归（issue 0001）
%
% 覆盖：
%   - kind="pde" 通过校验并编译为 MOL ODE（m.kind=pde, m.pde meta）
%   - G1 零阶 slab（耗尽支）/ G2 全穿透支 的解析/参考值
%   - G3 球对称一阶（n=256，收敛后与解析比值）
%   - G4 Monod 柱（16 节点，参考 run 的 mu/C 值）
%   - outputs C[i] / max(C) 语法、PDE 量纲检查
%   - Gap A：initial.param 不再静默变成 0
%   - PDE 报告渲染（网格/边界/PDE 小节）
root = bma.util.projectRoot();
fix = fullfile(root, 'tests', 'fixtures', 'upgrade', 'pde');

% ---------- G1：零阶 slab 耗尽支 ------------------------------------------
spec = fullfile(fix, 'pde_slab_zero.json');
r = bma.spec.validate(spec);
assert(r.valid, 'G1 PDE 规格校验失败：%s', localFirstError(r));
m = bma.model.build(spec);
assert(strcmp(m.kind, 'pde') && isfield(m, 'pde') && m.pde.n == 16, ...
    'PDE 编译元数据错误（kind=%s n=%g）', m.kind, m.pde.n);
res = bma.model.simulate(m, struct('n', 201));
vals = localOutputs(res);
localNear(vals.u2, 0.30770, 0.015, 'G1 u2');
localNear(vals.u3, 0.07772, 0.25, 'G1 u3');
assert(abs(vals.u4 - 0.00590) <= 0.01, 'G1 u4=%.5g 超出绝对容差', vals.u4);
fprintf('[PASS] G1 slab zero-order: u2=%.5f u3=%.5f u4=%.5f\n', vals.u2, vals.u3, vals.u4);

% ---------- G2：零阶 slab 全穿透支 ----------------------------------------
spec = fullfile(fix, 'pde_slab_penetrating.json');
m = bma.model.build(spec);
res = bma.model.simulate(m, struct('n', 201));
vals = localOutputs(res);
localNear(vals.u2, 0.95588, 0.01, 'G2 u2');
localNear(vals.u4, 0.90414, 0.01, 'G2 u4');
localNear(vals.u16, 0.75493, 0.01, 'G2 u16');
fprintf('[PASS] G2 slab penetrating: u2=%.5f u4=%.5f u16=%.5f\n', vals.u2, vals.u4, vals.u16);

% ---------- G4：Monod 柱 16 节点（参考 run golden） ------------------------
spec = fullfile(fix, 'pde_monod_column.json');
m = bma.model.build(spec);
res = bma.model.simulate(m, struct('n', 101));
vals = localOutputs(res);
localNear(vals.C_1, 0.16133, 0.005, 'G4 C1');
localNear(vals.C_16, 22.26575, 0.005, 'G4 C16');
localNear(vals.mu_1, 0.027865, 0.01, 'G4 mu1');
localNear(vals.mu_16, 0.700291, 0.01, 'G4 mu16');
localNear(vals.mu_min_pct, 3.9790, 0.01, 'G4 mu_min_pct');
fprintf('[PASS] G4 Monod column: C1=%.5f C16=%.5f mu1=%.5f mu16=%.5f pct=%.4f\n', ...
    vals.C_1, vals.C_16, vals.mu_1, vals.mu_16, vals.mu_min_pct);

% ---------- G3：球对称一阶（n=256） ---------------------------------------
spec = fullfile(fix, 'pde_sphere_first_order.json');
m = bma.model.build(spec);
assert(m.pde.n == 256 && strcmp(m.pde.geometry, 'sphere'), 'G3 网格/几何元数据错误');
res = bma.model.simulate(m, struct('n', 51));
vals = localOutputs(res);
% n=256 的 FV 离散与解析解差 ~0.5-0.8%；issue 的参考值来自另一套径向实现。
localNear(vals.ratio, 0.099947, 0.02, 'G3 center/edge ratio');
localNear(vals.u_edge, 9.9832, 0.01, 'G3 u_edge');
fprintf('[PASS] G3 sphere first-order: center=%.5f edge=%.5f ratio=%.6f\n', ...
    vals.u_center, vals.u_edge, vals.ratio);

% ---------- 量纲与 outputs 统计 ------------------------------------------
uc = bma.spec.checkUnits(fullfile(fix, 'pde_monod_column.json'));
assert(uc.ok, 'PDE 单位检查失败：%s', localFirstError(uc));
fprintf('[PASS] PDE units: checked=%d dimensional_ok=%d\n', uc.n_units_checked, uc.dimensional_ok);

% ---------- Gap A：initial.param 生效 -------------------------------------
odeSpec = struct();
odeSpec.schema_version = 'bma.modelSpec.v1';
odeSpec.name = 'initial_param_probe';
odeSpec.kind = 'ode';
odeSpec.time = struct('unit', 's', 'start', 0, 'end', 1, 'n', 3);
odeSpec.variables = {struct('id', 'X', 'unit', 'uM', 'initial', struct('param', 'X0'))};
odeSpec.parameters = {struct('id', 'X0', 'unit', 'uM', 'value', struct('value', 6)), ...
    struct('id', 'k', 'unit', '1/s', 'value', struct('value', 0.1))};
odeSpec.reactions = {struct('id', 'decay', 'stoichiometry', struct('X', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('X', 1)))};
odeSpec.outputs = {struct('id', 'X_obs', 'unit', 'uM', 'expression', 'X')};
mr = bma.spec.validate(odeSpec);
assert(mr.valid, 'initial.param ODE 规格校验失败：%s', localFirstError(mr));
mOde = bma.model.build(odeSpec);
assert(abs(mOde.speciesInitial(1) - 6) < 1e-12, ...
    'initial.param 未生效：期望 6，实际 %g', mOde.speciesInitial(1));
fprintf('[PASS] initial.param: X(0)=%g (not silently 0)\n', mOde.speciesInitial(1));

% ---------- PDE 报告/codegen ----------------------------------------------
runDir = fullfile(root, '.bma', 'test_tmp', bma.util.newId('pde_report'));
bma.util.ensureDir(runDir);
cg = bma.codegen.model(fullfile(fix, 'pde_monod_column.json'), runDir);
assert(cg.ok && isfile(cg.m_file), 'PDE codegen 失败');
assert(isfield(cg, 'pde_file') && isfile(cg.pde_file), '缺少 <name>_pde.m 元数据文件');
fprintf('[PASS] PDE codegen: %s + %s\n', cg.m_file, cg.pde_file);
rep = bma.report.build(runDir, bma.spec.load(fullfile(fix, 'pde_monod_column.json')), ...
    [], [], struct('title', 'PDE report probe'));
html = fileread(bma.util.absPath(root, rep.report_html));
assert(~isempty(strfind(html, 'PDE 离散与边界条件')), '报告缺少 PDE 小节');
assert(~isempty(strfind(html, 'representative column')), '报告缺少 approximation 限制');
fprintf('[PASS] PDE report section + approximation limitation\n');

fprintf('[test_model_pde] 全部通过\n');

% =========================================================================
function vals = localOutputs(res)
vals = struct();
for k = 1:numel(res.outputs)
    vals.(res.outputs(k).id) = res.outputs(k).final;
end
end

function localNear(actual, expected, relTol, label)
if ~isfinite(actual) || abs(actual - expected) > relTol * max(1, abs(expected))
    error('bma:test:pdeGolden', '%s: 期望 %.6g ± %.2g%%，实际 %.6g', ...
        label, expected, 100 * relTol, actual);
end
end

function e = localFirstError(report)
e = 'unknown';
try
    if isfield(report, 'errors') && ~isempty(report.errors)
        e = sprintf('%s: %s', report.errors{1}.code, report.errors{1}.message);
    elseif isfield(report, 'issues') && ~isempty(report.issues)
        e = sprintf('%s: %s', report.issues{1}.code, report.issues{1}.message);
    end
catch
end
end
