function r = start(workDir, runDir, primaryPath, opts)
%START Begin a sealed blind-literature modeling run.
%   r = bma.blind.start(workDir, runDir, primaryPath, opts)
%
%   The primary paper is sealed: only its abstract is extracted and written to
%   <run_dir>/blind/primary_abstract.md; the full text is never persisted by
%   this call, and bma.io.ingest refuses the sealed primary until
%   bma_blind_reveal. References are inventoried from a directory, a JSON list,
%   and/or the paper's bibliography (citation strings only).
%
%   opts: abstract_path, references_dir, references_json, from_primary,
%         title, min_rounds (default 3), budget_seconds (0=none),
%         max_references (default 300), max_bytes, force.
if nargin < 4 || isempty(opts)
    opts = struct();
end
workDir = char(workDir);
runDir = char(runDir);
primaryPath = char(primaryPath);
if ~isfolder(runDir)
    error('bma:blind:run_not_found', 'run 目录不存在：%s', runDir);
end
primaryAbs = bma.blind.internal.canonicalPath(bma.util.absPath(workDir, primaryPath));
if ~isfile(primaryAbs)
    error('bma:blind:primary_not_found', '主文献文件不存在：%s', primaryAbs);
end
protoFile = bma.blind.internal.protocolFile(runDir);
force = getBool(opts, 'force', false);
if isfile(protoFile) && ~force
    error('bma:blind:already_started', ...
        ['该 run 已存在盲建模协议（%s）。若确实要重新封印（会丢失全部笔记/自检记录），' ...
         '显式传 force=true；否则继续使用原协议。'], protoFile);
end

% ---- read primary WITHOUT persisting its body ----------------------------
fmt = bma.io.internal.detectFormat(primaryAbs);
if ~fmt.supported
    error('bma:blind:unsupported_format', ...
        '不支持的主文献格式 "%s"；支持：%s', fmt.ext, strjoin(bma.io.supportedFormats(), ', '));
end
maxBytes = getNum(opts, 'max_bytes', 2 * 1024 * 1024);
[rawText, titleHint, warnings, info] = bma.io.internal.readSourceText(primaryAbs, fmt, maxBytes);
text = bma.io.internal.normalizeText(rawText);
if isempty(strtrim(text))
    error('bma:blind:abstract_not_found', ...
        ['主文献解析文本为空（可能是扫描版 PDF，需要 OCR）。盲建模不能读取正文，' ...
         '请用 abstract_path 提供摘要文本。']);
end
sections = bma.io.sectionize(text);
provided = '';
if isfield(opts, 'abstract_path') && ~isempty(opts.abstract_path)
    ap = bma.util.absPath(workDir, char(opts.abstract_path));
    if ~isfile(ap)
        error('bma:blind:abstract_not_found', 'abstract_path 文件不存在：%s', ap);
    end
    provided = bma.util.readText(ap);
end
ab = bma.blind.internal.findAbstract(text, sections, provided);
warnings = [warnings, ab.warnings];

title = '';
if isfield(opts, 'title') && ~isempty(opts.title)
    title = strtrim(char(opts.title));
end
if isempty(title)
    title = strtrim(char(titleHint));
end
if isempty(title)
    title = primaryTitleLocal(sections, primaryAbs);
end

sha = bma.util.sha256File(primaryAbs);
if isempty(sha)
    warnings{end + 1} = '无法计算主文献 SHA-256：封印只能按路径识别，复制到其他路径可能绕过 ingest 防护。'; %#ok<AGROW>
end
d = dir(primaryAbs);
bytes = 0;
if ~isempty(d)
    bytes = d(1).bytes;
end

% ---- references -----------------------------------------------------------
refOpts = struct();
refOpts.max_references = getNum(opts, 'max_references', 300);
if isfield(opts, 'references_dir')
    refOpts.references_dir = opts.references_dir;
end
if isfield(opts, 'references_json')
    refOpts.references_json = opts.references_json;
end
fromPrimary = getBool(opts, 'from_primary', false);
if fromPrimary
    bib = bma.blind.internal.parseBibliography(text, sections);
    refOpts.bib_citations = bib.citations;
    warnings = [warnings, bib.warnings];
    if bib.count == 0
        warnings{end + 1} = 'from_primary=true 但未能从参考文献列表切出条目；请用 references_dir/references_json 提供。'; %#ok<AGROW>
    end
end
[refs, refWarnings] = bma.blind.internal.buildReferences( ...
    workDir, runDir, primaryAbs, sha, refOpts);
warnings = [warnings, refWarnings];
if isempty(refs)
    warnings{end + 1} = ['参考文献清单为空：建模证据将只剩摘要。' ...
        '请用 bma_blind_check(action:"references") 追加全部参考文献，否则无法通过停止判据。']; %#ok<AGROW>
end
coverage = bma.blind.internal.computeCoverage(refs);

% ---- protocol -------------------------------------------------------------
p = struct();
p.schema = 'bma.blindProtocol.v1';
p.run_id = basename(runDir);
p.created_at = bma.util.nowIso();
p.updated_at = p.created_at;
p.status = 'sealed';
p.primary = struct('source_path', primaryAbs, ...
    'source_rel', bma.util.relPath(workDir, primaryAbs), ...
    'bytes', bytes, 'sha256', sha, 'title', title, 'format', fmt.format, ...
    'abstract', ab, 'sealed_at', p.created_at);
p.guard = struct('sealed', true, 'ingest_blocked', true, ...
    'full_text_exposed', false, ...
    'note', ['建模期间只允许使用摘要；主文献全文/图表由 ingest 封印。' ...
             '诚实性要求：不得用 read/pwsh 直接读取主文献文件。']);
minR = getNum(opts, 'min_rounds', 3);
minR = max(2, min(20, round(minR)));
p.options = struct('min_rounds', minR, ...
    'budget_seconds', max(0, getNum(opts, 'budget_seconds', 0)), ...
    'max_references', refOpts.max_references, 'allow_citation_only', true);
p.question = struct('question', '', 'objective', '', ...
    'success_criteria', {{}}, 'out_of_scope', {{}}, 'recorded_at', '');
p.references = refs;
p.coverage = coverage;
p.model = struct('frozen', false, 'versions', {{}}, 'current', 0);
p.selfcheck = struct('rounds', {{}}, 'issues', {{}}, ...
    'rounds_completed', 0, ...
    'stop', struct('met', false, 'reasons', {{}}, 'evaluated_at', ''), ...
    'started_at', p.created_at, 'elapsed_seconds', 0);
p.reveal = [];
p.warnings = warnings;

bma.util.ensureDir(fullfile(runDir, 'blind'));
if isfile(protoFile)
    stamp = regexprep(p.created_at, '[^0-9]', '');
    copyfile(protoFile, fullfile(runDir, 'blind', ['protocol.overwritten-' stamp '.json']), 'f');
end
bma.blind.internal.saveProtocol(runDir, p);
bma.blind.internal.writePrimaryAbstract(workDir, runDir, p);
bma.blind.internal.updateSealRegistry(workDir, struct( ...
    'run_id', p.run_id, 'primary_path', primaryAbs, ...
    'primary_sha256', sha, 'protocol_path', protoFile, 'sealed', true, ...
    'sealed_at', p.created_at));

r = struct();
r.ok = true;
r.status = p.status;
r.run_dir = bma.util.relPath(workDir, runDir);
r.protocol_path = bma.util.relPath(workDir, protoFile);
r.abstract_path = bma.util.relPath(workDir, ...
    fullfile(runDir, 'blind', 'primary_abstract.md'));
r.primary = struct('title', p.primary.title, ...
    'source_path', p.primary.source_rel, 'sha256', sha, 'bytes', bytes, ...
    'format', fmt.format, ...
    'abstract_source', ab.source, 'abstract_confidence', ab.confidence, ...
    'abstract_section_id', ab.section_id, 'abstract_chars', ab.chars, ...
    'abstract_text', ab.text);
r.references = struct('count', numel(refs), ...
    'items', {refPreview(refs, 20)}, 'coverage', coverage);
r.options = p.options;
r.warnings = warnings;
r.next_steps = {'读取 blind/primary_abstract.md，用 bma_blind_check(action:"goal") 写清建模问题/目标与成功判据', ...
    '用 bma_blind_note 逐篇记录全部参考文献（quote 必须逐字，工具会校验）', ...
    '做候选机制与模型，bma_blind_check(action:"round") 记录自检/修补', ...
    '用 bma_blind_check(action:"freeze") 冻结模型，再 action:"stop" 通过停止判据', ...
    '最后用 bma_blind_reveal 解封主文献并 action:"compare" 对照'};
end

% ---------------------------------------------------------------------------
function items = refPreview(refs, limit)
items = {};
n = min(numel(refs), limit);
for k = 1:n
    ref = refs{k};
    items{end + 1} = struct('id', ref.id, 'citation', ref.citation, ...
        'access', ref.access, 'status', ref.status, ...
        'path', ref.path); %#ok<AGROW>
end
end

function title = primaryTitleLocal(sections, path)
title = '';
if isempty(sections)
    [~, title] = fileparts(path);
    return
end
% Front matter usually holds the title/authors before the first section.
for k = 1:numel(sections)
    kind = lower(strtrim(char(getField(sections(k), 'kind', ''))));
    if ~strcmp(kind, 'front_matter')
        continue
    end
    lines = regexp(char(getField(sections(k), 'text', '')), '\n', 'split');
    for j = 1:numel(lines)
        t = strtrim(lines{j});
        if numel(t) >= 3 && ~strcmpi(t, 'abstract') && ~strcmpi(t, 'summary')
            if numel(t) > 200
                t = [t(1:197) '...'];
            end
            title = t;
            return
        end
    end
end
for k = 1:numel(sections)
    h = strtrim(char(getField(sections(k), 'heading', '')));
    kind = lower(strtrim(char(getField(sections(k), 'kind', ''))));
    if strcmp(kind, 'front_matter') || isempty(h) || strcmpi(h, 'Full Text') || ...
            any(strcmpi(h, {'abstract', 'summary'}))
        continue
    end
    if numel(h) >= 3 && numel(h) <= 200
        title = h;
        return
    end
end
[~, title] = fileparts(path);
end

function b = basename(p)
[~, b] = fileparts(char(p));
end

function v = getBool(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = logical(s.(f));
else
    v = d;
end
end

function v = getNum(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f))
    v = double(s.(f));
else
    v = d;
end
end

function v = getField(s, f, d)
if isstruct(s) && isfield(s, f)
    v = s.(f);
else
    v = d;
end
end
