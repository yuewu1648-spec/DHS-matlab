function [canon, raw, consumed] = findUnitAfter(tail)
%FINDUNITAFTER 从「数字之后」的文本中识别单位，并给出规范化结果。
%   [canon, raw, consumed] = bma.io.internal.findUnitAfter(tail)
%
%   tail     ：紧跟在数字后的文本（函数内只取前 80 字符）
%   canon    ：规范化单位（如 uM / 1/s / uM/min / 1/(M*s)），非法时 ''
%   raw      ：原始单位片段（保留供追溯）
%   consumed ：tail 中被单位占用的字符数
%
%   策略：贪心扩展「首 token + 指数/除号/乘号/空格乘」候选，然后从长到短
%   回溯，用 normalizeUnit 做合法性校验。这样 "12.5 µM solution" 只会取 µM，
%   而 "mM s-1" 会得到 mM/s。
canon = '';
raw = '';
consumed = 0;
if isempty(tail)
    return
end
tail = char(tail);
tail = tail(1:min(numel(tail), 80));
% 统一 Unicode 减号/破折号（PDF/Word 常给 "s^−1" 而不是 "s^-1"）
dashCodes = [8722, 8211, 8212];
for k = 1:numel(dashCodes)
    tail = strrep(tail, char(dashCodes(k)), '-');
end

% 1) 倍数：2.5-fold
m = regexp(tail, '^\s*-\s*fold(?![A-Za-z])', 'match', 'once');
if ~isempty(m)
    canon = 'fold';
    raw = strtrim(m);
    consumed = numel(m);
    return
end

% 2) 相对离心力：1000 x g / 1000 x rpm
m = regexp(tail, '^\s*[x×]\s*(?:g|kg|mg|ug|rpm)(?![A-Za-z])', 'match', 'once');
if ~isempty(m)
    u = strtrim(regexprep(m, '^[x×]\s*', ''));
    cu = bma.io.internal.normalizeUnit(u);
    if ~isempty(cu)
        canon = cu;
        raw = u;
        consumed = numel(m);
        return
    end
end

% 3) 以 1/ 开头的单位（如 1/s、1/min）
[cls, clsb] = unitCharClasses();
m = regexp(tail, ['^\s*1\s*/\s*[' cls '][' clsb ']*'], 'match', 'once');
if ~isempty(m)
    cand = strtrim(m);
    cu = bma.io.internal.normalizeUnit(cand);
    if ~isempty(cu)
        canon = cu;
        raw = cand;
        consumed = numel(m);
        return
    end
end

% 4) 常规 token + 贪心扩展
[first, leading] = firstUnitToken(tail, cls, clsb);
if isempty(first)
    return
end
segs = {first};
cur = leading + numel(first);
ends = cur;
while cur < numel(tail) && numel(segs) < 6
    rest = tail(cur + 1:end);
    [seg, segLen] = nextUnitSegment(rest, cls, clsb);
    if segLen == 0
        break
    end
    segs{end + 1} = seg; %#ok<AGROW>
    cur = cur + segLen;
    ends(end + 1) = cur; %#ok<AGROW>
end
for k = numel(segs):-1:1
    cand = [segs{1:k}];
    cu = bma.io.internal.normalizeUnit(cand);
    if ~isempty(cu)
        canon = cu;
        raw = cand;
        consumed = ends(k);
        return
    end
end

% 5) 计数名词兜底：允许 0-2 个修饰词后跟数量名词
%    （如 "12 index cases"、"336 simultaneously infectious individuals"）
nounPat = ['(?:cases?|individuals?|persons?|people|inhabitants?|patients?|' ...
    'infections?|cells?|molecules?|copies|virions?|organisms?)(?![A-Za-z])'];
m = regexp(tail, ['^\s*(?:[A-Za-z][A-Za-z0-9\-]*\s+){0,2}' nounPat], 'match', 'once');
if ~isempty(m)
    canon = 'count';
    raw = strtrim(m);
    consumed = numel(m);
end
end

% ---------------------------------------------------------------------------
function [cls, clsb] = unitCharClasses()
% 单位首字符与后续字符（含微符号、希腊 mu、Omega、度、千分号）
cls = ['A-Za-z%' char(176) char(181) char(956) char(937) char(8240)];
clsb = [cls '0-9_'];
end

function [tok, leading] = firstUnitToken(tail, cls, clsb)
tok = '';
leading = 0;
st = regexp(tail, ['[' cls ']'], 'once');
if isempty(st)
    return
end
prefix = tail(1:st - 1);
if ~all(prefix == ' ' | prefix == char(9))
    return
end
m = regexp(tail(st:end), ['^[' clsb ']+'], 'match', 'once');
if isempty(m)
    return
end
tok = m;
leading = st - 1;
end

function [seg, segLen] = nextUnitSegment(rest, cls, clsb)
seg = '';
segLen = 0;
% 指数：^n / **n
m = regexp(rest, '^(?:\^|\*\*)\s*[-+]?\d+', 'match', 'once');
if ~isempty(m)
    seg = m;
    segLen = numel(m);
    return
end
% 上标指数：⁻¹ / ² / ³
sup = [char(8315) char(8314) char(8304) char(185) char(178) char(179) ...
    char(8308) char(8309) char(8310) char(8311) char(8312) char(8313)];
m = regexp(rest, ['^[' sup ']+'], 'match', 'once');
if ~isempty(m)
    seg = m;
    segLen = numel(m);
    return
end
% 无 caret 的负指数：-1 / -2
m = regexp(rest, '^\s*-\s*[123](?![0-9])', 'match', 'once');
if ~isempty(m)
    seg = m;
    segLen = numel(m);
    return
end
% 除法：/min
m = regexp(rest, ['^\s*/\s*[' cls '][' clsb ']*'], 'match', 'once');
if ~isempty(m)
    seg = m;
    segLen = numel(m);
    return
end
% 乘法：*min
m = regexp(rest, ['^\s*\*\s*[' cls '][' clsb ']*'], 'match', 'once');
if ~isempty(m)
    seg = m;
    segLen = numel(m);
    return
end
% 空格乘（只认常见单位词，避免吞掉正文）：nmol min-1 / M^-1 s^-1
wordPat = ['cells|cell|molecules|molecule|mmol|nmol|umol|pmol|fmol|mol|' ...
    'day|min|mM|uM|nM|pM|fM|M|mg|kg|g|mL|uL|nL|pL|L|rpm|K|h|d|s'];
m = regexp(rest, ['^\s+(?:' wordPat ')(?![A-Za-z])'], 'match', 'once');
if ~isempty(m)
    seg = m;
    segLen = numel(m);
end
end
