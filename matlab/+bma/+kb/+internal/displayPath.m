function p = displayPath(kbDir, relPath)
%DISPLAYPATH 知识库条目的对外 path 字段。
%   默认 kb/ 在项目内时返回**相对 projectRoot** 的路径（如 kb/archetypes/x.json，
%   与工具层/QA 的 projRoot 解析约定一致）；kb 在项目外（fixture）时返回绝对路径。
projectRoot = bma.util.projectRoot();
full = fullfile(char(kbDir), strrep(char(relPath), '/', filesep));
prLower = lower(regexprep(projectRoot, '[\\/]+$', ''));
fuLower = lower(regexprep(full, '[\\/]+$', ''));
if numel(fuLower) > numel(prLower) && strncmp(fuLower, prLower, numel(prLower)) ...
        && any(fuLower(numel(prLower) + 1) == [filesep '/'])
    p = bma.util.relPath(projectRoot, full);
else
    p = strrep(full, filesep, '/');
end
end
