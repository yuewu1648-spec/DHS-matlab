function [Z, method, Zsym] = leftNullspace(S)
%LEFTNULLSPACE 化学计量矩阵 S 的左零空间基（守恒律基，已归一化为最简整数）。
%   [Z, method, Zsym] = bma.model.leftNullspace(S)
%
% 返回 Z（nSpecies × k），满足 Z' * S = 0。每列对应一条守恒律：
%   Z(:,j)' * x = 常数
% 基向量被归一化为“最简整数系数”（各元素同时除以最大公约数，首个非零元素为正），
% 这样报告里的守恒量可以写成漂亮的形式（如 E + ES = E0、S + ES + P = S0）。
%
% method = 'symbolic'（Symbolic Math Toolbox 有理基）或 'numeric'（数值正交基理性化）。
% Zsym 为与 Z 对应的 sym 矩阵（便于需要精确分数时使用）。
nS = size(S, 1);
Z = zeros(nS, 0);
Zsym = [];
method = 'numeric';
if nS == 0
    return
end

% ---- 优先：Symbolic Math 有理基 ----
try
    if ~isempty(ver('symbolic')) && exist('sym', 'file') == 2
        Ssym = sym(S);
        N = [];
        try
            N = null(Ssym.', 'r');  % 部分版本符号 null 支持 'r'
        catch
            N = [];
        end
        if isempty(N) || ~isa(N, 'sym')
            try
                N = null(Ssym.');   % 符号 null 默认给出有理基
            catch
                N = [];
            end
        end
        if ~isempty(N) && isa(N, 'sym')
            [Zi, Zsymi] = integerizeSymBasis(N);
            if size(Zi, 1) == nS
                Zi = chooseNiceBasis(Zi);
                Zsym = sym(Zi);
                Z = Zi;
                method = 'symbolic';
                return
            end
        end
    end
catch
    Z = zeros(nS, 0);
    Zsym = [];
end

% ---- 兜底：数值正交基 → 有理化 → 最简整数 ----
try
    N = null(S.', 1e-10);
    [Zi, ~] = integerizeNumericBasis(N);
    Zi = chooseNiceBasis(Zi);
    Z = Zi;
    Zsym = sym(Zi);
catch
    Z = zeros(nS, 0);
    Zsym = [];
end
method = 'numeric';
end

% =========================================================================
function Zout = chooseNiceBasis(Zint)
% 从整数基的 ±1 组合中挑出“好看”的守恒律基：
% 优先（1）所有系数非负（守恒池）；（2）非零系数少；（3）系数绝对值小。
% 这样 E+ES、S+ES+P 这类物理守恒量会优先于任意线性组合被选中。
nS = size(Zint, 1);
k = size(Zint, 2);
Zout = Zint;
if k == 0 || k > 8
    return
end
combos = enumerateComboList(k);
bestCols = zeros(nS, 0);
bestScores = [];
for j = 1:numel(combos)
    c = combos{j};
    v = Zint * c(:);
    if all(v == 0)
        continue
    end
    v = normalizeIntegerVector(v);
    score = scoreVector(v);
    if isempty(bestCols)
        bestCols = v;
        bestScores = score;
    else
        bestCols(:, end+1) = v; %#ok<AGROW>
        bestScores(end+1) = score; %#ok<AGROW>
    end
end
if isempty(bestCols)
    return
end
[~, order] = sort(bestScores);
selected = zeros(nS, 0);
for j = 1:numel(order)
    v = bestCols(:, order(j));
    if size(selected, 2) == 0
        selected = v;
    elseif rank([selected v]) > size(selected, 2)
        selected(:, end+1) = v; %#ok<AGROW>
    end
    if size(selected, 2) >= k
        break
    end
end
if size(selected, 2) == k
    % 按首个非零物种在 species 顺序中的位置排序，保证输出稳定
    firstIdx = zeros(1, k);
    for j = 1:k
        firstIdx(j) = find(selected(:, j) ~= 0, 1);
    end
    [~, ord2] = sort(firstIdx);
    Zout = selected(:, ord2);
end
end

function combos = enumerateComboList(k)
% ±1/0 组合（k<=4 全枚举；更大规模只枚举单列与两列组合）
vals = {-1, 0, 1};
combos = {};
if k <= 4
    idx = zeros(1, k);
    total = 3 ^ k;
    for t = 0:(total - 1)
        x = t;
        for j = 1:k
            idx(j) = mod(x, 3);
            x = floor(x / 3);
        end
        c = zeros(k, 1);
        for j = 1:k
            c(j) = vals{idx(j) + 1};
        end
        if any(c ~= 0)
            combos{end+1} = c; %#ok<AGROW>
        end
    end
else
    for j = 1:k
        c = zeros(k, 1);
        c(j) = 1;
        combos{end+1} = c; %#ok<AGROW>
    end
    for j = 1:k
        for m = (j + 1):k
            c = zeros(k, 1);
            c(j) = 1;
            c(m) = 1;
            combos{end+1} = c; %#ok<AGROW>
            c(m) = -1;
            combos{end+1} = c; %#ok<AGROW>
        end
    end
end
end

function score = scoreVector(v)
nNZ = sum(v ~= 0);
allNonNeg = all(v >= 0) || all(v <= 0);
maxAbs = max(abs(v));
if allNonNeg
    score = nNZ * 100 + maxAbs;
else
    score = 10000 + nNZ * 100 + maxAbs;
end
end

function v = normalizeIntegerVector(v)
g = 0;
for i = 1:numel(v)
    if v(i) ~= 0
        g = gcd(g, abs(v(i)));
    end
end
if g > 1
    v = v / g;
end
firstNZ = find(v ~= 0, 1);
if ~isempty(firstNZ) && v(firstNZ) < 0
    v = -v;
end
end

% =========================================================================
function [Zi, ZsymOut] = integerizeSymBasis(N)
% 符号有理基 → 最简整数基（每列独立归一化）
nS = size(N, 1);
k = size(N, 2);
Zi = zeros(nS, k);
for j = 1:k
    nums = zeros(nS, 1);
    dens = ones(nS, 1);
    for i = 1:nS
        [n, d] = numden(N(i, j));
        ni = double(n);
        di = double(d);
        if ~isfinite(ni) || ~isfinite(di) || ni ~= round(ni) || di ~= round(di) || di == 0
            [ni, di] = rat(double(N(i, j)), 1e-10);
        end
        nums(i) = ni;
        dens(i) = di;
    end
    Zi(:, j) = smallestIntegerVector(nums, dens);
end
ZsymOut = sym(Zi);
end

function [Zi, ZsymOut] = integerizeNumericBasis(N)
nS = size(N, 1);
k = size(N, 2);
Zi = zeros(nS, k);
if isempty(N) || k == 0
    ZsymOut = [];
    return
end
for j = 1:k
    z = N(:, j);
    [n, d] = rat(z, 1e-9);   % 逐元素有理逼近
    Zi(:, j) = smallestIntegerVector(double(n(:)), double(d(:)));
end
ZsymOut = sym(Zi);
end

function ints = smallestIntegerVector(nums, dens)
% 由 nums./dens 构造最简整数向量：通分后除以最大公约数，首个非零为正
nums = double(nums(:));
dens = double(dens(:));
n = numel(nums);
ints = zeros(n, 1);
% 防止极端分母/分子（数值噪声）
nums(~isfinite(nums)) = 0;
dens(~isfinite(dens) | dens == 0) = 1;
L = dens(1);
for i = 2:n
    L = lcm(L, dens(i));
end
if ~isfinite(L) || L <= 0
    L = 1;
end
for i = 1:n
    ints(i) = round(nums(i) * (L / dens(i)));
end
% 最大公约数归一化
g = 0;
for i = 1:n
    if ints(i) ~= 0
        g = gcd(g, abs(ints(i)));
    end
end
if g > 1
    ints = ints / g;
end
% 数值噪声：|系数| 远小于最大系数时置 0（避免 pseudo-integer 基出现 1e14 级系数）
maxAbs = max(abs(ints));
if maxAbs > 0
    ints(abs(ints) < maxAbs * 1e-9) = 0;
end
firstNZ = find(ints ~= 0, 1);
if ~isempty(firstNZ) && ints(firstNZ) < 0
    ints = -ints;
end
end
