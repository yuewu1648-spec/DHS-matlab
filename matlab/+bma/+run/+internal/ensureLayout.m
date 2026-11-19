function d = ensureLayout(runDir)
%ENSURELAYOUT 创建运行目录的标准子目录（幂等），返回各子目录绝对路径。
%   标准子目录见 DESIGN §7：literature/models/data/fits/figures/report，
%   另含 logs/（与 server 端 ensureRunLayout 保持一致）。
names = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs', 'artifacts'};
d = struct();
for k = 1:numel(names)
    p = fullfile(runDir, names{k});
    bma.util.ensureDir(p);
    d.(names{k}) = p;
end
end
