function v = getField(s, name, default)
%GETFIELD 安全读取结构体字段。
%   v = getField(s, name, default)
%   jsondecode 在 JSON null 时给出 []，此处对“空值”回退到默认值；
%   字段不存在、s 不是结构体时同样返回默认值。适合处理来自 JSON 的规格。
if nargin < 3
    default = [];
end
if isstruct(s) && isfield(s, name)
    v = s.(name);
    if isempty(v) && ~ischar(v)
        % [] / 空数组 / 空元胞 视为缺失（JSON null 的解码结果）
        v = default;
    end
else
    v = default;
end
end
