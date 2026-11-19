function [sections, sentences] = sentenceize(text, sections)
%SENTENCEIZE 给每个章节附加句子级切分与稳定引用 id（section#sN）。
%   [sections, sentences] = bma.io.sentenceize(text, sections)
%
% 返回：
%   sections   每个元素新增 sentences 字段（struct 数组：id/text/char_start/char_end）
%   sentences  扁平 struct 数组：id, section_id, section_heading, text,
%              char_start, char_end（均为全文 1-based 偏移）
%
% 句子边界：. ! ? 。 ！ ？ 后接空白 + 大写/数字/引号/括号/中文；跳过常见缩写
% （Fig./Eq./et al./e.g./i.e./vs./approx./ca./No.）以免把引文切开。
% 该实现只做“可引用”的启发式切分，不追求语言学完美；id 在文档内稳定。

if nargin < 1 || isempty(text)
    sentences = emptySentences();
    return
end
if nargin < 2 || isempty(sections)
    sections = bma.io.sectionize(text);
end
text = char(text);
n = numel(text);
sentences = emptySentences();
abbrev = {'Fig.', 'Figs.', 'Eq.', 'Eqs.', 'Ref.', 'Refs.', 'No.', 'vs.', 'ca.', ...
    'approx.', 'al.', 'e.g.', 'i.e.', 'cf.', 'resp.', 'Tab.', 'Table.'};
for s = 1:numel(sections)
    sec = sections(s);
    a = max(1, round(sec.char_start));
    b = min(n, round(sec.char_end));
    if b < a
        sections(s).sentences = emptySentences();
        continue
    end
    raw = text(a:b);
    % 章节标题行不当作句子的开头，避免引用到标题+正文的混合文本
    if isfield(sec, 'heading') && ~isempty(sec.heading)
        nl = find(raw == char(10), 1, 'first');
        if ~isempty(nl) && nl <= 400
            firstLine = strtrim(raw(1:nl-1));
            hd = strtrim(char(sec.heading));
            if ~isempty(hd) && (strcmpi(firstLine, hd) || ~isempty(strfind(lower(firstLine), lower(hd))))
                a = a + nl;
                raw = text(a:b);
            end
        end
    end
    [starts, ends] = splitSentences(raw, abbrev);
    items = emptySentences();
    for k = 1:numel(starts)
        i0 = starts(k);
        i1 = ends(k);
        while i0 <= i1 && isspace(raw(i0))
            i0 = i0 + 1;
        end
        while i1 >= i0 && isspace(raw(i1))
            i1 = i1 - 1;
        end
        if i1 < i0
            continue
        end
        st = strtrim(raw(i0:i1));
        if isempty(st)
            continue
        end
        item = struct('id', sprintf('%s#s%d', char(sec.id), numel(items) + 1), ...
            'section_id', char(sec.id), 'section_heading', char(sec.heading), ...
            'text', st, 'char_start', a + i0 - 1, 'char_end', a + i1 - 1);
        items(end + 1) = item; %#ok<AGROW>
    end
    sections(s).sentences = items;
    if ~isempty(items)
        sentences = [sentences, items]; %#ok<AGROW>
    end
end
end

% ---------------------------------------------------------------------------
function out = emptySentences()
out = struct('id', {}, 'section_id', {}, 'section_heading', {}, ...
    'text', {}, 'char_start', {}, 'char_end', {});
end

function [starts, ends] = splitSentences(raw, abbrev)
n = numel(raw);
starts = 1;
ends = [];
i = 1;
while i <= n
    ch = raw(i);
    if any(ch == '.!?。！？')
        j = i + 1;
        while j <= n && (raw(j) == ' ' || raw(j) == sprintf('\t') || ...
                raw(j) == sprintf('\r') || raw(j) == sprintf('\n'))
            j = j + 1;
        end
        boundary = false;
        if j > n
            boundary = true;
        elseif isSentenceStartChar(raw(j))
            boundary = true;
        end
        if boundary && i > 1 && i < n && (raw(i-1) >= '0' && raw(i-1) <= '9') && (raw(i+1) >= '0' && raw(i+1) <= '9')
            boundary = false;   % 小数 3.5 / 7.2
        end
        if boundary && isAbbreviation(raw, i, abbrev)
            boundary = false;
        end
        if boundary
            ends(end + 1) = i; %#ok<AGROW>
            starts(end + 1) = j; %#ok<AGROW>
            i = j;
            continue
        end
    end
    i = i + 1;
end
if isempty(ends) || ends(end) < n
    ends(end + 1) = n; %#ok<AGROW>
end
starts = starts(:).';
ends = ends(:).';
if numel(starts) > numel(ends)
    starts = starts(1:numel(ends));
end
end

function tf = isSentenceStartChar(ch)
tf = (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ...
    ch == '"' || ch == '''' || ch == '(' || ch == '[' || ...
    ch == char(8220) || ch == char(8216) || ch == char(12290) || ...
    (double(ch) >= 19968 && double(ch) <= 40959);   % CJK
end

function tf = isAbbreviation(raw, pos, abbrev)
tf = false;
lim = max(1, pos - 12);
seg = raw(lim:pos);
for k = 1:numel(abbrev)
    a = abbrev{k};
    if numel(seg) >= numel(a) && strcmpi(seg(end - numel(a) + 1:end), a)
        tf = true;
        return
    end
end
% "et al." 形式
if numel(seg) >= 6 && strcmpi(seg(end - 5:end), 'et al.')
    tf = true;
end
end
