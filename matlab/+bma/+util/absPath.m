function p = absPath(workDir, maybeRel)
%ABSPATH Resolve maybeRel against workDir unless it is already absolute.
if isempty(maybeRel)
    p = workDir;
    return
end
isAbs = ~isempty(regexp(maybeRel, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'));
if isAbs
    p = maybeRel;
else
    p = fullfile(workDir, strrep(maybeRel, '/', filesep));
end
end
