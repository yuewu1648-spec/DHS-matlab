function [hits, total] = search(query, tags, limit, varargin)
%SEARCH 知识库检索（中英文混合分词 + 字段加权）。
%   hits = bma.kb.search('米氏酶动力学')
%   hits = bma.kb.search('Michaelis-Menten Km', {'archetype'}, 5)
%   [hits, total] = bma.kb.search(query, tags, limit, 'KbDir', dir)
%
%   分词：英文/数字按词（小写），中文按 2-gram；打分：name(3.0) > keywords(2.2)
%   > tags(1.8) > summary(1.2) > other(0.6)，同一 token 命中多个字段会累加。
%   返回字段：id / type / name / name_en / summary / score / matched_terms /
%            path / tags
if nargin < 1 || isempty(query)
    query = '';
end
if nargin < 2 || isempty(tags)
    tags = {};
end
if nargin < 3 || isempty(limit)
    limit = 10;
end
limit = max(0, min(200, double(limit)));
hits = emptyHits();
total = 0;
if isempty(strtrim(char(query)))
    return
end
qToks = bma.kb.internal.tokenize(char(query));
if isempty(qToks)
    return
end
idx = bma.kb.index(varargin{:});
if isempty(idx.items)
    return
end
filters = toFilterCell(tags);
weights = struct('name', 3.0, 'keywords', 2.2, 'tags', 1.8, ...
    'summary', 1.2, 'other', 0.6);
n = numel(idx.items);
scores = zeros(1, n);
matched = cell(1, n);
for k = 1:n
    item = idx.items(k);
    if ~isempty(filters) && ~matchesTags(item, filters)
        continue
    end
    sc = 0;
    mt = {};
    for t = 1:numel(qToks)
        tok = qToks{t};
        w = 0;
        if any(strcmp(item.name_tokens, tok))
            w = w + weights.name;
        end
        if any(strcmp(item.keyword_tokens, tok))
            w = w + weights.keywords;
        end
        if any(strcmp(item.tag_tokens, tok))
            w = w + weights.tags;
        end
        if any(strcmp(item.summary_tokens, tok))
            w = w + weights.summary;
        end
        if any(strcmp(item.other_tokens, tok))
            w = w + weights.other;
        end
        if w > 0
            sc = sc + w;
            mt{end + 1} = tok; %#ok<AGROW>
        end
    end
    if sc > 0
        scores(k) = sc;
        matched{k} = mt;
    end
end
keep = find(scores > 0);
total = numel(keep);
if total == 0
    return
end
% 按分数降序（同分按条目 id 升序，保证稳定）
[~, ord] = sortrows([-scores(keep)', (1:numel(keep))']);
keep = keep(ord);
nOut = min(limit, total);
for j = 1:nOut
    k = keep(j);
    item = idx.items(k);
    e = struct();
    e.id = item.id;
    e.type = item.type;
    e.name = item.name;
    e.name_en = item.name_en;
    e.summary = truncateText(item.summary, 240);
    e.score = round(scores(k) * 10000) / 10000;
    e.matched_terms = matched{k}(1:min(8, numel(matched{k})));
    e.path = item.path;
    e.tags = item.tags;
    if isempty(hits)
        hits = e;
    else
        hits(end + 1) = e; %#ok<AGROW>
    end
end
end

% ---------------------------------------------------------------------------
function hits = emptyHits()
hits = struct('id', {}, 'type', {}, 'name', {}, 'name_en', {}, ...
    'summary', {}, 'score', {}, 'matched_terms', {}, 'path', {}, 'tags', {});
end

function filters = toFilterCell(tags)
filters = {};
if isempty(tags)
    return
end
if ischar(tags)
    filters = {lower(strtrim(tags))};
elseif isstring(tags)
    filters = cellfun(@(s) lower(strtrim(char(s))), cellstr(tags), 'UniformOutput', false);
elseif iscell(tags)
    for k = 1:numel(tags)
        if ischar(tags{k}) && ~isempty(strtrim(tags{k}))
            filters{end + 1} = lower(strtrim(tags{k})); %#ok<AGROW>
        end
    end
end
filters = filters(~cellfun(@isempty, filters));
end

function tf = matchesTags(item, filters)
cands = [item.tags, {item.type, item.domain, item.scale, item.model_class}];
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

function s = truncateText(s, maxLen)
s = char(s);
if numel(s) > maxLen
    s = [s(1:maxLen - 3) '...'];
end
end
