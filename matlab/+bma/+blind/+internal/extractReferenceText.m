function out = extractReferenceText(workDir, runDir, ref)
%EXTRACTREFERENCETEXT Read + cache one reference's text for quote checking.
%   out = bma.blind.internal.extractReferenceText(workDir, runDir, ref)
%
%   Cache: <run_dir>/blind/refs/<ref_id>/text.txt + meta.json. The cache is
%   reused while the source SHA-256 is unchanged, so re-recording a note after
%   a failed quote check does not re-parse a large PDF.
%
%   Returns: available, text, text_path (relative to workDir), text_chars,
%   reused, warnings.
out = struct('available', false, 'text', '', 'text_path', '', ...
    'text_chars', 0, 'bytes', 0, 'reused', false, 'warnings', {{}});
if ~isstruct(ref)
    return
end
access = lower(strtrim(char(getStr(ref, 'access', ''))));
absPath = char(getStr(ref, 'abs_path', ''));
id = char(getStr(ref, 'id', 'R0'));
if ~strcmp(access, 'file') || isempty(absPath) || ~isfile(absPath)
    out.warnings{end + 1} = '该参考文献没有可读文件（题录条目）。';
    return
end
cacheDir = fullfile(runDir, 'blind', 'refs', id);
textFile = fullfile(cacheDir, 'text.txt');
metaFile = fullfile(cacheDir, 'meta.json');
sha = char(getStr(ref, 'sha256', ''));
if isfile(textFile) && isfile(metaFile)
    try
        meta = bma.util.readJson(metaFile);
        if ~isempty(sha) && strcmpi(char(getStr(meta, 'sha256', '')), sha)
            out.text = bma.util.readText(textFile);
            out.available = true;
            out.text_chars = numel(out.text);
            out.text_path = bma.util.relPath(workDir, textFile);
            out.reused = true;
            d = dir(textFile);
            if ~isempty(d)
                out.bytes = d(1).bytes;
            end
            return
        end
    catch
        % Fall through and re-extract.
    end
end
warnings = {};
text = '';
try
    fmt = bma.io.internal.detectFormat(absPath);
    if ~fmt.supported
        error('bma:blind:unsupported_format', '不支持的文献格式：%s', absPath);
    end
    [raw, ~, warnings, info] = bma.io.internal.readSourceText(absPath, fmt, 2 * 1024 * 1024);
    text = bma.io.internal.normalizeText(raw);
    bma.util.ensureDir(cacheDir);
    bma.util.writeTextAtomic(textFile, text);
    meta = struct('schema', 'bma.blindRefText.v1', 'source_path', absPath, ...
        'sha256', sha, 'bytes', getField(info, 'bytes', 0), ...
        'text_chars', numel(text), 'truncated', getField(info, 'truncated', false), ...
        'extracted_at', bma.util.nowIso(), 'warnings', {warnings});
    bma.util.writeJsonAtomic(metaFile, meta);
catch err
    warnings{end + 1} = sprintf('参考文献文本抽取失败：%s', err.message);
    bma.util.ensureDir(cacheDir);
    meta = struct('schema', 'bma.blindRefText.v1', 'source_path', absPath, ...
        'sha256', sha, 'text_chars', 0, 'error', err.message, ...
        'extracted_at', bma.util.nowIso(), 'warnings', {warnings});
    bma.util.writeJsonAtomic(metaFile, meta);
end
out.warnings = warnings;
out.text = text;
out.text_chars = numel(text);
out.available = numel(strtrim(text)) > 0;
if out.available
    out.text_path = bma.util.relPath(workDir, textFile);
end
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
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
