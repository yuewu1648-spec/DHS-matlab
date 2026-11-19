function [absPath, dispPath] = resolveItemPath(kbDir, relPath)
%RESOLVEITEMPATH 把索引条目的 path（可能是相对 projectRoot 的 'kb/...' 或绝对路径）
%   解析为绝对路径；同时给出对外展示路径。
absPath = '';
dispPath = '';
p = char(relPath);
if isempty(p)
    return
end
dispPath = p;
kbDir = char(kbDir);
if ~isempty(regexp(p, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    absPath = p;
    return
end
projectRoot = bma.util.projectRoot();
candProject = fullfile(projectRoot, strrep(p, '/', filesep));
candKb = fullfile(kbDir, strrep(p, '/', filesep));
if isfile(candProject)
    absPath = candProject;
elseif isfile(candKb)
    absPath = candKb;
else
    absPath = candProject;
end
end
