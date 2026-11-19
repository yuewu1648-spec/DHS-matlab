function d = resolveKbDir(kbDir)
%RESOLVEKBDIR 解析知识库根目录：显式参数 > 环境变量 BMA_KB_DIR > <projectRoot>/kb。
if nargin >= 1 && ~isempty(kbDir)
    d = char(kbDir);
else
    env = getenv('BMA_KB_DIR');
    if ~isempty(env)
        d = env;
    else
        d = fullfile(bma.util.projectRoot(), 'kb');
    end
end
if isstring(d)
    d = char(d);
end
d = char(d);
if ~isempty(regexp(d, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    % 已是绝对路径
else
    d = bma.util.absPath(pwd, d);
end
d = regexprep(d, '[\\/]+$', '');
end
