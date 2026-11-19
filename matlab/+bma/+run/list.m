function [runs, total] = list(workDir, varargin)
%LIST 列出 <workDir>/.bma/runs 下的全部运行（按 updated_at 倒序）。
%   runs = bma.run.list(workDir)
%   [runs, total] = bma.run.list(workDir)
%
%   每个元素字段：run_dir, run_dir_rel, run_id, name, created_at, updated_at,
%   status, models(cellstr), model_count, fits, fit_count, literature_count,
%   figures, figure_count, reports(cellstr), report_count 等。
p = inputParser;
p.addParameter('WorkDir', '', @(x)ischar(x) || isstring(x));
p.parse(varargin{:});
if nargin < 1 || isempty(workDir)
    workDir = p.Results.WorkDir;
    if isempty(workDir)
        workDir = pwd;
    end
end
if isstring(workDir)
    workDir = char(workDir);
end
workDir = char(workDir);
if isempty(regexp(workDir, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    workDir = bma.util.absPath(pwd, workDir);
end
runsRoot = fullfile(workDir, '.bma', 'runs');
runs = [];
total = 0;
if ~isfolder(runsRoot)
    return
end
d = dir(runsRoot);
d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
d = d(~startsWith({d.name}, '.'));
items = [];
sortKeys = {};
for k = 1:numel(d)
    runDir = fullfile(runsRoot, d(k).name);
    if ~isfile(fullfile(runDir, 'run.json'))
        continue
    end
    try
        meta = bma.util.readJson(fullfile(runDir, 'run.json'));
    catch
        continue
    end
    try
        s = bma.run.internal.summarizeRun(runDir, workDir, meta);
    catch
        continue
    end
    if isempty(items)
        items = s;
    else
        items(end + 1) = s; %#ok<AGROW>
    end
    key = s.updated_at;
    if isempty(key)
        key = s.created_at;
    end
    if isempty(key)
        key = s.run_id;
    end
    sortKeys{end + 1} = char(key); %#ok<AGROW>
end
if isempty(items)
    return
end
[~, ord] = sort(sortKeys);
ord = fliplr(ord);
runs = items(ord);
total = numel(runs);
end
