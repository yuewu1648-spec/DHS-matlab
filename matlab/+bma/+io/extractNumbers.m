function nums = extractNumbers(text, sections, varargin)
%EXTRACTNUMBERS 从文献全文中抽取带单位的数值参数（含符号、上下文、章节、位置）。
%   nums = bma.io.extractNumbers(text, sections)
%   nums = bma.io.extractNumbers(text)                 % 内部自动 sectionize
%   nums = bma.io.extractNumbers(..., 'SkipReferences', true, 'ContextChars', 80)
%
%   返回 struct 数组，字段：
%     value        数值（double；科学计数法自动折算）
%     unit         规范化单位（µM->uM，s^-1->1/s，min^-1->1/min ...）
%     unit_raw     原文单位片段
%     symbol       参数符号/标识（Km、kcat、EC50、R0、pH ...；无法确定时 ''）
%     context      ±ContextChars 字符上下文（空白折叠）
%     section_id   所属章节 id（与 sectionize 输出一致）
%     section_heading 所属章节标题
%     char_start   数字在全文中的 1-based 字符位置
%     quote        原文证据片段（数字 + 单位）
%     is_range     是否来自 "a-b 单位" 区间
%     range        区间端点 [a b]（非区间为 []）
%
%   设计原则：宁可少报不可误报。只有「带合法单位」或「带明确符号/赋值」的数值
%   才会被保留；URL/DOI/引文/图表编号/页码/年份/统计量（p 值）等误报源会被过滤。
nums = bma.io.internal.emptyNumbers();
if nargin < 1 || isempty(text)
    return
end
if isstring(text)
    text = char(text);
end
text = char(text);
n = numel(text);
if n == 0
    return
end
if nargin < 2 || isempty(sections)
    sections = bma.io.sectionize(text);
end

p = inputParser;
p.addParameter('SkipReferences', true, @(x)islogical(x) || isnumeric(x));
p.addParameter('ContextChars', 80, @(x)isnumeric(x) && isscalar(x));
p.parse(varargin{:});
opts = p.Results;
contextChars = opts.ContextChars;

% 1) 屏蔽不可信区间（URL/DOI/引文/图表编号/页码语境），以及 References 章节
mask = bma.io.internal.excludedMask(text);
if opts.SkipReferences
    mask = bma.io.internal.sectionMask(sections, mask, text, 'references');
end

% 2) 区间值预处理（同时处理 "10-3" 型科学计数）
[entries, mask] = bma.io.internal.extractRanges(text, sections, mask, contextChars);

% 3) 主扫描：数字 + 单位 + 符号
numPat = '(?:^|[^A-Za-z0-9_.])([+-]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)';
[tokens, extents] = regexp(text, numPat, 'tokens', 'tokenExtents');
for i = 1:numel(extents)
    ext = extents{i};
    startPos = ext(1, 1);
    endPos = ext(1, 2);
    if startPos > endPos
        continue
    end
    if any(mask(startPos:endPos))
        continue
    end
    mstr = tokens{i}{1};
    val = str2double(regexprep(mstr, ',', ''));
    if isnan(val) || ~isfinite(val)
        continue
    end
    % 科学计数：1.5 x 10^-3 / 10^3
    [val, powEnd] = applyPower(text, endPos, val);
    tail = '';
    if powEnd < n
        tail = text(powEnd + 1:min(n, powEnd + 70));
    end
    [canon, rawUnit, consumed] = bma.io.internal.findUnitAfter(tail);
    unitEnd = powEnd;
    if ~isempty(canon)
        unitEnd = powEnd + consumed;
    end
    sym = bma.io.internal.findSymbolBefore(text, startPos);
    if isempty(sym)
        sym = symbolAcrossLineBreak(text, startPos);
    end
    if any(mask(startPos:unitEnd))
        continue
    end
    if isempty(canon) && isempty(sym)
        continue
    end
    if isempty(canon) && isYearLike(val)
        continue
    end
    if isempty(canon) && isStatisticLike(sym, val)
        continue
    end
    if isPageLike(text, startPos, endPos)
        continue
    end
    entries(end + 1) = bma.io.internal.makeNumberEntry(text, sections, ...
        startPos, val, canon, rawUnit, sym, unitEnd, false, [], contextChars); %#ok<AGROW>
    mask(startPos:unitEnd) = true;
end

% 4) 按出现顺序返回
if numel(entries) > 1
    [~, ord] = sort([entries.char_start]);
    entries = entries(ord);
end
nums = entries;
end

% ---------------------------------------------------------------------------
function sym = symbolAcrossLineBreak(text, pos)
%SYMBOLACROSSLINEBREAK Recover "ks\n2 = 3.5e-4" style subscripted symbols.
sym = '';
lim = max(1, pos - 120);
seg = text(lim:pos - 1);
tok = regexp(seg, '([A-Za-z][A-Za-z0-9_]*)\s*\r?\n\s*(\d)\s*[=:≈]\s*$', 'tokens', 'once');
if ~isempty(tok)
    sym = [tok{1} tok{2}];
end
end
function [val, newEnd] = applyPower(text, endPos, val)
% 识别 1.5 x 10^-3 与 10^3；返回折算后的值与实际占用的结束位置
newEnd = endPos;
n = numel(text);
if endPos >= n
    return
end
tail = text(endPos + 1:min(n, endPos + 24));
m = regexp(tail, '^\s*[x×]\s*10\s*(?:\^|\*\*)\s*([-+]?\d+)', 'match', 'once');
if ~isempty(m)
    expo = regexp(m, '([-+]?\d+)\s*$', 'tokens', 'once');
    val = val * 10 ^ str2double(expo{1});
    newEnd = endPos + numel(m);
    return
end
if abs(val - 10) < 1e-12
    m = regexp(tail, '^\s*(?:\^|\*\*)\s*([-+]?\d+)', 'match', 'once');
    if ~isempty(m)
        expo = regexp(m, '([-+]?\d+)\s*$', 'tokens', 'once');
        val = 10 ^ str2double(expo{1});
        newEnd = endPos + numel(m);
    end
end
end

function tf = isYearLike(val)
tf = val == round(val) && val >= 1900 && val <= 2100;
end

function tf = isStatisticLike(sym, val)
% 形如 "p = 0.03" 的显著性水平不是机制参数，过滤以免污染证据表
tf = ~isempty(sym) && any(strcmpi(sym, {'p', 'pval', 'p_value', 'pvalue'})) && val < 1;
end

function tf = isPageLike(text, startPos, endPos)
% 数字独占一行（页眉/页脚/行号）
tf = false;
n = numel(text);
lo = startPos;
while lo > 1 && text(lo - 1) ~= char(10)
    lo = lo - 1;
end
hi = endPos;
while hi < n && text(hi + 1) ~= char(10)
    hi = hi + 1;
end
line = strtrim(text(lo:hi));
if isempty(line)
    return
end
tf = ~isempty(regexp(line, '^\d{1,4}$', 'once'));
end
