function workDir = inferWorkDir(runDir)
%INFERWORKDIR 从 <workDir>/.bma/runs/<id> 反推 workDir；无法反推时返回 pwd。
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
