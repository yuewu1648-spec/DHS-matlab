function [units, map] = units(varargin)
%UNITS 读取 kb/units.json 单位表（供 spec 单位/量纲校验复用）。
%   units = bma.kb.units()
%   [units, map] = bma.kb.units('KbDir', dir)
%
%   units 为 struct 数组：id / dim / factor / base / symbol / aliases / note
%   map   为 containers.Map：单位 id -> struct(dim, factor, base)
p = inputParser;
p.addParameter('KbDir', '', @(x)ischar(x) || isstring(x));
p.parse(varargin{:});
kbDir = bma.kb.internal.resolveKbDir(p.Results.KbDir);
units = bma.kb.internal.readUnits(kbDir);
map = [];
if nargout > 1
    map = containers.Map();
    for k = 1:numel(units)
        s = struct('dim', units(k).dim, 'factor', units(k).factor, ...
            'base', units(k).base);
        map(units(k).id) = s;
    end
end
end
