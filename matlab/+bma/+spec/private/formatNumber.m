function s = formatNumber(v)
%FORMATNUMBER 将数值格式化为适合嵌入公式/提示的短字符串。
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
    s = 'NaN';
    return
end
if v == 0
    s = '0';
    return
end
if v == round(v) && abs(v) < 1e15
    s = sprintf('%.0f', v);
else
    s = sprintf('%.6g', v);
end
end
