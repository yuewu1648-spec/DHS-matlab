function r = get(id, varargin)
%GET 读取一个知识库条目的完整 JSON（archetype / principle / ontology / unit）。
%   r = bma.kb.get('enzyme_kinetics')
%   r = bma.kb.get('ontology.class.ode')
%   r = bma.kb.get('unit.uM')
%
%   返回：item（完整条目 struct）、path（相对 kb 根）、path_abs、id、type、kb_dir。
%   条目不存在时报 bma:kb:notFound。
if nargin < 1 || isempty(id)
    error('bma:kb:missingId', 'bma.kb.get 需要条目的 id。');
end
if isstring(id)
    id = char(id);
end
id = strtrim(char(id));
idx = bma.kb.index(varargin{:});
if isempty(idx.items)
    error('bma:kb:empty', ...
        '知识库为空：%s。请等待 kb 内容就绪，或检查 BMA_KB_DIR/KbDir 设置。', idx.kb_dir);
end
ids = {idx.items.id};
pos = find(strcmp(ids, id), 1);
if isempty(pos)
    pos = find(strcmpi(ids, id), 1);
end
if isempty(pos)
    error('bma:kb:notFound', ...
        '知识库中不存在条目 "%s"（共 %d 条）。可用 bma.kb.list/bma.kb.search 查询。', ...
        id, numel(idx.items));
end
info = idx.items(pos);
[item, relPath] = lookupItem(idx, info);
[pathAbs, pathDisp] = bma.kb.internal.resolveItemPath(idx.kb_dir, relPath);
r = struct();
r.item = item;
r.path = pathDisp;
r.path_abs = pathAbs;
r.id = info.id;
r.type = info.type;
r.kb_dir = idx.kb_dir;
end

% ---------------------------------------------------------------------------
function [item, relPath] = lookupItem(idx, info)
relPath = info.path;
item = struct();
if isempty(relPath)
    return
end
[full, ~] = bma.kb.internal.resolveItemPath(idx.kb_dir, relPath);
if isempty(full)
    return
end
if ~isempty(info.selector) && strncmp(info.selector, 'ontology:', 9)
    parts = strsplit(info.selector, ':');
    if numel(parts) < 3
        return
    end
    json = bma.util.readJson(full);
    cname = parts{2};
    i = str2double(parts{3});
    if ~isfield(json, cname) || i < 1
        return
    end
    entries = json.(cname);
    if isstruct(entries)
        if i <= numel(entries)
            item = entries(i);
        end
    elseif iscell(entries)
        if i <= numel(entries) && isstruct(entries{i})
            item = entries{i};
        end
    end
    return
end
if ~isempty(info.selector) && strncmp(info.selector, 'units:', 6)
    unitId = info.selector(7:end);
    units = bma.kb.internal.readUnits(idx.kb_dir);
    for k = 1:numel(units)
        if strcmp(units(k).id, unitId)
            item = units(k);
            return
        end
    end
end
item = bma.util.readJson(full);
end
