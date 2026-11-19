function [entries, mask] = extractRanges(text, sections, mask, contextChars)
%EXTRACTRANGES 抽取区间数值（"5-10 µM" / "5 to 10 min"）与失去 caret 的科学计数
%   [entries, mask] = bma.io.internal.extractRanges(text, sections, mask, contextChars)
%
%   * 普通区间：为两端各生成一条记录（is_range=true，range=[a b]，单位相同）；
%   * "10-3 s-1" 这种 PDF 上标丢失/Unicode 减号情形：识别为 1e-3，只报一条；
%   * 命中区间写入 mask，主扫描不再重复处理。
entries = bma.io.internal.emptyNumbers();
n = numel(text);
rangePat = '(?:^|[^A-Za-z0-9_.])([+-]?\d+(?:\.\d+)?)\s*(?:-|to)\s*([+-]?\d+(?:\.\d+)?)';
[tokens, extents] = regexp(text, rangePat, 'tokens', 'tokenExtents');
for i = 1:numel(extents)
    ext = extents{i};
    if size(ext, 1) < 2
        continue
    end
    aStart = ext(1, 1);
    aEnd = ext(1, 2);
    bStart = ext(2, 1);
    bEnd = ext(2, 2);
    if aStart > aEnd || bStart > bEnd
        continue
    end
    if any(mask(aStart:bEnd))
        continue
    end
    a = str2double(text(aStart:aEnd));
    b = str2double(text(bStart:bEnd));
    if isnan(a) || isnan(b) || ~isfinite(a) || ~isfinite(b)
        continue
    end
    tail = '';
    if bEnd < n
        tail = text(bEnd + 1:min(n, bEnd + 70));
    end
    [canon, rawUnit, consumed] = bma.io.internal.findUnitAfter(tail);
    if isempty(canon)
        continue
    end
    unitEnd = bEnd + consumed;
    % "10-3 s-1" -> 1e-3 s^-1（PDF 上标丢失/Unicode 减号情形，按科学计数处理；
    %  普通区间在 b < a 时已被拒绝，因此这里不会误伤 "5-10 µM"）
    if abs(a - 10) < 1e-12 && b == round(b) && abs(b) <= 6
        sym = bma.io.internal.findSymbolBefore(text, aStart);
        entries(end + 1) = bma.io.internal.makeNumberEntry(text, sections, ...
            aStart, 10 ^ (-b), canon, rawUnit, sym, unitEnd, false, [], contextChars); %#ok<AGROW>
        mask(aStart:unitEnd) = true;
        continue
    end
    % 两端均非负却逆序，视为解析噪声
    if b < a && a >= 0 && b >= 0
        continue
    end
    sym = bma.io.internal.findSymbolBefore(text, aStart);
    entries(end + 1) = bma.io.internal.makeNumberEntry(text, sections, ...
        aStart, a, canon, rawUnit, sym, unitEnd, true, [a b], contextChars); %#ok<AGROW>
    entries(end + 1) = bma.io.internal.makeNumberEntry(text, sections, ...
        bStart, b, canon, rawUnit, sym, unitEnd, true, [a b], contextChars); %#ok<AGROW>
    mask(aStart:unitEnd) = true;
end
end
