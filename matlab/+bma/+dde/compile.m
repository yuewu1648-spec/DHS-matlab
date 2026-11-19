function m = compile(spec)
%COMPILE Compile a kind="dde" spec into a dde23-ready model structure.
%   m = bma.dde.compile(spec)
%
% v1 supports constant delays declared in the top-level `delays` array:
%   {"id":"tau1","lag":2,"unit":"h"}
% Rate expressions use delay(S, tau1); S is a variable id and tau1 a delay id.
% The time unit of each delay must equal time.unit (no silent conversion).
% Only expression rate laws are supported in v1; mass-action/MM/Hill are
% rejected with a clear error so a delayed rate is not silently misread.
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
spec = bma.spec.normalize(spec);
if ~isstruct(spec) || isempty(spec)
    error('bma:dde:badSpec', 'DDE 需要模型规格结构体');
end
if ~isfield(spec, 'kind') || ~strcmpi(char(spec.kind), 'dde')
    error('bma:dde:badKind', 'DDE 编译需要 kind="dde"');
end
time = getF(spec, 'time', struct());
timeUnit = char(getF(time, 'unit', 's'));
vars = itemize(getF(spec, 'variables', []));
params = itemize(getF(spec, 'parameters', []));
reacs = itemize(getF(spec, 'reactions', []));
outs = itemize(getF(spec, 'outputs', []));
nS = numel(vars);
nP = numel(params);
nR = numel(reacs);
if nS < 1 || nR < 1
    error('bma:dde:noModel', 'DDE 至少需要一个变量和一个反应');
end
species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
speciesUnits = cellfun(@(v) char(getF(v, 'unit', '')), vars, 'UniformOutput', false);
paramIds = cellfun(@(p) char(getF(p, 'id', '')), params, 'UniformOutput', false);
paramValues = zeros(1, nP);
paramUnits = cellfun(@(p) char(getF(p, 'unit', '')), params, 'UniformOutput', false);
for j = 1:nP
    v = getF(getF(params{j}, 'value', struct()), 'value', []);
    if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
        error('bma:dde:badParameter', '参数 "%s" 缺少有限数值', paramIds{j});
    end
    paramValues(j) = double(v);
end
% Delay declarations: constant (lag) or state/time-dependent (expression).
delays = itemize(getF(spec, 'delays', []));
if isempty(delays)
    error('bma:dde:noDelays', 'kind="dde" 需要顶层 delays:[{id,lag,unit}] 或 [{id,expression,unit}]');
end
neutral = logical(getF(spec, 'neutral', false));
if isfield(spec, 'dde_mode') && ~isempty(spec.dde_mode)
    mode = lower(char(spec.dde_mode));
elseif neutral
    mode = 'neutral';
elseif any(cellfun(@(d) isfield(d, 'expression') && ~isempty(d.expression), delays))
    mode = 'state_dependent';
else
    mode = 'constant';
end
if ~any(strcmp(mode, {'constant', 'state_dependent', 'neutral'}))
    error('bma:dde:badMode', 'dde_mode 支持 constant/state_dependent/neutral，收到 "%s"', mode);
end
nD = numel(delays);
lags = zeros(1, nD);
delayExprs = cell(1, nD);
delayFuns = cell(1, nD);
delayCodes = cell(1, nD);
delayIds = cell(1, nD);
for j = 1:nD
    d = delays{j};
    did = char(getF(d, 'id', ''));
    unit = char(getF(d, 'unit', timeUnit));
    if isempty(did)
        error('bma:dde:badDelay', '第 %d 个 delay 缺少 id', j);
    end
    if ~strcmp(unit, timeUnit)
        error('bma:dde:badDelayUnit', ...
            'delay "%s" 的 unit="%s" 与 time.unit="%s" 不一致；v1 不做延迟单位换算，请统一单位', ...
            did, unit, timeUnit);
    end
    expr = char(getF(d, 'expression', ''));
    if ~isempty(expr)
        if strcmp(mode, 'constant')
            error('bma:dde:badMode', 'delay "%s" 有 expression，但 dde_mode=constant', did);
        end
        refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
        for si = 1:nS, refs(species{si}) = sprintf('y(%d)', si); end
        for pj = 1:nP, refs(paramIds{pj}) = sprintf('p(%d)', pj); end
        refs('t') = 't';
        try
            [code, ~] = bma.spec.expressionCode(expr, refs);
            delayFuns{j} = str2func(['@(t,y,p) ' code]);
            delayCodes{j} = code;
        catch err
            error('bma:dde:delayCompile', 'delay "%s" 表达式编译失败：%s', did, err.message);
        end
        delayExprs{j} = expr;
    else
        lag = getF(d, 'lag', []);
        if ~isnumeric(lag) || ~isscalar(lag) || ~isfinite(lag) || lag < 0
            error('bma:dde:badDelay', 'delay "%s" 的 lag 必须是正有限数值（或提供 expression）', did);
        end
        lags(j) = double(lag);
    end
    delayIds{j} = did;
end
if strcmp(mode, 'constant') && any(lags <= 0)
    error('bma:dde:badDelay', '常量延迟必须 > 0');
end
% A state-dependent declaration whose expression is actually constant (e.g.
% delay tau, where tau is a parameter) is mathematically a constant delay.
% Route it through dde23 so it matches a lag declaration exactly.
requestedMode = mode;
if strcmp(mode, 'state_dependent') && any(~cellfun(@isempty, delayFuns))
    yProbe = zeros(nS, 1);
    for qi = 1:nS
        ini = getF(vars{qi}, 'initial', struct());
        yProbe(qi) = double(getF(ini, 'value', 0));
    end
    probeVals = zeros(3, nD);
    for si = 1:3
        tt = (si - 1) * 1.7;
        yy = yProbe + (si - 1) * 0.9;
        for dj = 1:nD
            if isempty(delayFuns{dj})
                probeVals(si, dj) = lags(dj);
            else
                probeVals(si, dj) = delayFuns{dj}(tt, yy, paramValues(:));
            end
        end
    end
    if all(isfinite(probeVals(:))) && all(probeVals(:) > 0) ...
            && all(max(probeVals, [], 1) - min(probeVals, [], 1) < 1e-12)
        lags = probeVals(1, :);
        delayFuns = cell(1, nD);
        delayCodes = cell(1, nD);
        mode = 'constant';
    end
end
if all(cellfun(@isempty, delayFuns))
    mDelays = lags;
else
    mDelays = [];
end
delayIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:nD
    delayIndex(delayIds{j}) = j;
end
% Species/parameter maps.
speciesIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for i = 1:nS
    speciesIndex(species{i}) = i;
end
paramIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:nP
    paramIndex(paramIds{j}) = j;
end
% Build time-delay rate functions.
S = zeros(nS, nR);
rateFuns = cell(1, nR);
rateCodes = cell(1, nR);
for r = 1:nR
    rid = char(getF(reacs{r}, 'id', ''));
    stoich = getF(reacs{r}, 'stoichiometry', struct());
    fn = fieldnames(stoich);
    for j = 1:numel(fn)
        if ~isKey(speciesIndex, fn{j})
            error('bma:dde:unknownSpecies', '反应 "%s" 的化学计量引用了未知变量 "%s"', rid, fn{j});
        end
        S(speciesIndex(fn{j}), r) = stoich.(fn{j});
    end
    rate = getF(reacs{r}, 'rate', struct());
    kind = lower(char(getF(rate, 'kind', '')));
    if ~strcmp(kind, 'expression')
        error('bma:dde:unsupportedRate', ...
            'DDE v1 只支持 expression 速率（延迟项写成 delay(S,tau)）；反应 "%s" 是 "%s"', rid, kind);
    end
    expr = char(getF(rate, 'expression', ''));
    [expr, delayRefs] = rewriteDelays(expr, speciesIndex, delayIndex, mode);
    refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for i = 1:nS
        refs(species{i}) = sprintf('y(%d)', i);
    end
    for j = 1:nP
        refs(paramIds{j}) = sprintf('p(%d)', j);
    end
    refs('t') = 't';
    keysD = delayRefs.keys;
    for j = 1:numel(keysD)
        refs(keysD{j}) = delayRefs(keysD{j});
    end
    try
        [code, ~] = bma.spec.expressionCode(expr, refs);
        rateFuns{r} = str2func(['@(t,y,Z,p) ' code]);
        rateCodes{r} = code;
    catch err
        error('bma:dde:rateCompile', '反应 "%s" 的延迟表达式无法编译：%s', rid, err.message);
    end
end
rhs = @(t, y, Z, p) localRhs(t, y, Z, p, S, rateFuns);
% History: constant vector from variables (or explicit history.value).
history = zeros(nS, 1);
historySpec = getF(spec, 'history', struct());
if isstruct(historySpec) && isfield(historySpec, 'value') && ~isempty(historySpec.value)
    hv = historySpec.value;
    if isnumeric(hv) && numel(hv) == nS
        history = hv(:);
        for i = 1:nS
            if ~isfinite(history(i))
                error('bma:dde:badHistory', 'history.value 含 NaN/Inf');
            end
        end
    else
        error('bma:dde:badHistory', 'history.value 必须是长度 %d 的数值向量', nS);
    end
else
    for i = 1:nS
        ini = getF(vars{i}, 'initial', struct());
        v = getF(ini, 'value', 0);
        if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
            error('bma:dde:badInitial', '变量 "%s" 初值无效', species{i});
        end
        history(i) = v;
    end
end
% Outputs: current-time expressions only (delayed outputs are not supported).
outFuns = cell(1, numel(outs));
outputCodes = cell(1, numel(outs));
for o = 1:numel(outs)
    expr = char(getF(outs{o}, 'expression', ''));
    refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for i = 1:nS
        refs(species{i}) = sprintf('y(%d)', i);
    end
    for j = 1:nP
        refs(paramIds{j}) = sprintf('p(%d)', j);
    end
    try
        [code, ~] = bma.spec.expressionCode(expr, refs);
        outFuns{o} = str2func(['@(y,p) ' code]);
        outputCodes{o} = code;
    catch err
        error('bma:dde:outputCompile', '输出 "%s" 无法编译：%s', ...
            char(getF(outs{o}, 'id', '')), err.message);
    end
end
m = struct();
m.kind = 'dde';
m.name = char(getF(spec, 'name', 'dde_model'));
m.title = char(getF(spec, 'title', m.name));
m.time = time;
m.species = species;
m.speciesUnits = speciesUnits;
m.speciesIndex = speciesIndex;
m.params = paramIds;
m.paramUnits = paramUnits;
m.paramValues = paramValues;
m.paramIndex = paramIndex;
m.n_species = nS;
m.n_params = nP;
m.n_reactions = nR;
m.S = S;
m.rhs = rhs;
m.rate_codes = rateCodes;
m.delay_codes = delayCodes;
m.output_codes = outputCodes;
m.mode = mode;
m.requested_mode = requestedMode;
m.neutral = strcmp(mode, 'neutral');
m.delays = mDelays;
m.delay_exprs = delayExprs;
m.delayFuns = delayFuns;
m.delayFun = @(t, y, p) localDelays(t, y, p, lags, delayFuns, mode);
m.delay_ids = delayIds;
m.history = history;
m.outputFuns = outFuns;
m.outputs = buildOutputStruct(outs, outFuns);
m.initial = history;
m.spec = spec;
m.warnings = {};
end

function dydt = localRhs(t, y, Z, p, S, rateFuns)
nR = numel(rateFuns);
rates = zeros(nR, 1);
for r = 1:nR
    rates(r) = rateFuns{r}(t, y(:), Z, p(:));
end
dydt = S * rates;
end

function d = localDelays(t, y, p, lags, delayFuns, mode) %#ok<INUSD>
if strcmp(mode, 'constant') || all(cellfun(@isempty, delayFuns))
    d = lags(:);
    return
end
d = zeros(numel(delayFuns), 1);
for j = 1:numel(delayFuns)
    if isempty(delayFuns{j})
        error('bma:dde:badDelay', '延迟 %d 缺少表达式', j);
    end
    d(j) = delayFuns{j}(t, y(:), p(:));
end
if any(~isfinite(d)) || any(d <= 0)
    error('bma:dde:badDelayValue', '状态依赖延迟必须为正有限值（当前 %s）', mat2str(d));
end
end

function [expr, refs] = rewriteDelays(expr, speciesIndex, delayIndex, mode)
% delay(S,tau) -> Z(i,j), delay_deriv(S,tau) -> Z(i,j) for neutral DDEs.
% This keeps the restricted expression parser unchanged and makes the delay
% index explicit. In neutral mode Z carries y'(delay), not y(delay).
refs = containers.Map('KeyType', 'char', 'ValueType', 'char');
pat = '(delay_deriv|delay)\(\s*([A-Za-z][A-Za-z0-9_]*)\s*,\s*([A-Za-z][A-Za-z0-9_]*)\s*\)';
[tokens, starts, ends] = regexp(expr, pat, 'tokens', 'start', 'end');
for k = numel(tokens):-1:1
    fn = tokens{k}{1};
    sid = tokens{k}{2};
    did = tokens{k}{3};
    if ~isKey(speciesIndex, sid)
        error('bma:dde:unknownSpecies', '%s(%s,%s) 引用了未知变量', fn, sid, did);
    end
    if ~isKey(delayIndex, did)
        error('bma:dde:unknownDelay', '%s(%s,%s) 引用了未声明的 delay', fn, sid, did);
    end
    if strcmp(fn, 'delay') && strcmp(mode, 'neutral')
        error('bma:dde:neutralState', ...
            'neutral DDE 的 ddendsd 回调只提供延迟导数；请用 delay_deriv(S,tau)，不要用 delay(S,tau)');
    end
    if strcmp(fn, 'delay_deriv') && ~strcmp(mode, 'neutral')
        error('bma:dde:neutralDeriv', 'delay_deriv(S,tau) 只适用于 neutral 模式');
    end
    key = sprintf('%s__%s_%s', fn, sid, did);
    refs(key) = sprintf('Z(%d,%d)', speciesIndex(sid), delayIndex(did));
    expr = [expr(1:starts(k) - 1) key expr(ends(k) + 1:end)];
end
end

function out = buildOutputStruct(outs, outFuns)
out = struct('id', {}, 'name', {}, 'unit', {}, 'fh', {});
for o = 1:numel(outs)
    out(o) = struct('id', char(getF(outs{o}, 'id', sprintf('out%d', o))), ...
        'name', char(getF(outs{o}, 'name', '')), ...
        'unit', char(getF(outs{o}, 'unit', '')), ...
        'fh', outFuns{o});
end
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end

function items = itemize(x)
if iscell(x)
    items = x(:).';
elseif isstruct(x)
    items = num2cell(x(:).');
elseif isempty(x)
    items = {};
else
    items = {x};
end
end
