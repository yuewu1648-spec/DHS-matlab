function [txt, warnings] = docxToText(path, maxBytes)
%DOCXTOTEXT 读取 .docx：extractFileText + 把表格结构化保留为 TSV 文本。
%   [txt, warnings] = bma.io.internal.docxToText(path, maxBytes)
%
%   Word 文档里的表格若直接由 extractFileText 读取，单元格边界会丢失，
%   bma.io.extractTables 无法识别。这里：
%     1) 解包 docx（zip），把每个 <w:tbl> 替换为一段占位标记段落；
%     2) 重新打包为临时 docx，用 extractFileText 读取（保留原始段落顺序）；
%     3) 把占位标记回填为「制表符分隔」的表格文本，字符偏移与 body 顺序一致。
%   若重打包路径失败，回退为原始 extractFileText 并把表格文本追加在文末。
warnings = {};
txt = '';
if nargin < 2 || isempty(maxBytes)
    maxBytes = 2 * 1024 * 1024;
end
info = dir(path);
if ~isempty(info) && info(1).bytes > maxBytes
    warnings{end + 1} = sprintf( ...
        '文件较大（%.2f MB > %.2f MB）：DOCX 需整体解析，已截断解析文本。', ...
        info(1).bytes / 1048576, maxBytes / 1048576);
end

tableTexts = {};
markers = {};
tmpDir = '';
tmpDocx = '';
zipTmp = '';
try
    tmpDir = tempname;
    bma.util.ensureDir(tmpDir);
    unzip(path, tmpDir);
    docXmlPath = fullfile(tmpDir, 'word', 'document.xml');
    if ~isfile(docXmlPath)
        error('bma:io:docx', 'docx 缺少 word/document.xml');
    end
    xml = bma.util.readText(docXmlPath);
    [xml2, tableTexts, markers] = replaceTables(xml);
    bma.util.writeTextAtomic(docXmlPath, xml2);
    tmpDocx = [tempname '.docx'];
    zipTmp = [tempname '.zip'];
    relFiles = walkFiles(tmpDir, '');
    relFiles = cellfun(@(p) strrep(p, '/', filesep), relFiles, 'UniformOutput', false);
    zip(zipTmp, relFiles, tmpDir);
    [ok, msg] = movefile(zipTmp, tmpDocx, 'f');
    if ~ok
        error('bma:io:docx', '无法生成临时 docx：%s', msg);
    end
    raw = extractFileText(tmpDocx);
    txt = char(raw);
    for k = 1:numel(markers)
        if ~isempty(tableTexts{k})
            txt = strrep(txt, markers{k}, tableTexts{k});
        end
    end
catch err
    warnings{end + 1} = sprintf('DOCX 表格结构化失败，回退为纯文本读取：%s', err.message);
    raw = extractFileText(path);
    txt = char(raw);
    if ~isempty(tableTexts)
        txt = [txt char(10) char(10) strjoin(tableTexts, [char(10) char(10)])]; %#ok<AGROW>
    end
end
% 清理临时文件
try
    if ~isempty(zipTmp) && isfile(zipTmp)
        delete(zipTmp);
    end
catch
end
try
    if ~isempty(tmpDocx) && isfile(tmpDocx)
        delete(tmpDocx);
    end
catch
end
try
    if ~isempty(tmpDir) && isfolder(tmpDir)
        rmdir(tmpDir, 's');
    end
catch
end
if numel(txt) > maxBytes
    txt = txt(1:maxBytes);
end
end

% ---------------------------------------------------------------------------
function relFiles = walkFiles(base, prefix)
relFiles = {};
d = dir(fullfile(base, '*'));
for k = 1:numel(d)
    name = d(k).name;
    if any(strcmp(name, {'.', '..'}))
        continue
    end
    if d(k).isdir
        sub = walkFiles(fullfile(base, name), [prefix name '/']);
        relFiles = [relFiles, sub]; %#ok<AGROW>
    else
        relFiles{end + 1} = [prefix name]; %#ok<AGROW>
    end
end
end

function [xmlOut, tableTexts, markers] = replaceTables(xml)
xmlOut = xml;
tableTexts = {};
markers = {};
[s, e] = regexp(xml, '<w:tbl(?=[\s>/])[^>]*>[\s\S]*?</w:tbl>', 'start', 'end');
for k = numel(s):-1:1
    block = xml(s(k):e(k));
    marker = sprintf('__BMAWDTBL%04d__', k);
    tableTexts{k} = docxTableToTsv(block); %#ok<AGROW>
    markers{k} = marker; %#ok<AGROW>
    xmlOut = [xmlOut(1:s(k) - 1) ...
        '<w:p><w:r><w:t>' marker '</w:t></w:r></w:p>' ...
        xmlOut(e(k) + 1:end)];
end
end

function tsv = docxTableToTsv(block)
rows = regexp(block, '<w:tr(?=[\s>/])[^>]*>[\s\S]*?</w:tr>', 'match');
lines = cell(1, numel(rows));
for r = 1:numel(rows)
    cells = regexp(rows{r}, '<w:tc(?=[\s>/])[^>]*>[\s\S]*?</w:tc>', 'match');
    cs = cell(1, numel(cells));
    for c = 1:numel(cells)
        cs{c} = docxCellText(cells{c});
    end
    lines{r} = strjoin(cs, char(9));
end
tsv = strjoin(lines, char(10));
end

function t = docxCellText(cellXml)
% 提取单元格内全部 <w:t> 文本（保持 run 顺序），并处理 <w:tab/>、<w:br/>
cellXml = regexprep(cellXml, '<w:tab\s*/>', char(9));
cellXml = regexprep(cellXml, '<w:br\s*/>', ' ');
tokens = regexp(cellXml, '<w:t(?=[\s>/])[^>]*>([\s\S]*?)</w:t>', 'tokens');
parts = cell(1, numel(tokens));
for k = 1:numel(tokens)
    parts{k} = bma.io.internal.htmlUnescape(tokens{k}{1});
end
t = strjoin(parts, '');
t = regexprep(t, '<[^>]*>', '');
t = regexprep(t, '\s+', ' ');
t = strtrim(t);
end
