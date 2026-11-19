function items = itemize(x)
%ITEMIZE 将 jsondecode 得到的实体列表统一成 1×N 的元胞数组。
%   jsondecode 对同构对象数组返回 struct 数组，对异构对象数组返回 cell，
%   对单个对象返回 struct。本函数把所有情况统一为 cell，元素保持原样（结构体/字符串），
%   便于上游按统一方式遍历。
items = {};
if isempty(x)
    return
end
if isstruct(x)
    n = numel(x);
    items = cell(1, n);
    for k = 1:n
        items{k} = x(k);
    end
elseif iscell(x)
    n = numel(x);
    items = reshape(x, 1, n);
else
    items = {x};
end
end
