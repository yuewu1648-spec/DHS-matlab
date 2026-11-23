function c = asStructList(v)
%ASSTRUCTLIST Normalize a JSON-backed list to a cell array of structs/values.
%   jsondecode returns a struct array for homogeneous object arrays, a cell
%   array for mixed/empty arrays, and [] for empty arrays. Protocol code always
%   manipulates cell arrays.
if isempty(v)
    c = {};
elseif iscell(v)
    c = v(:)';
elseif isstruct(v)
    c = num2cell(v(:)');
else
    c = {v};
end
end
