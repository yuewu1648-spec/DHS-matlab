function txt = readText(path)
%READTEXT Read a UTF-8 text file into a char row vector.
fid = fopen(path, 'r', 'n', 'UTF-8');
if fid < 0
    error('bma:util:readText', 'Cannot open text file: %s', path);
end
cleaner = onCleanup(@() fclose(fid));
raw = fread(fid, Inf, '*char')';
txt = raw;
end
