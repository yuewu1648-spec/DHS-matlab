function h = sha256File(path)
%SHA256FILE Lowercase SHA-256 hex digest of a file ('' when unavailable).
%   h = bma.util.sha256File(path)
%
%   Used by the blind-literature seal, artifact import and model freeze. Returns
%   an empty string when the file is missing or the JVM digest is unavailable;
%   callers must treat '' as "cannot prove identity" instead of silently
%   accepting the file.
h = '';
p = char(path);
if exist(p, 'file') ~= 2
    return
end
try
    md = java.security.MessageDigest.getInstance('SHA-256');
    fis = java.io.FileInputStream(p);
    cleaner = onCleanup(@() fis.close()); %#ok<NASGU>
    buf = zeros(1, 65536, 'int8');
    while true
        n = fis.read(buf, 0, numel(buf));
        if n < 0
            break
        end
        if n > 0
            md.update(buf(1:n));
        end
    end
    digest = typecast(md.digest(), 'uint8');
    h = lower(sprintf('%02x', digest));
catch
    h = '';
end
end
