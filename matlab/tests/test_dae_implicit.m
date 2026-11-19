% test_dae_implicit.m — 0.9.1 implicit DAE via ode15i/decic
root = bma.util.projectRoot();
p = fullfile(root, 'tests', 'fixtures', 'upgrade', 'dae', 'implicit_index1.json');
v = bma.spec.validate(p);
assert(v.valid, '隐式 DAE spec 校验失败');
m = bma.model.build(p);
r = bma.model.simulate(m, struct('n', 101));
assert(r.success && strcmp(r.solver, 'ode15i'), 'ode15i 求解失败：%s', strjoin(r.warnings, '; '));
assert(abs(r.Y(end, 1) - (1 - exp(-5))) < 2e-2, 'x 终值不符合 1-exp(-t)');
assert(abs(r.Y(end, 2) - r.Y(end, 1)) < 2e-2, '代数约束 x=y 未满足');
fprintf('[PASS] implicit DAE: x_end=%.4f y_end=%.4f\n', r.Y(end, 1), r.Y(end, 2));

d = struct('t', r.t, 'Y', r.Y(:, 1), 'outputs', {{'x'}});
fr = bma.fit.estimate(m, d, struct('params_to_fit', {{'k'}}, ...
    'multistart', 1, 'max_iter', 8, 'save_artifacts', false));
assert(abs(fr.params(1).value - 1) < 0.05, 'DAE 拟合 k=%.4f 偏离 1', fr.params(1).value);
fprintf('[PASS] implicit DAE fit: k=%.4f\n', fr.params(1).value);

threw = false;
try, bma.model.analyze(m); catch err, threw = strcmp(err.identifier, 'bma:dae:analysisUnsupported'); end
assert(threw, 'DAE analyze 应明确拒绝');
fprintf('[test_dae_implicit] 全部通过\n');
