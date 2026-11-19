function rel = exportFig(fig, opts)
%EXPORTFIG 把 figure 导出为 150dpi PNG 并返回契约要求的相对路径。
%   rel = bma.plot.internal.exportFig(fig, opts)
%   opts 为 bma.plot.internal.resolveOpts 的返回值。
% 注意：调用方负责关闭 figure（本函数不关闭，避免 onCleanup 重复 close）。
try
    exportgraphics(fig, opts.absPath, 'Resolution', opts.dpi);
catch err
    % 极端情况下退化为 print（仍无显示器依赖）
    print(fig, opts.absPath, '-dpng', sprintf('-r%d', opts.dpi));
    if exist(opts.absPath, 'file') ~= 2
        rethrow(err);
    end
end
if opts.relative
    rel = bma.util.relPath(opts.workDir, opts.absPath);
else
    rel = opts.absPath;
end
end
