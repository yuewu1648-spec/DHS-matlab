function [solMat, methods, residuals, stats, warnings, notes] = steadyStates(m, opts)
%STEADYSTATES 求 ODE 的非负物理稳态（私有函数，供 bma.model.analyze 调用）。
%   [solMat, methods, residuals, stats, warnings, notes] = steadyStates(m, opts)
%
% 物理稳态 = 满足 dydt=0、非负、且位于初始状态所在守恒流形上的状态：
%   - 无守恒律：直接解 f(y)=0（符号 solve/vpasolve 优先，fsolve 多起点补充）；
%   - 有守恒律：解增广方程 [f(y); Z'*(y-y0)] = 0（lsqnonlin），
%     避免把守恒流形外的伪稳态（f≈0 但守恒量漂移的点）当成稳态。
% 之后按容差去重，并统计 total_found（候选数）与 physical_count（物理稳态数）。
%
% 输出：
%   solMat    nS×K 数值矩阵（每列一个稳态）
%   methods   1×K cellstr
%   residuals 1×K 残差范数
%   stats     struct('total_found', 候选解总数, 'physical_count', K, 'methods', cellstr)
%   warnings / notes 中文警告/说明
nS = m.n_species;
p = m.paramValues;
y0 = m.initial(:);
solMat = zeros(nS, 0);
methods = {};
residuals = zeros(1, 0);
warnings = {};
notes = {};
stats = struct('total_found', 0, 'physical_count', 0, 'methods', {{}});
stats.symbolic = struct('mode', 'auto', 'attempted', false, 'skipped', false, ...
    'reason', '', 'complexity', struct(), 'max_states', 6, ...
    'max_score', 12, 'elapsed_ms', 0);
if nS == 0
    return
end
if ~isfield(opts, 'multistart') || isempty(opts.multistart) || ~isnumeric(opts.multistart)
    nStarts = 10;
else
    nStarts = max(4, round(opts.multistart));
end

% ---- 符号求解难度预判（issue 0.5.0 / I1） --------------------------------
% vpasolve 对高维有理非线性方程组可能进入不可中断的长搜索；MATLAB 服务是
% 单线程的，一旦发生就会让后续所有 RPC 排队。默认只对“小且低复杂度”的模型
% 尝试符号求解；其余模型直接走数值多起点，并在结果中明确记录原因与替代方法。
symMode = 'auto';
if isfield(opts, 'symbolic') && ~isempty(opts.symbolic)
    symMode = lower(char(opts.symbolic));
end
if ~ismember(symMode, {'auto', 'on', 'off'})
    error('bma:model:badSymbolicMode', ...
        'options.symbolic 必须是 auto / on / off，实际为 "%s"。', symMode);
end
maxSymbolicStates = getOptNum(opts, 'symbolic_max_states', 6);
maxSymbolicScore = getOptNum(opts, 'symbolic_max_score', 12);
complexity = symbolicComplexity(m);
allowSymbolic = strcmp(symMode, 'on') || (strcmp(symMode, 'auto') && ...
    nS <= maxSymbolicStates && complexity.score <= maxSymbolicScore);
stats.symbolic.mode = symMode;
stats.symbolic.complexity = complexity;
stats.symbolic.max_states = maxSymbolicStates;
stats.symbolic.max_score = maxSymbolicScore;
symbolicReason = '';
if strcmp(symMode, 'off')
    symbolicReason = 'options.symbolic="off"：调用方显式关闭符号求解';
elseif ~allowSymbolic && strcmp(symMode, 'auto')
    if nS > maxSymbolicStates
        symbolicReason = sprintf('状态数 %d > symbolic_max_states=%d', nS, maxSymbolicStates);
    else
        symbolicReason = sprintf('符号复杂度 score=%g > symbolic_max_score=%g', ...
            complexity.score, maxSymbolicScore);
    end
end
if ~isempty(symbolicReason)
    stats.symbolic.skipped = true;
    stats.symbolic.reason = symbolicReason;
    notes{end+1} = sprintf(['符号稳态求解已跳过（%s）；改用多起点数值搜索 + 数值 ' ...
        'Jacobian/特征值。可用 options.symbolic="on" 强制尝试，但高维非线性方程组可能长时间不返回。'], ...
        symbolicReason);
end
rhs0 = m.rhs(0, y0, p);
rhsScale = max(1, norm(rhs0));
tolRhs = 1e-8 * rhsScale;
tolCons = 1e-8;

% ---- 守恒律（用于物理分支筛选） ----
Z = zeros(nS, 0);
c = zeros(0, 1);
try
    [Z, ~, ~] = bma.model.leftNullspace(m.S);
    if ~isempty(Z)
        c = Z.' * y0;
    end
catch
    Z = zeros(nS, 0);
end
nLaws = size(Z, 2);
if nLaws > 0
    notes{end+1} = sprintf(['检测到 %d 个守恒律：稳态求解加入守恒约束 Z''(y-y0)=0，' ...
        '只保留与初始状态同一物理分支上的稳态。'], nLaws);
end

candidates = zeros(nS, 0);
candMethods = {};
candResiduals = zeros(1, 0);
candCons = zeros(1, 0);
totalFound = 0;

% ---- 1) 无守恒律且难度允许时优先符号求解 ----
if nLaws == 0 && ~stats.symbolic.skipped
    hasMinMax = false;
    for r = 1:m.n_reactions
        if ~isempty(regexp(m.fluxText{r}, '(^|[^A-Za-z0-9_])min\s*\(|(^|[^A-Za-z0-9_])max\s*\(', 'once'))
            hasMinMax = true;
            break
        end
    end
    if hasMinMax
        subst = true;
        if isfield(opts, 'substitute_guards') && ~isempty(opts.substitute_guards)
            subst = logical(opts.substitute_guards);
        end
        if subst
            % Strip numeric min/max guards (e.g. max(x, 0)) for the symbolic
            % attempt only; numeric steady states still use the exact RHS.
            m2 = m;
            stripped = {};
            for r = 1:m.n_reactions
                [cleanTxt, changed] = stripNumericGuards(m.fluxText{r});
                if changed
                    m2.fluxText{r} = cleanTxt;
                    stripped{end+1} = struct('reaction', m.reactions(r).id, ...
                        'original', m.fluxText{r}, 'cleaned', cleanTxt); %#ok<AGROW>
                end
            end
            if isempty(stripped)
                stats.symbolic.skipped = true;
                stats.symbolic.reason = '速率表达式含无法剥离的 min/max';
                notes{end+1} = '速率表达式包含无法识别的 min/max 形式，跳过符号稳态求解。';
            else
                notes{end+1} = sprintf(['速率表达式含数值 min/max 护栏：为符号稳态分析剥离了 %d 处' ...
                    '（数值稳态仍使用原始 RHS）。'], numel(stripped));
                stats.guard_substitution = struct('requested', true, ...
                    'attempted', true, 'stripped', {stripped});
                stats.symbolic.attempted = true;
                tSym = tic;
                try
                    [symSols, symMethod] = symbolicSteadyStates(m2);
                    if ~isempty(symSols)
                        notes{end+1} = sprintf('符号求解得到 %d 个候选稳态（%s）。', size(symSols, 2), symMethod);
                        for k = 1:size(symSols, 2)
                            y = symSols(:, k);
                            candidates(:, end+1) = y; %#ok<AGROW>
                            candMethods{end+1} = symMethod; %#ok<AGROW>
                            candResiduals(end+1) = norm(m.rhs(0, y, p)); %#ok<AGROW>
                            candCons(end+1) = 0; %#ok<AGROW>
                            totalFound = totalFound + 1;
                        end
                    end
                catch err
                    warnings{end+1} = sprintf('符号稳态求解失败（%s），使用数值多起点。', err.message); %#ok<AGROW>
                end
                stats.symbolic.elapsed_ms = round(toc(tSym) * 1000);
                notes{end+1} = '符号求解仅用于候选初值；最终稳态仍按原始（含护栏）RHS 校验。';
            end
        else
            stats.symbolic.skipped = true;
            stats.symbolic.reason = '速率表达式含 min/max 且 options.substitute_guards=false';
            notes{end+1} = '速率表达式包含 min/max 等非光滑函数，跳过符号稳态求解。';
        end
    else
        stats.symbolic.attempted = true;
        tSym = tic;
        try
            [symSols, symMethod] = symbolicSteadyStates(m);
            if ~isempty(symSols)
                notes{end+1} = sprintf('符号求解得到 %d 个候选稳态（%s）。', size(symSols, 2), symMethod);
                for k = 1:size(symSols, 2)
                    y = symSols(:, k);
                    candidates(:, end+1) = y; %#ok<AGROW>
                    candMethods{end+1} = symMethod; %#ok<AGROW>
                    candResiduals(end+1) = norm(m.rhs(0, y, p)); %#ok<AGROW>
                    candCons(end+1) = 0; %#ok<AGROW>
                    totalFound = totalFound + 1;
                end
            else
                notes{end+1} = sprintf('符号求解未得到显式稳态（%s），使用数值多起点。', symMethod);
            end
        catch err
            warnings{end+1} = sprintf('符号稳态求解失败（%s），使用数值多起点。', err.message); %#ok<AGROW>
        end
        stats.symbolic.elapsed_ms = round(toc(tSym) * 1000);
    end
elseif nLaws > 0 && ~stats.symbolic.skipped
    stats.symbolic.skipped = true;
    stats.symbolic.reason = '存在守恒律：改用带守恒约束的数值多起点';
end

% ---- 2) 数值多起点（有守恒律时带守恒约束）----
maxNumericSeconds = getOptNum(opts, 'numeric_budget_seconds', 120);
if exist('fsolve', 'file') == 2
    try
        [numSols, numMethods, numRes, numCons, numTotal, w2, numericStopped] = ...
            numericMultistart(m, nStarts, Z, c, rhsScale, maxNumericSeconds);
        warnings = [warnings, w2];
        for k = 1:size(numSols, 2)
            candidates(:, end+1) = numSols(:, k); %#ok<AGROW>
            candMethods{end+1} = numMethods{k}; %#ok<AGROW>
            candResiduals(end+1) = numRes(k); %#ok<AGROW>
            candCons(end+1) = numCons(k); %#ok<AGROW>
        end
        totalFound = totalFound + numTotal;
        stats.numeric = struct('budget_seconds', maxNumericSeconds, ...
            'stopped_early', logical(numericStopped));
    catch err
        warnings{end+1} = sprintf('数值多起点稳态搜索失败：%s', err.message);
    end
else
    warnings{end+1} = 'Optimization Toolbox 的 fsolve/lsqnonlin 不可用，仅返回符号求解结果。';
end

% ---- 3) 物理筛选 + 去重 ----
for k = 1:size(candidates, 2)
    y = candidates(:, k);
    if any(~isfinite(y)) || any(y < -1e-7)
        continue
    end
    y(y < 0) = 0;
    if norm(m.rhs(0, y, p)) > max(tolRhs, 1e-7 * (1 + norm(y)))
        continue
    end
    if nLaws > 0
        consErr = norm(Z.' * (y - y0));
        if consErr > tolCons * (1 + norm(c))
            continue
        end
        % 守恒约束投影（消除数值微漂移）
        try
            y = y - Z * ((Z.' * Z) \ (Z.' * (y - y0)));
            y(y < 0 & y > -1e-9) = 0;
        catch
        end
    end
    % 数值噪声清零（避免报告里出现 -2.3e-08 这样的伪负值）
    tolZero = 1e-7 * max(1, max(abs(y)));
    y(abs(y) < tolZero) = 0;
    dup = false;
    for j = 1:size(solMat, 2)
        if norm(y - solMat(:, j)) <= 1e-5 * (1 + norm(y))
            dup = true;
            break
        end
    end
    if dup
        continue
    end
    solMat(:, end+1) = y; %#ok<AGROW>
    methods{end+1} = candMethods{k}; %#ok<AGROW>
    residuals(end+1) = norm(m.rhs(0, y, p)); %#ok<AGROW>
end

% ---- 3.5) 合并连续稳态族（守恒系统沿守恒流形的中点为稳态）----
merged = 0;
if size(solMat, 2) > 1 && nLaws > 0
    try
        rhsScale2 = max(1, norm(m.rhs(0, y0, p)));
        distToY0 = zeros(1, size(solMat, 2));
        for k = 1:size(solMat, 2)
            distToY0(k) = norm(solMat(:, k) - y0);
        end
        [~, order] = sort(distToY0);
        keep = false(1, size(solMat, 2));
        for ii = 1:numel(order)
            i = order(ii);
            sameFamily = false;
            for jj = 1:numel(order)
                j = order(jj);
                if ~keep(j)
                    continue
                end
                mid = (solMat(:, i) + solMat(:, j)) / 2;
                if norm(m.rhs(0, mid, p)) <= 1e-6 * rhsScale2
                    sameFamily = true;
                    break
                end
            end
            if ~sameFamily
                keep(i) = true;
            else
                merged = merged + 1;
            end
        end
        if any(keep)
            solMat = solMat(:, keep);
            methods = methods(keep);
            residuals = residuals(keep);
        end
    catch
        merged = 0;
    end
    if merged > 0
        notes{end+1} = sprintf(['检测到连续稳态族（守恒系统沿守恒流形存在无穷多稳态），' ...
            '已合并 %d 个候选，仅保留距初值最近的代表点。'], merged);
    end
end

% ---- 4) 汇总 ----
if totalFound > size(solMat, 2)
    notes{end+1} = sprintf(['数值搜索共得到 %d 个候选解，经“非负 + 守恒 + 残差 + 去重”' ...
        '筛选后保留 %d 个物理稳态。'], totalFound, size(solMat, 2));
end
if size(solMat, 2) == 0
    warnings{end+1} = '未找到非负物理稳态（可能无稳态、或数值搜索未收敛）。';
else
    notes{end+1} = sprintf('物理稳态搜索完成：保留 %d 个（方法：%s）。', ...
        size(solMat, 2), strjoin(unique(methods), ' / '));
end
stats.total_found = totalFound;
stats.physical_count = size(solMat, 2);
stats.methods = unique(methods);
end

% =========================================================================
function [sols, methods, residuals, consErrs, totalFound, warnings, stoppedEarly] = ...
    numericMultistart(m, nStarts, Z, c, rhsScale, maxSeconds)
warnings = {};
stoppedEarly = false;
nS = m.n_species;
p = m.paramValues;
y0 = m.initial(:);
nLaws = size(Z, 2);
useConstrained = nLaws > 0 && exist('lsqnonlin', 'file') == 2;
sols = zeros(nS, 0);
methods = {};
residuals = zeros(1, 0);
consErrs = zeros(1, 0);
totalFound = 0;
if useConstrained
    fun = @(y) [m.rhs(0, y, p); Z.' * (y - y0)];
    optName = 'lsqnonlin';
else
    fun = @(y) m.rhs(0, y, p);
    optName = 'fsolve';
end
% 确定性随机种子（结果可复现）
oldState = rng;
try
    rng(42, 'twister');
catch
end
total = max(4, nStarts);
starts = zeros(nS, total);
starts(:, 1) = y0;
starts(:, 2) = zeros(nS, 1);
starts(:, 3) = max(abs(y0), 1);
scale = max(1, abs(y0));
nLog = max(0, floor((total - 3) / 2));
for k = 1:nLog
    starts(:, 3 + k) = scale .* (10 .^ (3 * rand(nS, 1) - 1));
end
for k = (3 + nLog + 1):total
    starts(:, k) = max(0, y0 + scale .* (2 * rand(nS, 1) - 1) .* (10 .^ (2 * rand(nS, 1) - 1)));
end
try
    rng(oldState);
catch
end
% 把起点投影到守恒流形上（若存在守恒律）
if nLaws > 0
    for k = 1:size(starts, 2)
        try
            starts(:, k) = starts(:, k) - Z * ((Z.' * Z) \ (Z.' * (starts(:, k) - y0)));
        catch
        end
    end
end
if useConstrained
    opts = optimoptions('lsqnonlin', 'Display', 'off', ...
        'MaxIterations', 2000, 'MaxFunctionEvaluations', 30000, ...
        'FunctionTolerance', 1e-14, 'StepTolerance', 1e-14);
else
    opts = optimoptions('fsolve', 'Display', 'off', ...
        'MaxIterations', 2000, 'MaxFunctionEvaluations', 30000, ...
        'FunctionTolerance', 1e-14, 'StepTolerance', 1e-14);
end
tStart = tic;
for k = 1:size(starts, 2)
    if toc(tStart) > maxSeconds
        stoppedEarly = true;
        warnings{end+1} = sprintf(['数值稳态多起点达到 %.0f s 预算，已停止剩余起点' ...
            '（已完成 %d/%d；可用 options.numeric_budget_seconds 调整）。'], ...
            maxSeconds, k - 1, size(starts, 2)); %#ok<AGROW>
        break
    end
    try
        if useConstrained
            [ys, resnorm, ~, exitflag] = lsqnonlin(fun, starts(:, k), [], [], opts); %#ok<ASGLU>
        else
            [ys, resnorm, exitflag] = fsolve(fun, starts(:, k), opts); %#ok<ASGLU>
        end
    catch
        continue
    end
    if isempty(ys) || ~all(isfinite(ys)) || any(imag(ys) ~= 0) %#ok<ISMAT>
        continue
    end
    ys = real(ys);
    if any(ys < -1e-7)
        continue
    end
    totalFound = totalFound + 1;
    if nLaws > 0
        consErr = norm(Z.' * (ys - y0));
    else
        consErr = 0;
    end
    sols(:, end+1) = ys; %#ok<AGROW>
    if useConstrained
        methods{end+1} = 'lsqnonlin+守恒约束'; %#ok<AGROW>
    else
        methods{end+1} = 'fsolve'; %#ok<AGROW>
    end
    residuals(end+1) = norm(m.rhs(0, ys, p)); %#ok<AGROW>
    consErrs(end+1) = consErr; %#ok<AGROW>
end
if ~isempty(sols) && totalFound == 0
    totalFound = size(sols, 2);
end
end

% =========================================================================
% 符号稳态求解（无守恒律时使用）
% =========================================================================
function [sols, methodName] = symbolicSteadyStates(m)
sols = zeros(m.n_species, 0);
methodName = 'symbolic';
if isempty(ver('symbolic')) || exist('str2sym', 'file') == 0
    methodName = 'symbolic(unavailable)';
    return
end
nS = m.n_species;
rateStr = cell(1, m.n_reactions);
for r = 1:m.n_reactions
    rateStr{r} = substituteParams(m.fluxText{r}, m);
end
try
    vsym = cell(1, m.n_reactions);
    for r = 1:m.n_reactions
        vsym{r} = str2sym(rateStr{r});
    end
    vars = cell(1, nS);
    for i = 1:nS
        vars{i} = sym(m.species{i});
    end
    vcol = vertcat(vsym{:});
    eqs = m.S * vcol == 0;
catch err
    methodName = sprintf('symbolic(parse-failed:%s)', err.message);
    return
end
isLinear = false;
try
    Jsym = jacobian(eqs, [vars{:}]);
    isLinear = isempty(symvar(Jsym));
catch
    isLinear = false;
end
try
    if isLinear
        methodName = 'symbolic(solve)';
        res = solve(eqs, [vars{:}], 'ReturnConditions', false);
    else
        methodName = 'symbolic(vpasolve)';
        res = vpasolve(eqs, [vars{:}]);
    end
catch
    sols = zeros(nS, 0);
    return
end
sols = extractSymSolutions(res, vars, nS);
if ~isempty(sols)
    good = all(isfinite(sols), 1) & all(sols >= -1e-9, 1);
    sols = sols(:, good);
    sols(sols < 0 & sols > -1e-9) = 0;
end
end

function sols = extractSymSolutions(res, vars, nS)
sols = zeros(nS, 0);
if isempty(res)
    return
end
try
    if isstruct(res)
        for k = 1:numel(res)
            vec = zeros(nS, 1);
            ok = true;
            for i = 1:nS
                name = char(vars{i});
                if ~isfield(res(k), name)
                    ok = false;
                    break
                end
                val = double(res(k).(name));
                if ~isempty(val) && (~isreal(val) || ~isfinite(val))
                    ok = false;
                    break
                end
                vec(i) = real(val);
            end
            if ok
                sols(:, end+1) = vec; %#ok<AGROW>
            end
        end
    elseif isa(res, 'sym')
        d = double(res);
        if isvector(d) && numel(d) == nS
            sols = d(:);
        elseif ismatrix(d) && size(d, 1) == nS
            sols = real(d);
        end
    end
catch
    sols = zeros(nS, 0);
end
end

function expr = substituteParams(expr, m)
for j = numel(m.params):-1:1
    expr = regexprep(expr, tokenPattern(m.params{j}), numLiteral(m.paramValues(j)));
end
for k = numel(m.compartmentIds):-1:1
    expr = regexprep(expr, tokenPattern(m.compartmentIds{k}), numLiteral(m.compartmentVolumes(k)));
end
end

function pat = tokenPattern(id)
pat = ['(?<![A-Za-z0-9_])' id '(?![A-Za-z0-9_])'];
end

function s = numLiteral(v)
s = sprintf('%.17g', v);
end


% =========================================================================
function [out, changed] = stripNumericGuards(text)
%STRIPNUMERICGUARDS Remove purely numeric min/max guards from one expression.
%   max(expr, 3) -> expr ; min(1, expr) -> expr ; nested forms are peeled
%   iteratively. Non-numeric guards (e.g. min(x,y)) are left untouched.
out = char(text);
changed = false;
numPat = '[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?';
for iter = 1:20
    before = out;
    out = regexprep(out, ['max\s*\(\s*([^,()]+?)\s*,\s*(' numPat ')\s*\)'], '$1');
    out = regexprep(out, ['max\s*\(\s*(' numPat ')\s*,\s*([^,()]+?)\s*\)'], '$2');
    out = regexprep(out, ['min\s*\(\s*([^,()]+?)\s*,\s*(' numPat ')\s*\)'], '$1');
    out = regexprep(out, ['min\s*\(\s*(' numPat ')\s*,\s*([^,()]+?)\s*\)'], '$2');
    if strcmp(out, before)
        break
    end
    changed = true;
end
end

% =========================================================================
function v = getOptNum(opts, name, default)
v = default;
try
    if isfield(opts, name) && ~isempty(opts.(name)) && isnumeric(opts.(name)) && isscalar(opts.(name))
        v = double(opts.(name));
    end
catch
end
end

function c = symbolicComplexity(m)
%SYMBOLICCOMPLEXITY Cheap static estimate of how hard vpasolve will be.
% Counts state-state products, state-in-denominator rational terms, nontrivial
% powers and transcendental/guard functions. It never evaluates the model.
states = m.species(:)';
c = struct('n_states', m.n_species, 'nonlinear_products', 0, ...
    'rational_terms', 0, 'powers', 0, 'transcendental', 0, 'score', 0);
for r = 1:m.n_reactions
    txt = char(m.fluxText{r});
    pairs = regexp(txt, '([A-Za-z_]\w*)\s*\*\s*([A-Za-z_]\w*)', 'tokens');
    for k = 1:numel(pairs)
        a = pairs{k}{1};
        b = pairs{k}{2};
        if any(strcmp(a, states)) && any(strcmp(b, states))
            c.nonlinear_products = c.nonlinear_products + 1;
        end
    end
    slash = strfind(txt, '/');
    for k = 1:numel(slash)
        seg = txt(slash(k) + 1:min(numel(txt), slash(k) + 160));
        depth = 0;
        cut = numel(seg);
        for j = 1:numel(seg)
            ch = seg(j);
            if ch == '('
                depth = depth + 1;
            elseif ch == ')'
                if depth == 0
                    cut = j - 1;
                    break
                end
                depth = depth - 1;
            elseif depth == 0 && any(ch == '+-*,')
                cut = j - 1;
                break
            end
        end
        if hasStateToken(seg(1:max(0, cut)), states)
            c.rational_terms = c.rational_terms + 1;
        end
    end
    powers = regexp(txt, '\^\s*([+-]?\d+(?:\.\d+)?)', 'tokens');
    for k = 1:numel(powers)
        if abs(str2double(powers{k}{1}) - 1) > 1e-12
            c.powers = c.powers + 1;
        end
    end
    c.powers = c.powers + numel(regexp(txt, '\^\s*[A-Za-z_]', 'match'));
    c.transcendental = c.transcendental + numel(regexp(txt, ...
        '(^|[^A-Za-z0-9_])(exp|log|sqrt|min|max|abs)\s*\(', 'match'));
end
c.score = c.nonlinear_products + 2 * c.rational_terms + 2 * c.powers + ...
    2 * c.transcendental;
end

function tf = hasStateToken(segment, states)
tf = false;
for k = 1:numel(states)
    pat = ['(?<![A-Za-z0-9_])' regexptranslate('escape', states{k}) '(?![A-Za-z0-9_])'];
    if ~isempty(regexp(segment, pat, 'once'))
        tf = true;
        return
    end
end
end
