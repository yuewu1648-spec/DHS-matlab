function writeJsonAtomic(path, s, varargin)
%WRITEJSONATOMIC Write a struct as pretty UTF-8 JSON using a temp-then-move.
%   bma.util.writeJsonAtomic(path, s)
%   bma.util.writeJsonAtomic(path, s, 'Pretty', false)
p = inputParser;
p.addParameter('Pretty', true);
p.parse(varargin{:});

bma.util.ensureDir(fileparts(path));
if p.Results.Pretty
    txt = jsonencode(s, 'PrettyPrint', true);
else
    txt = jsonencode(s);
end
tmp = [path '.tmp-' char(java.util.UUID.randomUUID())];
bma.util.writeTextAtomic(tmp, txt);
if exist(path, 'file')
    % copyfile keeps the target present for concurrent readers; a movefile
    % with overwrite briefly removes it on Windows, which breaks file-IPC
    % polling clients.
    [ok, msg] = copyfile(tmp, path, 'f');
    if ok
        delete(tmp);
    end
else
    [ok, msg] = movefile(tmp, path);
end
if ~ok
    error('bma:util:writeJsonAtomic', 'Cannot move JSON into place: %s (%s)', path, msg);
end
end
