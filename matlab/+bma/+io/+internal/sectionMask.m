function mask = sectionMask(sections, mask, text, kindName)
%SECTIONMASK 把指定 kind 的章节整体标记为不可用区间。
%   默认用于屏蔽 References（文献列表里的年份、页码、卷期号几乎全是误报）。
n = numel(text);
if isempty(sections)
    return
end
for k = 1:numel(sections)
    if ~strcmpi(sections(k).kind, kindName)
        continue
    end
    lo = sections(k).char_start;
    hi = sections(k).char_end;
    if isempty(hi) || isnan(hi) || hi < lo
        hi = lo + numel(sections(k).text) - 1;
    end
    lo = max(1, lo);
    hi = min(n, hi);
    if hi >= lo
        mask(lo:hi) = true;
    end
end
end
