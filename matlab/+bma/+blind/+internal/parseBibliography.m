function out = parseBibliography(text, sections)
%PARSEBIBLIOGRAPHY Extract reference-list entries from a paper text.
%   out = bma.blind.internal.parseBibliography(text, sections)
%
%   Blind-mode exception: the bibliography is citation metadata. The parser
%   returns ONLY the individual citation strings (never the surrounding body /
%   reference section text), so the agent can enumerate the references without
%   seeing the paper's scientific content.
%
%   Returns: citations (cellstr), source, confidence, count, warnings.
out = struct('citations', {{}}, 'source', 'none', 'confidence', 'none', ...
    'count', 0, 'warnings', {{}});
if nargin < 2 || isempty(sections)
    sections = struct('kind', {}, 'heading', {}, 'text', {});
end
region = '';
source = 'none';
for k = 1:numel(sections)
    kind = lower(strtrim(char(getField(sections(k), 'kind', ''))));
    heading = lower(strtrim(char(getField(sections(k), 'heading', ''))));
    if strcmp(kind, 'references') || any(strcmp(heading, ...
            {'references', 'bibliography', 'literature cited', 'works cited', 'reference list'}))
        region = char(getField(sections(k), 'text', ''));
        source = 'section';
        break
    end
end
if isempty(region)
    ext = regexp(text, ['(?im)^[ \t]*(?:references|bibliography|literature cited|' ...
        'works cited)[ \t]*[.:]?[ \t]*$'], 'tokenExtents', 'once');
    if ~isempty(ext)
        startPos = ext(2) + 1;
        endPos = numel(text);
        nextHead = regexp(text(startPos:end), ['(?im)^[ \t]*(?:supplementary|appendix|' ...
            'acknowledg|author contributions|funding|conflict of interest)[^\n]*$'], 'once');
        if ~isempty(nextHead)
            endPos = startPos + nextHead - 2;
        end
        region = text(startPos:endPos);
        source = 'heading';
    end
end
if isempty(region)
    return
end
region = regexprep(region, '\r\n?', char(10));
region = regexprep(region, '\n{3,}', [char(10) char(10)]);

% 1) Numbered entries: "[1] ...", "1. ...", "1) ..."
starts = regexp(region, '(?m)^[ \t]*(?:\[\d{1,3}\]|\d{1,3}[.)])[ \t]+', 'start');
citations = {};
if numel(starts) >= 1
    starts = sort(starts);
    for i = 1:numel(starts)
        if i < numel(starts)
            stop = starts(i + 1) - 1;
        else
            stop = numel(region);
        end
        piece = region(starts(i):stop);
        piece = regexprep(piece, '(?m)^[ \t]*(?:\[\d{1,3}\]|\d{1,3}[.)])[ \t]+', '', 'once');
        c = cleanCitation(piece);
        if ~isempty(c)
            citations{end + 1} = c; %#ok<AGROW>
        end
    end
    out.confidence = 'numbered';
end

% 2) Paragraph-separated entries.
if isempty(citations)
    parts = regexp(region, ['\n[ \t]*\n'], 'split');
    for i = 1:numel(parts)
        c = cleanCitation(parts{i});
        if ~isempty(c)
            citations{end + 1} = c; %#ok<AGROW>
        end
    end
    if numel(citations) >= 2
        out.confidence = 'paragraph';
    end
end

% 3) One-entry-per-line fallback (wrapped lines are merged).
if isempty(citations) || (numel(citations) == 1 && numel(citations{1}) > 1500)
    lines = regexp(region, '\n', 'split');
    entries = {};
    current = '';
    for i = 1:numel(lines)
        line = strtrim(lines{i});
        if isempty(line)
            continue
        end
        if isBibliographyFooter(line)
            continue
        end
        newEntry = numel(line) >= 30 && ...
            (numel(line) >= 45 || ~isempty(regexp(line, '\b(?:19|20)\d{2}\b', 'once'))) && ...
            (isempty(current) || ~isempty(regexp(line, '^[A-Z0-9]', 'once')));
        if newEntry && ~isempty(current)
            entries{end + 1} = current; %#ok<AGROW>
            current = line;
        elseif newEntry
            current = line;
        elseif ~isempty(current)
            current = [current ' ' line];
        else
            current = line;
        end
    end
    if ~isempty(current)
        entries{end + 1} = current;
    end
    citations = {};
    for i = 1:numel(entries)
        c = cleanCitation(entries{i});
        if ~isempty(c)
            citations{end + 1} = c; %#ok<AGROW>
        end
    end
    if numel(citations) >= 1
        out.confidence = 'lines';
    end
end

% 4) Deduplicate and drop obvious non-citations.
seen = {};
uniq = {};
for i = 1:numel(citations)
    key = lower(regexprep(citations{i}, '\s+', ' '));
    if any(strcmp(seen, key))
        continue
    end
    if isBibliographyFooter(key) || numel(key) < 20
        continue
    end
    seen{end + 1} = key; %#ok<AGROW>
    uniq{end + 1} = citations{i}; %#ok<AGROW>
end
citations = uniq;
if isempty(citations)
    out.warnings{end + 1} = '检测到参考文献标题，但未能切分出条目；请用 references_dir/references_json 显式提供。';
    out.confidence = 'none';
end
if strcmp(out.confidence, 'lines')
    out.warnings{end + 1} = ['参考文献按“每行一条”回退切分；' ...
        '若条目把期刊/年份拆行，可能合并错误。请用 references_dir 提供原文 PDF 更可靠。'];
end
out.citations = citations;
out.source = source;
out.count = numel(citations);
end

% ---------------------------------------------------------------------------
function c = cleanCitation(raw)
c = char(raw);
c = regexprep(c, '\r\n?', ' ');
c = regexprep(c, '\s+', ' ');
c = strtrim(c);
% Strip a leading marker that survived the split.
c = regexprep(c, '^(?:\[\d{1,3}\]|\d{1,3}[.)])\s+', '');
% Drop page headers/footers that end up inside the list.
if isBibliographyFooter(c)
    c = '';
    return
end
if numel(c) > 1500
    c = [c(1:1497) '...'];
end
if numel(c) < 20
    c = '';
end
end

function tf = isBibliographyFooter(line)
low = lower(strtrim(char(line)));
tf = strcmp(low, 'references') || strcmp(low, 'bibliography') || ...
    ~isempty(regexp(low, '^(?:downloaded from|this article is protected|copyright|©|all rights reserved)', 'once')) || ...
    ~isempty(regexp(low, '^(?:page|vol\.?)\s+\d+', 'once'));
end

function v = getField(s, f, d)
if isstruct(s) && isfield(s, f)
    v = s.(f);
else
    v = d;
end
end
