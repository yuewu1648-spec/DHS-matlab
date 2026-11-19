function writeTextAtomic(path, txt)
%WRITETEXTATOMIC Write UTF-8 text using a temp-then-move strategy.
bma.util.ensureDir(fileparts(path));
tmp = [path '.tmp-' char(java.util.UUID.randomUUID())];
fid = fopen(tmp, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:util:writeTextAtomic', 'Cannot write text file: %s', path);
end
try
    fwrite(fid, txt, 'char');
catch err
    fclose(fid);
    rethrow(err);
end
fclose(fid);
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
    error('bma:util:writeTextAtomic', 'Cannot move text into place: %s (%s)', path, msg);
end
end
