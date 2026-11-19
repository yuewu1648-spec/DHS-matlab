function r = importArtifact(workDir, runDir, sourcePath, opts)
%IMPORTARTIFACT 把 run_dir 之外的产物复制进 <run_dir>/artifacts/ 并登记清单。
%   r = bma.run.importArtifact(workDir, runDir, sourcePath)
%   r = bma.run.importArtifact(workDir, runDir, sourcePath, opts)
%
% 用途（issue 0.5.0 / I2/I5）：某些沙箱里 agent 启动的 MATLAB 批处理无法
% 直接写 <work_dir>/.bma；它可以先写到外部目录，再用本函数把 .mat/.png/
% .csv 等复制回 run_dir。报告构建会扫描 artifacts/ 并把图片内嵌，因此报告
% 不再依赖 run_dir 之外的绝对路径。
%
% opts:
%   name      目标文件名/目录名（默认取源 basename；自动去重）
%   kind      自由标签（默认按扩展名推断）
%   recursive 源为目录时是否递归复制（默认 true）
%
% 返回 {ok, imported, artifacts, artifact_dir, artifacts_path, run_dir,
%       source_path, warnings}；路径均相对 workDir。
if nargin < 4 || isempty(opts)
    opts = struct();
end
workDir = char(workDir);
runDir = char(runDir);
if ~isfolder(runDir)
    error('bma:run:notFound', '运行目录不存在：%s', runDir);
end
src = char(sourcePath);
if isempty(regexp(src, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    src = bma.util.absPath(workDir, src);
end
if ~isfile(src) && ~isfolder(src)
    error('bma:run:artifactNotFound', '要导入的产物不存在：%s', src);
end
artDir = fullfile(runDir, 'artifacts');
bma.util.ensureDir(artDir);
warnings = {};

name = '';
if isfield(opts, 'name') && ~isempty(opts.name)
    name = char(opts.name);
else
    [~, base, ext] = fileparts(src);
    name = [base ext];
end
name = sanitizeName(name);
dest = uniqueDest(artDir, name);
attempted = false;
try
    if isfolder(src)
        recursive = true;
        if isfield(opts, 'recursive') && ~isempty(opts.recursive)
            recursive = logical(opts.recursive);
        end
        if recursive
            copyfile(src, dest, 'f');
        else
            copyfile(src, dest);
        end
    else
        copyfile(src, dest, 'f');
    end
    attempted = true;
catch err
    warnings{end+1} = sprintf('复制产物失败：%s', err.message); %#ok<AGROW>
end

entries = {};
if attempted && (isfile(dest) || isfolder(dest))
    if isfolder(dest)
        files = dir(fullfile(dest, '**', '*'));
        files = files(~[files.isdir]);
    else
        files = dir(dest);
    end
    for k = 1:numel(files)
        fpath = fullfile(files(k).folder, files(k).name);
        try
            entries{end+1} = makeEntry(workDir, runDir, fpath, src, opts); %#ok<AGROW>
        catch err
            warnings{end+1} = sprintf('登记产物失败 %s：%s', fpath, err.message); %#ok<AGROW>
        end
    end
elseif ~attempted
    % keep warnings; the caller sees imported=0
end

manifestPath = fullfile(runDir, 'artifacts.json');
manifest = struct('schema', 'bma.artifacts.v1', ...
    'run_id', basename(runDir), 'updated_at', bma.util.nowIso(), ...
    'entries', {{}});
if isfile(manifestPath)
    try
        old = bma.util.readJson(manifestPath);
        if isstruct(old) && isfield(old, 'entries')
            oldEntries = old.entries;
            if isstruct(oldEntries) && ~iscell(oldEntries)
                oldEntries = num2cell(oldEntries);
            end
            if ~iscell(oldEntries)
                oldEntries = {};
            end
            manifest.entries = oldEntries;
            if isfield(old, 'run_id')
                manifest.run_id = old.run_id;
            end
        end
    catch
        warnings{end+1} = '现有 artifacts.json 无法解析，已用新清单覆盖。'; %#ok<AGROW>
    end
end
manifest.entries = [manifest.entries, entries];
bma.util.writeJsonAtomic(manifestPath, manifest);

r = struct();
r.ok = attempted;
r.imported = numel(entries);
r.artifacts = entries;
r.artifact_dir = bma.util.relPath(workDir, artDir);
r.artifacts_path = bma.util.relPath(workDir, manifestPath);
r.run_dir = bma.util.relPath(workDir, runDir);
r.source_path = src;
r.warnings = warnings;
end

% ---------------------------------------------------------------------------
function name = sanitizeName(name)
name = strtrim(char(name));
name = regexprep(name, '[\\/]+', '-');
name = regexprep(name, '[^A-Za-z0-9._-]+', '-');
name = regexprep(name, '^[.-]+|[.-]+$', '');
if isempty(name)
    name = 'artifact';
end
if numel(name) > 120
    [~, base, ext] = fileparts(name);
    name = [base(1:min(end, 100)) ext];
end
end

function dest = uniqueDest(dirPath, name)
dest = fullfile(dirPath, name);
if ~isfile(dest) && ~isfolder(dest)
    return
end
[~, base, ext] = fileparts(name);
for i = 2:999
    candidate = fullfile(dirPath, sprintf('%s-%d%s', base, i, ext));
    if ~isfile(candidate) && ~isfolder(candidate)
        dest = candidate;
        return
    end
end
error('bma:run:artifactCollision', '无法为 %s 生成唯一目标名。', name);
end

function e = makeEntry(workDir, runDir, filePath, sourcePath, opts)
[~, name, ext] = fileparts(filePath);
kind = lower(regexprep(ext, '^\.', ''));
if isempty(kind)
    kind = 'file';
end
if isfield(opts, 'kind') && ~isempty(opts.kind)
    kind = char(opts.kind);
end
d = dir(filePath);
e = struct();
e.name = [name ext];
e.kind = kind;
e.rel_path = bma.util.relPath(workDir, filePath);
e.run_rel_path = bma.util.relPath(runDir, filePath);
e.source_path = sourcePath;
e.bytes = d.bytes;
e.sha256 = sha256File(filePath);
e.imported_at = bma.util.nowIso();
end

function h = sha256File(p)
h = '';
try
    md = java.security.MessageDigest.getInstance('SHA-256');
    fis = java.io.FileInputStream(p);
    cleaner = onCleanup(@() fis.close()); %#ok<NASGU>
    buf = zeros(1, 65536, 'int8');
    while true
        n = fis.read(buf, 0, numel(buf));
        if n < 0
            break
        end
        if n > 0
            md.update(buf(1:n));
        end
    end
    digest = typecast(md.digest(), 'uint8');
    h = lower(sprintf('%02x', digest));
catch
    h = '';
end
end

function b = basename(p)
[~, b] = fileparts(char(p));
end
