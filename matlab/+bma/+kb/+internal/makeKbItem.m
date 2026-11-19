function item = makeKbItem(id, type, name, name_en, summary, tags, keywords, ...
    domain, scale, model_class, path, selector, otherText)
%MAKEKBITEM 构造一条知识库索引条目（含字段加权检索所需的分组 token）。
item = struct();
item.id = char(id);
item.type = char(type);
item.name = char(name);
item.name_en = char(name_en);
item.summary = char(summary);
if isempty(tags)
    tags = {};
end
item.tags = tags;
item.keywords = keywords;
item.domain = char(domain);
item.scale = char(scale);
item.model_class = char(model_class);
item.path = char(path);
item.selector = char(selector);
item.name_tokens = bma.kb.internal.tokenize([item.name ' ' item.name_en ' ' item.id]);
item.keyword_tokens = bma.kb.internal.tokenize(strjoin(keywords, ' '));
item.tag_tokens = bma.kb.internal.tokenize([strjoin(tags, ' ') ' ' item.domain ' ' ...
    item.scale ' ' item.model_class ' ' item.type]);
item.summary_tokens = bma.kb.internal.tokenize(item.summary);
if nargin < 13
    otherText = '';
end
item.other_tokens = bma.kb.internal.tokenize(otherText);
end
