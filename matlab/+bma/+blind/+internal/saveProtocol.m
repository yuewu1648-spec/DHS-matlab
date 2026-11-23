function saveProtocol(runDir, p)
%SAVEPROTOCOL Persist the blind-literature protocol atomically.
p.updated_at = bma.util.nowIso();
bma.util.writeJsonAtomic(bma.blind.internal.protocolFile(runDir), p);
end
