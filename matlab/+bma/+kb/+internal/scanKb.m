function idx = scanKb(kbDir)
%SCANKB 扫描 kb/ 目录构建内存索引（archetypes / principles / ontology / units）。
%   idx = bma.kb.internal.scanKb(kbDir)
%
%   索引条目字段见 emptyKbItems；每条带 5 组检索 token（name/keywords/tags/
%   summary/other），供 bma.kb.search 做字段加权打分。
idx = struct();
idx.schema = 'bma.kb.index.v1';
idx.kb_dir = char(kbDir);
idx.built_at = bma.util.nowIso();
idx.manifest = bma.kb.internal.buildManifest(kbDir);
idx.items = bma.kb.internal.emptyKbItems();
idx.warnings = {};
if ~isfolder(kbDir)
    idx.warnings{end + 1} = sprintf(['知识库目录不存在：%s。' ...
        '（kb 内容由 kb-author 提供；在就绪前 kb.* 返回空索引，不阻塞其它模块。）'], kbDir);
    idx.counts = countsOf(idx.items);
    return
end

files = bma.kb.internal.walkJson(kbDir, '');
% 第一轮：普通条目文件（archetypes/、principles/ 及其它 JSON）
for k = 1:numel(files)
    rel = files{k};
    if strcmpi(rel, 'ontology.json') || strcmpi(rel, 'units.json')
        continue
    end
    low = lower(rel);
    if startsWith(low, 'archetypes/')
        defaultType = 'archetype';
    elseif startsWith(low, 'principles/')
        defaultType = 'principle';
    else
        defaultType = 'other';
    end
    [item, warning] = itemFromFile(kbDir, rel, defaultType);
    if ~isempty(warning)
        idx.warnings{end + 1} = warning; %#ok<AGROW>
    end
    idx.items = appendItem(idx.items, item);
end

% 第二轮：ontology.json（层次 / 模型类别 / 尺度 展开为独立条目）
[ontoItems, warnings] = ontologyItems(kbDir);
for k = 1:numel(ontoItems)
    idx.items = appendItem(idx.items, ontoItems(k));
end
idx.warnings = [idx.warnings, warnings];

% 第三轮：units.json（单位表，type=unit；默认 kb.list 不列出，可用 tag='unit'）
units = bma.kb.internal.readUnits(kbDir);
unitsDisp = bma.kb.internal.displayPath(kbDir, 'units.json');
for k = 1:numel(units)
    u = units(k);
    tags = nonEmpty({u.dim, u.base, 'unit'});
    keywords = [u.aliases, nonEmpty({u.dim, u.base, u.symbol})];
    summary = sprintf('单位 %s：dim=%s，factor=%g，base=%s', ...
        u.id, u.dim, u.factor, u.base);
    otherText = strjoin(nonEmpty({u.note, u.symbol}), ' ');
    item = bma.kb.internal.makeKbItem(['unit.' char(u.id)], 'unit', u.id, ...
        u.symbol, summary, tags, keywords, 'units', '', '', unitsDisp, ...
        ['units:' char(u.id)], otherText);
    idx.items = appendItem(idx.items, item);
end

idx.items = ensureUniqueIds(idx.items);
idx.counts = countsOf(idx.items);
end

% ---------------------------------------------------------------------------
function [item, warning] = itemFromFile(kbDir, rel, defaultType)
item = [];
warning = '';
full = fullfile(kbDir, rel);
try
    json = bma.util.readJson(full);
catch err
    warning = sprintf('跳过无法解析的 KB 文件 %s：%s', rel, err.message);
    return
end
if ~isstruct(json) || ~isscalar(json)
    warning = sprintf('跳过结构异常的 KB 文件 %s（顶层不是单个 JSON 对象）。', rel);
    return
end
id = strField(json, 'id', '');
if isempty(id)
    [~, base] = fileparts(rel);
    id = base;
end
type = strField(json, 'type', defaultType);
name = strField(json, 'name', id);
nameEn = strField(json, 'name_en', '');
summary = strField(json, 'summary', '');
if isempty(summary)
    summary = strField(json, 'description', '');
end
domain = strField(json, 'domain', '');
scale = strField(json, 'scale', '');
modelClass = strField(json, 'model_class', '');
tags = cellField(json, 'tags');
tags = uniqueStable([tags, nonEmpty({domain, scale, modelClass, type})]);
keywords = cellField(json, 'keywords');
if isempty(keywords)
    keywords = cellField(json, 'when_to_use');
end
other = bma.kb.internal.collectStrings(bma.kb.internal.pickFields(json, ...
    {'when_to_use', 'equations', 'assumptions', 'evidence_cues', ...
    'fitting_notes', 'identifiability_notes', 'notes', 'description', ...
    'examples', 'typical_questions', 'common_models', 'matlab_impl', ...
    'terms', 'related', 'references', 'model_spec_class', 'time_scale', ...
    'spec_template', 'variables', 'parameters'}));
dispPath = bma.kb.internal.displayPath(kbDir, rel);
item = bma.kb.internal.makeKbItem(id, type, name, nameEn, summary, tags, ...
    keywords, domain, scale, modelClass, dispPath, '', strjoin(other, ' '));
end

function [items, warnings] = ontologyItems(kbDir)
items = bma.kb.internal.emptyKbItems();
warnings = {};
file = fullfile(kbDir, 'ontology.json');
if ~isfile(file)
    return
end
try
    json = bma.util.readJson(file);
catch err
    warnings{end + 1} = sprintf('跳过无法解析的 ontology.json：%s', err.message);
    return
end
if ~isstruct(json) || ~isscalar(json)
    warnings{end + 1} = 'ontology.json 顶层结构异常，已跳过。';
    return
end
topText = strjoin(bma.kb.internal.collectStrings( ...
    bma.kb.internal.pickFields(json, {'levels', 'model_classes', 'scales'})), ' ');
ontoDisp = bma.kb.internal.displayPath(kbDir, 'ontology.json');
topItem = bma.kb.internal.makeKbItem('ontology', 'ontology', ...
    strField(json, 'name', 'ontology'), strField(json, 'name_en', ''), ...
    strField(json, 'description', ''), nonEmpty({'ontology'}), {}, ...
    '', '', '', ontoDisp, '', topText);
items = appendItem(items, topItem);
containers = {'levels', 'ontology_level', 'level'; ...
    'model_classes', 'ontology_class', 'class'; ...
    'scales', 'ontology_scale', 'scale'};
for c = 1:size(containers, 1)
    cname = containers{c, 1};
    ctype = containers{c, 2};
    cshort = containers{c, 3};
    if ~isfield(json, cname) || isempty(json.(cname))
        continue
    end
    entries = toStructArray(json.(cname));
    for i = 1:numel(entries)
        e = entries(i);
        eid = strField(e, 'id', sprintf('%s%d', cname, i));
        itemName = strField(e, 'name', eid);
        itemNameEn = strField(e, 'name_en', '');
        summary = strField(e, 'description', '');
        if isempty(summary)
            summary = strField(e, 'summary', '');
        end
        if isempty(summary)
            summary = strField(e, 'when', '');
        end
        keywords = [cellField(e, 'keywords'), cellField(e, 'examples'), ...
            cellField(e, 'typical_questions'), cellField(e, 'common_models')];
        keywords = uniqueStable(keywords);
        tags = uniqueStable([nonEmpty({ctype, cname, eid}), ...
            nonEmpty({strField(e, 'model_spec_class', '')})]);
        other = bma.kb.internal.collectStrings(bma.kb.internal.pickFields(e, ...
            {'examples', 'typical_questions', 'common_models', 'time_scale', ...
            'matlab_impl', 'when', 'when_to_use', 'description', 'notes'}));
        item = bma.kb.internal.makeKbItem( ...
            ['ontology.' cshort '.' slug(eid)], ctype, itemName, ...
            itemNameEn, summary, tags, keywords, eid, '', '', ...
            ontoDisp, sprintf('ontology:%s:%d', cname, i), ...
            strjoin(other, ' '));
        items = appendItem(items, item);
    end
end
end

% ---------------------------------------------------------------------------
function items = appendItem(items, item)
if isempty(item)
    return
end
if isempty(items)
    items = item;
else
    items(end + 1) = item;
end
end

function items = ensureUniqueIds(items)
if isempty(items)
    return
end
seen = containers.Map();
for k = 1:numel(items)
    base = items(k).id;
    key = lower(base);
    if isKey(seen, key)
        n = seen(key) + 1;
        seen(key) = n;
        items(k).id = sprintf('%s-%d', base, n);
    else
        seen(key) = 1;
    end
end
end

function c = countsOf(items)
c = struct();
c.total = numel(items);
types = {'archetype', 'principle', 'ontology', 'ontology_level', ...
    'ontology_class', 'ontology_scale', 'unit', 'other'};
for k = 1:numel(types)
    c.(types{k}) = 0;
end
if isempty(items)
    return
end
for k = 1:numel(items)
    t = items(k).type;
    if isfield(c, t)
        c.(t) = c.(t) + 1;
    end
end
end

function arr = toStructArray(v)
arr = [];
if isstruct(v)
    arr = v;
    return
end
if iscell(v)
    for k = 1:numel(v)
        if isstruct(v{k}) && isscalar(v{k})
            if isempty(arr)
                arr = v{k};
            else
                arr(end + 1) = v{k}; %#ok<AGROW>
            end
        end
    end
end
end

function v = strField(s, f, d)
v = d;
if ~isstruct(s) || ~isfield(s, f) || isempty(s.(f))
    return
end
raw = s.(f);
if ischar(raw)
    v = raw;
elseif isstring(raw)
    v = char(raw);
end
end

function v = cellField(s, f)
v = {};
if ~isstruct(s) || ~isfield(s, f) || isempty(s.(f))
    return
end
raw = s.(f);
if ischar(raw)
    if ~isempty(strtrim(raw))
        v = {raw};
    end
elseif isstring(raw)
    v = cellstr(raw);
elseif iscell(raw)
    for k = 1:numel(raw)
        if ischar(raw{k}) && ~isempty(strtrim(raw{k}))
            v{end + 1} = raw{k}; %#ok<AGROW>
        elseif isstring(raw{k}) && strlength(raw{k}) > 0
            v{end + 1} = char(raw{k}); %#ok<AGROW>
        end
    end
end
v = v(~cellfun(@isempty, v));
end

function out = nonEmpty(c)
out = {};
for k = 1:numel(c)
    if ischar(c{k}) && ~isempty(strtrim(c{k}))
        out{end + 1} = c{k}; %#ok<AGROW>
    elseif isstring(c{k}) && strlength(c{k}) > 0
        out{end + 1} = char(c{k}); %#ok<AGROW>
    end
end
end

function out = uniqueStable(c)
out = {};
if isempty(c)
    return
end
seen = containers.Map();
for k = 1:numel(c)
    if ~ischar(c{k})
        continue
    end
    key = lower(c{k});
    if ~isKey(seen, key)
        seen(key) = 1;
        out{end + 1} = c{k}; %#ok<AGROW>
    end
end
end

function s = slug(s)
s = lower(char(s));
s = regexprep(s, ['[^a-z0-9' char(13312) '-' char(40959) ']+'], '-');
s = regexprep(s, '^-+|-+$', '');
if isempty(s)
    s = 'item';
end
if numel(s) > 64
    s = s(1:64);
end
end
