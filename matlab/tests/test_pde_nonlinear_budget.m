% test_pde_nonlinear_budget.m — 0.14.0 hardening of the native 2D path
%
% Covers the three defects found on a real biofilm model (Stewart 2016 Case 4B):
%   1) a nonlinear Monod source term hung solvepde forever (negative/NaN trial
%      states drove the denominator through the -KM pole -> NaN -> the error
%      controller rejected every step and the march never finished);
%   2) max_seconds was checked only after solvepde returned, so it could not
%      bound a stuck solve (see scripts/pde_watchdog.ps1 for the hard budget);
%   3) steady=true was unusable because the builder always set d=1 (parabolic).
root = bma.util.projectRoot();
runDir = fullfile(root, '.bma', 'test_tmp', bma.util.newId('pde_nonlinear'));
bma.util.ensureDir(runDir);

% ---------------- shared spec: 90 x 65 um, Monod sink, one Dirichlet edge ----
De = 223; qmax = 4.6956; KM = 4.762; Co = 100;
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'pde2d_monod_plain';
spec.kind = 'pde';
spec.time = struct('unit', 's', 'start', 0, 'end', 20, 'n', 5);
spec.variables = {struct('id', 'G', 'unit', 'mg/L', 'initial', struct('value', 0))};
spec.parameters = { ...
    struct('id', 'De', 'unit', 'um^2/s', 'value', struct('value', De)), ...
    struct('id', 'Co', 'unit', 'mg/L', 'value', struct('value', Co)), ...
    struct('id', 'qmax', 'unit', 'mg/L/s', 'value', struct('value', qmax)), ...
    struct('id', 'KM', 'unit', 'mg/L', 'value', struct('value', KM))};
spec.pde = struct();
spec.pde.dim = 2;
spec.pde.solver = 'toolbox';
spec.pde.domain = struct('geometry', 'rectangle', 'size', [90 65], ...
    'mesh', struct('hmax', 6));
spec.pde.diffusion = {struct('species', 'G', 'coeff', 'De')};
spec.pde.bc = {struct('edge', 3, 'type', 'dirichlet', 'value', 'Co')};
spec.pde.probes = {struct('id', 'top', 'species', 'G', 'x', 45, 'y', 62), ...
    struct('id', 'bottom', 'species', 'G', 'x', 45, 'y', 3)};
% NOTE: deliberately the *unregularised* form that used to hang
spec.reactions = {struct('id', 'uptake', 'stoichiometry', struct('G', -1), ...
    'rate', struct('kind', 'michaelis_menten', ...
    'parameters', struct('vmax', 'qmax', 'km', 'KM'), ...
    'species', struct('substrate', 'G')))};

vr = bma.spec.validate(spec);
assert(vr.valid, 'plain-Monod 2D spec 校验失败：%s', localFirst(vr));

% ---------------- 1) unregularised Monod must now finish --------------------
t0 = tic;
r1 = bma.pde.simulate(spec, struct('run_dir', fullfile(runDir, 'plain'), ...
    'work_dir', root, 'max_dof', 50000));
el = toc(t0);
assert(r1.success && strcmp(r1.solver, 'pde_toolbox'), 'plain-Monod 2D 求解失败');
assert(el < 120, 'plain-Monod 2D 用时 %.1f s，回归：仍然卡住', el);
v = r1.probes{1}.values;          % top probe time series
vBot = r1.probes{2}.values;       % bottom probe time series
assert(all(isfinite(v)) && all(isfinite(vBot)), 'probe 含 NaN/Inf');
assert(max(v) <= Co * 1.02, 'probe 超过边界浓度（源项符号或钳位异常）');
assert(v(end) > v(2), '顶边 probe 未随时间升高（Dirichlet 边界未生效）');
assert(v(end) > vBot(end), '顶边 probe 未高于底部 probe（梯度方向异常）');
assert(isfield(r1, 'diagnostics') && ...
    (r1.diagnostics.clamped_states + r1.diagnostics.nonfinite_source) > 0, ...
    '源项保护从未触发：既没有负浓度钳位也没有非有限值拦截（该模型本应触发其一）');
fprintf(['[PASS] plain Monod 2D: %.1f s, nodes=%d, clamped=%d, nonfinite=%d, ' ...
    'top=%.2f bottom=%.2f\n'], el, r1.stats.nodes, r1.diagnostics.clamped_states, ...
    r1.diagnostics.nonfinite_source, v(end), vBot(end));

% ---------------- 2) max_seconds is advisory, and reports itself as such ---
% solvepde exposes no callback and setInitialConditions takes only a scalar or a
% length-N vector, so an in-process deadline is impossible; the hard budget lives
% in scripts/pde_watchdog.ps1 (child process + forced kill).
r2 = bma.pde.simulate(spec, struct('run_dir', fullfile(runDir, 'advisory'), ...
    'work_dir', root, 'max_dof', 50000, 'max_seconds', 1));
assert(r2.success, 'advisory 预算下求解失败');
assert(isfield(r2, 'budget') && r2.budget.advisory && ~r2.budget.interruptible, ...
    'budget 结构未如实标注 advisory/interruptible');
assert(abs(r2.budget.max_seconds - 1) < 1e-9, 'budget.max_seconds 未按入参记录');
fprintf('[PASS] advisory budget: elapsed=%.2f s, max_seconds=%.0f, interruptible=%d\n', ...
    r2.budget.elapsed_s, r2.budget.max_seconds, r2.budget.interruptible);

% ---------------- 3) steady=true uses the elliptic form --------------------
spec3 = spec;
spec3.name = 'pde2d_diffusion_steady';
spec3.time = struct('unit', 's', 'start', 0, 'end', 1, 'n', 3);
spec3.reactions = {struct('id', 'noop', 'stoichiometry', struct('G', -1), ...
    'rate', struct('kind', 'expression', 'expression', '0*G'))};
% zero net source: the steady field must be uniform Co (Dirichlet on edge 3,
% zero flux elsewhere)
r3 = bma.pde.simulate(spec3, struct('run_dir', fullfile(runDir, 'steady'), ...
    'work_dir', root, 'max_dof', 50000, 'steady', true));
assert(r3.success && r3.stats.steady, 'steady=true 求解失败（2D 稳态路径）');
U3 = r3.field_stats(1);
assert(abs(U3.max(end) - Co) < 1e-3 * Co + 1e-6 && abs(U3.min(end) - Co) < 1e-3 * Co + 1e-6, ...
    '稳态场不是均匀 Co（min=%.4g max=%.4g）', U3.min(end), U3.max(end));
fprintf('[PASS] steady=true (elliptic): min=%.4f max=%.4f\n', U3.min(end), U3.max(end));

fprintf('[test_pde_nonlinear_budget] 全部通过\n');

% =========================================================================
function e = localFirst(r)
e = 'unknown';
try
    if isfield(r, 'errors') && ~isempty(r.errors)
        e = sprintf('%s: %s', r.errors{1}.code, r.errors{1}.message);
    end
catch
end
end
