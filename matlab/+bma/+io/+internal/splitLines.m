function lines = splitLines(txt)
%SPLITLINES 逐行拆分文本，并记录每行在原文中的 1-based 字符区间。
%   lines = bma.io.internal.splitLines(txt)
%   lines(k).start / lines(k).stop / lines(k).text
%
%   start/stop 指向原文本中该行的首、尾字符（不含换行符），因此
%   txt(lines(k).start:lines(k).stop) == lines(k).text 恒成立（空行时 stop = start-1）。
txt = char(txt);
n = numel(txt);
if n == 0
    lines = struct('start', {}, 'stop', {}, 'text', {});
    return
end
nl = find(txt == char(10));
starts = [1, nl + 1];
stops = [nl - 1, n];
keep = starts <= n;
starts = starts(keep);
stops = stops(keep);
m = numel(starts);
texts = cell(1, m);
for k = 1:m
    if stops(k) >= starts(k)
        texts{k} = txt(starts(k):stops(k));
    else
        texts{k} = '';
    end
end
lines = struct('start', num2cell(starts), 'stop', num2cell(stops), 'text', texts);
end
