function out = optLocal(m, data, p0Fit, fitNames, fixedVals, opts)
%OPTLOCAL 单次局部有界最小二乘（lsqnonlin，失败退 fmincon/fminsearch）。
%   out = bma.fit.optLocal(m, data, p0Fit, fitNames, fixedVals, opts)
%
% 输入：
%   p0Fit      初始猜测（按 fitNames 顺序的列向量）
%   fitNames   参与拟合的参数 id（cellstr）
%   fixedVals  固定参数覆盖（struct：参数 id → 数值），也用于剖面似然中
%              把被扫描参数固定在当前扫描值
%   opts       字段：boundsFit(可选 2×p 或 lb/ub)、max_iter、max_fe、
%              solver、rtol、atol、maxstep
% 输出 out：
%   pFit, pAll, sse, residual, jac, exitflag, iterations, solver,
%   converged, message, pred, nRes, penalty_used, n_evaluations, n_failures
%
% 目标函数为加权残差平方和：r = sqrt(w).*(Y - Yhat)，缺失观测残差记 0；
% 仿真失败时返回大惩罚残差，避免优化器被 NaN 破坏；积分器警告在优化期间
% 统一关闭，失败次数记录到 out.n_failures 供上层汇总。

if nargin < 6 || isempty(opts)
    opts = struct();
end
fitNames = toCellstrLocal(fitNames);
fixedVals = sanitizeFixed(fixedVals);
nFit = numel(fitNames);
p0Fit = double(p0Fit(:));
if numel(p0Fit) ~= nFit
    if nFit == 0
        p0Fit = zeros(0, 1);
    else
        error('bma:fit:optLocalSize', '初始猜测长度 %d 与待拟合参数个数 %d 不一致。', ...
            numel(p0Fit), nFit);
    end
end

allNames = cellstr(m.params);
baseAll = baseParamVector(m);
mask = isfinite(data.Y);
yVals = data.Y;
yVals(~mask) = 0;
w = data.weights;
if isempty(w)
    w = ones(size(data.Y));
end
w(~mask) = 0;
sqrtW = sqrt(w);
dataScale = max(1, max(abs(yVals(:))));
nEntries = numel(yVals);
penaltyValue = 1e4 * dataScale * sqrt(max(1, nEntries));

% 提取上下界
[lb, ub] = fitBounds(opts, m, fitNames);
lb = lb(:);
ub = ub(:);
if any(lb > ub)
    error('bma:fit:bounds', '参数下界大于上界（%s）。', strjoin(fitNames, ', '));
end
p0Fit = clampToBounds(p0Fit, lb, ub);

% 优化期间关闭积分器警告（拟合试探点会触发大量 ode 失败警告）
wState = warning('off', 'all');
cleanerW = onCleanup(@() warning(wState)); %#ok<NASGU>
nEval = 0;
nFail = 0;
tStartAll = tic;
maxSeconds = getNum(opts, 'max_seconds', 60);
timedOut = false;

% 残差函数（嵌套函数，便于统计失败次数）
residualFcn = @residualsAt;

useLsq = nFit > 0;
solverUsed = 'none';
exitflag = 0;
iterations = 0;
message = '';
xBest = p0Fit;
rBest = [];
sseBest = Inf;
jac = zeros(nEntries, nFit);

if useLsq
    % --- 首选 lsqnonlin（有界、信赖域反射）---
    maxIter = getNum(opts, 'max_iter', 400);
    maxFE = getNum(opts, 'max_fe', max(2000, 60 * max(1, nFit)));
    fdStep = getNum(opts, 'fd_step', 1e-4);   % 相对有限差分步长（过大/过小都不稳）
    try
        lsqOpts = optimoptions('lsqnonlin', 'Display', 'off', ...
            'Algorithm', 'trust-region-reflective', ...
            'MaxIterations', maxIter, ...
            'MaxFunctionEvaluations', maxFE, ...
            'FiniteDifferenceStepSize', fdStep, ...
            'FunctionTolerance', 1e-10, ...
            'StepTolerance', 1e-10, ...
            'OptimalityTolerance', 1e-10, ...
            'OutputFcn', @(x, ov, state) timeGuard(x, ov, state, maxSeconds, tStartAll), ...
            'TypicalX', max(abs(p0Fit(:)), 1e-3));
        [xBest, resnorm, residualOut, exitflag, output, ~, jacOut] = ...
            lsqnonlin(residualFcn, p0Fit, lb, ub, lsqOpts);
        rBest = residualOut(:);
        sseBest = sum(rBest.^2);
        iterations = output.iterations;
        solverUsed = 'lsqnonlin';
        message = output.message;
        % A wall-clock OutputFcn stop is not a converged lsqnonlin result.
        % Try the fmincon fallback instead of reporting a false success.
        if exitflag <= 0 && (contains(message, '输出或绘图函数停止') ...
                || contains(message, 'OutputFcn', 'IgnoreCase', true))
            solverUsed = 'lsqnonlin-timeout';
            message = sprintf('%s（wall-clock 超时，转 fmincon）', message);
        end
        if ~isempty(jacOut)
            jac = jacOut;
        else
            jac = finiteDiffJacobian(residualFcn, xBest, lb, ub);
        end
    catch err
        message = sprintf('lsqnonlin 失败：%s', err.message);
        solverUsed = 'lsqnonlin-failed';
    end
end

% --- 退化路径 1：fmincon 最小化 0.5*||r||² ---
if useLsq && ~strcmp(solverUsed, 'lsqnonlin')
    try
        maxIter = getNum(opts, 'max_iter', 400);
        maxFE = getNum(opts, 'max_fe', max(2000, 60 * max(1, nFit)));
        sseFcn = @(x) 0.5 * sum(residualFcn(x).^2);
        fmOpts = optimoptions('fmincon', 'Display', 'off', ...
            'Algorithm', 'interior-point', ...
            'MaxIterations', maxIter, ...
            'MaxFunctionEvaluations', maxFE, ...
            'StepTolerance', 1e-10, ...
            'OptimalityTolerance', 1e-8);
        [xBest, ~, exitflag, output] = fmincon(sseFcn, p0Fit, [], [], [], [], ...
            lb, ub, [], fmOpts);
        rBest = residualFcn(xBest);
        sseBest = sum(rBest.^2);
        iterations = output.iterations;
        solverUsed = 'fmincon';
        message = sprintf('%s；fmincon 后：%s', message, output.message);
        jac = finiteDiffJacobian(residualFcn, xBest, lb, ub);
    catch err
        message = sprintf('%s；fmincon 失败：%s', message, err.message);
        solverUsed = 'fmincon-failed';
    end
end

% --- 退化路径 2：fminsearch + 边界罚函数 ---
if useLsq && ~ismember(solverUsed, {'lsqnonlin', 'fmincon'})
    try
        maxIter = getNum(opts, 'max_iter', 400);
        fsOpts = optimset('Display', 'off', 'MaxIter', maxIter, ...
            'MaxFunEvals', max(2000, 80 * max(1, nFit)));
        obj = @(x) boundedSse(residualFcn, x, lb, ub);
        [xBest, ~, exitflag, output] = fminsearch(obj, p0Fit, fsOpts);
        rBest = residualFcn(xBest);
        sseBest = sum(rBest.^2);
        iterations = output.iterations;
        solverUsed = 'fminsearch';
        message = sprintf('%s；fminsearch 后：%s', message, output.message);
        jac = finiteDiffJacobian(residualFcn, xBest, lb, ub);
    catch err
        message = sprintf('%s；fminsearch 失败：%s', message, err.message);
        solverUsed = 'fminsearch-failed';
    end
end

% 若全部失败，至少返回初始点的结果（不做静默成功）
if isempty(rBest)
    rBest = residualFcn(p0Fit);
    sseBest = sum(rBest.^2);
    xBest = p0Fit;
    exitflag = 0;
    solverUsed = 'none';
end

% 最终一致性：边界内、有限值
xBest = clampToBounds(xBest, lb, ub);
rCheck = residualFcn(xBest);
sseCheck = sum(rCheck.^2);
if sseCheck < sseBest
    sseBest = sseCheck;
    rBest = rCheck;
end
penaltyUsed = ~all(isfinite(rBest)) || any(abs(rBest) >= 0.99 * penaltyValue);

pAll = assembleAll(xBest, fitNames, fixedVals, baseAll, allNames);
pred = [];
try
    pred = bma.fit.simulatePredictions(m, data, pAll, opts);
catch err
    message = sprintf('%s；最终预测计算失败：%s', message, err.message);
end

out = struct();
out.pFit = xBest;
out.fitNames = fitNames;
out.pAll = pAll;
out.sse = sseBest;
out.residual = rBest;
out.jac = jac;
out.exitflag = exitflag;
out.iterations = iterations;
out.solver = solverUsed;
out.converged = exitflag > 0 && isfinite(sseBest) && ~penaltyUsed;
out.message = message;
out.pred = pred;
out.nRes = nEntries;
out.penalty_used = penaltyUsed;
out.n_evaluations = nEval;
out.n_failures = nFail;
out.timed_out = timedOut;

% ------------------------------------------------------------------
% 嵌套函数：加权残差
% ------------------------------------------------------------------
    function r = residualsAt(x)
        nEval = nEval + 1;
        try
            pAllX = assembleAll(x, fitNames, fixedVals, baseAll, allNames);
            predX = bma.fit.simulatePredictions(m, data, pAllX, opts);
            resid = data.Y - predX;
            resid(~mask) = 0;
            r = sqrtW(:) .* resid(:);
            if any(~isfinite(r))
                nFail = nFail + 1;
                r = repmat(penaltyValue, nEntries, 1);
            end
        catch
            nFail = nFail + 1;
            r = repmat(penaltyValue, nEntries, 1);
        end
    end
end

% ======================================================================
% 局部函数
% ======================================================================
function pAll = assembleAll(x, fitNames, fixedVals, baseAll, allNames)
%ASSEMBLEALL 把待拟合向量 + 固定覆盖组装成完整参数向量。
pAll = baseAll;
for k = 1:numel(fitNames)
    idx = find(strcmp(allNames, fitNames{k}), 1);
    if isempty(idx)
        error('bma:fit:paramUnknown', '未知参数：%s', fitNames{k});
    end
    pAll(idx) = x(k);
end
names = fieldnames(fixedVals);
for k = 1:numel(names)
    idx = find(strcmp(allNames, names{k}), 1);
    if ~isempty(idx)
        pAll(idx) = fixedVals.(names{k});
    end
end
end

function sse = boundedSse(residualFcn, x, lb, ub)
%BOUNDEDSSE fminsearch 用的边界罚函数。
pen = 0;
viol = 0;
for k = 1:numel(x)
    if x(k) < lb(k)
        viol = viol + (lb(k) - x(k)) / max(1, abs(lb(k)) + 1e-9);
    elseif x(k) > ub(k)
        viol = viol + (x(k) - ub(k)) / max(1, abs(ub(k)) + 1e-9);
    end
end
if viol > 0
    pen = 1e6 * viol^2;
end
r = residualFcn(x);
sse = sum(r.^2) + pen;
end

function J = finiteDiffJacobian(fcn, x, lb, ub)
%FINITEDIFFJACOBIAN 中心差分求残差雅可比（用于无 lsqnonlin 输出时）。
x = x(:);
n = numel(x);
r0 = fcn(x);
mRes = numel(r0);
J = zeros(mRes, n);
for k = 1:n
    h = 1e-6 * max(1, abs(x(k)));
    xp = x;
    xm = x;
    if x(k) + h <= ub(k)
        xp(k) = x(k) + h;
    end
    if x(k) - h >= lb(k)
        xm(k) = x(k) - h;
    end
    denom = xp(k) - xm(k);
    if denom == 0
        J(:, k) = 0;
        continue
    end
    J(:, k) = (fcn(xp) - fcn(xm)) / denom;
end
end

function [lb, ub] = fitBounds(opts, m, fitNames)
%FITBOUNDS 取待拟合参数的上下界（opts 覆盖优先）。
nFit = numel(fitNames);
lb = -1e6 * ones(nFit, 1);
ub = 1e6 * ones(nFit, 1);
if isfield(opts, 'lb') && isfield(opts, 'ub') ...
        && ~isempty(opts.lb) && ~isempty(opts.ub)
    lb = double(opts.lb(:));
    ub = double(opts.ub(:));
    if numel(lb) == 1, lb = repmat(lb, nFit, 1); end
    if numel(ub) == 1, ub = repmat(ub, nFit, 1); end
    return
end
if isfield(opts, 'specParams') && ~isempty(opts.specParams)
    params = opts.specParams;
    for k = 1:numel(fitNames)
        idx = find(strcmp({params.id}, fitNames{k}), 1);
        if isempty(idx)
            continue
        end
        v = paramValue(params(idx));
        b = paramBounds(params(idx), v);
        lb(k) = b(1);
        ub(k) = b(2);
    end
end
end

function b = paramBounds(p, v)
b = [];
if isfield(p, 'bounds') && ~isempty(p.bounds)
    b = double(p.bounds(:));
    if numel(b) == 2
        b = [min(b), max(b)];
    else
        b = [];
    end
elseif isfield(p, 'lower') && isfield(p, 'upper') ...
        && ~isempty(p.lower) && ~isempty(p.upper)
    b = [double(p.lower), double(p.upper)];
end
if isempty(b)
    if v > 0
        b = [max(1e-12, v * 1e-4), max(v * 1e4, 1e-9)];
    else
        b = [-1e6, 1e6];
    end
end
if b(1) == b(2)
    b = b + [-1e-9, 1e-9];
end
end

function v = paramValue(p)
v = 1;
if isfield(p, 'value')
    if isnumeric(p.value)
        v = double(p.value);
    elseif isstruct(p.value) && isfield(p.value, 'value')
        v = double(p.value.value);
    end
end
end

function x = clampToBounds(x, lb, ub)
x = double(x(:));
x = min(max(x, lb(:)), ub(:));
end

function baseAll = baseParamVector(m)
%BASEPARAMVECTOR 以 m.spec 参数默认值为基准的完整参数向量。
baseAll = zeros(numel(m.params), 1);
spec = struct();
if isfield(m, 'spec')
    spec = m.spec;
end
for k = 1:numel(m.params)
    name = m.params{k};
    val = 0;
    if isfield(spec, 'parameters') && ~isempty(spec.parameters)
        idx = find(strcmp({spec.parameters.id}, name), 1);
        if ~isempty(idx)
            val = paramValue(spec.parameters(idx));
        end
    end
    if isfield(m, 'paramValues') && numel(m.paramValues) == numel(m.params)
        val = double(m.paramValues(k));
    end
    baseAll(k) = val;
end
end

function names = toCellstrLocal(x)
if isempty(x)
    names = {};
elseif iscell(x)
    names = cellfun(@(s) char(s), x(:).', 'UniformOutput', false);
elseif isstring(x)
    names = cellstr(x(:).');
elseif ischar(x)
    parts = strtrim(strsplit(x, ','));
    names = parts(~cellfun(@isempty, parts));
else
    names = {};
end
end

function s = sanitizeFixed(s)
if isempty(s)
    s = struct();
elseif isa(s, 'containers.Map')
    out = struct();
    k = keys(s);
    for i = 1:numel(k)
        out.(char(k{i})) = double(s(k{i}));
    end
    s = out;
end
end

function v = getNum(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
else
    v = default;
end
end

function stop = timeGuard(~, ~, ~, maxSeconds, tStartAll)
% OutputFcn-compatible wall-clock stop. The anonymous wrapper above captures
% the per-start budget and start tic; @timeGuard alone used to reference an
% undefined function (ISSUE-005).
stop = isfinite(maxSeconds) && maxSeconds > 0 && toc(tStartAll) > maxSeconds;
end
