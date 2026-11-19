function res = simulate(m, opts)
%SIMULATE Solve a compiled kind="dde" model with dde23.
%   res = bma.dde.simulate(m, opts)
%
% Constant delays only (dde23). v1 does not provide DDE fitting; use this for
% forward simulation/figures. Returns the same t/Y/outputs shape as
% bma.model.simulate so bma.plot.* and the report collector can reuse it.
if nargin < 2 || isempty(opts)
    opts = struct();
end
warnings = {};
tStart = double(getF(getF(m, 'time', struct()), 'start', 0));
tEnd = double(getF(getF(m, 'time', struct()), 'end', 100));
n = double(getF(getF(m, 'time', struct()), 'n', 101));
if isfield(opts, 'time_end') && ~isempty(opts.time_end), tEnd = double(opts.time_end); end
if isfield(opts, 'n') && ~isempty(opts.n), n = double(opts.n); end
if ~isfinite(tStart) || ~isfinite(tEnd) || tEnd <= tStart || n < 2
    error('bma:dde:badTime', 'DDE 时间轴无效');
end
tvec = linspace(tStart, tEnd, round(n)).';
p = m.paramValues(:);
if isfield(opts, 'param_overrides') && isstruct(opts.param_overrides)
    fn = fieldnames(opts.param_overrides);
    for k = 1:numel(fn)
        j = m.paramIndex(fn{k});
        p(j) = double(opts.param_overrides.(fn{k}));
    end
end
y0 = m.history(:);
if isfield(opts, 'initial_overrides') && isstruct(opts.initial_overrides)
    fn = fieldnames(opts.initial_overrides);
    for k = 1:numel(fn)
        i = m.speciesIndex(fn{k});
        y0(i) = double(opts.initial_overrides.(fn{k}));
    end
end
% dde23 history is evaluated for t <= tStart; a constant history covers the
% common initial-value case. History expressions are intentionally not part of
% v1 (they would need a time-dependent callback).
history = @(tt) y0; %#ok<NASGU>
solOpts = ddeset('RelTol', 1e-6, 'AbsTol', 1e-9);
if isfield(opts, 'rtol') && ~isempty(opts.rtol)
    solOpts = ddeset(solOpts, 'RelTol', double(opts.rtol));
end
if isfield(opts, 'atol') && ~isempty(opts.atol)
    solOpts = ddeset(solOpts, 'AbsTol', double(opts.atol));
end
ok = true;
errMsg = '';
mode = 'constant';
if isfield(m, 'mode') && ~isempty(m.mode), mode = char(m.mode); end
try
    ddefun = @(t, y, Z) m.rhs(t, y, Z, p);
    if strcmp(mode, 'constant')
        sol = dde23(ddefun, m.delays, history, [tStart tEnd], solOpts);
    elseif strcmp(mode, 'state_dependent')
        % ddesd's dely callback returns the PAST TIME t-tau, not tau itself.
        delayfun = @(t, y) t - m.delayFun(t, y, p);
        sol = ddesd(ddefun, delayfun, history, [tStart tEnd], solOpts);
    elseif strcmp(mode, 'neutral')
        % ddensd's delyp callback also uses the past-time t-tau convention.
        delayfun = @(t, y) t - m.delayFun(t, y, p);
        % ddensd callback receives state delays (Z) and derivative delays (Yp).
        % v1 neutral specs use derivative delays only; passing [] for Z keeps
        % delay(S,tau) unavailable (compile rejects it in neutral mode).
        ddefunN = @(t, y, Z, Yp) m.rhs(t, y, Yp, p); %#ok<INUSD>
        sol = ddensd(ddefunN, [], delayfun, history, [tStart tEnd], solOpts);
    else
        error('bma:dde:badMode', '未知 DDE 模式 "%s"', mode);
    end
    t = sol.x(:);
    Y = sol.y.';
    if numel(t) ~= numel(tvec) || any(abs(t - tvec) > 1e-12)
        Y = interp1(t, Y, tvec, 'linear');
        t = tvec;
    end
catch err
    ok = false;
    errMsg = err.message;
    t = tvec;
    Y = nan(numel(tvec), m.n_species);
    warnings{end+1} = sprintf('%s 求解失败：%s', upper(mode), errMsg);
end
% Outputs are current-time expressions; delayed outputs are not supported.
out = struct('id', {}, 'name', {}, 'unit', {}, 't', {}, 'y', {}, ...
    'final', {}, 'min', {}, 'max', {});
for o = 1:numel(m.outputs)
    try
        vals = zeros(numel(t), 1);
        for k = 1:numel(t)
            vals(k) = m.outputFuns{o}(Y(k, :).', p);
        end
    catch err
        vals = nan(numel(t), 1);
        warnings{end+1} = sprintf('输出 "%s" 求值失败：%s', m.outputs(o).id, err.message); %#ok<AGROW>
    end
    out(o) = struct('id', m.outputs(o).id, 'name', m.outputs(o).name, ...
        'unit', m.outputs(o).unit, 't', t, 'y', vals, ...
        'final', vals(end), 'min', min(vals), 'max', max(vals));
end
res = struct();
res.kind = 'dde';
res.mode = mode;
if strcmp(mode, 'constant')
    res.solver = 'dde23';
elseif strcmp(mode, 'state_dependent')
    res.solver = 'ddesd';
else
    res.solver = 'ddensd';
end
res.requested_solver = res.solver;
res.success = ok;
res.warnings = warnings;
res.t = t;
res.Y = Y;
res.outputs = out;
res.species = m.species;
res.speciesUnits = m.speciesUnits;
res.timeUnit = char(getF(getF(m, 'time', struct()), 'unit', ''));
res.tspan = [tStart tEnd];
res.delays = m.delays;
res.delay_ids = m.delay_ids;
res.spec = m.spec;
res.stats = struct('n_steps', numel(t));
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end
