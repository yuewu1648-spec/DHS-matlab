function id = newId(prefix)
%NEWID Time-ordered unique id with an optional readable prefix.
if nargin < 1 || isempty(prefix)
    prefix = 'id';
end
stamp = char(datetime('now', 'Format', 'yyyyMMdd-HHmmss-SSS'));
r = randi([0 16777215], 1, 1);
id = sprintf('%s-%s-%06x', prefix, stamp, r);
end
