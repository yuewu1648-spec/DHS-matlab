function m = compile(spec)
%COMPILE Compile a kind="bvp" spec into a bvp4c-ready model structure.
%   m = bma.bvp.compile(spec)
%
% Spec: kind="bvp", domain:{x0,x1,n}, bc:[{side:"left"|"right",
% expression:"..."}], variables/parameters/reactions/outputs. Rate expressions
% use the independent variable x and species ids. v1 supports expression rates
% only.
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
spec = bma.spec.normalize(spec);
if ~isstruct(spec) || ~strcmpi(char(getF(spec, 'kind', '')), 'bvp')
    error('bma:bvp:badKind', 'BVP 编译需要 kind="bvp"');
end
domain = getF(spec, 'domain', struct());
x0 = double(getF(domain, 'x0', 0));
x1 = double(getF(domain, 'x1', 1));
n = double(getF(domain, 'n', 101));
if ~isfinite(x0) || ~isfinite(x1) || x1 <= x0 || n < 2
    error('bma:bvp:badDomain', 'domain 需要 x1>x0 且 n>=2');
end
vars = itemize(getF(spec, 'variables', []));
params = itemize(getF(spec, 'parameters', []));
reacs = itemize(getF(spec, 'reactions', []));
outs = itemize(getF(spec, 'outputs', []));
bc = itemize(getF(spec, 'bc', []));
nS = numel(vars);
nP = numel(params);
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
paramIds = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
paramValues = zeros(1, nP);
for j = 1:nP
    v = getF(getF(params{j}, 'value', struct()), 'value', []);
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        error('bma:bvp:badParameter', '参数 "%s" 缺少有限数值', paramIds{j});
    end
    paramValues(j) = double(v);
end
if isempty(bc)
    error('bma:bvp:noBC', 'BVP 需要 bc 边值条件');
end
if numel(bc) ~= nS
    error('bma:bvp:bcCount', 'BVP 需要 %d 个边值条件（当前 %d 个）', nS, numel(bc));
end
% ODE RHS.
S = zeros(nS, numel(reacs));
rateFuns = cell(1, numel(reacs));
for r = 1:numel(reacs)
    rid = char(getF(reacs{r}, 'id', ''));
    stoich = getF(reacs{r}, 'stoichiometry', struct());
    fn = fieldnames(stoich);
    for j = 1:numel(fn)
        i = find(strcmp(species, fn{j}), 1);
        if isempty(i), error('bma:bvp:unknownSpecies', '反应 "%s" 引用未知变量 "%s"', rid, fn{j}); end
        S(i, r) = stoich.(fn{j});
    end
    rate = getF(reacs{r}, 'rate', struct());
    if ~strcmpi(char(getF(rate, 'kind', '')), 'expression')
        error('bma:bvp:unsupportedRate', 'BVP v1 只支持 expression 速率');
    end
    refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for i = 1:nS, refs(species{i}) = sprintf('y(%d)', i); end
    for j = 1:nP, refs(paramIds{j}) = sprintf('p(%d)', j); end
    refs('x') = 'x';
    try
        [code, ~] = bma.spec.expressionCode(char(getF(rate, 'expression', '')), refs);
        rateFuns{r} = str2func(['@(x,y,p) ' code]);
    catch err
        error('bma:bvp:rateCompile', '反应 "%s" 编译失败：%s', rid, err.message);
    end
end
odefun = @(x, y, p) localOde(x, y, p, S, rateFuns);
% Boundary residuals: refs are ya/yb depending on side.
bcfuns = cell(1, numel(bc));
for k = 1:numel(bc)
    side = lower(char(getF(bc{k}, 'side', '')));
    if ~any(strcmp(side, {'left', 'right'}))
        error('bma:bvp:badBC', 'bc[%d].side 必须是 left/right', k - 1);
    end
    refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for i = 1:nS
        if strcmp(side, 'left')
            refs(species{i}) = sprintf('ya(%d)', i);
        else
            refs(species{i}) = sprintf('yb(%d)', i);
        end
    end
    for j = 1:nP, refs(paramIds{j}) = sprintf('p(%d)', j); end
    try
        [code, ~] = bma.spec.expressionCode(char(getF(bc{k}, 'expression', '')), refs);
        bcfuns{k} = str2func(['@(ya,yb,p) ' code]);
    catch err
        error('bma:bvp:bcCompile', 'bc[%d] 编译失败：%s', k - 1, err.message);
    end
end
bcfun = @(ya, yb, p) localBc(ya, yb, p, bcfuns);
% Outputs (current x/y only).
outFuns = cell(1, numel(outs));
for o = 1:numel(outs)
    refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for i = 1:nS, refs(species{i}) = sprintf('y(%d)', i); end
    for j = 1:nP, refs(paramIds{j}) = sprintf('p(%d)', j); end
    refs('x') = 'x';
    try
        [code, ~] = bma.spec.expressionCode(char(getF(outs{o}, 'expression', '')), refs);
        outFuns{o} = str2func(['@(x,y,p) ' code]);
    catch err
        error('bma:bvp:outputCompile', '输出 "%s" 编译失败：%s', ...
            char(getF(outs{o}, 'id', '')), err.message);
    end
end
y0 = zeros(nS, 1);
for i = 1:nS
    v = getF(getF(vars{i}, 'initial', struct()), 'value', 0);
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        error('bma:bvp:badInitial', '变量 "%s" 初值无效', species{i});
    end
    y0(i) = v;
end
m = struct();
m.kind = 'bvp';
m.name = char(getF(spec, 'name', 'bvp_model'));
m.title = char(getF(spec, 'title', m.name));
m.domain = struct('x0', x0, 'x1', x1, 'n', n);
m.species = species;
m.params = paramIds;
m.paramValues = paramValues;
if nP > 0
    m.paramIndex = containers.Map(paramIds, num2cell(1:nP));
else
    m.paramIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
end
m.speciesIndex = containers.Map(species, num2cell(1:nS));
m.n_species = nS;
m.n_params = nP;
m.n_reactions = numel(reacs);
m.S = S;
m.odefun = odefun;
m.bcfun = bcfun;
m.initial = y0;
m.outputFuns = outFuns;
m.outputs = buildOutputStruct(outs, outFuns);
m.spec = spec;
m.time = struct('unit', char(getF(domain, 'unit', '1')), 'start', x0, 'end', x1, 'n', n);
end

function dydx = localOde(x, y, p, S, fns)
rates = zeros(numel(fns), 1);
for r = 1:numel(fns), rates(r) = fns{r}(x, y(:), p(:)); end
dydx = S * rates;
end

function r = localBc(ya, yb, p, fns)
r = zeros(numel(fns), 1);
for k = 1:numel(fns), r(k) = fns{k}(ya(:), yb(:), p(:)); end
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
