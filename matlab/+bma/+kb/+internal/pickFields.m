function out = pickFields(json, names)
%PICKFIELDS 收集 struct 中指定字段的原始值（供 collectStrings 递归展平）。
%   注意：json 必须是标量 struct（调用方保证）；字段值可能是 struct 数组，
%   作为整体放进 cell，交给 collectStrings 逐元素处理。
out = {};
if ~isstruct(json) || ~isscalar(json)
    return
end
for k = 1:numel(names)
    if ~isfield(json, names{k})
        continue
    end
    val = json.(names{k});
    if ~isempty(val)
        out{end + 1} = val; %#ok<AGROW>
    end
end
end
