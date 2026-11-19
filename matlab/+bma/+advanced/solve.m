function res = solve(method, problem, opts)
%SOLVE Advanced MATLAB capabilities that are not bma.modelSpec kinds.
%   res = bma.advanced.solve(method, problem, opts)
%
% Supported methods:
%   system_id : identify a linear/nonlinear black-box model from CSV data
%               (System Identification Toolbox: tfest/ssest/arx).
%   symbolic   : closed-form ODE solution with dsolve (Symbolic Toolbox).
%   sde        : Euler-Maruyama simulation of a scalar/multi-state SDE with
%                drift and diffusion expressions.
%
% This path is intentionally separate from fit/identifiability: its output is
% a numerical/symbolic result + artifacts, not an ODE state-vector model.
if nargin < 3 || isempty(opts), opts = struct(); end
method = lower(char(method));
switch method
    case 'system_id'
        res = systemIdentify(problem, opts);
    case 'symbolic'
        res = symbolicSolve(problem, opts);
    case 'sde'
        res = sdeSimulate(problem, opts);
    case 'ssa'
        res = ssaSimulate(problem, opts);
    otherwise
        error('bma:advanced:badMethod', ...
            '高级方法 "%s" 未实现；支持 system_id / symbolic / sde / ssa', method);
end
res.method = method;
end

% =========================================================================
function res = systemIdentify(problem, opts)
if ~isstruct(problem), error('bma:advanced:badProblem', 'system_id 需要 problem 对象'); end
file = char(getF(problem, 'data_csv', ''));
if isempty(file), error('bma:advanced:badProblem', 'system_id 需要 data_csv'); end
if ~isfile(file)
    file = bma.util.absPath(char(getF(opts, 'work_dir', bma.util.projectRoot())), file);
end
if ~isfile(file), error('bma:advanced:dataMissing', '找不到数据文件：%s', file); end
T = readtable(file);
timeCol = char(getF(problem, 'time_column', 'time'));
if ~any(strcmp(T.Properties.VariableNames, timeCol))
    error('bma:advanced:dataColumns', 'CSV 缺少时间列 "%s"', timeCol);
end
t = double(T.(timeCol));
yCol = char(getF(problem, 'output_column', ''));
if isempty(yCol) || ~any(strcmp(T.Properties.VariableNames, yCol))
    error('bma:advanced:dataColumns', 'CSV 缺少输出列 "%s"', yCol);
end
y = double(T.(yCol));
inCols = itemize(getF(problem, 'input_columns', {}));
u = [];
if ~isempty(inCols)
    u = zeros(numel(t), numel(inCols));
    for k = 1:numel(inCols)
        name = char(inCols{k});
        if ~any(strcmp(T.Properties.VariableNames, name))
            error('bma:advanced:dataColumns', 'CSV 缺少输入列 "%s"', name);
        end
        u(:, k) = double(T.(name));
    end
end
if numel(t) < 5, error('bma:advanced:dataTooShort', '系统辨识至少需要 5 个采样点'); end
ts = median(diff(t));
if ~isfinite(ts) || ts <= 0, error('bma:advanced:badTime', '时间列必须严格递增'); end
data = iddata(y, u, ts);
kind = lower(char(getF(problem, 'model', 'tfest')));
order = getF(problem, 'order', []);
model = [];
switch kind
    case 'tfest'
        np = double(getF(problem, 'np', 2));
        nz = double(getF(problem, 'nz', max(1, np - 1)));
        model = tfest(data, np, nz);
    case 'ssest'
        n = double(getF(problem, 'order', 2));
        model = ssest(data, n);
    case 'arx'
        na = double(getF(problem, 'na', 2));
        nb = double(getF(problem, 'nb', 2));
        nk = double(getF(problem, 'nk', 1));
        model = arx(data, [na nb nk]);
    otherwise
        error('bma:advanced:badModel', 'system_id model 支持 tfest/ssest/arx');
end
try
    [~, fit] = compare(data, model);
catch
    fit = NaN;
end
res = struct();
res.ok = true;
res.model_type = kind;
res.fit_percent = fit;
res.data_csv = file;
res.time_step = ts;
res.n_samples = numel(t);
try
    res.model_text = evalc('disp(model)');
catch
    res.model_text = '';
end
% Artifacts: comparison figure + summary JSON.
figDir = fullfile(char(getF(opts, 'run_dir', pwd)), 'figures');
bma.util.ensureDir(figDir);
figPath = fullfile(figDir, 'system_identification.png');
try
    f = figure('Visible', 'off');
    compare(data, model);
    title(sprintf('System identification: %s', kind), 'Interpreter', 'none');
    exportgraphics(f, figPath, 'Resolution', 200);
    close(f);
    res.figure = figPath;
catch err
    res.figure = '';
    res.figure_warning = err.message;
end
res.summary = sprintf('System identification (%s): fit=%s%% on %d samples', ...
    kind, num2str(fit, '%.2f'), numel(t));
end

% =========================================================================
function res = symbolicSolve(problem, opts)
if ~isstruct(problem), error('bma:advanced:badProblem', 'symbolic 需要 problem 对象'); end
eqs = itemize(getF(problem, 'equations', {}));
vars = itemize(getF(problem, 'variables', {}));
if isempty(eqs) || isempty(vars)
    error('bma:advanced:badProblem', 'symbolic 需要 equations 与 variables');
end
try
    eqStr = cellfun(@char, eqs, 'UniformOutput', false);
    varStr = cellfun(@char, vars, 'UniformOutput', false);
    conds = itemize(getF(problem, 'conditions', {}));
    eqSym = cellfun(@str2sym, eqStr, 'UniformOutput', false);
    varSym = cellfun(@str2sym, varStr, 'UniformOutput', false);
    if isempty(conds)
        if numel(eqSym) == 1
            sol = dsolve(eqSym{1});
        else
            sol = dsolve(eqSym);
        end
    else
        condStr = cellfun(@char, conds, 'UniformOutput', false);
        condSym = cellfun(@str2sym, condStr, 'UniformOutput', false);
        if numel(eqSym) == 1
            sol = dsolve(eqSym{1}, condSym{1});
        else
            sol = dsolve(eqSym, condSym);
        end
    end
catch err
    error('bma:advanced:symbolic', 'dsolve 失败：%s', err.message);
end
res = struct();
res.ok = true;
res.equations = eqs;
res.variables = vars;
res.conditions = itemize(getF(problem, 'conditions', {}));
res.solution = char(sol);
res.solution_tex = '';
try, res.solution_tex = latex(sol); catch, end
res.summary = 'Symbolic ODE solution with dsolve';
end

% =========================================================================
function res = ssaSimulate(problem, opts) %#ok<INUSD>
%SSASIMULATE Exact Gillespie direct-method SSA for expression propensities.
if ~isstruct(problem), error('bma:advanced:badProblem', 'ssa 需要 problem 对象'); end
vars = itemize(getF(problem, 'variables', {}));
nS = numel(vars);
if nS < 1, error('bma:advanced:badProblem', 'ssa 需要 variables'); end
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
y0 = zeros(nS, 1);
for i = 1:nS
    y0(i) = round(double(getF(getF(vars{i}, 'initial', struct()), 'value', 0)));
    if y0(i) < 0, error('bma:advanced:badInitial', 'SSA 初始分子数必须非负'); end
end
params = itemize(getF(problem, 'parameters', {}));
pids = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
pvals = zeros(1, numel(params));
for j = 1:numel(params)
    pvals(j) = double(getF(getF(params{j}, 'value', struct()), 'value', 0));
end
reacs = itemize(getF(problem, 'reactions', {}));
nR = numel(reacs);
if nR < 1, error('bma:advanced:badProblem', 'ssa 需要 reactions'); end
S = zeros(nS, nR);
for r = 1:nR
    st = getF(reacs{r}, 'stoichiometry', struct());
    fn = fieldnames(st);
    for k = 1:numel(fn)
        i = find(strcmp(species, fn{k}), 1);
        if isempty(i), error('bma:advanced:unknownSpecies', 'SSA 反应引用未知变量 "%s"', fn{k}); end
        S(i, r) = st.(fn{k});
    end
end
tEnd = double(getF(problem, 'time_end', 20));
n = double(getF(problem, 'n', 101));
paths = double(getF(problem, 'paths', 50));
refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
for i = 1:nS, refs(species{i}) = sprintf('y(%d)', i); end
for j = 1:numel(pids), refs(pids{j}) = sprintf('p(%d)', j); end
refs('t') = 't';
rateFuns = cell(1, nR);
for r = 1:nR
    rate = getF(reacs{r}, 'rate', struct());
    expr = char(getF(rate, 'expression', ''));
    if isempty(expr)
        error('bma:advanced:ssaRate', 'SSA 反应 %d 需要 rate.expression（mass_action 请先展开为表达式）', r);
    end
    [code, ~] = bma.spec.expressionCode(expr, refs);
    rateFuns{r} = str2func(['@(t,y,p) ' code]);
end
t = linspace(0, tEnd, round(n)).';
Ymean = zeros(numel(t), nS);
Ystd = zeros(numel(t), nS);
for q = 1:paths
    y = y0;
    states = zeros(numel(t), nS);
    kOut = 1;
    tt = 0;
    maxEvents = 5e6;
    nev = 0;
    while kOut <= numel(t) && tt <= tEnd && nev < maxEvents
        while kOut <= numel(t) && t(kOut) <= tt
            states(kOut, :) = y.';
            kOut = kOut + 1;
        end
        if kOut > numel(t), break; end
        a = zeros(nR, 1);
        for r = 1:nR
            a(r) = max(0, rateFuns{r}(tt, y, pvals));
        end
        a0 = sum(a);
        if ~isfinite(a0) || a0 <= 0
            tt = tEnd + 1;
            break
        end
        tau = -log(max(rand(), realmin)) / a0;
        tt = tt + tau;
        nev = nev + 1;
        if tt > tEnd, break; end
        r = find(rand() <= cumsum(a) / a0, 1);
        y = y + S(:, r);
        if any(y < 0)
            y = max(y, 0);
        end
    end
    while kOut <= numel(t)
        states(kOut, :) = y.';
        kOut = kOut + 1;
    end
    Ymean = Ymean + states / paths;
    Ystd = Ystd + states.^2 / paths;
end
Ystd = sqrt(max(0, Ystd - Ymean.^2));
res = struct();
res.ok = true;
res.solver = 'gillespie_direct';
res.t = t;
res.mean = Ymean;
res.std = Ystd;
res.paths = paths;
res.species = species;
res.summary = sprintf('Exact Gillespie SSA: %d paths, %d reactions', paths, nR);
end

function res = sdeSimulate(problem, opts) %#ok<INUSD>
%SDESIMULATE Euler-Maruyama approximation (fixed step, drift/diffusion).
if ~isstruct(problem), error('bma:advanced:badProblem', 'sde 需要 problem 对象'); end
vars = itemize(getF(problem, 'variables', {}));
n = numel(vars);
if n < 1, error('bma:advanced:badProblem', 'sde 需要 variables'); end
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
y0 = zeros(n, 1);
for i = 1:n
    y0(i) = double(getF(getF(vars{i}, 'initial', struct()), 'value', 0));
end
params = itemize(getF(problem, 'parameters', {}));
pids = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
pvals = zeros(1, numel(params));
for j = 1:numel(params)
    pvals(j) = double(getF(getF(params{j}, 'value', struct()), 'value', 0));
end
tEnd = double(getF(problem, 'time_end', 10));
nSteps = double(getF(problem, 'n', 1001));
paths = double(getF(problem, 'paths', 20));
dt = tEnd / (nSteps - 1);
drift = makeFcn(char(getF(problem, 'drift', '')), species, pids, n);
diffusion = makeFcn(char(getF(problem, 'diffusion', '')), species, pids, n);
Y = zeros(nSteps, n, paths);
for q = 1:paths
    y = y0;
    Y(1, :, q) = y.';
    for k = 2:nSteps
        t = (k - 1) * dt;
        b = drift(t, y, pvals);
        d = diffusion(t, y, pvals);
        y = y + b(:) * dt + d(:) .* sqrt(dt) .* randn(n, 1);
        Y(k, :, q) = y.';
    end
end
t = linspace(0, tEnd, nSteps).';
meanY = mean(Y, 3);
stdY = std(Y, 0, 3);
res = struct();
res.ok = true;
res.solver = 'euler_maruyama';
res.t = t;
res.mean = meanY;
res.std = stdY;
res.paths = paths;
res.species = species;
res.spec = problem;
res.summary = sprintf('SDE Euler-Maruyama: %d paths, %d steps', paths, nSteps);
end

function fh = makeFcn(expr, species, pids, n)
if isempty(expr), error('bma:advanced:badProblem', 'sde 需要 drift/diffusion 表达式'); end
refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
for i = 1:n, refs(species{i}) = sprintf('y(%d)', i); end
for j = 1:numel(pids), refs(pids{j}) = sprintf('p(%d)', j); end
[code, ~] = bma.spec.expressionCode(expr, refs);
fh = str2func(['@(t,y,p) ' code]);
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

function items = itemize(x)
if iscell(x), items = x(:).';
elseif isstruct(x), items = num2cell(x(:).');
elseif isempty(x), items = {};
else, items = {x}; end
end
