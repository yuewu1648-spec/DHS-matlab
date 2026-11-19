function r = init(workDir, name, varargin)
%INIT 创建或复用一次建模运行的标准目录，并写入 run.json（幂等）。
%   r = bma.run.init(workDir, name)
%   r = bma.run.init(workDir)                 % 复用 <workDir>/.bma/runs/.current.json
%   r = bma.run.init(workDir, name, 'New', true)  % 强制新建
%
%   目录结构（DESIGN §7，另含 logs/）：
%     <workDir>/.bma/runs/<run_id>/
%       run.json, literature/, models/, data/, fits/, figures/, report/, logs/
%
%   run_id：未给 name 时生成 rYYYYMMDD-HHMMSS-xxxx（DESIGN §7 格式）；
%           给了 name 时用 name 的合法化形式作为 run_id。
%   幂等：同一 name / 同一 current run 重复调用返回同一 run_dir，created=false。
if nargin < 1 || isempty(workDir)
    workDir = pwd;
end
if isstring(workDir)
    workDir = char(workDir);
end
workDir = char(workDir);
if isempty(regexp(workDir, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    workDir = bma.util.absPath(pwd, workDir);
end
runsRoot = fullfile(workDir, '.bma', 'runs');
p = inputParser;
p.addParameter('New', false, @(x)islogical(x) || isnumeric(x));
p.parse(varargin{:});
forceNew = logical(p.Results.New);

if nargin < 2 || isempty(name)
    name = '';
elseif isstring(name)
    name = char(name);
end
name = strtrim(char(name));

bma.util.ensureDir(runsRoot);
currentFile = fullfile(runsRoot, '.current.json');

% 1) 未指定 name：复用 current run
if isempty(name) && ~forceNew && isfile(currentFile)
    try
        cur = bma.util.readJson(currentFile);
        if isfield(cur, 'run_dir')
            cand = bma.util.absPath(workDir, cur.run_dir);
            if isfolder(cand) && isfile(fullfile(cand, 'run.json'))
                r = buildResult(cand, workDir, false);
                return
            end
        end
    catch
        % current 标记损坏则忽略并新建
    end
end

% 2) 指定 name：同名 run 直接复用
created = true;
if ~isempty(name)
    runId = sanitizeName(name);
    if isempty(runId)
        error('bma:run:badName', 'run name 非法（不能为空或包含路径字符）：%s', name);
    end
    runDir = fullfile(runsRoot, runId);
    if ~forceNew && isfolder(runDir) && isfile(fullfile(runDir, 'run.json'))
        r = buildResult(runDir, workDir, false);
        writeCurrent(currentFile, runDir, workDir, name);
        return
    end
else
    runId = generateRunId();
    for guard = 1:20
        runDir = fullfile(runsRoot, runId);
        if ~isfolder(runDir)
            break
        end
        runId = generateRunId();
    end
end

% 3) 新建 run
bma.util.ensureDir(runDir);
dirs = bma.run.internal.ensureLayout(runDir);
nowIso = bma.util.nowIso();
meta = struct();
meta.schema = 'bma.run.v1';
meta.run_id = runId;
meta.name = name;
meta.created_at = nowIso;
meta.updated_at = nowIso;
meta.work_dir = workDir;
meta.status = 'active';
bma.util.writeJsonAtomic(fullfile(runDir, 'run.json'), meta);
writeCurrent(currentFile, runDir, workDir, name);

r = buildResult(runDir, workDir, true);
r.dirs = dirs;
end

% ---------------------------------------------------------------------------
function r = buildResult(runDir, workDir, created)
meta = bma.util.readJson(fullfile(runDir, 'run.json'));
r = struct();
r.run_id = getf(meta, 'run_id', basename(runDir));
% DESIGN §4.4 约定：result 中的 run_dir 相对 work_dir；另给 run_dir_abs 供内部使用
r.run_dir = bma.util.relPath(workDir, runDir);
r.run_dir_abs = runDir;
r.run_dir_rel = r.run_dir;
r.run_json_path = bma.util.relPath(workDir, fullfile(runDir, 'run.json'));
r.run_json_abs = fullfile(runDir, 'run.json');
r.run_json_rel = r.run_json_path;
r.created = logical(created);
r.name = getf(meta, 'name', '');
r.created_at = getf(meta, 'created_at', getf(meta, 'created', ''));
r.updated_at = getf(meta, 'updated_at', r.created_at);
r.status = getf(meta, 'status', 'active');
r.work_dir = getf(meta, 'work_dir', workDir);
names = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs', 'artifacts'};
dirs = struct();
for k = 1:numel(names)
    dirs.(names{k}) = fullfile(runDir, names{k});
end
r.dirs = dirs;
end

function writeCurrent(currentFile, runDir, workDir, name)
cur = struct();
cur.schema = 'bma.run.current.v1';
cur.run_id = basename(runDir);
cur.run_dir = bma.util.relPath(workDir, runDir);
cur.name = name;
cur.updated_at = bma.util.nowIso();
try
    bma.util.writeJsonAtomic(currentFile, cur);
catch
    % current 标记只是便利信息，写失败不影响 run 本身
end
end

function id = generateRunId()
stamp = char(datetime('now', 'Format', 'yyyyMMdd-HHmmss'));
id = sprintf('r%s-%s', stamp, lower(dec2hex(randi([0 65535], 1, 1), 4)));
end

function id = sanitizeName(name)
id = lower(strtrim(char(name)));
id = regexprep(id, '[^a-z0-9._-]+', '-');
id = regexprep(id, '^-+|-+$', '');
if any(strcmp(id, {'.', '..'})) || isempty(id)
    id = '';
    return
end
if numel(id) > 64
    id = id(1:64);
    id = regexprep(id, '[-.]+$', '');
end
end

function name = basename(p)
[~, name] = fileparts(char(p));
end

function v = getf(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end

