function runDir = resolveRunDir(runDir, workDir)
%RESOLVERUNDIR 把 run_dir 参数解析为绝对路径（支持绝对路径 / 相对 pwd /
%   相对 workDir / 纯 run_id）。
if nargin < 2
    workDir = '';
end
if isempty(runDir)
    error('bma:run:missingRunDir', '缺少 run_dir 参数。');
end
if isstring(runDir)
    runDir = char(runDir);
end
runDir = char(runDir);
if ~isempty(regexp(runDir, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    return
end
candidates = {};
if ~isempty(workDir)
    wd = char(workDir);
    if ~isempty(regexp(wd, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
        candidates{end + 1} = bma.util.absPath(wd, runDir); %#ok<AGROW>
        candidates{end + 1} = fullfile(wd, '.bma', 'runs', runDir); %#ok<AGROW>
    end
end
candidates{end + 1} = bma.util.absPath(pwd, runDir); %#ok<AGROW>
candidates{end + 1} = fullfile(pwd, '.bma', 'runs', runDir); %#ok<AGROW>
for k = 1:numel(candidates)
    if isfolder(candidates{k})
        runDir = candidates{k};
        return
    end
end
% 不存在时取第一个候选（由调用方报 not found）
runDir = candidates{1};
end
