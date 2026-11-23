function p = canonicalPath(p)
%CANONICALPATH Absolute, separators-normalized path for seal comparisons.
%   Windows paths are case-insensitive; the comparison helper lowercases too.
if isempty(p)
    p = '';
    return
end
p = char(p);
try
    f = java.io.File(p);
    p = char(f.getCanonicalPath());
catch
    if isempty(regexp(p, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
        p = fullfile(pwd, p);
    end
end
p = strrep(p, '/', filesep);
p = strrep(p, '\', filesep);
end
