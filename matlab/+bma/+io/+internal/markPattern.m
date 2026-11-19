function mask = markPattern(text, mask, pattern)
%MARKPATTERN 将正则 pattern 在 text 中的所有命中区间标记进 mask。
%   用于把 URL / DOI / 引文 / 图表编号等“不可信数字区域”整体屏蔽。
[s, e] = regexp(text, pattern, 'start', 'end');
n = numel(text);
for k = 1:numel(s)
    lo = max(1, s(k));
    hi = min(n, e(k));
    if hi >= lo
        mask(lo:hi) = true;
    end
end
end
