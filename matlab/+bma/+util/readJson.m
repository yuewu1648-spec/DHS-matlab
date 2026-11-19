function s = readJson(path)
%READJSON Read a UTF-8 JSON file into a MATLAB struct.
fid = fopen(path, 'r', 'n', 'UTF-8');
if fid < 0
    error('bma:util:readJson', 'Cannot open JSON file: %s', path);
end
cleaner = onCleanup(@() fclose(fid));
txt = fread(fid, Inf, '*char')';
if isempty(strtrim(txt))
    s = struct();
    return
end
s = jsondecode(txt);
end
