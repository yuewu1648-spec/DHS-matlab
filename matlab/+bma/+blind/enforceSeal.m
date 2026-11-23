function enforceSeal(runDir, srcAbs)
%ENFORCESEAL Refuse to ingest the sealed primary paper during blind modeling.
%   bma.blind.enforceSeal(runDir, srcAbs)
%
%   Called by bma.io.ingest. Two layers protect the primary:
%     1) the run's own protocol.json (sealed flag);
%     2) a workspace-level seal registry, so creating a fresh run directory
%        cannot be used to ingest the same primary through bma_literature_ingest.
%   Matching is by canonical path OR SHA-256. After bma_blind_reveal both layers
%   are lifted for that run; other sealed runs still block the same file.
runDir = char(runDir);
srcAbs = bma.blind.internal.canonicalPath(srcAbs);
srcSha = '';
if isfile(srcAbs)
    srcSha = bma.util.sha256File(srcAbs);
end

% ---- layer 1: this run's protocol ---------------------------------------
protoFile = bma.blind.internal.protocolFile(runDir);
if isfile(protoFile)
    try
        p = bma.util.readJson(protoFile);
        if isstruct(p) && isfield(p, 'guard') && isstruct(p.guard) && ...
                isfield(p.guard, 'sealed') && logical(p.guard.sealed) && ...
                isfield(p, 'primary') && isstruct(p.primary)
            if matchesPrimary(p.primary, srcAbs, srcSha)
                error('bma:blind:sealed', sealMessage('当前 run'));
            end
        end
    catch err
        if strcmp(err.identifier, 'bma:blind:sealed')
            rethrow(err)
        end
        % Corrupt protocol: fall through to the workspace registry.
    end
end

% ---- layer 2: workspace seal registry -----------------------------------
[blocked, entry] = bma.blind.internal.findSealedEntry( ...
    bma.blind.internal.workspaceOf(runDir), srcAbs, srcSha);
if blocked
    error('bma:blind:sealed', sealMessage(sprintf('run %s', ...
        char(getStr(entry, 'run_id', '?')))));
end
end

% ---------------------------------------------------------------------------
function tf = matchesPrimary(primary, srcAbs, srcSha)
tf = false;
p = char(getStr(primary, 'source_path', ''));
if ~isempty(p) && strcmpi(bma.blind.internal.canonicalPath(p), srcAbs)
    tf = true;
    return
end
h = char(getStr(primary, 'sha256', ''));
if ~isempty(h) && ~isempty(srcSha) && strcmpi(h, srcSha)
    tf = true;
end
end

function msg = sealMessage(where)
msg = ['主文献受盲建模封印保护（' where '）：建模期间不得读取全文（含图/表/正文）。' ...
    '当前只允许使用 blind/primary_abstract.md。请用 bma_blind_* 工具推进；' ...
    '结束自检后调用 bma_blind_reveal 解封，再 ingest 全文做对照。'];
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end
