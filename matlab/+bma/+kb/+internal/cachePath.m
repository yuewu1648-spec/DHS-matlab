function p = cachePath(kbDir)
%CACHEPATH 知识库索引缓存文件路径（按 kb_dir 哈希隔离，避免 fixture 互相污染）。
projectRoot = bma.util.projectRoot();
h = bma.io.internal.hashText(lower(char(kbDir)), 10);
p = fullfile(projectRoot, '.bma', 'cache', ['kb-index-' h '.json']);
end
