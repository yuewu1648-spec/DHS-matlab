% test_dimensionless_time.m — ISSUE-011 allow time.unit="1"
root = bma.util.projectRoot();
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'rossler_dimensionless';
spec.kind = 'ode';
spec.time = struct('unit', '1', 'start', 0, 'end', 10, 'n', 101);
spec.variables = {struct('id', 'X', 'unit', '1', 'initial', struct('value', 0.1)), ...
    struct('id', 'Y', 'unit', '1', 'initial', struct('value', 0.1)), ...
    struct('id', 'Z', 'unit', '1', 'initial', struct('value', 0.1))};
spec.parameters = {struct('id', 'a', 'unit', '1', 'value', struct('value', 0.2)), ...
    struct('id', 'b', 'unit', '1', 'value', struct('value', 0.2)), ...
    struct('id', 'c', 'unit', '1', 'value', struct('value', 5.7))};
spec.reactions = {struct('id', 'dX', 'stoichiometry', struct('X', 1), ...
    'rate', struct('kind', 'expression', 'expression', '-Y-Z')), ...
    struct('id', 'dY', 'stoichiometry', struct('Y', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'X+a*Y')), ...
    struct('id', 'dZ', 'stoichiometry', struct('Z', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'b+Z*(X-c)'))};
spec.outputs = {struct('id', 'X', 'unit', '1', 'expression', 'X')};
v = bma.spec.validate(spec);
assert(v.valid, '无量纲时间规格应有效：%s', firstErr(v));
assert(v.units_check.ok && v.units_check.dimensional_ok, '无量纲时间量纲检查应通过');
m = bma.model.build(spec);
r = bma.model.simulate(m, struct('n', 101));
assert(r.success && all(isfinite(r.Y(:))), '无量纲 Rössler 仿真失败');
fprintf('[PASS] dimensionless time.unit=1: valid, units checked=%d\n', ...
    v.units_check.n_units_checked);
fprintf('[test_dimensionless_time] 全部通过\n');

function e = firstErr(v)
e = 'unknown';
if isfield(v, 'errors') && ~isempty(v.errors)
    e = v.errors{1}.message;
end
end
