% test_dae_mass.m — 0.9.0 linear-implicit DAE via ode15s mass matrix
%
% dx/dt = 1-x, 0 = x-y, x(0)=y(0)=0. The DAE solution is x=y=1-exp(-t).
root = bma.util.projectRoot();
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'dae_mass_probe';
spec.kind = 'ode';
spec.time = struct('unit', 's', 'start', 0, 'end', 5, 'n', 101);
spec.variables = {struct('id', 'x', 'unit', 'uM', 'initial', struct('value', 0)), ...
    struct('id', 'y', 'unit', 'uM', 'initial', struct('value', 0))};
spec.parameters = {struct('id', 'k', 'unit', '1/s', 'value', struct('value', 1), ...
    'estimate', true, 'bounds', [0.2, 3])};
spec.reactions = {struct('id', 'src', 'stoichiometry', struct('x', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'k*(1-x)')), ...
    struct('id', 'constraint', 'stoichiometry', struct('y', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'x-y'))};
spec.outputs = {struct('id', 'x', 'unit', 'uM', 'expression', 'x'), ...
    struct('id', 'y', 'unit', 'uM', 'expression', 'y')};
v = bma.spec.validate(spec);
assert(v.valid, 'DAE spec 校验失败：%s', localFirst(v));
m = bma.model.build(spec);
r = bma.model.simulate(m, struct('n', 101, 'mass_matrix', [1 0; 0 0]));
assert(r.success, '质量矩阵 DAE 求解失败：%s', strjoin(r.warnings, '; '));
assert(all(isfinite(r.Y(:))), 'DAE 输出含 NaN');
assert(abs(r.Y(end, 1) - (1 - exp(-5))) < 2e-2, 'x 终值不符合 1-exp(-t)');
assert(abs(r.Y(end, 2) - r.Y(end, 1)) < 2e-2, '代数约束 x=y 未满足');
assert(any(contains(r.warnings, 'mass_matrix')), '奇异质量矩阵应有明确 warning');
fprintf('[PASS] mass-matrix DAE: x_end=%.4f y_end=%.4f\n', r.Y(end, 1), r.Y(end, 2));

% A bad mass matrix must fail loudly, not silently fall back to ODE.
threw = false;
try
    bma.model.simulate(m, struct('mass_matrix', [1 0 0; 0 1 0]));
catch err
    threw = contains(err.message, 'mass_matrix');
end
assert(threw, '错误尺寸的 mass_matrix 未报错');
fprintf('[PASS] mass_matrix dimension gate\n');

% fit through the mass-matrix simulation path
d = struct('t', r.t, 'Y', r.Y(:, 1), 'outputs', {{'x'}});
fr = bma.fit.estimate(m, d, struct('params_to_fit', {{'k'}}, ...
    'mass_matrix', [1 0; 0 0], 'multistart', 1, 'max_iter', 8, ...
    'save_artifacts', false));
assert(abs(fr.params(1).value - 1) < 0.05, 'DAE 拟合 k=%.4f 偏离 1', fr.params(1).value);
fprintf('[PASS] DAE mass-matrix fit: k=%.4f\n', fr.params(1).value);
fprintf('[test_dae_mass] 全部通过\n');

function e = localFirst(r)
e = 'unknown';
try
    if isfield(r, 'errors') && ~isempty(r.errors)
        e = sprintf('%s: %s', r.errors{1}.code, r.errors{1}.message);
    end
catch
end
end
