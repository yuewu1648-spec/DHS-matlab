function items = walkJson(baseDir, prefix)
%WALKJSON 递归列出目录下所有 .json 文件（相对路径，正斜杠，排序）。
%   items = bma.kb.internal.walkJson(kbDir, '')
if nargin < 2
    prefix = '';
end
items = {};
if ~isfolder(baseDir)
    return
end
d = dir(fullfile(baseDir, '*'));
for k = 1:numel(d)
    name = d(k).name;
    if any(strcmp(name, {'.', '..'}))
        continue
    end
    if d(k).isdir
        sub = bma.kb.internal.walkJson(fullfile(baseDir, name), [prefix name '/']);
        if ~isempty(sub)
            items = [items, sub]; %#ok<AGROW>
        end
    elseif numel(name) > 5 && strcmpi(name(end - 4:end), '.json')
        items{end + 1} = [prefix name]; %#ok<AGROW>
    end
end
items = sort(items);
end
