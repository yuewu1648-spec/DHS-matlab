function units = readUnits(kbDir)
%READUNITS 读取 kb/units.json 的单位表。
%   units = bma.kb.internal.readUnits(kbDir)
%   返回 struct 数组：id / dim / factor / base / symbol / aliases(cellstr) / note
%
%   注意：units.json 的键可能不是合法 MATLAB 标识符（如 "1"、"1/s"、"%"),
%   jsondecode 会报错或改名，因此这里用花括号配对 + 正则直接解析文本。
units = struct('id', {}, 'dim', {}, 'factor', {}, 'base', {}, ...
    'symbol', {}, 'aliases', {}, 'note', {});
file = fullfile(char(kbDir), 'units.json');
if ~isfile(file)
    return
end
try
    txt = bma.util.readText(file);
catch
    return
end

% 定位 "units": { ... } 的花括号主体
openIdx = regexp(txt, '"units"\s*:\s*\{', 'end', 'once');
if isempty(openIdx)
    return
end
body = balancedBody(txt, openIdx);
if isempty(body)
    return
end

% 方式一：键值对形式 "uM": { ... }
entries = regexp(body, '"((?:[^"\\]|\\.)+)"\s*:\s*\{([^{}]*)\}', 'tokens');
for k = 1:numel(entries)
    unitId = unescapeJson(entries{k}{1});
    inner = entries{k}{2};
    units(end + 1) = buildUnit(unitId, inner); %#ok<AGROW>
end
if ~isempty(units)
    return
end

% 方式二：数组形式 [{ "id": "uM", ... }, ...]
objects = regexp(body, '\{[^{}]*\}', 'match');
for k = 1:numel(objects)
    inner = objects{k};
    unitId = fieldStr(inner, 'id');
    if isempty(unitId)
        continue
    end
    units(end + 1) = buildUnit(unitId, inner); %#ok<AGROW>
end
end

% ---------------------------------------------------------------------------
function u = buildUnit(unitId, inner)
u = struct();
u.id = char(unitId);
u.dim = fieldStr(inner, 'dim');
factor = fieldNum(inner, 'factor');
if isnan(factor)
    factor = 1;
end
u.factor = factor;
u.base = fieldStr(inner, 'base');
u.symbol = fieldStr(inner, 'symbol');
u.aliases = fieldStrArray(inner, 'aliases');
u.note = fieldStr(inner, 'note');
end

function body = balancedBody(txt, openPos)
% 返回 txt(openPos) 处 '{' 所配对的花括号内部文本
body = '';
if openPos < 1 || openPos > numel(txt) || txt(openPos) ~= '{'
    return
end
depth = 0;
inStr = false;
for i = openPos:numel(txt)
    ch = txt(i);
    if inStr
        if ch == '"' && (i == 1 || txt(i - 1) ~= '\')
            inStr = false;
        end
        continue
    end
    if ch == '"'
        inStr = true;
    elseif ch == '{'
        depth = depth + 1;
    elseif ch == '}'
        depth = depth - 1;
        if depth == 0
            body = txt(openPos + 1:i - 1);
            return
        end
    end
end
end

function v = fieldStr(inner, name)
v = '';
m = regexp(inner, ['"' name '"\s*:\s*"((?:[^"\\]|\\.)*)"'], 'tokens', 'once');
if ~isempty(m)
    v = unescapeJson(m{1});
end
end

function v = fieldNum(inner, name)
v = NaN;
m = regexp(inner, ['"' name '"\s*:\s*([-+]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][-+]?\d+)?)'], 'tokens', 'once');
if ~isempty(m)
    v = str2double(m{1});
end
end

function v = fieldStrArray(inner, name)
v = {};
m = regexp(inner, ['"' name '"\s*:\s*\[([^\]]*)\]'], 'tokens', 'once');
if isempty(m)
    return
end
tokens = regexp(m{1}, '"((?:[^"\\]|\\.)*)"', 'tokens');
for k = 1:numel(tokens)
    v{end + 1} = unescapeJson(tokens{k}{1}); %#ok<AGROW>
end
end

function s = unescapeJson(s)
s = char(s);
s = strrep(s, '\\"', '"');
s = strrep(s, '\\\\', '\');
s = strrep(s, '\/', '/');
end
