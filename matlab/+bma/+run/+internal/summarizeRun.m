function s = summarizeRun(runDir, workDir, meta)
%SUMMARIZERUN 汇总一个 run 目录的元数据与产物清单。
if nargin < 3 || isempty(meta)
    metaFile = fullfile(runDir, 'run.json');
    if isfile(metaFile)
        meta = bma.util.readJson(metaFile);
    else
        meta = struct();
    end
end
s = struct();
s.run_dir = char(runDir);
s.run_dir_rel = bma.util.relPath(workDir, runDir);
s.run_id = getf(meta, 'run_id', '');
if isempty(s.run_id)
    [~, s.run_id] = fileparts(char(runDir));
end
s.name = getf(meta, 'name', '');
s.created_at = getf(meta, 'created_at', getf(meta, 'created', ''));
s.updated_at = getf(meta, 'updated_at', s.created_at);
s.status = getf(meta, 'status', 'active');
s.work_dir = getf(meta, 'work_dir', char(workDir));
s.run_json_path = fullfile(runDir, 'run.json');

s.literature = listDirs(fullfile(runDir, 'literature'));
s.models = listDirs(fullfile(runDir, 'models'));
s.fits = listDirs(fullfile(runDir, 'fits'));
s.figures = listFiles(fullfile(runDir, 'figures'), '*.png');
s.reports = [listFiles(fullfile(runDir, 'report'), '*.html'), ...
    listFiles(fullfile(runDir, 'report'), '*.md')];
s.literature_count = numel(s.literature);
s.model_count = numel(s.models);
s.fit_count = numel(s.fits);
s.figure_count = numel(s.figures);
s.report_count = numel(s.reports);
end

% ---------------------------------------------------------------------------
function names = listDirs(folder)
names = {};
if ~isfolder(folder)
    return
end
d = dir(folder);
d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
names = sort({d.name});
end

function names = listFiles(folder, varargin)
names = {};
if ~isfolder(folder)
    return
end
patterns = varargin;
if isempty(patterns)
    patterns = {'*'};
end
all = {};
for k = 1:numel(patterns)
    d = dir(fullfile(folder, patterns{k}));
    all = [all, {d(~[d.isdir]).name}]; %#ok<AGROW>
end
names = sort(unique(all));
end

function v = getf(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end
