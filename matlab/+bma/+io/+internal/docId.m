function id = docId(path, contentText)
%DOCID 由「文件名 slug + 内容哈希」生成稳定、可读、幂等的文献 id。
%   id = bma.io.internal.docId(path, contentText)
%
%   同一路径 + 同一内容 -> 同一个 id（重复 ingest 幂等）；
%   文件名不同但内容相同 -> id 因 slug 不同而不同，便于人工辨认。
[~, base] = fileparts(char(path));
slug = lower(char(base));
slug = regexprep(slug, '[^a-z0-9]+', '-');
slug = regexprep(slug, '^-+|-+$', '');
if isempty(slug)
    slug = 'doc';
end
if numel(slug) > 48
    slug = slug(1:48);
    slug = regexprep(slug, '-+$', '');
end
h = bma.io.internal.hashText(contentText, 10);
id = [slug '-' h];
end
