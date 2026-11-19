function ensureDir(path)
%ENSUREDIR Create a directory (and parents) when it does not exist.
if isempty(path)
    return
end
if ~isfolder(path)
    [ok, msg] = mkdir(path);
    if ~ok
        error('bma:util:ensureDir', 'Cannot create directory: %s (%s)', path, msg);
    end
end
end
