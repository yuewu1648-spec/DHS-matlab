function ab = findAbstract(text, sections, provided)
%FINDABSTRACT Extract ONLY the abstract from a primary-paper text.
%   ab = bma.blind.internal.findAbstract(text, sections, provided)
%
%   The blind protocol is allowed to see the primary paper's abstract and
%   nothing else. This function therefore never returns body text: it prefers a
%   sectionized Abstract/Summary section, then a line-anchored heading, then an
%   inline "Abstract:" marker, and refuses (instead of guessing) when it cannot
%   isolate one. `provided` is an optional user-supplied abstract text file
%   content, which is authoritative.
%
%   Returns: text, source, section_id, confidence, chars, warnings.
ab = struct('text', '', 'source', '', 'section_id', '', ...
    'confidence', '', 'chars', 0, 'warnings', {{}});
if nargin < 2 || isempty(sections)
    sections = struct('id', {}, 'heading', {}, 'kind', {}, 'text', {}, ...
        'char_start', {}, 'char_end', {});
end
if nargin < 3
    provided = '';
end
if ~isempty(provided)
    t = cleanAbstract(char(provided));
    if numel(t) < 80
        error('bma:blind:abstract_not_found', ...
            '提供的摘要文件内容过短（%d 字符）。请提供完整摘要（UTF-8 文本）。', numel(t));
    end
    if numel(t) > 12000
        ab.warnings{end + 1} = sprintf( ...
            '提供的摘要 %d 字符，超过 12000；已截断（摘要通常 < 3000 字符，请确认文件只含摘要）。', numel(t));
        t = t(1:12000);
    end
    ab.text = t;
    ab.source = 'provided_file';
    ab.confidence = 'high';
    ab.chars = numel(t);
    return
end

% 1) Sectionized abstract / summary ---------------------------------------
best = '';
bestId = '';
bestConf = '';
for k = 1:numel(sections)
    sec = sections(k);
    kind = lower(strtrim(char(getField(sec, 'kind', ''))));
    heading = lower(strtrim(char(getField(sec, 'heading', ''))));
    isAbstract = any(strcmp(kind, {'abstract', 'summary', 'abstract_and_keywords'})) || ...
        any(strcmp(heading, {'abstract', 'summary', 'abstract and keywords'}));
    if ~isAbstract
        continue
    end
    t = stripLeadingHeading(char(getField(sec, 'text', '')), ...
        char(getField(sec, 'heading', '')));
    t = cutAtKeywords(cleanAbstract(t));
    if numel(t) < 80
        continue
    end
    % Graphical/structured abstracts can be split into several sections; keep
    % the longest recognized abstract section instead of the first stub.
    if numel(t) > numel(best)
        best = t;
        bestId = char(getField(sec, 'id', ''));
        bestConf = 'high';
    end
end
if ~isempty(best)
    ab.text = best;
    ab.section_id = bestId;
    ab.source = 'section';
    ab.confidence = bestConf;
    ab.chars = numel(best);
    ab = capAbstract(ab, 6000);
    return
end

% 2) Line-anchored heading in the raw text --------------------------------
tokens = regexp(text, '(?im)^[ \t]*(?:abstract|summary)[ \t]*[.:]?[ \t]*$', 'tokenExtents');
if ~isempty(tokens)
    ext = tokens{1};
    startPos = ext(2) + 1;
    endPos = textEndAfter(sections, startPos, numel(text));
    t = cleanAbstract(text(startPos:endPos));
    t = cutAtKeywords(t);
    t = cutAtHeading(t, '(?im)^[ \t]*(?:\d+[.)]?\s*)?(?:introduction|background)\b');
    if numel(t) >= 80
        ab.text = t;
        ab.source = 'regex_heading';
        ab.confidence = 'medium';
        ab.chars = numel(t);
        ab.warnings{end + 1} = ['未得到章节化的 Abstract 标题，按 "Abstract" 行锚点截取；' ...
            '已用下一章节起始位置与 Introduction 标题截断。请核对摘要完整性。'];
        ab = capAbstract(ab, 6000);
        return
    end
end

% 3) Inline "Abstract: ..." near the front matter -------------------------
head = text(1:min(numel(text), 12000));
ext = regexp(head, '(?i)(?:^|\n)[ \t]*(?:abstract|summary)[ \t]*[.:—–-][ \t]*', 'tokenExtents', 'once');
if ~isempty(ext) && ext(2) < numel(head)
    startPos = ext(2) + 1;
    endPos = min(startPos + 5000, numel(text));
    t = cleanAbstract(text(startPos:endPos));
    t = cutAtKeywords(t);
    t = cutAtHeading(t, '(?im)^[ \t]*(?:\d+[.)]?\s*)?(?:introduction|background|results)\b');
    if numel(t) >= 80
        ab.text = t;
        ab.source = 'regex_inline';
        ab.confidence = 'low';
        ab.chars = numel(t);
        ab.warnings{end + 1} = ['只能在正文中按行内 "Abstract:" 标记截取，' ...
            '可能夹带引言文字。请用 abstract_path 提供权威摘要，或在报告局限中声明。'];
        ab = capAbstract(ab, 4000);
        return
    end
end

error('bma:blind:abstract_not_found', ...
    ['无法从主文献中可靠地单独提取摘要（未找到 Abstract/Summary 章节或锚点）。' ...
     '盲建模协议不能退化为读取全文：请用 abstract_path 提供一个只含摘要的 UTF-8 文本文件，' ...
     '或把摘要单独提供。']);
end

% ---------------------------------------------------------------------------
function ab = capAbstract(ab, limit)
if ab.chars > limit
    ab.text = ab.text(1:limit);
    ab.chars = numel(ab.text);
    ab.warnings{end + 1} = sprintf('摘要超过 %d 字符，已截断；请确认是否夹带了正文。', limit);
end
end

function t = cleanAbstract(t)
if isempty(t)
    return
end
t = char(t);
t = strrep(t, char(13), char(10));
t = strrep(t, char(160), ' ');
t = strrep(t, char(0), '');
t = regexprep(t, '\n{3,}', [char(10) char(10)]);
t = strtrim(t);
end

function t = stripLeadingHeading(t, heading)
t = char(t);
heading = strtrim(char(heading));
if isempty(t)
    return
end
if ~isempty(heading)
    pat = ['^[ \t]*' regexptranslate('escape', heading) '[ \t]*[:.\-—–]?[ \t]*'];
    t2 = regexprep(t, pat, '', 'once', 'ignorecase');
    if numel(t2) < numel(t)
        t = t2;
        return
    end
end
% Fallback: drop a short, punctuation-free first line that is not a sentence.
lines = regexp(t, '\n', 'split');
if numel(lines) > 1
    first = strtrim(lines{1});
    if ~isempty(first) && numel(first) <= 60 && ...
            isempty(regexp(first, '[.;!?]', 'once')) && ...
            isempty(regexp(first, '\s{2,}', 'once'))
        t = strjoin(lines(2:end), char(10));
    end
end
t = strtrim(t);
end

function t = cutAtKeywords(t)
if isempty(t)
    return
end
m = regexp(t, '(?im)^[ \t]*(?:key\s*words?|keywords|index terms|abbreviations)[ \t]*[:：]?', 'once');
if ~isempty(m) && m > 1
    t = t(1:m - 1);
end
t = strtrim(t);
end

function t = cutAtHeading(t, pattern)
if isempty(t)
    return
end
m = regexp(t, pattern, 'once');
if ~isempty(m) && m > 1
    t = strtrim(t(1:m - 1));
end
end

function endPos = textEndAfter(sections, startPos, textLen)
% Next section start after startPos (minus one char), else end of text.
endPos = textLen;
starts = zeros(1, numel(sections));
for k = 1:numel(sections)
    starts(k) = double(getField(sections(k), 'char_start', 0));
end
starts = starts(starts > startPos);
if ~isempty(starts)
    endPos = min(endPos, min(starts) - 1);
end
end

function v = getField(s, f, d)
if isstruct(s) && isfield(s, f)
    v = s.(f);
else
    v = d;
end
end
