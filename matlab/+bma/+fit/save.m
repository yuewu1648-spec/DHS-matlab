function path = save(fr, path)
%SAVE 保存拟合结果（JSON，或扩展名为 .mat 时存 MAT）。
%   path = bma.fit.save(fr, path)
%
% fit.json 是 dispatch / report.build 的契约文件；MAT 版本保留完整 double 精度，
% 便于同一进程内快速加载。
if nargin < 2 || isempty(path)
    error('bma:fit:savePath', 'bma.fit.save 需要输出路径。');
end
path = char(path);
bma.util.ensureDir(fileparts(path));
[~, ~, ext] = fileparts(path);
if strcmpi(ext, '.mat')
    save(path, 'fr', '-v7');
else
    bma.util.writeJsonAtomic(path, fr);
end
end
