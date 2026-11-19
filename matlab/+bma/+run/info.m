function [r, total] = info(runDir, varargin)
%INFO 读取一次运行的详细信息（run.json + 产物清单）。
%   r = bma.run.info(runDir)
%   r = bma.run.info(runId)            % 也可传纯 run_id（在 pwd/.bma/runs 下查找）
%   r = bma.run.info(..., 'WorkDir', workDir)
p = inputParser;
p.addParameter('WorkDir', '', @(x)ischar(x) || isstring(x));
p.parse(varargin{:});
workDirArg = char(p.Results.WorkDir);
runDir = bma.run.internal.resolveRunDir(runDir, workDirArg);
if ~isfolder(runDir)
    error('bma:run:notFound', '运行目录不存在：%s', runDir);
end
metaFile = fullfile(runDir, 'run.json');
if ~isfile(metaFile)
    error('bma:run:missingMeta', ...
        '运行目录缺少 run.json：%s。请使用 bma.run.init 创建标准运行目录。', runDir);
end
meta = bma.util.readJson(metaFile);
if isempty(workDirArg)
    workDir = bma.run.internal.inferWorkDir(runDir);
else
    workDir = workDirArg;
    if isempty(regexp(workDir, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
        workDir = bma.util.absPath(pwd, workDir);
    end
end
r = bma.run.internal.summarizeRun(runDir, workDir, meta);
r.exists = true;
r.run_json_rel = bma.util.relPath(workDir, metaFile);
r.dirs = buildDirs(runDir);
total = 1; %#ok<NASGU>
end

% ---------------------------------------------------------------------------
function dirs = buildDirs(runDir)
names = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs'};
dirs = struct();
for k = 1:numel(names)
    dirs.(names{k}) = fullfile(runDir, names{k});
end
end
