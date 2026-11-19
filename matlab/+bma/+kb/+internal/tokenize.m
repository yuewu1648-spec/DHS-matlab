function toks = tokenize(str)
%TOKENIZE 中英文混合分词：英文/数字按词（小写），中文按 2-gram。
%   toks = bma.kb.internal.tokenize(str)
%
%   "米氏酶动力学 Michaelis-Menten" -> {'michaelis','menten','米氏','氏酶','酶动','动力','力学'}
%   单个中文字符保留为单 token；英文单字母被丢弃以降低噪声。
toks = {};
if isempty(str)
    return
end
if iscell(str)
    str = strjoin(str(~cellfun(@isempty, str)), ' ');
elseif isstring(str)
    str = strjoin(cellstr(str), ' ');
end
str = lower(char(str));
if isempty(str)
    return
end

% 英文/数字 token
latin = regexp(str, '[a-z][a-z0-9]*', 'match');
for k = 1:numel(latin)
    if numel(latin{k}) >= 2
        toks{end + 1} = latin{k}; %#ok<AGROW>
    end
end

% 中文连续片段：2-gram
zhPat = ['[' char(13312) '-' char(40959) ']+'];
runs = regexp(str, zhPat, 'match');
for r = 1:numel(runs)
    run = runs{r};
    n = numel(run);
    if n == 1
        toks{end + 1} = run; %#ok<AGROW>
    else
        for i = 1:n - 1
            toks{end + 1} = run(i:i + 1); %#ok<AGROW>
        end
    end
end

if isempty(toks)
    return
end
toks = unique(toks, 'stable');
end
