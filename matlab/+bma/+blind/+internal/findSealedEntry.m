function [blocked, entry] = findSealedEntry(workDir, srcAbs, srcSha)
%FINDSEALEDENTRY Look for an active sealed primary in the workspace registry.
%   Any sealed entry matching the canonical path or SHA-256 blocks ingestion.
blocked = false;
entry = struct();
file = bma.blind.internal.sealRegistryFile(workDir);
if ~isfile(file)
    return
end
try
    doc = bma.util.readJson(file);
catch
    return
end
if ~isstruct(doc) || ~isfield(doc, 'seals')
    return
end
seals = bma.blind.internal.asStructList(doc.seals);
srcAbs = bma.blind.internal.canonicalPath(srcAbs);
for k = 1:numel(seals)
    s = seals{k};
    if ~isstruct(s) || ~logical(getBool(s, 'sealed', false))
        continue
    end
    same = false;
    p = char(getStr(s, 'primary_path', ''));
    if ~isempty(p) && strcmpi(bma.blind.internal.canonicalPath(p), srcAbs)
        same = true;
    end
    if ~same && ~isempty(srcSha)
        h = char(getStr(s, 'primary_sha256', ''));
        same = ~isempty(h) && strcmpi(h, srcSha);
    end
    if same
        blocked = true;
        entry = s;
        return
    end
end
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end

function v = getBool(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = logical(s.(f));
else
    v = d;
end
end
