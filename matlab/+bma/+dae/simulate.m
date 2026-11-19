function res = simulate(m, opts)
%SIMULATE Solve a compiled kind="dae" model with ode15i after decic.
if nargin < 2 || isempty(opts), opts = struct(); end
t0 = double(getF(getF(m, 'time', struct()), 'start', 0));
t1 = double(getF(getF(m, 'time', struct()), 'end', 10));
n = double(getF(getF(m, 'time', struct()), 'n', 101));
if isfield(opts, 'time_end') && ~isempty(opts.time_end), t1 = double(opts.time_end); end
if isfield(opts, 'n') && ~isempty(opts.n), n = double(opts.n); end
p = m.paramValues(:);
if isfield(opts, 'param_overrides') && isstruct(opts.param_overrides)
    fn = fieldnames(opts.param_overrides);
    for k = 1:numel(fn)
        p(m.paramIndex(fn{k})) = double(opts.param_overrides.(fn{k}));
    end
end
y0 = m.initial(:);
yp0 = m.initial_derivative(:);
if isfield(opts, 'initial_overrides') && isstruct(opts.initial_overrides)
    fn = fieldnames(opts.initial_overrides);
    for k = 1:numel(fn)
        y0(m.speciesIndex(fn{k})) = double(opts.initial_overrides.(fn{k}));
    end
end
tvec = linspace(t0, t1, round(n)).';
solOpts = odeset('RelTol', 1e-6, 'AbsTol', 1e-9);
if isfield(opts, 'rtol') && ~isempty(opts.rtol), solOpts = odeset(solOpts, 'RelTol', opts.rtol); end
if isfield(opts, 'atol') && ~isempty(opts.atol), solOpts = odeset(solOpts, 'AbsTol', opts.atol); end
ok = true; errMsg = '';
try
    odeF = @(t, y, yp) m.residual(t, y, yp, p);
    [y0c, yp0c] = decic(odeF, t0, y0, [], yp0, []);
    sol = ode15i(odeF, [t0 t1], y0c, yp0c, solOpts);
    t = sol.x(:);
    Y = sol.y.';
    if numel(t) ~= numel(tvec) || any(abs(t - tvec) > 1e-12)
        Y = interp1(t, Y, tvec, 'linear');
        t = tvec;
    end
    y0 = y0c;
catch err
    ok = false; errMsg = err.message;
    t = tvec; Y = nan(numel(tvec), m.n_species);
end
out = struct('id', {}, 'name', {}, 'unit', {}, 't', {}, 'y', {}, ...
    'final', {}, 'min', {}, 'max', {});
for o = 1:numel(m.outputs)
    try
        vals = zeros(numel(t), 1);
        for k = 1:numel(t)
            vals(k) = m.outputFuns{o}(t(k), Y(k, :).', p);
        end
    catch
        vals = nan(numel(t), 1);
    end
    out(o) = struct('id', m.outputs(o).id, 'name', m.outputs(o).name, ...
        'unit', m.outputs(o).unit, 't', t, 'y', vals, ...
        'final', vals(end), 'min', min(vals), 'max', max(vals));
end
res = struct();
res.kind = 'dae';
res.solver = 'ode15i';
res.requested_solver = 'ode15i';
res.success = ok;
res.warnings = {};
if ~ok, res.warnings{end+1} = sprintf('ode15i 求解失败：%s', errMsg); end
res.t = t;
res.Y = Y;
res.outputs = out;
res.species = m.species;
res.timeUnit = char(getF(getF(m, 'time', struct()), 'unit', ''));
res.tspan = [t0 t1];
res.initial = y0;
res.spec = m.spec;
res.stats = struct('n_points', numel(t));
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
