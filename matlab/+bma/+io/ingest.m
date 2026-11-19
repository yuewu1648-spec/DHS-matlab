function doc = ingest(path, runDir, varargin)
%INGEST 解析一篇文献并落盘结构化产物（幂等）。
%   doc = bma.io.ingest(path, runDir)
%   doc = bma.io.ingest(path, runDir, 'WorkDir', workDir, 'DocId', id)
%
%   支持格式见 bma.io.supportedFormats()：.pdf/.docx/.txt/.md/.markdown/.html/.htm。
%   PDF/DOCX 用 Text Analytics extractFileText；HTML 用 htmlTree/extractHTMLText；
%   txt/md 直读。产物写入 <runDir>/literature/<doc_id>/：
%       text.txt / sections.json / numbers.json / tables.json
%
%   返回 struct（字段对齐 DESIGN §4.4 literature.ingest）：
%       doc_id, format, title, char_count, sections, numbers, tables, warnings,
%       text_path, sections_path, numbers_path, tables_path,
%       doc_dir, doc_dir_abs, source_path, source_bytes, truncated, 计数与时间戳
%   *_path 为相对 work_dir 的正斜杠路径；无 WorkDir 时由 runDir 反推
%   （runDir 位于 <workDir>/.bma/runs/<id> 时取 .bma 之前的目录）。
p = inputParser;
p.addParameter('DocId', '', @(x)ischar(x) || isstring(x));
p.addParameter('WorkDir', '', @(x)ischar(x) || isstring(x));
p.addParameter('MaxBytes', 2 * 1024 * 1024, @(x)isnumeric(x) && isscalar(x));
p.addParameter('ExtractFigures', true, @(x)islogical(x) || isnumeric(x));
p.addParameter('MaxFigures', 40, @(x)isnumeric(x) && isscalar(x));
p.parse(varargin{:});
opts = p.Results;

if nargin < 1 || isempty(path)
    error('bma:io:missingPath', 'bma.io.ingest 需要文献路径。');
end
if isstring(path)
    path = char(path);
end
path = char(path);
if nargin < 2 || isempty(runDir)
    runDir = '';
elseif isstring(runDir)
    runDir = char(runDir);
end

% ---- 解析 workDir / runDir -------------------------------------------------
if isempty(opts.WorkDir)
    if isempty(runDir)
        workDir = pwd;
    elseif isAbsolutePath(runDir)
        workDir = inferWorkDir(runDir);
    else
        workDir = pwd;
    end
else
    workDir = char(opts.WorkDir);
    if ~isAbsolutePath(workDir)
        workDir = bma.util.absPath(pwd, workDir);
    end
end
srcAbs = path;
if ~isAbsolutePath(srcAbs)
    srcAbs = bma.util.absPath(workDir, srcAbs);
end
if ~isfile(srcAbs)
    error('bma:io:fileNotFound', '文献文件不存在：%s', srcAbs);
end
if isempty(runDir)
    runDirAbs = fullfile(workDir, '.bma');
elseif isAbsolutePath(runDir)
    runDirAbs = runDir;
else
    runDirAbs = bma.util.absPath(workDir, runDir);
end

% ---- 格式与文本 -----------------------------------------------------------
fmt = bma.io.internal.detectFormat(srcAbs);
if ~fmt.supported
    error('bma:io:unsupportedFormat', ...
        '不支持的文献格式 "%s"；支持：%s', fmt.ext, ...
        strjoin(bma.io.supportedFormats(), ', '));
end
[txt, titleHint, warnings, info] = bma.io.internal.readSourceText(srcAbs, fmt, opts.MaxBytes);
txt = bma.io.internal.normalizeText(txt);
if isempty(txt)
    warnings{end + 1} = '解析结果为空文本，请检查文件是否为扫描版 PDF（需 OCR）或内容为空。'; %#ok<AGROW>
end

% ---- 结构化解析 -----------------------------------------------------------
sections = bma.io.sectionize(txt);
[sections, sentences] = bma.io.sentenceize(txt, sections);
[layoutConfidence, lowConfidenceSections, lowConfidenceRatio, layoutWarning] = ...
    sectionConfidenceSummary(sections);
if ~isempty(layoutWarning)
    warnings{end + 1} = layoutWarning; %#ok<AGROW>
end
numbers = bma.io.extractNumbers(txt, sections);
numbers = assignSentenceIds(numbers, sections);
tables = bma.io.extractTables(txt, sections);
% ISSUE-015: detect equation-number-only lines (formulas are often bitmaps).
eqTokens = regexp(txt, '(?m)^\s*\((\d+)\)\s*$', 'tokens');
equationsAsImages = {};
for q = 1:numel(eqTokens), equationsAsImages{end+1} = eqTokens{q}{1}; end %#ok<AGROW>
if ~isempty(equationsAsImages)
    warnings{end+1} = sprintf(['检测到公式编号占位符 (%s)：这些公式可能以位图排版；' ...
        '必须从正文/图注反推或人工校对 PDF，不能把占位符当作公式内容。'], ...
        strjoin(unique(equationsAsImages), ', '));
end
if isempty(sections) && ~isempty(txt)
    warnings{end + 1} = '未识别到章节标题，已将全文作为单章节处理。'; %#ok<AGROW>
end

% ---- 落盘（幂等：相同输入 -> 相同 doc_id 与相同文件内容） -------------------
if isempty(strtrim(char(opts.DocId)))
    docId = bma.io.internal.docId(srcAbs, txt);
else
    docId = sanitizeDocId(char(opts.DocId));
end
docDir = fullfile(runDirAbs, 'literature', docId);
bma.util.ensureDir(docDir);
textFile = fullfile(docDir, 'text.txt');
sectionsFile = fullfile(docDir, 'sections.json');
numbersFile = fullfile(docDir, 'numbers.json');
tablesFile = fullfile(docDir, 'tables.json');
sentencesFile = fullfile(docDir, 'sentences.json');
bma.util.writeTextAtomic(textFile, txt);
bma.util.writeJsonAtomic(sectionsFile, sections);
bma.util.writeJsonAtomic(numbersFile, numbers);
bma.util.writeJsonAtomic(tablesFile, tables);
bma.util.writeJsonAtomic(sentencesFile, sentences);

% ---- PDF 位图插图（ISS-12；矢量图/JPX 会明确告警） ----
figures = struct('index', {}, 'file', {}, 'width', {}, 'height', {}, ...
    'page', {}, 'caption', {}, 'bytes', {}, 'filter', {}, 'format', {});
figureWarnings = {};
figuresPath = '';
figureClass = '';
vectorOnly = false;
figuresRasterized = false;
figureReason = '';
if strcmpi(fmt.format, 'pdf') && logical(opts.ExtractFigures)
    try
        figOut = bma.io.extractPdfFigures(srcAbs, fullfile(docDir, 'figures'), ...
            struct('max_figures', opts.MaxFigures));
        figureWarnings = figOut.warnings;
        figureClass = figOut.figure_class;
        vectorOnly = figOut.vector_only;
        figuresRasterized = figOut.rasterized;
        figureReason = figOut.reason;
        figures = addCaptions(figOut.figures, txt);
        if ~isempty(figures)
            for k = 1:numel(figures)
                figures(k).rel_path = bma.util.relPath(workDir, ...
                    fullfile(docDir, 'figures', figures(k).file));
            end
        end
        manifest = struct('schema', 'bma.literatureFigures.v1', ...
            'source', srcAbs, 'figures', figures, 'count', numel(figures), ...
            'figure_class', figureClass, 'vector_only', vectorOnly, ...
            'rasterized', figuresRasterized, 'reason', figureReason);
        figuresPath = fullfile(docDir, 'figures.json');
        bma.util.writeJsonAtomic(figuresPath, manifest);
    catch err
        figureWarnings{end+1} = sprintf('PDF 插图抽取失败：%s', err.message);
    end
end

% ---- 返回 -----------------------------------------------------------------
doc = struct();
doc.doc_id = docId;
doc.format = fmt.format;
doc.title = chooseTitle(titleHint, sections, txt, srcAbs);
doc.char_count = numel(txt);
doc.sections = sections;
doc.numbers = numbers;
doc.tables = tables;
doc.sentences = sentences;
doc.sentence_count = numel(sentences);
doc.figures = figures;
doc.figure_count = numel(figures);
doc.figure_class = figureClass;
doc.vector_only = logical(vectorOnly);
doc.figures_rasterized = logical(figuresRasterized);
doc.figure_reason = figureReason;
doc.figure_warnings = figureWarnings;
doc.warnings = [warnings, figureWarnings];
doc.text_path = bma.util.relPath(workDir, textFile);
doc.sections_path = bma.util.relPath(workDir, sectionsFile);
doc.numbers_path = bma.util.relPath(workDir, numbersFile);
doc.tables_path = bma.util.relPath(workDir, tablesFile);
doc.sentences_path = bma.util.relPath(workDir, sentencesFile);
if ~isempty(figuresPath)
    doc.figures_path = bma.util.relPath(workDir, figuresPath);
end
doc.doc_dir = bma.util.relPath(workDir, docDir);
doc.doc_dir_abs = docDir;
doc.source_path = srcAbs;
doc.source_bytes = info.bytes;
if isfield(info, 'text_chars') && ~isempty(info.text_chars)
    doc.text_chars = info.text_chars;
else
    doc.text_chars = numel(txt);
end
if isfield(info, 'text_chars_total') && ~isempty(info.text_chars_total)
    doc.text_chars_total = info.text_chars_total;
else
    doc.text_chars_total = numel(txt);
end
doc.truncated = logical(info.truncated);
doc.truncation_reason = '';
if doc.truncated
    doc.truncation_reason = sprintf('按字符上限截断：%d -> %d', doc.text_chars_total, doc.text_chars);
end
doc.section_count = numel(sections);
doc.section_confidence = layoutConfidence;
doc.low_confidence_sections = lowConfidenceSections;
doc.low_confidence_ratio = lowConfidenceRatio;
doc.number_count = numel(numbers);
doc.table_count = numel(tables);
doc.equations_as_images = equationsAsImages;
doc.created_at = bma.util.nowIso();
end

% ---------------------------------------------------------------------------
function tf = isAbsolutePath(p)
tf = ~isempty(regexp(char(p), '^([A-Za-z]:[\\/]|\\\\|/)', 'once'));
end

function workDir = inferWorkDir(runDir)
% 从 <workDir>/.bma/... 反推 workDir；无法反推时退回 pwd
workDir = pwd;
m = regexp(char(runDir), '[\\/]\.bma(?=[\\/]|$)', 'once');
if ~isempty(m) && m > 1
    workDir = char(runDir);
    workDir = workDir(1:m - 1);
    if numel(workDir) == 2 && workDir(2) == ':'
        workDir = [workDir filesep];
    end
end
end

function id = sanitizeDocId(id)
id = lower(strtrim(char(id)));
id = regexprep(id, '[^a-z0-9]+', '-');
id = regexprep(id, '^-+|-+$', '');
if isempty(id)
    id = bma.util.newId('doc');
end
end

function title = chooseTitle(titleHint, sections, txt, path)
title = '';
if ~isempty(titleHint)
    title = strtrim(char(titleHint));
end
if isempty(title) && ~isempty(sections)
    s1 = sections(1);
    if ~strcmpi(s1.kind, 'front_matter') && ~strcmpi(s1.heading, 'Full Text')
        cand = strtrim(s1.heading);
        if numel(cand) >= 3 && numel(cand) <= 200
            title = cand;
        end
    end
    if isempty(title) && strcmpi(s1.kind, 'front_matter')
        lines = bma.io.internal.splitLines(s1.text);
        for k = 1:min(numel(lines), 5)
            t = strtrim(lines(k).text);
            if numel(t) >= 3
                if numel(t) > 200
                    t = [t(1:197) '...'];
                end
                title = t;
                break
            end
        end
    end
end
if isempty(title)
    lines = bma.io.internal.splitLines(txt);
    for k = 1:min(numel(lines), 5)
        t = strtrim(lines(k).text);
        if numel(t) >= 3
            if numel(t) > 200
                t = [t(1:197) '...'];
            end
            title = t;
            break
        end
    end
end
if isempty(title)
    [~, base] = fileparts(char(path));
    title = base;
end
end


% ---------------------------------------------------------------------------
function [level, lowCount, ratio, warningText] = sectionConfidenceSummary(sections)
% Estimate layout/sectioning reliability from per-section confidence flags.
% A true two-column reorder needs x-coordinates, which Text Analytics does not
% expose; this conservative warning prevents silently citing a wrong section.
level = 'high';
lowCount = 0;
ratio = 0;
warningText = '';
if isempty(sections)
    return
end
for k = 1:numel(sections)
    if isfield(sections(k), 'section_confidence') && ...
            strcmpi(char(sections(k).section_confidence), 'low')
        lowCount = lowCount + 1;
    end
end
ratio = lowCount / numel(sections);
meanLen = mean(arrayfun(@(s) numel(char(s.text)), sections(:)));
if ratio > 0.30 || (numel(sections) > 40 && meanLen < 400)
    level = 'low';
elseif ratio > 0.15
    level = 'medium';
end
if strcmp(level, 'low')
    warningText = sprintf(['分节可靠性低：%d/%d 个章节标题呈碎片化（低置信度 %.0f%%），' ...
        '可能是双栏 PDF 的栏内断行或扫描件。引用 section_id/heading 前请回 text.txt 核对；' ...
        '句子级 sentence_id 仍可用，但不要把章节归属当成语义证据。'], ...
        lowCount, numel(sections), 100 * ratio);
elseif strcmp(level, 'medium')
    warningText = sprintf(['部分章节标题呈碎片化（%d/%d，%.0f%%）；若引用跨栏内容，' ...
        '请回 text.txt 核对章节归属。'], lowCount, numel(sections), 100 * ratio);
end
end

% ---------------------------------------------------------------------------
function numbers = assignSentenceIds(numbers, sections)
%ASSIGNSENTENCEIDS Add sentence_id to each number when its position is inside one.
if isempty(numbers) || ~isfield(sections, 'sentences')
    return
end
for i = 1:numel(numbers)
    pos = numbers(i).char_start;
    best = '';
    for s = 1:numel(sections)
        if pos < sections(s).char_start || pos > sections(s).char_end
            continue
        end
        items = sections(s).sentences;
        for k = 1:numel(items)
            if pos >= items(k).char_start && pos <= items(k).char_end
                best = items(k).id;
                break
            end
        end
        if ~isempty(best)
            break
        end
    end
    numbers(i).sentence_id = best;
end
end

function figures = addCaptions(figures, txt)
%ADDCAPTIONS Best-effort pair figure N with "Fig./Figure N" caption text.
if isempty(figures)
    return
end
for k = 1:numel(figures)
    pat = ['(?:Fig(?:ure)?[.]?\s*' num2str(k) ')\s*[.:)]?\s*'];
    tok = regexp(txt, pat, 'once');
    if isempty(tok)
        % extraction order may not match numbering; leave empty
        figures(k).caption = '';
        continue
    end
    tail = txt(tok:min(numel(txt), tok + 240));
    tail = regexprep(tail, '\s+', ' ');
    tail = strtrim(tail);
    if numel(tail) > 180
        tail = [tail(1:180) '…'];
    end
    figures(k).caption = tail;
end
end
