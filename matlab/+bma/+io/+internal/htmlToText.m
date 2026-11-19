function [txt, title] = htmlToText(html)
%HTMLTOTEXT 抽取 HTML 正文纯文本，并尽量返回 <title>。
%   [txt, title] = bma.io.internal.htmlToText(html)
%
%   正文优先使用 Text Analytics 的 htmlTree + extractHTMLText；若不可用则退化为
%   正则清洗。两条路径都会：
%     * 移除 script/style/comment；
%     * 把 <table> 替换为占位标记，解析后回填为「制表符分隔行」——
%       这样 bma.io.extractTables 能在 html 文档里正确定位表格（含字符偏移）。
%
%   注：MATLAB regexp 中 \b 不是 PCRE 的词边界，这里用前导/尾随字符类与前瞻。
txt = '';
title = '';
if isempty(html)
    return
end
if isstring(html)
    html = char(html);
end
html = char(html);

% <title>
m = regexpi(html, '<title[^>]*>(.*?)</title>', 'tokens', 'once');
if ~isempty(m)
    titleRaw = regexprep(m{1}, '<[^>]*>', ' ');
    title = strtrim(bma.io.internal.htmlUnescape(titleRaw));
    title = regexprep(title, '\s+', ' ');
end

% 移除脚本、样式、注释
clean = regexprep(html, '<script(?=[\s>/])[^>]*>[\s\S]*?</script>', ' ', 'ignorecase');
clean = regexprep(clean, '<style(?=[\s>/])[^>]*>[\s\S]*?</style>', ' ', 'ignorecase');
clean = regexprep(clean, '<!--[\s\S]*?-->', ' ');

% 表格 -> 占位标记（解析完成后回填 TSV 文本）
[clean, tableTexts, markers] = replaceTables(clean);

% 首选 htmlTree/extractHTMLText
try
    tree = htmlTree(clean);
    body = [];
    try
        body = findElement(tree, 'body');
    catch
        try
            body = tree.findElement('body');
        catch
            body = [];
        end
    end
    if ~isempty(body)
        txt = char(extractHTMLText(body(1)));
    else
        txt = char(extractHTMLText(tree));
    end
catch
    txt = '';
end

% 回退：正则清洗
if isempty(strtrim(txt))
    txt = regexpText(clean);
end

% 回填表格文本
for k = 1:numel(markers)
    if ~isempty(tableTexts{k})
        txt = strrep(txt, markers{k}, tableTexts{k});
    end
end
end

% ---------------------------------------------------------------------------
function [htmlOut, tableTexts, markers] = replaceTables(html)
tableTexts = {};
markers = {};
htmlOut = html;
[s, e] = regexp(html, '<table(?=[\s>/])[^>]*>[\s\S]*?</table>', 'start', 'end');
for k = numel(s):-1:1
    block = html(s(k):e(k));
    tsv = tableBlockToTsv(block);
    marker = sprintf('__BMATBL%04d__', k);
    tableTexts{k} = tsv; %#ok<AGROW>
    markers{k} = marker; %#ok<AGROW>
    htmlOut = [htmlOut(1:s(k) - 1) '<p>' marker '</p>' htmlOut(e(k) + 1:end)];
end
end

function tsv = tableBlockToTsv(block)
lines = {};
cap = regexpi(block, '<caption[^>]*>([\s\S]*?)</caption>', 'tokens', 'once');
caption = '';
if ~isempty(cap)
    caption = stripToText(cap{1});
end
if ~isempty(caption)
    lines{end + 1} = caption; %#ok<AGROW>
end
rows = regexpi(block, '<tr(?=[\s>/])[^>]*>([\s\S]*?)</tr>', 'tokens');
for r = 1:numel(rows)
    cells = regexpi(rows{r}{1}, '<t[hd](?=[\s>/])[^>]*>([\s\S]*?)</t[hd]>', 'tokens');
    cs = cell(1, numel(cells));
    for c = 1:numel(cells)
        cs{c} = stripToText(cells{c}{1});
    end
    lines{end + 1} = strjoin(cs, char(9)); %#ok<AGROW>
end
tsv = strjoin(lines, char(10));
end

function t = stripToText(s)
t = regexprep(s, '<[^>]*>', ' ');
t = bma.io.internal.htmlUnescape(t);
t = regexprep(t, '\s+', ' ');
t = strtrim(t);
end

function txt = regexpText(html)
% 块级标签 -> 换行；表格单元格 -> 制表符
txt = regexprep(html, '</?(?:p|br|div|li|ul|ol|tr|h[1-6]|section|article|table|thead|tbody|blockquote|pre|dt|dd|header|footer|nav|main)(?=[\s>/])[^>]*>', '\n', 'ignorecase');
txt = regexprep(txt, '</?t[dh](?=[\s>/])[^>]*>', '\t', 'ignorecase');
txt = regexprep(txt, '<[^>]*>', '');
txt = bma.io.internal.htmlUnescape(txt);
end
