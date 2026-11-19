function e = makeNumberEntry(text, sections, startPos, value, unit, unitRaw, ...
    symbol, quoteEnd, isRange, rangeVals, contextChars)
%MAKENUMBERENTRY 组装单个数字抽取结果（统一字段顺序，保证 struct 数组可拼接）。
if nargin < 11 || isempty(contextChars)
    contextChars = 80;
end
n = numel(text);
quoteEnd = min(n, max(startPos, round(quoteEnd)));
e = struct();
e.value = double(value);
e.unit = char(unit);
e.unit_raw = char(unitRaw);
e.symbol = char(symbol);
lo = max(1, startPos - contextChars);
hi = min(n, quoteEnd + contextChars);
ctx = text(lo:hi);
ctx = regexprep(ctx, '\s+', ' ');
ctx = strtrim(ctx);
if numel(ctx) > 320
    ctx = [ctx(1:317) '...'];
end
e.context = ctx;
[sid, sheading] = bma.io.internal.sectionAt(sections, startPos);
e.section_id = sid;
e.section_heading = sheading;
e.char_start = double(startPos);
q = text(startPos:quoteEnd);
q = regexprep(q, '\s+', ' ');
q = strtrim(q);
if numel(q) > 100
    q = q(1:100);
end
e.quote = q;
e.is_range = logical(isRange);
if isempty(rangeVals)
    e.range = [];
else
    e.range = double(rangeVals(:)');
end
e.sentence_id = '';
end
