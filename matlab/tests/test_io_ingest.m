% test_io_ingest.m — 验证 bma.io.ingest 的多格式解析、产物布局与幂等。
% 覆盖 .md/.txt/.html/.docx/.pdf；docx/pdf 由测试内自生成的合法最小文档验证。
% 由 matlab/tests/run_all_tests.m 或 RPC test.run 调用，失败即抛异常。

fprintf('  [test_io_ingest] start\n');
workDir = tempname;
mkdir(workDir);
cleaner = onCleanup(@() safeRmdir(workDir));
litDir = fullfile(workDir, 'lit');
bma.util.ensureDir(litDir);
runDir = fullfile(workDir, '.bma', 'runs', 'r-test');
bma.util.ensureDir(runDir);

% ---- 1) Markdown：章节 + 数字 + 表格 ----
mdLines = { ...
    '# Kinetic Characterization of Enzyme Variants', ...
    '', ...
    '## Abstract', ...
    'We report steady-state kinetics with Km = 12.5 uM and kcat = 3.4 s-1 for the lead variant.', ...
    '', ...
    '## Methods', ...
    'Assays were performed at 37 C for 24 h using 0.5 uM enzyme and 5-10 uM substrate.', ...
    '', ...
    '## Results', ...
    'The EC50 was 0.8 nM while R0 ~ 2.5 under the tested conditions.', ...
    '', ...
    'Table 1. Summary of fitted kinetic parameters.', ...
    '', ...
    '| Variant | Km (uM) | kcat (1/s) |', ...
    '|---|---|---|', ...
    '| WT | 12.5 | 3.4 |', ...
    '| Mutant A | 8.1 | 1.2 |', ...
    '', ...
    '## References', ...
    '1. Smith J, Doe J. Kinetic analysis. J Biol Chem. 2019; 294(4): 1234-1250.'};
mdPath = fullfile(litDir, 'enzyme_variants.md');
writeText(mdPath, strjoin(mdLines, char(10)));

doc = bma.io.ingest(mdPath, runDir);
required = {'doc_id', 'format', 'title', 'char_count', 'sections', 'numbers', ...
    'tables', 'warnings', 'text_path', 'sections_path', 'numbers_path', 'tables_path'};
for f = 1:numel(required)
    assertTrue(isfield(doc, required{f}), sprintf('ingest 缺少字段 %s', required{f}));
end
assertTrue(strcmp(doc.format, 'markdown'), 'md 格式应为 markdown');
assertTrue(contains(doc.title, 'Kinetic'), sprintf('title 应含 Kinetic，实际 "%s"', doc.title));
assertTrue(doc.char_count > 300, 'md 文本长度应 > 300');
assertTrue(numel(doc.sections) >= 4, sprintf('md 章节应 >= 4，实际 %d', numel(doc.sections)));
assertTrue(numel(doc.numbers) >= 5, sprintf('md 数字应 >= 5，实际 %d', numel(doc.numbers)));
assertTrue(numel(doc.tables) >= 1, 'md 应识别 Markdown 表格');
assertTrue(isstruct(doc.sections) && isfield(doc.sections, 'heading'), 'sections 字段错误');
assertTrue(isstruct(doc.numbers) && isfield(doc.numbers, 'value'), 'numbers 字段错误');
assertTrue(isstruct(doc.tables) && isfield(doc.tables, 'header'), 'tables 字段错误');
assertTrue(hasValue(doc.numbers, 12.5), '应抽取到 Km=12.5');
assertTrue(hasValue(doc.numbers, 3.4), '应抽取到 kcat=3.4');

% 产物文件与路径
expectedText = bma.io.internal.normalizeText(bma.util.readText(mdPath));
textFile = resolvePath(workDir, doc.text_path);
assertTrue(isfile(textFile), 'text.txt 应存在');
assertTrue(strcmp(bma.util.readText(textFile), expectedText), 'text.txt 内容应为归一化原文');
assertTrue(isfile(resolvePath(workDir, doc.sections_path)), 'sections.json 应存在');
assertTrue(isfile(resolvePath(workDir, doc.numbers_path)), 'numbers.json 应存在');
assertTrue(isfile(resolvePath(workDir, doc.tables_path)), 'tables.json 应存在');
assertTrue(isfolder(doc.doc_dir_abs), 'doc_dir_abs 应存在');
assertTrue(strcmp(fileparts(textFile), doc.doc_dir_abs), ...
    'text.txt 应位于 <runDir>/literature/<doc_id>/');
assertTrue(contains(doc.doc_id, '-'), 'doc_id 应含 hash 后缀');
assertTrue(numel(doc.doc_id) > 8, 'doc_id 长度异常');

% 幂等：重复 ingest 得到相同 doc_id 与相同文件内容
before = {bma.util.readText(textFile), ...
    bma.util.readText(resolvePath(workDir, doc.sections_path)), ...
    bma.util.readText(resolvePath(workDir, doc.numbers_path)), ...
    bma.util.readText(resolvePath(workDir, doc.tables_path))};
docAgain = bma.io.ingest(mdPath, runDir);
assertTrue(strcmp(docAgain.doc_id, doc.doc_id), '重复 ingest 的 doc_id 应相同（幂等）');
after = {bma.util.readText(textFile), ...
    bma.util.readText(resolvePath(workDir, doc.sections_path)), ...
    bma.util.readText(resolvePath(workDir, doc.numbers_path)), ...
    bma.util.readText(resolvePath(workDir, doc.tables_path))};
for k = 1:4
    assertTrue(strcmp(before{k}, after{k}), sprintf('重复 ingest 的第 %d 个产物应完全一致', k));
end
% 不同 run_dir 下同样内容 -> 相同 doc_id
docOther = bma.io.ingest(mdPath, fullfile(workDir, '.bma', 'runs', 'r-other'));
assertTrue(strcmp(docOther.doc_id, doc.doc_id), '同一文件在不同 run_dir 下 doc_id 应相同');

% ---- 2) TXT ----
txtPath = fullfile(litDir, 'sample_notes.txt');
txtLines = { ...
    'Steady State Kinetics of the Wild Type Enzyme', ...
    '', ...
    'Abstract', ...
    'The Michaelis constant Km was 15.2 uM and the maximal rate Vmax was 2.1 uM/min.', ...
    '', ...
    'Methods', ...
    'All assays were performed at 25 C for 30 min with 100 nM enzyme.'};
writeText(txtPath, strjoin(txtLines, char(10)));
docTxt = bma.io.ingest(txtPath, runDir);
assertTrue(strcmp(docTxt.format, 'txt'), 'txt 格式错误');
assertTrue(docTxt.char_count > 100, 'txt 文本长度异常');
assertTrue(numel(docTxt.sections) >= 2, 'txt 章节应 >= 2');
assertTrue(numel(docTxt.numbers) >= 2, 'txt 数字应 >= 2');
assertTrue(~isempty(docTxt.title), 'txt 标题不应为空');

% ---- 3) HTML ----
htmlPath = fullfile(litDir, 'enzyme_study.html');
html = [ ...
    '<!DOCTYPE html><html><head><meta charset="utf-8">' ...
    '<title>Kinetic Study of Enzyme Variants</title></head><body>' ...
    '<h1>Kinetic Study of Enzyme Variants</h1>' ...
    '<h2>Abstract</h2><p>We measured the Michaelis constant Km = 12.5 uM and kcat = 3.4 s-1.</p>' ...
    '<h2>Methods</h2><p>Assays used 0.5 uM enzyme at 37 C for 24 h.</p>' ...
    '<h2>Results</h2><p>The EC50 was 0.8 nM and R0 ~ 2.5.</p>' ...
    '</body></html>'];
writeText(htmlPath, html);
docHtml = bma.io.ingest(htmlPath, runDir);
assertTrue(strcmp(docHtml.format, 'html'), 'html 格式错误');
assertTrue(strcmpi(docHtml.title, 'Kinetic Study of Enzyme Variants'), ...
    sprintf('html title 应来自 <title>，实际 "%s"', docHtml.title));
assertTrue(docHtml.char_count > 80, 'html 文本长度异常');
assertTrue(numel(docHtml.sections) >= 2, sprintf('html 章节应 >= 2，实际 %d', numel(docHtml.sections)));
assertTrue(numel(docHtml.numbers) >= 2, 'html 数字应 >= 2');
assertTrue(contains(bma.util.readText(resolvePath(workDir, docHtml.text_path)), 'Michaelis'), ...
    'html 正文应包含 Michaelis');

% ---- 4) DOCX（测试内生成最小合法 docx） ----
docxPath = fullfile(litDir, 'enzyme_variants.docx');
makeDocx(docxPath, { ...
    'Kinetic Characterization of Enzyme Variants', '', 'Abstract', ...
    'We measured the Michaelis constant Km = 12.5 uM and kcat = 3.4 s-1.', '', ...
    'Methods', 'Assays were performed at 37 C for 24 h with 0.5 uM enzyme.', '', ...
    'Results', 'The EC50 was 0.8 nM for the lead compound.'});
docDocx = bma.io.ingest(docxPath, runDir);
assertTrue(strcmp(docDocx.format, 'docx'), 'docx 格式错误');
assertTrue(docDocx.char_count > 80, sprintf('docx 文本长度异常：%d', docDocx.char_count));
assertTrue(numel(docDocx.numbers) >= 3, sprintf('docx 数字应 >= 3，实际 %d', numel(docDocx.numbers)));
assertTrue(hasValue(docDocx.numbers, 12.5), 'docx 应抽取到 12.5');

% ---- 5) PDF（测试内生成最小合法 PDF） ----
pdfPath = fullfile(litDir, 'enzyme_variants.pdf');
makePdf(pdfPath, { ...
    'Kinetic Study of Enzyme Variants', ...
    'Abstract', ...
    'We measured the Michaelis constant Km = 12.5 uM and kcat = 3.4 s-1.', ...
    'Methods', ...
    'Assays were performed at 37 C for 24 h.', ...
    'Results', ...
    'The EC50 was 0.8 nM for the lead compound.'});
docPdf = bma.io.ingest(pdfPath, runDir);
assertTrue(strcmp(docPdf.format, 'pdf'), 'pdf 格式错误');
assertTrue(docPdf.char_count > 80, sprintf('pdf 文本长度异常：%d', docPdf.char_count));
assertTrue(numel(docPdf.numbers) >= 2, sprintf('pdf 数字应 >= 2，实际 %d', numel(docPdf.numbers)));
assertTrue(contains(bma.util.readText(resolvePath(workDir, docPdf.text_path)), 'Michaelis'), ...
    'pdf 正文应包含 Michaelis');

% ---- 6) supportedFormats ----
fmts = bma.io.supportedFormats();
assertTrue(iscell(fmts), 'supportedFormats 应返回 cellstr');
for need = {'.pdf', '.docx', '.txt', '.md', '.html', '.htm', '.markdown'}
    assertTrue(any(strcmp(fmts, need{1})), sprintf('supportedFormats 缺少 %s', need{1}));
end
[fmts2, details] = bma.io.supportedFormats();
assertTrue(iscell(fmts2) && numel(fmts2) == numel(fmts), 'supportedFormats 两个输出不一致');
assertTrue(isstruct(details) && isfield(details, 'extension'), 'details 字段错误');
assertTrue(numel(details) == numel(fmts), 'details 数量应与扩展名一致');

% ---- 7) 不支持的格式 -> 明确错误 ----
xyzPath = fullfile(litDir, 'data.xyz');
writeText(xyzPath, 'not a paper');
caught = false;
try
    bma.io.ingest(xyzPath, runDir);
catch err
    caught = strcmp(err.identifier, 'bma:io:unsupportedFormat');
end
assertTrue(caught, '不支持的格式应报 bma:io:unsupportedFormat');

% ---- 8) 大文件截断策略（MaxBytes 可覆盖，便于测试） ----
bigPath = fullfile(litDir, 'big_notes.txt');
writeText(bigPath, repmat('The measured rate was 1.5 uM/min under standard conditions. ', 1, 300));
docBig = bma.io.ingest(bigPath, runDir, 'MaxBytes', 400);
assertTrue(docBig.truncated, '大文件应标记 truncated');
assertTrue(~isempty(docBig.warnings), '大文件截断应给 warning');
assertTrue(docBig.char_count <= 600, sprintf('截断后字符数异常：%d', docBig.char_count));

% ---- 9) WorkDir 选项 + 相对路径 ----
docRel = bma.io.ingest('lit/enzyme_variants.md', '.bma/runs/r-rel', 'WorkDir', workDir);
assertTrue(strcmp(docRel.doc_id, doc.doc_id), '带 WorkDir 的相对路径解析后 doc_id 应一致');
assertTrue(isfile(resolvePath(workDir, docRel.text_path)), 'WorkDir 模式下产物路径应正确');

% ---- 10) 空文本 -> 空章节/数字/表格 + warning ----
emptyPath = fullfile(litDir, 'empty.txt');
writeText(emptyPath, '');
docEmpty = bma.io.ingest(emptyPath, runDir);
assertTrue(docEmpty.char_count == 0, '空文本 char_count 应为 0');
assertTrue(isempty(docEmpty.sections), '空文本 sections 应为空');
assertTrue(isempty(docEmpty.numbers), '空文本 numbers 应为空');
assertTrue(~isempty(docEmpty.warnings), '空文本应给 warning');

fprintf('  [test_io_ingest] PASS (md/txt/html/docx/pdf + idempotent)\n');

% ---------------------------------------------------------------------------
function assertTrue(cond, msg)
if ~cond
    error('test_io_ingest:fail', '%s', msg);
end
end

function safeRmdir(d)
try
    if isfolder(d)
        rmdir(d, 's');
    end
catch
end
end

function writeText(path, txt)
bma.util.writeTextAtomic(path, txt);
end

function p = resolvePath(workDir, rel)
p = bma.util.absPath(workDir, rel);
end

function tf = hasValue(nums, value)
tf = false;
for k = 1:numel(nums)
    if abs(double(nums(k).value) - value) < 1e-9
        tf = true;
        return
    end
end
end

function s = xmlEscape(s)
s = strrep(s, '&', '&amp;');
s = strrep(s, '<', '&lt;');
s = strrep(s, '>', '&gt;');
s = strrep(s, '"', '&quot;');
end

function makeDocx(path, paragraphs)
% 生成最小合法 .docx（OOXML zip 包），供 extractFileText 解析测试
stage = tempname;
mkdir(stage);
bma.util.ensureDir(fullfile(stage, '_rels'));
bma.util.ensureDir(fullfile(stage, 'word'));
bma.util.ensureDir(fullfile(stage, 'word', '_rels'));
ct = [ ...
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' ...
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' ...
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' ...
    '<Default Extension="xml" ContentType="application/xml"/>' ...
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' ...
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>' ...
    '</Types>'];
rels = [ ...
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' ...
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' ...
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' ...
    '</Relationships>'];
docRels = [ ...
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' ...
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' ...
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' ...
    '</Relationships>'];
styles = [ ...
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' ...
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' ...
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>' ...
    '</w:styles>'];
body = '';
for k = 1:numel(paragraphs)
    txt = paragraphs{k};
    if isempty(txt)
        body = [body '<w:p/>']; %#ok<AGROW>
    else
        body = [body '<w:p><w:r><w:t xml:space="preserve">' ...
            xmlEscape(txt) '</w:t></w:r></w:p>']; %#ok<AGROW>
    end
end
document = [ ...
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' ...
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' ...
    '<w:body>' body '<w:sectPr/></w:body></w:document>'];
writeText(fullfile(stage, '[Content_Types].xml'), ct);
writeText(fullfile(stage, '_rels', '.rels'), rels);
writeText(fullfile(stage, 'word', 'document.xml'), document);
writeText(fullfile(stage, 'word', '_rels', 'document.xml.rels'), docRels);
writeText(fullfile(stage, 'word', 'styles.xml'), styles);
zipTmp = fullfile(stage, 'package.zip');
files = {'[Content_Types].xml', '_rels/.rels', 'word/document.xml', ...
    'word/_rels/document.xml.rels', 'word/styles.xml'};
zip(zipTmp, files, stage);
[ok, msg] = movefile(zipTmp, path, 'f');
if ~ok
    error('test_io_ingest:docx', '生成 docx 失败：%s', msg);
end
safeRmdir(stage);
end

function makePdf(path, lines)
% 用 MATLAB Report Generator 生成合法 PDF（license 已在验收环境确认可用）
bma.util.ensureDir(fileparts(path));
try
    import mlreportgen.dom.*
    d = Document(path, 'pdf');
    for k = 1:numel(lines)
        append(d, Paragraph(lines{k}));
    end
    close(d);
catch err
    error('test_io_ingest:pdf', 'Report Generator 生成 PDF 失败：%s', err.message);
end
end
