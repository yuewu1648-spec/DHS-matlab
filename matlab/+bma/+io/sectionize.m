function sections = sectionize(text)
%SECTIONIZE 将文献全文切分为章节（生物学论文标题启发式）。
%   sections = bma.io.sectionize(text)
%
%   返回 struct 数组，字段：
%     id, heading, level, char_start, char_end, text, kind
%   char_start/char_end 为 1-based 原文区间；各章节首尾相接，因此对原文的
%   字符覆盖率恒为 100%（> 95% 的验收要求）。
%
%   标题识别启发（按优先级）：
%     1) Markdown 标题（# / ## ...）；
%     2) 常见生物学期刊章节名（Abstract/Introduction/Results/Methods/
%        Discussion/References/...，允许 "Abstract: ..." 行内正文）；
%     3) 数字编号标题（"2.1 Cell culture" / "3. Results"），层级由编号点数给出；
%     4) 全大写短行；
%     5) 短 Title Case 行（前后有空行、下一行是正文）。
%   表格行、图表标题、公式、行内句号结尾的正文行不会被当作标题。
sections = bma.io.internal.emptySections();
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
lines = bma.io.internal.splitLines(text);
m = numel(lines);

% 1) 收集候选标题
starts = zeros(0, 1);
headings = {};
levels = zeros(0, 1);
kinds = {};
prevKind = '';
for k = 1:m
    [isHead, heading, level, kind] = classifyLine(lines(k).text, lines, k, prevKind);
    if isHead
        starts(end + 1, 1) = lines(k).start; %#ok<AGROW>
        headings{end + 1} = heading; %#ok<AGROW>
        levels(end + 1, 1) = level; %#ok<AGROW>
        kinds{end + 1} = kind; %#ok<AGROW>
        prevKind = kind;
    end
end

% 2) 无标题 -> 整篇一个章节
if isempty(starts)
    sections = makeSection('s1', 'Full Text', 1, 1, n, text, 'body');
    return
end

% 3) 首标题前的内容作为 Front Matter（若含非空内容）
starts = starts(:);
ends = [starts(2:end) - 1; n];
count = 0;
preamble = text(1:starts(1) - 1);
if ~isempty(strtrim(preamble))
    count = count + 1;
    sections(count) = makeSection(sprintf('s%d', count), 'Front Matter', 1, ...
        1, starts(1) - 1, preamble, 'front_matter');
end
for k = 1:numel(starts)
    count = count + 1;
    secStart = starts(k);
    secEnd = ends(k);
    if count == 1 && isempty(strtrim(preamble))
        % 首标题前只有空白：把空白并入首章节，保证全文覆盖
        secStart = 1;
    end
    raw = text(secStart:secEnd);
    sections(count) = makeSection(sprintf('s%d', count), headings{k}, ...
        levels(k), secStart, secEnd, raw, kinds{k});
end
sections = addSectionConfidence(sections);
end

% ---------------------------------------------------------------------------
function sections = addSectionConfidence(sections)
%ADDSECTIONCONFIDENCE Flag likely PDF-column/fragment headings.
% Text Analytics returns flattened text without x-coordinates, so true
% two-column reordering is not available here. Instead of silently trusting a
% wrong section, mark fragment-like headings as low confidence; ingest turns a
% high low-confidence ratio into a top-level layout warning (issue I6/U6.2).
for k = 1:numel(sections)
    h = strtrim(char(sections(k).heading));
    % Known journal section names are strong evidence even if short.
    [knownKind, ~] = knownHeading(lower(h));
    if ~isempty(knownKind) || strcmpi(h, 'Full Text') || strcmpi(h, 'Front Matter')
        sections(k).section_confidence = 'high';
        continue
    end
    sections(k).section_confidence = confidenceOfHeading(h, sections(k).text);
end
end

function c = confidenceOfHeading(heading, body)
c = 'high';
h = strtrim(char(heading));
if isempty(h)
    c = 'low';
    return
end
letters = regexprep(h, '[^A-Za-z]', '');
if isempty(letters)
    c = 'low';
    return
end
if numel(h) <= 14 && isempty(strfind(h, ' '))
    c = 'low';
    return
end
if any(ismember(h, '[]{}')) || ~isempty(regexp(h, '^[A-Za-z]{1,3}[,;]', 'once'))
    c = 'low';
    return
end
vowels = sum(ismember(lower(letters), 'aeiou'));
if vowels / numel(letters) < 0.15
    c = 'low';
    return
end
if numel(strtrim(char(body))) < 120 && numel(h) <= 20
    c = 'low';
end
end

% ---------------------------------------------------------------------------
function sec = makeSection(id, heading, level, charStart, charEnd, raw, kind)
sec = struct('id', id, 'heading', char(heading), 'level', double(level), ...
    'char_start', double(charStart), 'char_end', double(charEnd), ...
    'text', strtrim(char(raw)), 'kind', char(kind), ...
    'section_confidence', 'high');
end

function [isHead, heading, level, kind] = classifyLine(raw, lines, k, prevKind)
isHead = false;
heading = '';
level = 1;
kind = 'other';
if nargin < 4
    prevKind = '';
end
inReferences = strcmpi(prevKind, 'references');
line = strtrim(char(raw));
if isempty(line)
    return
end

% Markdown 标题
md = regexp(line, '^(#{1,6})\s+(.+)$', 'tokens', 'once');
if ~isempty(md)
    isHead = true;
    level = numel(md{1});
    heading = cleanEmphasis(strtrim(md{2}));
    % 编号标题（"## 1. Introduction"）：kind 用去掉编号后的部分判断
    stripped = regexprep(lower(heading), '^(\d+(?:\.\d+){0,4})[\.\)]?\s+', '');
    kind = kindOfHeading(stripped);
    return
end

% 去除粗体/斜体标记（**Abstract**、_Results_）
cleaned = cleanEmphasis(line);
cleaned = strtrim(cleaned);
if isempty(cleaned)
    return
end

% 明显不是标题的行
if any(cleaned == '|') || any(cleaned == char(9))
    return
end
low = lower(cleaned);

% 已知章节名（含 "Abstract: 正文" / "1. Introduction" 的编号前缀）
numPrefix = '';
numLevel = 0;
mnum = regexp(cleaned, '^(\d+(?:\.\d+){0,4})[\.\)]?\s+(.+)$', 'tokens', 'once');
if ~isempty(mnum) && ~inReferences
    numPrefix = mnum{1};
    rest = strtrim(mnum{2});
    numLevel = 1 + numel(strfind(numPrefix, '.'));
    [knownKind, knownName] = knownHeading(lower(rest));
    if ~isempty(knownKind)
        isHead = true;
        heading = [numPrefix ' ' knownName];
        level = numLevel;
        kind = knownKind;
        return
    end
    % 编号 + 全大写/Title Case 短标题
    if isAllCapsHeading(rest)
        isHead = true;
        heading = [numPrefix ' ' strtrim(rest)];
        level = numLevel;
        kind = 'other';
        return
    end
    if isTitleCaseHeading(rest, lines, k, true)
        isHead = true;
        heading = [numPrefix ' ' strtrim(rest)];
        level = numLevel;
        kind = 'other';
        return
    end
    % 有编号但不像标题 -> 继续尝试其它启发（如 "1. Introduction" 已处理）
end

% 已知章节名 + 可选行内正文
[knownKind, knownName] = knownHeading(low);
if ~isempty(knownKind)
    % 已知章节名是强信号：部分 PDF/HTML 抽取文本没有空行，短标题行直接接受，
    % 避免因缺少空行而漏检（正文行几乎不会恰好等于 "Abstract"/"Methods" 等）。
    contextOK = isHeadingContext(lines, k) || numel(cleaned) <= 80;
    if contextOK
        isHead = true;
        heading = knownName;
        level = 1;
        kind = knownKind;
        return
    end
    % "Abstract: ..." 行内正文（即使上一行不是空行也可接受）
    mInline = regexp(low, ['^(' knownNameLowerPattern() ')\s*[:\-]\s+\S'], 'once');
    if ~isempty(mInline) || startsWith(low, [lower(knownName) ':'])
        isHead = true;
        heading = knownName;
        level = 1;
        kind = knownKind;
        return
    end
end

% 全大写短行
if isAllCapsHeading(cleaned) && isHeadingContext(lines, k)
    isHead = true;
    heading = cleaned;
    level = 1;
    kind = kindOfHeading(low);
    return
end

% 短 Title Case 行
if isTitleCaseHeading(cleaned, lines, k, false) && isHeadingContext(lines, k)
    isHead = true;
    heading = cleaned;
    level = 2;
    kind = kindOfHeading(low);
    return
end
end

function tf = isHeadingContext(lines, k)
% 标题上下文：位于行首（或首行），且前后至少一边有空行，避免正文硬换行误判
tf = false;
m = numel(lines);
prevBlank = k == 1 || isempty(strtrim(lines(k - 1).text));
if prevBlank
    tf = true;
    return
end
nextBlank = k == m || isempty(strtrim(lines(k + 1).text));
if nextBlank
    tf = true;
end
end

function tf = isAllCapsHeading(line)
tf = false;
line = strtrim(line);
line = regexprep(line, '[\.:;,]+$', '');
if numel(line) < 3 || numel(line) > 80
    return
end
letters = regexprep(line, '[^A-Za-z]', '');
if numel(letters) < 2
    return
end
upperCount = sum(letters >= 'A' & letters <= 'Z');
if upperCount / numel(letters) < 0.85
    return
end
words = regexp(line, '\S+', 'match');
tf = numel(words) <= 10;
end

function tf = isTitleCaseHeading(line, lines, k, numbered)
tf = false;
line = strtrim(line);
line = regexprep(line, '[\.:;,]+$', '');
if numel(line) < 3 || numel(line) > 90
    return
end
if any(line == '=') || any(line == '{') || any(line == '[')
    return
end
% 图表/公式/参考文献引用不是标题
if ~isempty(regexpi(line, '^(fig(ure)?|tab(le)?|scheme|eq(uation)?|supp)(?=[\s.:]|$)', 'once'))
    return
end
% 以句号结尾的句子不是标题
if ~isempty(regexp(line, '[.;,]$', 'once')) && ~numbered
    return
end
words = regexp(line, '\S+', 'match');
if numel(words) < 1 || numel(words) > 12
    return
end
firstLetter = regexp(line, '[A-Za-z]', 'match', 'once');
if isempty(firstLetter) || ~(firstLetter >= 'A' && firstLetter <= 'Z')
    return
end
% 每个实词首字母大写（允许 the/of/in/and/for/to/with 等小词）
smallWords = {'a', 'an', 'the', 'of', 'in', 'on', 'at', 'for', 'to', 'and', ...
    'or', 'with', 'by', 'from', 'via', 'vs', 'versus', 'into', 'under', 'over', 'as'};
cap = 0;
nWord = 0;
for w = 1:numel(words)
    wd = words{w};
    firstCh = regexp(wd, '[A-Za-z]', 'match', 'once');
    if isempty(firstCh)
        continue
    end
    nWord = nWord + 1;
    if any(strcmpi(wd, smallWords))
        continue
    end
    if firstCh >= 'A' && firstCh <= 'Z'
        cap = cap + 1;
    end
end
if nWord == 0 || cap / nWord < 0.6
    return
end
% 下一非空行应当是更长的正文（或空行后是正文）
nextLen = 0;
for j = k + 1:min(numel(lines), k + 3)
    t = strtrim(lines(j).text);
    if ~isempty(t)
        nextLen = numel(t);
        break
    end
end
if nextLen < max(30, ceil(0.9 * numel(line)))
    return
end
tf = true;
end

function out = cleanEmphasis(in)
out = strtrim(char(in));
for k = 1:3
    new = regexprep(out, '^\*\*|\*\*$', '');
    new = regexprep(new, '^__|__$', '');
    new = regexprep(new, '^\*|\*$', '');
    new = regexprep(new, '^_|_$', '');
    new = strtrim(new);
    if strcmp(new, out)
        break
    end
    out = new;
end
end

function [kind, displayName] = knownHeading(low)
% 返回 '' 表示不是已知章节名；displayName 为规范化显示名
persistent KEYS KINDS DISPLAY
if isempty(KEYS)
    KEYS = { ...
        'abstract', 'summary', 'abstract and keywords', ...
        'introduction', 'background', 'introduction and background', ...
        'results', 'results and discussion', ...
        'discussion', 'discussion and conclusions', ...
        'conclusion', 'conclusions', 'concluding remarks', 'conclusions and outlook', ...
        'methods', 'method', 'materials and methods', 'materials & methods', ...
        'methods and materials', 'experimental procedures', 'experimental section', ...
        'experimental', 'methodology', 'materials', 'subjects and methods', ...
        'patients and methods', 'online methods', 'star methods', 'methods summary', ...
        'references', 'bibliography', 'literature cited', 'works cited', ...
        'references and notes', 'reference list', ...
        'acknowledgements', 'acknowledgments', 'acknowledgement', 'acknowledgment', ...
        'funding', 'funding information', 'financial support', 'funding sources', ...
        'author contributions', 'author contribution', 'contributions', ...
        'authors'' contributions', 'author contributions statement', ...
        'conflict of interest', 'conflicts of interest', 'competing interests', ...
        'declaration of competing interest', 'declaration of interests', ...
        'data availability', 'data availability statement', 'availability of data', ...
        'data and materials availability', ...
        'supplementary material', 'supplementary materials', 'supplementary information', ...
        'supporting information', 'supplementary data', 'supplementary figures', ...
        'supplementary tables', ...
        'figure legends', 'figure captions', 'legends', ...
        'table legends', 'table captions', ...
        'appendix', 'appendices', 'appendix a', ...
        'keywords', 'key words', 'abbreviations', 'abbreviations list', ...
        'highlights', 'graphical abstract', 'significance', 'significance statement', ...
        'author summary', 'study limitations', 'limitations', 'main text'};
    KINDS = { ...
        'abstract', 'abstract', 'abstract', ...
        'introduction', 'introduction', 'introduction', ...
        'results', 'results', ...
        'discussion', 'discussion', ...
        'conclusion', 'conclusion', 'conclusion', 'conclusion', ...
        'methods', 'methods', 'methods', 'methods', ...
        'methods', 'methods', 'methods', ...
        'methods', 'methods', 'methods', 'methods', ...
        'methods', 'methods', 'methods', 'methods', ...
        'references', 'references', 'references', 'references', ...
        'references', 'references', ...
        'acknowledgements', 'acknowledgements', 'acknowledgements', 'acknowledgements', ...
        'funding', 'funding', 'funding', 'funding', ...
        'author_contributions', 'author_contributions', 'author_contributions', ...
        'author_contributions', 'author_contributions', ...
        'conflict', 'conflict', 'conflict', ...
        'conflict', 'conflict', ...
        'data_availability', 'data_availability', 'data_availability', ...
        'data_availability', ...
        'supplementary', 'supplementary', 'supplementary', ...
        'supplementary', 'supplementary', 'supplementary', ...
        'supplementary', ...
        'figure_legends', 'figure_legends', 'figure_legends', ...
        'table_legends', 'table_legends', ...
        'appendix', 'appendix', 'appendix', ...
        'keywords', 'keywords', 'abbreviations', 'abbreviations', ...
        'other', 'other', 'other', 'other', ...
        'other', 'limitations', 'limitations', 'other'};
    DISPLAY = { ...
        'Abstract', 'Summary', 'Abstract', ...
        'Introduction', 'Background', 'Introduction', ...
        'Results', 'Results and Discussion', ...
        'Discussion', 'Discussion and Conclusions', ...
        'Conclusion', 'Conclusions', 'Concluding Remarks', 'Conclusions and Outlook', ...
        'Methods', 'Method', 'Materials and Methods', 'Materials & Methods', ...
        'Methods and Materials', 'Experimental Procedures', 'Experimental Section', ...
        'Experimental', 'Methodology', 'Materials', 'Subjects and Methods', ...
        'Patients and Methods', 'Online Methods', 'STAR Methods', 'Methods Summary', ...
        'References', 'Bibliography', 'Literature Cited', 'Works Cited', ...
        'References and Notes', 'Reference List', ...
        'Acknowledgements', 'Acknowledgments', 'Acknowledgements', 'Acknowledgments', ...
        'Funding', 'Funding Information', 'Financial Support', 'Funding Sources', ...
        'Author Contributions', 'Author Contributions', 'Contributions', ...
        'Author Contributions', 'Author Contributions', ...
        'Conflict of Interest', 'Conflicts of Interest', 'Competing Interests', ...
        'Declaration of Competing Interest', 'Declaration of Interests', ...
        'Data Availability', 'Data Availability Statement', 'Availability of Data', ...
        'Data and Materials Availability', ...
        'Supplementary Material', 'Supplementary Materials', 'Supplementary Information', ...
        'Supporting Information', 'Supplementary Data', 'Supplementary Figures', ...
        'Supplementary Tables', ...
        'Figure Legends', 'Figure Captions', 'Legends', ...
        'Table Legends', 'Table Captions', ...
        'Appendix', 'Appendices', 'Appendix A', ...
        'Keywords', 'Key Words', 'Abbreviations', 'Abbreviations', ...
        'Highlights', 'Graphical Abstract', 'Significance', 'Significance Statement', ...
        'Author Summary', 'Study Limitations', 'Limitations', 'Main Text'};
end
kind = '';
displayName = '';
low = strtrim(char(low));
low = regexprep(low, '[\s:;,.]+$', '');
for k = 1:numel(KEYS)
    key = KEYS{k};
    if strcmp(low, key)
        kind = KINDS{k};
        displayName = DISPLAY{k};
        return
    end
    % 允许行内正文 "Abstract: ..."（col 检查由调用方负责）
    if strncmp(low, [key ':'], numel(key) + 1) || strncmp(low, [key ' -'], numel(key) + 2)
        kind = KINDS{k};
        displayName = DISPLAY{k};
        return
    end
end
% 模糊匹配：PDF 抽取可能把连字（fi/ti/fl...）变成非法字符后被删除，
% 造成 "Introducon" 这类缺字母的标题。仅对短行（<=40 字符）做编辑距离<=2 匹配。
if numel(low) <= 40
    cand = regexprep(low, '[^a-z]', '');
    if numel(cand) >= 5
        bestIdx = 0;
        bestDist = Inf;
        for k = 1:numel(KEYS)
            key = KEYS{k};
            if abs(numel(key) - numel(cand)) > 2
                continue
            end
            d = editDistance(cand, key);
            if d < bestDist
                bestDist = d;
                bestIdx = k;
            end
        end
        allowed = 0;
        if numel(cand) >= 10
            allowed = 2;
        elseif numel(cand) >= 6
            allowed = 1;
        end
        if bestIdx > 0 && bestDist <= allowed
            kind = KINDS{bestIdx};
            displayName = DISPLAY{bestIdx};
        end
    end
end
end

function d = editDistance(a, b)
% 经典 Levenshtein 距离（字符串很短，O(n*m) 足够）
na = numel(a);
nb = numel(b);
if na == 0
    d = nb;
    return
end
if nb == 0
    d = na;
    return
end
prev = 0:nb;
for i = 1:na
    cur = zeros(1, nb + 1);
    cur(1) = i;
    for j = 1:nb
        cost = 1;
        if a(i) == b(j)
            cost = 0;
        end
        cur(j + 1) = min([cur(j) + 1, prev(j + 1) + 1, prev(j) + cost]);
    end
    prev = cur;
end
d = prev(nb + 1);
end

function kind = kindOfHeading(low)
[kind, ~] = knownHeading(low);
if isempty(kind)
    kind = 'other';
end
end

function p = knownNameLowerPattern()
% 供行内标题判断使用的已知名称正则（较长名称优先）
persistent P
if isempty(P)
    names = {'materials and methods', 'methods and materials', 'results and discussion', ...
        'discussion and conclusions', 'abstract and keywords', 'data availability statement', ...
        'author contributions', 'conflict of interest', 'competing interests', ...
        'supplementary information', 'supporting information', 'figure legends', ...
        'table legends', 'concluding remarks', 'graphical abstract', 'significance statement', ...
        'online methods', 'star methods', 'experimental procedures', 'experimental section', ...
        'introduction', 'background', 'abstract', 'summary', 'results', 'discussion', ...
        'conclusions', 'conclusion', 'methods', 'references', 'acknowledgements', ...
        'acknowledgments', 'funding', 'keywords', 'appendix', 'highlights'};
    P = strjoin(names, '|');
end
p = P;
end
