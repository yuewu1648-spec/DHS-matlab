% test_advanced_solve.m — 0.9.0 advanced MATLAB capabilities
% system_id (tfest) / symbolic (dsolve) / sde (Euler-Maruyama)
root = bma.util.projectRoot();
work = fullfile(root, '.bma', 'test_tmp', bma.util.newId('advanced'));
bma.util.ensureDir(work);

% symbolic closed form
p = struct('equations', {{'diff(x(t),t)=a*x(t)'}}, ...
    'variables', {{'x(t)'}}, 'conditions', {{'x(0)=1'}});
rs = bma.advanced.solve('symbolic', p, struct('work_dir', work));
assert(rs.ok && contains(rs.solution, 'exp(a*t)'), 'dsolve 结果错误：%s', rs.solution);
fprintf('[PASS] symbolic dsolve: %s\n', rs.solution);

% dispatch path (the tool reaches this case through the heavy worker)
rd = bma.server.dispatch('advanced.solve', struct('method', 'symbolic', ...
    'problem', p), struct('work_dir', work));
assert(rd.ok && contains(rd.solution, 'exp(a*t)'), 'dispatch advanced.solve 失败');
fprintf('[PASS] advanced.solve dispatch\n');

% system identification from a generated CSV
t = (0:0.1:20)';
u = sin(t);
y = filter([0 1], [1 -0.8], u) + 0.01 * randn(size(t));
csv = fullfile(work, 'sysid.csv');
T = table(t, u, y, 'VariableNames', {'time', 'u', 'y'});
writetable(T, csv);
pid = struct('data_csv', csv, 'time_column', 'time', 'output_column', 'y', ...
    'input_columns', {{'u'}}, 'model', 'tfest', 'np', 2, 'nz', 1);
ri = bma.advanced.solve('system_id', pid, struct('work_dir', work, 'run_dir', work));
assert(ri.ok && ri.fit_percent > 90, 'system_id fit 过低：%g', ri.fit_percent);
assert(isfile(ri.figure), 'system_id 缺图');
fprintf('[PASS] system_id tfest: fit=%.2f%%\n', ri.fit_percent);

% stochastic simulation (Euler-Maruyama) should return finite mean/std
s = struct();
s.variables = {struct('id', 'x', 'initial', struct('value', 1))};
s.parameters = {struct('id', 'k', 'value', struct('value', 1))};
s.drift = '-k*x';
s.diffusion = '0.1*x';
s.time_end = 1;
s.n = 101;
s.paths = 5;
rde = bma.advanced.solve('sde', s, struct());
assert(rde.ok && all(isfinite(rde.mean(:))) && all(isfinite(rde.std(:))), 'sde 输出非有限');
fprintf('[PASS] sde Euler-Maruyama: paths=%d mean_end=%.4f\n', rde.paths, rde.mean(end));

% exact Gillespie SSA: birth-death with steady mean kb/kd = 5
sp = struct();
sp.variables = {struct('id', 'x', 'initial', struct('value', 0))};
sp.parameters = {struct('id', 'kb', 'value', struct('value', 5)), ...
    struct('id', 'kd', 'value', struct('value', 1))};
sp.reactions = {struct('id', 'birth', 'stoichiometry', struct('x', 1), ...
    'rate', struct('expression', 'kb')), ...
    struct('id', 'death', 'stoichiometry', struct('x', -1), ...
    'rate', struct('expression', 'kd*x'))};
sp.time_end = 20;
sp.n = 101;
sp.paths = 40;
rssa = bma.advanced.solve('ssa', sp, struct());
assert(rssa.ok && abs(rssa.mean(end) - 5) < 1.5, 'SSA 稳态均值异常：%g', rssa.mean(end));
assert(all(isfinite(rssa.std(:))), 'SSA std 非有限');
fprintf('[PASS] exact Gillespie SSA: mean_end=%.3f\n', rssa.mean(end));
fprintf('[test_advanced_solve] 全部通过\n');
