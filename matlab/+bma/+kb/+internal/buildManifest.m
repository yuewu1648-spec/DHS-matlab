function manifest = buildManifest(kbDir)
%BUILDMANIFEST 生成 kb 目录的 JSON 文件清单（路径 + mtime + 字节数）。
%   索引缓存通过比较该清单判断是否失效：任一文件新增/删除/修改都会触发重建。
manifest = struct('path', {}, 'mtime', {}, 'bytes', {});
if ~isfolder(kbDir)
    return
end
files = bma.kb.internal.walkJson(kbDir, '');
for k = 1:numel(files)
    full = fullfile(kbDir, files{k});
    d = dir(full);
    if isempty(d)
        continue
    end
    manifest(end + 1) = struct('path', files{k}, 'mtime', ...
        d(1).datenum, 'bytes', double(d(1).bytes)); %#ok<AGROW>
end
end
