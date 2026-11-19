function idx = index(varargin)
%INDEX 扫描 kb/ 构建（或复用缓存的）知识库内存索引。
%   idx = bma.kb.index()
%   idx = bma.kb.index('KbDir', dir)      % 指向 fixture KB（测试/自造知识库）
%   idx = bma.kb.index('Force', true)     % 强制重建
%   idx = bma.kb.index('UseCache', false) % 不读写磁盘缓存
%
%   默认知识库目录：<projectRoot>/kb；可用环境变量 BMA_KB_DIR 或 'KbDir' 覆盖。
%   缓存失效策略：比较 kb/**/*.json 的 mtime + 字节数清单，任一变化即重建；
%   同时用 persistent 内存索引加速同一会话内的多次检索。
p = inputParser;
p.addParameter('KbDir', '', @(x)ischar(x) || isstring(x));
p.addParameter('Force', false, @(x)islogical(x) || isnumeric(x));
p.addParameter('UseCache', true, @(x)islogical(x) || isnumeric(x));
p.parse(varargin{:});
kbDir = bma.kb.internal.resolveKbDir(p.Results.KbDir);
manifest = bma.kb.internal.buildManifest(kbDir);
sig = signatureOf(kbDir, manifest);

persistent MEM
if ~p.Results.Force && ~isempty(MEM) && isfield(MEM, 'sig') && strcmp(MEM.sig, sig)
    idx = MEM.idx;
    return
end

cacheFile = bma.kb.internal.cachePath(kbDir);
if ~p.Results.Force && p.Results.UseCache && isfile(cacheFile)
    try
        cached = bma.util.readJson(cacheFile);
        if isstruct(cached) && isfield(cached, 'items') ...
                && isfield(cached, 'manifest') ...
                && bma.kb.internal.sameManifest(cached.manifest, manifest)
            idx = cached;
            if ~isfield(idx, 'warnings') || isempty(idx.warnings)
                idx.warnings = {};
            end
            MEM = struct('sig', sig, 'idx', idx);
            return
        end
    catch
        % 缓存损坏则重建
    end
end

idx = bma.kb.internal.scanKb(kbDir);
if p.Results.UseCache
    try
        bma.util.writeJsonAtomic(cacheFile, idx);
    catch
        % 缓存写失败不影响检索正确性
    end
end
MEM = struct('sig', sig, 'idx', idx);
end

% ---------------------------------------------------------------------------
function sig = signatureOf(kbDir, manifest)
parts = {lower(char(kbDir))};
for k = 1:numel(manifest)
    parts{end + 1} = sprintf('%s|%.10g|%d', manifest(k).path, ...
        manifest(k).mtime, round(manifest(k).bytes)); %#ok<AGROW>
end
sig = bma.io.internal.hashText(strjoin(parts, ';'), 16);
end
