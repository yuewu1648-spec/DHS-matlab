function res = solve(m, opts)
%SOLVE Solve a compiled kind="bvp" model with bvp4c.
if nargin < 2 || isempty(opts), opts = struct(); end
p = m.paramValues(:);
if isfield(opts, 'param_overrides') && isstruct(opts.param_overrides)
    fn = fieldnames(opts.param_overrides);
    for k = 1:numel(fn)
        j = m.paramIndex(fn{k});
        p(j) = double(opts.param_overrides.(fn{k}));
    end
end
x0 = m.domain.x0; x1 = m.domain.x1; n = m.domain.n;
if isfield(opts, 'n') && ~isempty(opts.n), n = double(opts.n); end
try
    solinit = bvpinit(linspace(x0, x1, n), m.initial);
    sol = bvp4c(@(x, y) m.odefun(x, y, p), @(ya, yb) m.bcfun(ya, yb, p), solinit);
    t = linspace(x0, x1, n).';
    Y = deval(sol, t).';
    ok = true;
    errMsg = '';
catch err
    ok = false;
    errMsg = err.message;
    t = linspace(x0, x1, n).';
    Y = nan(numel(t), m.n_species);
end
out = struct('id', {}, 'name', {}, 'unit', {}, 't', {}, 'y', {}, ...
    'final', {}, 'min', {}, 'max', {});
for o = 1:numel(m.outputs)
    try
        vals = zeros(numel(t), 1);
        for k = 1:numel(t)
            vals(k) = m.outputFuns{o}(t(k), Y(k, :).', p);
        end
    catch err
        vals = nan(numel(t), 1);
        errMsg = [errMsg '；输出求值失败：' err.message];
    end
    out(o) = struct('id', m.outputs(o).id, 'name', m.outputs(o).name, ...
        'unit', m.outputs(o).unit, 't', t, 'y', vals, ...
        'final', vals(end), 'min', min(vals), 'max', max(vals));
end
res = struct();
res.kind = 'bvp';
res.solver = 'bvp4c';
res.requested_solver = 'bvp4c';
res.success = ok;
res.warnings = {};
if ~ok, res.warnings{end+1} = sprintf('bvp4c 求解失败：%s', errMsg); end
res.t = t;
res.Y = Y;
res.outputs = out;
res.species = m.species;
res.timeUnit = char(getF(m.time, 'unit', '1'));
res.tspan = [x0 x1];
res.spec = m.spec;
res.stats = struct('n_points', numel(t));
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
