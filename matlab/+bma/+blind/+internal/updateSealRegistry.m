function updateSealRegistry(workDir, entry)
%UPDATESEALREGISTRY Insert/replace one run's seal entry in the workspace registry.
file = bma.blind.internal.sealRegistryFile(workDir);
doc = struct('schema', 'bma.blindSeals.v1', 'seals', {{}}, ...
    'updated_at', bma.util.nowIso());
if isfile(file)
    try
        old = bma.util.readJson(file);
        if isstruct(old)
            if isfield(old, 'seals')
                doc.seals = bma.blind.internal.asStructList(old.seals);
            end
            if isfield(old, 'schema') && ~isempty(old.schema)
                doc.schema = old.schema;
            end
        end
    catch
        % Corrupt registry: rebuild it rather than silently dropping the seal.
    end
end
seals = {};
for k = 1:numel(doc.seals)
    s = doc.seals{k};
    if isstruct(s) && ~strcmpi(char(getStr(s, 'run_id', '')), char(getStr(entry, 'run_id', '')))
        seals{end + 1} = s; %#ok<AGROW>
    end
end
seals{end + 1} = entry;
doc.seals = seals;
doc.updated_at = bma.util.nowIso();
bma.util.ensureDir(fileparts(file));
bma.util.writeJsonAtomic(file, doc);
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end
