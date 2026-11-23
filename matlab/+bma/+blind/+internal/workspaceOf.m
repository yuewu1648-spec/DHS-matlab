function p = workspaceOf(runDir)
%WORKSPACEOF Derive <work_dir> from <work_dir>/.bma/runs/<id>.
p = char(runDir);
m = regexp(p, '[\\/]\.bma([\\/]|$)', 'start', 'once');
if ~isempty(m) && m > 1
    p = p(1:m - 1);
    if numel(p) == 2 && p(2) == ':'
        p = [p filesep];
    end
else
    p = pwd;
end
end
