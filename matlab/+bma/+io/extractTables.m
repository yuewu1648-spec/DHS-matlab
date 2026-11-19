function tables = extractTables(text, sections)
%EXTRACTTABLES 从文献全文中抽取表格（Markdown / 制表符 / 空格对齐）。
%   tables = bma.io.extractTables(text)
%   tables = bma.io.extractTables(text, sections)
%
%   返回 struct 数组，字段：
%     id / caption / header(cellstr) / rows(1xR cell，每行是 cellstr)
%     section_id / section_heading / char_start / format('markdown'|'tsv'|'fixed')
%     n_rows / n_cols
%
%   识别优先级：Markdown 管道表 > 制表符表 > 空格对齐表；已识别的行区间会被
%   标记，避免同一块被重复识别。caption 会向上回看 1-2 行寻找 "Table 1." 之类。
tables = bma.io.internal.emptyTables();
if nargin < 1 || isempty(text)
    return
end
if isstring(text)
    text = char(text);
end
text = char(text);
if isempty(text)
    return
end
if nargin < 2 || isempty(sections)
    sections = bma.io.sectionize(text);
end
lines = bma.io.internal.splitLines(text);
consumed = false(1, numel(lines));

tables = detectMarkdown(text, lines, consumed, sections, tables);
tables = detectTsv(text, lines, consumed, sections, tables);
tables = detectFixed(text, lines, consumed, sections, tables);

if isempty(tables)
    return
end
% 按出现位置排序并编号
[~, ord] = sort([tables.char_start]);
tables = tables(ord);
for k = 1:numel(tables)
    tables(k).id = sprintf('t%d', k);
end
end

% ---------------------------------------------------------------------------
function tables = detectMarkdown(text, lines, consumed, sections, tables)
m = numel(lines);
k = 1;
while k <= m
    if consumed(k) || ~isPipeLine(lines(k).text)
        k = k + 1;
        continue
    end
    if k + 1 > m || ~isSeparatorLine(lines(k + 1).text)
        k = k + 1;
        continue
    end
    headerCells = parsePipeCells(lines(k).text);
    rows = {};
    j = k + 2;
    while j <= m && ~consumed(j) && isPipeLine(lines(j).text) ...
            && ~isSeparatorLine(lines(j).text)
        rows{end + 1} = parsePipeCells(lines(j).text); %#ok<AGROW>
        j = j + 1;
    end
    if isempty(rows)
        k = k + 1;
        continue
    end
    for q = k:j - 1
        consumed(q) = true;
    end
    [caption, capIdx] = findCaption(lines, k, consumed);
    if capIdx > 0
        consumed(capIdx) = true;
    end
    nCols = numel(headerCells);
    for r = 1:numel(rows)
        nCols = max(nCols, numel(rows{r}));
    end
    header = padCells(headerCells, nCols);
    rowCells = cell(1, numel(rows));
    for r = 1:numel(rows)
        rowCells{r} = padCells(rows{r}, nCols);
    end
    tables = appendTable(tables, text, lines(k).start, sections, caption, ...
        header, rowCells, 'markdown');
    k = j;
end
end

function tables = detectTsv(text, lines, consumed, sections, tables)
m = numel(lines);
k = 1;
while k <= m
    if consumed(k)
        k = k + 1;
        continue
    end
    fields = splitTabs(lines(k).text);
    if numel(fields) < 2
        k = k + 1;
        continue
    end
    nCols = numel(fields);
    rows = {fields};
    j = k + 1;
    while j <= m && ~consumed(j)
        f2 = splitTabs(lines(j).text);
        if numel(f2) ~= nCols
            break
        end
        rows{end + 1} = f2; %#ok<AGROW>
        j = j + 1;
    end
    if numel(rows) < 2
        k = k + 1;
        continue
    end
    for q = k:j - 1
        consumed(q) = true;
    end
    [caption, capIdx] = findCaption(lines, k, consumed);
    if capIdx > 0
        consumed(capIdx) = true;
    end
    header = rows{1};
    dataRows = rows(2:end);
    tables = appendTable(tables, text, lines(k).start, sections, caption, ...
        header, dataRows, 'tsv');
    k = j;
end
end

function tables = detectFixed(text, lines, consumed, sections, tables)
m = numel(lines);
k = 1;
while k <= m
    if consumed(k)
        k = k + 1;
        continue
    end
    fields = splitFixed(lines(k).text);
    if numel(fields) < 2 || numel(lines(k).text) > 300
        k = k + 1;
        continue
    end
    nCols = numel(fields);
    rows = {fields};
    j = k + 1;
    while j <= m && ~consumed(j)
        f2 = splitFixed(lines(j).text);
        if numel(f2) ~= nCols
            break
        end
        rows{end + 1} = f2; %#ok<AGROW>
        j = j + 1;
    end
    if numel(rows) < 2
        k = k + 1;
        continue
    end
    % 至少一列以数字为主，避免把正文行误判为表格
    numericCols = 0;
    for c = 1:nCols
        cnt = 0;
        for r = 1:numel(rows)
            if isNumericCell(rows{r}{c})
                cnt = cnt + 1;
            end
        end
        if cnt / numel(rows) >= 0.6
            numericCols = numericCols + 1;
        end
    end
    headerNumeric = true;
    for c = 1:nCols
        if ~isNumericCell(rows{1}{c})
            headerNumeric = false;
            break
        end
    end
    ok = numericCols >= 1;
    if ok && headerNumeric
        ok = numel(rows) >= 3;
    end
    if ~ok
        k = k + 1;
        continue
    end
    for q = k:j - 1
        consumed(q) = true;
    end
    [caption, capIdx] = findCaption(lines, k, consumed);
    if capIdx > 0
        consumed(capIdx) = true;
    end
    header = rows{1};
    dataRows = rows(2:end);
    tables = appendTable(tables, text, lines(k).start, sections, caption, ...
        header, dataRows, 'fixed');
    k = j;
end
end

% ---------------------------------------------------------------------------
function tables = appendTable(tables, text, charStart, sections, caption, header, rows, format)
[sid, sheading] = bma.io.internal.sectionAt(sections, charStart);
e = struct();
e.id = '';
e.caption = char(caption);
e.header = header;
e.rows = rows;
e.section_id = sid;
e.section_heading = sheading;
e.char_start = double(charStart);
e.format = char(format);
e.n_rows = numel(rows);
e.n_cols = numel(header);
if isempty(tables)
    tables = e;
else
    tables(end + 1) = e; %#ok<AGROW>
end
end

function [caption, lineIdx] = findCaption(lines, tableStart, consumed)
% 向上回看 1-2 个非空行寻找 "Table 1." / "**Table S2**" / "表 1" 标题
caption = '';
lineIdx = 0;
for back = 1:3
    idx = tableStart - back;
    if idx < 1
        return
    end
    if consumed(idx)
        return
    end
    t = strtrim(lines(idx).text);
    if isempty(t)
        continue
    end
    if ~isempty(regexpi(t, '^(?:\*\*|__)?\s*(?:table|表)\s*(?:S?\d+|[IVX]+)', 'once'))
        caption = t;
        lineIdx = idx;
        return
    end
    return
end
end

function tf = isPipeLine(line)
t = strtrim(line);
tf = sum(t == '|') >= 2;
end

function tf = isSeparatorLine(line)
t = strtrim(line);
if sum(t == '|') < 1 || sum(t == '-') < 2
    tf = false;
    return
end
rest = regexprep(t, '[|\-:\s]', '');
tf = isempty(rest);
end

function cells = parsePipeCells(line)
s = strtrim(line);
s = strrep(s, '\|', char(1));
if ~isempty(s) && s(1) == '|'
    s = s(2:end);
end
if ~isempty(s) && s(end) == '|'
    s = s(1:end - 1);
end
cells = regexp(s, '\|', 'split');
for k = 1:numel(cells)
    c = strtrim(cells{k});
    c = strrep(c, char(1), '|');
    c = cleanCell(c);
    cells{k} = c;
end
end

function cells = splitTabs(line)
s = strtrim(char(line));
if isempty(strfind(s, char(9))) %#ok<STREMP>
    cells = {s};
    return
end
cells = strsplit(s, sprintf('\t'), 'CollapseDelimiters', false);
for k = 1:numel(cells)
    cells{k} = cleanCell(strtrim(cells{k}));
end
end

function cells = splitFixed(line)
s = strtrim(char(line));
cells = regexp(s, '\s{2,}', 'split');
cells = cells(~cellfun(@isempty, cells));
for k = 1:numel(cells)
    cells{k} = cleanCell(strtrim(cells{k}));
end
end

function c = cleanCell(c)
c = char(c);
c = regexprep(c, '^\*\*|\*\*$', '');
c = regexprep(c, '^__|__$', '');
c = regexprep(c, '^`|`$', '');
c = strtrim(c);
end

function cells = padCells(cells, nCols)
for k = numel(cells) + 1:nCols
    cells{k} = '';
end
% 单元格统一为 char
for k = 1:numel(cells)
    if isstring(cells{k})
        cells{k} = char(cells{k});
    end
end
end

function tf = isNumericCell(c)
if isstring(c)
    c = char(c);
end
c = strtrim(char(c));
tf = ~isempty(regexp(c, '^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?%?$', 'once'));
end
