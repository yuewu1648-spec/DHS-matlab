function m = compile(spec)
%COMPILE Compile a kind="dae" spec for ode15i/decic.
%   m = bma.dae.compile(spec)
%
% Spec has top-level `dae.residuals`: residual expressions F(t,y,y')=0.
% Species derivatives are written as <id>dot (e.g. xdot); species values as
% <id>; parameters as ids. `dae.initial_derivative` is an optional vector for
% decic's initial guess. v1 is fully implicit ODE/DAE (index-1 practical limit
% of ode15i); higher-index systems need index reduction/manual formulation.
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
spec = bma.spec.normalize(spec);
if ~isstruct(spec) || ~strcmpi(char(getF(spec, 'kind', '')), 'dae')
    error('bma:dae:badKind', 'DAE 编译需要 kind="dae"');
end
time = getF(spec, 'time', struct());
vars = itemize(getF(spec, 'variables', []));
params = itemize(getF(spec, 'parameters', []));
outs = itemize(getF(spec, 'outputs', []));
dae = getF(spec, 'dae', struct());
residuals = itemize(getF(dae, 'residuals', []));
nS = numel(vars);
nP = numel(params);
if nS < 1 || isempty(residuals)
    error('bma:dae:noModel', 'DAE 需要 variables 与非空 dae.residuals');
end
if numel(residuals) ~= nS
    error('bma:dae:residualCount', 'DAE 需要 %d 条残差方程（当前 %d）', nS, numel(residuals));
end
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
paramIds = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
paramValues = zeros(1, nP);
for j = 1:nP
    v = getF(getF(params{j}, 'value', struct()), 'value', []);
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        error('bma:dae:badParameter', '参数 "%s" 缺少有限数值', paramIds{j});
    end
    paramValues(j) = double(v);
end
refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
for i = 1:nS
    refs(species{i}) = sprintf('y(%d)', i);
    refs([species{i} 'dot']) = sprintf('yp(%d)', i);
end
for j = 1:nP
    refs(paramIds{j}) = sprintf('p(%d)', j);
end
refs('t') = 't';
resFuns = cell(1, numel(residuals));
resCodes = cell(1, numel(residuals));
for k = 1:numel(residuals)
    try
        [code, ~] = bma.spec.expressionCode(char(residuals{k}), refs);
        resFuns{k} = str2func(['@(t,y,yp,p) ' code]);
        resCodes{k} = code;
    catch err
        error('bma:dae:residualCompile', '残差 %d 编译失败：%s', k, err.message);
    end
end
residual = @(t, y, yp, p) localResidual(t, y, yp, p, resFuns);
y0 = zeros(nS, 1);
for i = 1:nS
    v = getF(getF(vars{i}, 'initial', struct()), 'value', 0);
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        error('bma:dae:badInitial', '变量 "%s" 初值无效', species{i});
    end
    y0(i) = v;
end
yp0 = zeros(nS, 1);
if isfield(dae, 'initial_derivative') && ~isempty(dae.initial_derivative)
    v = dae.initial_derivative;
    if ~isnumeric(v) || numel(v) ~= nS
        error('bma:dae:badInitialDerivative', 'dae.initial_derivative 必须是长度 %d 的数值向量', nS);
    end
    yp0 = v(:);
end
outFuns = cell(1, numel(outs));
for o = 1:numel(outs)
    try
        [code, ~] = bma.spec.expressionCode(char(getF(outs{o}, 'expression', '')), refs);
        outFuns{o} = str2func(['@(t,y,p) ' code]);
    catch err
        error('bma:dae:outputCompile', '输出 "%s" 编译失败：%s', ...
            char(getF(outs{o}, 'id', '')), err.message);
    end
end
m = struct();
m.kind = 'dae';
m.name = char(getF(spec, 'name', 'dae_model'));
m.title = char(getF(spec, 'title', m.name));
m.time = time;
m.species = species;
m.speciesIndex = containers.Map(species, num2cell(1:nS));
m.params = paramIds;
m.paramValues = paramValues;
if nP > 0
    m.paramIndex = containers.Map(paramIds, num2cell(1:nP));
else
    m.paramIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
end
m.n_species = nS;
m.n_params = nP;
m.n_residuals = numel(residuals);
m.residual = residual;
m.residual_codes = resCodes;
m.initial = y0;
m.initial_derivative = yp0;
m.outputFuns = outFuns;
m.outputs = buildOutputStruct(outs, outFuns);
m.spec = spec;
m.warnings = {};
end

function r = localResidual(t, y, yp, p, fns)
r = zeros(numel(fns), 1);
for k = 1:numel(fns)
    r(k) = fns{k}(t, y(:), yp(:), p(:));
end
end

function out = buildOutputStruct(outs, fns)
out = struct('id', {}, 'name', {}, 'unit', {}, 'fh', {});
for o = 1:numel(outs)
    out(o) = struct('id', char(getF(outs{o}, 'id', sprintf('out%d', o))), ...
        'name', char(getF(outs{o}, 'name', '')), ...
        'unit', char(getF(outs{o}, 'unit', '')), 'fh', fns{o});
end
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
