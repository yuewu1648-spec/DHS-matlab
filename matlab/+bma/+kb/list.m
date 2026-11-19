function [items, total] = list(tag, limit, varargin)
%LIST 列出知识库条目（可按 tag/type/domain/keyword 过滤）。
%   items = bma.kb.list()
%   items = bma.kb.list('archetype')
%   items = bma.kb.list('unit', 200)
%   [items, total] = bma.kb.list(tag, limit, 'KbDir', dir)
%
%   默认不列出 type=unit 的单位条目（避免刷屏）；显式 tag='unit' 可列出。
%   返回字段：id / type / name / name_en / summary / tags / path /
%            domain / scale / model_class
if nargin < 1 || isempty(tag)
    tag = '';
end
if nargin < 2 || isempty(limit)
    limit = 50;
end
limit = max(0, min(500, double(limit)));
idx = bma.kb.index(varargin{:});
items = emptyListItems();
total = 0;
if isempty(idx.items)
    return
end
all = idx.items;
filters = toFilterCell(tag);
keep = false(1, numel(all));
for k = 1:numel(all)
    if isempty(filters)
        keep(k) = ~strcmp(all(k).type, 'unit');
    else
        keep(k) = matchesAny(all(k), filters);
    end
end
filtered = all(keep);
total = numel(filtered);
if total == 0
    return
end
% 排序：按类型优先级，再按原有（文件路径/名称）顺序
rank = zeros(1, total);
for k = 1:total
    rank(k) = typeRank(filtered(k).type);
end
keys = rank * 1e6 + (1:total);
[~, ord] = sort(keys);
filtered = filtered(ord);
n = min(limit, total);
for k = 1:n
    e = struct();
    e.id = filtered(k).id;
    e.type = filtered(k).type;
    e.name = filtered(k).name;
    e.name_en = filtered(k).name_en;
    e.summary = filtered(k).summary;
    e.tags = filtered(k).tags;
    e.path = filtered(k).path;
    e.domain = filtered(k).domain;
    e.scale = filtered(k).scale;
    e.model_class = filtered(k).model_class;
    if isempty(items)
        items = e;
    else
        items(end + 1) = e; %#ok<AGROW>
    end
end
end

% ---------------------------------------------------------------------------
function items = emptyListItems()
items = struct('id', {}, 'type', {}, 'name', {}, 'name_en', {}, ...
    'summary', {}, 'tags', {}, 'path', {}, 'domain', {}, 'scale', {}, ...
    'model_class', {});
end

function filters = toFilterCell(tag)
filters = {};
if isempty(tag)
    return
end
if ischar(tag)
    filters = {lower(strtrim(tag))};
elseif isstring(tag)
    filters = cellfun(@(s) lower(strtrim(char(s))), cellstr(tag), 'UniformOutput', false);
elseif iscell(tag)
    for k = 1:numel(tag)
        if ischar(tag{k}) && ~isempty(strtrim(tag{k}))
            filters{end + 1} = lower(strtrim(tag{k})); %#ok<AGROW>
        end
    end
end
filters = filters(~cellfun(@isempty, filters));
end

function tf = matchesAny(item, filters)
cands = [item.tags, item.keywords, {item.type, item.domain, item.scale, ...
    item.model_class, item.id}];
tf = false;
for f = 1:numel(filters)
    for c = 1:numel(cands)
        if ischar(cands{c}) && strcmpi(cands{c}, filters{f})
            tf = true;
            return
        end
    end
end
end

function r = typeRank(t)
switch lower(char(t))
    case 'archetype'
        r = 1;
    case 'principle'
        r = 2;
    case 'ontology_class'
        r = 3;
    case 'ontology_level'
        r = 4;
    case 'ontology_scale'
        r = 5;
    case 'ontology'
        r = 6;
    case 'unit'
        r = 7;
    otherwise
        r = 8;
end
end
