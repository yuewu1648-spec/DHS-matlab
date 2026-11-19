function sym = findSymbolBefore(text, startPos)
%FINDSYMBOLBEFORE 从数字前的文本推断该数值对应的符号/参数名。
%   sym = bma.io.internal.findSymbolBefore(text, startPos)
%
%   支持四类线索（precision-first，避免把普通单词当符号）：
%     1) "Km = 12.5" / "Kd ≈ 3" / "kcat: 4"（显式赋值/比较符）；
%     2) "kcat of 3.4" / "Vmax was 2.1"（介词桥接，且符号在已知词表或含大写）；
%     3) "pH 7.4" / "EC50 0.8"（已知符号紧跟数字）；
%     4) 无法确定时返回 ''（宁缺毋滥）。
sym = '';
if startPos <= 1
    return
end
n = numel(text);
lo = max(1, startPos - 60);
pre = text(lo:startPos - 1);

% 1) 显式赋值/比较符
m = regexp(pre, '([A-Za-z][A-Za-z0-9_/\-]{0,20})\s*(?:=|≈|~|≃|<=|>=|<|>)\s*$', 'tokens', 'once');
if ~isempty(m)
    cand = m{1};
    if ~isStopWord(cand)
        sym = cand;
        return
    end
end

% 2) 介词桥接
m = regexp(pre, '([A-Za-z][A-Za-z0-9_/\-]{0,20})\s+(?:of|was|were|is|are|reached|reaches|equals|equaled|at)\s+$', 'tokens', 'once');
if ~isempty(m)
    cand = m{1};
    if isKnownSymbol(cand) || hasInnerUpper(cand)
        sym = cand;
        return
    end
end

% 3) 已知符号紧跟数字（"pH 7.4"）
m = regexp(pre, '([A-Za-z][A-Za-z0-9_/\-]{0,20})\s+$', 'tokens', 'once');
if ~isempty(m)
    cand = m{1};
    if isKnownSymbol(cand)
        sym = cand;
        return
    end
end

% 4) 初始条件记法：S(0) = 1188 / I(0) = 12
m = regexp(pre, '([A-Za-z])\(\s*(?:0|t|eq)\s*\)\s*=\s*$', 'tokens', 'once');
if ~isempty(m)
    sym = sprintf('%s(0)', m{1});
    return
end

% 5) 时间/序号语境："on day 18" / "by week 3"（观测时间点，非物理量）
m = regexp(pre, '(?:^|[^A-Za-z])(day|days|week|weeks|month|months|year|years|hour|hours)\s+$', 'tokens', 'once');
if ~isempty(m)
    sym = m{1};
    return
end
end

% ---------------------------------------------------------------------------
function tf = isStopWord(w)
persistent STOPS
if isempty(STOPS)
    STOPS = {'the', 'a', 'an', 'about', 'approximately', 'approx', 'around', ...
        'note', 'value', 'values', 'result', 'results', 'total', 'mean', ...
        'average', 'range', 'between', 'from', 'to', 'at', 'in', 'on', 'for', ...
        'and', 'or', 'was', 'were', 'is', 'are', 'be', 'been', 'has', 'have', ...
        'had', 'this', 'that', 'these', 'those', 'it', 'its', 'we', 'they', ...
        'there', 'here', 'also', 'only', 'both', 'each', 'per', 'with', ...
        'without', 'than', 'then', 'when', 'where', 'which', 'while', 'all', ...
        'any', 'some', 'more', 'less', 'most', 'least', 'up', 'down', 'higher', ...
        'lower', 'increase', 'decrease', 'increased', 'decreased', 'changed', ...
        'nearly', 'over', 'under', 'figure', 'fig', 'table', 'tab', 'eq', ...
        'equation', 'section', 'sec', 'page', 'ref', 'reference', 'see', ...
        'shown', 'observed', 'measured', 'estimated', 'reported', 'given', ...
        'using', 'used', 'approximately', 'respectively', '1', '2', '3'};
end
tf = any(strcmpi(w, STOPS));
end

function tf = isKnownSymbol(w)
persistent KNOWN
if isempty(KNOWN)
    KNOWN = {'km', 'kcat', 'kcat_km', 'kd', 'ki', 'ka', 'kf', 'kr', 'koff', ...
        'kon', 'kdeg', 'k1', 'k2', 'k3', 'k4', 'vmax', 'v0', 'vi', 'r0', ...
        'reff', 'n0', 'ec50', 'ec90', 'ic50', 'ic90', 'gi50', 'cc50', ...
        'ph', 'pka', 'tm', 't50', 't1/2', 'td', 'keq', 'rmax', 'ks', 'km_app', ...
        'half-life', 'half_life', 'slope', 'intercept', 'duration', 'delay', ...
        'lambda', 'mu', 'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'tau'};
end
tf = any(strcmpi(w, KNOWN));
end

function tf = hasInnerUpper(w)
% 含大写字母（非首字母）的标识符，如 EC50 / R0 / Vmax，允许作为符号
tf = false;
for k = 2:numel(w)
    if w(k) >= 'A' && w(k) <= 'Z'
        tf = true;
        return
    end
end
end
