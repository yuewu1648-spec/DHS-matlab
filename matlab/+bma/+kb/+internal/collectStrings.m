function out = collectStrings(v)
%COLLECTSTRINGS 递归收集 struct/cell 中的全部字符串，用于构建检索 token。
%
%   防护要点（kb JSON 里存在 struct 数组/嵌套 cell/equations/references）：
%     * struct 数组不能直接 v.(field)（MATLAB 会展开成逗号列表 → 输入参数太多），
%       必须逐元素递归；
%     * 深度上限 20、累计字符串上限 20000，避免异常嵌套造成递归失控；
%     * 数字/逻辑值不进入 token，避免参数范围数字污染检索。
out = {};
out = collectInto(v, out, 0, 20000);
end

function out = collectInto(v, out, depth, maxItems)
if depth > 20 || numel(out) > maxItems
    return
end
if isstruct(v)
    if ~isscalar(v)
        for k = 1:numel(v)
            out = collectInto(v(k), out, depth + 1, maxItems);
        end
        return
    end
    f = fieldnames(v);
    for k = 1:numel(f)
        val = v.(f{k});
        if ~isempty(val)
            out = collectInto(val, out, depth + 1, maxItems);
        end
    end
elseif iscell(v)
    for k = 1:numel(v)
        out = collectInto(v{k}, out, depth + 1, maxItems);
    end
elseif isstring(v)
    for k = 1:numel(v)
        if strlength(v(k)) > 0
            out{end + 1} = char(v(k)); %#ok<AGROW>
        end
    end
elseif ischar(v)
    if ~isempty(strtrim(v))
        out{end + 1} = v;
    end
end
end
