function rel = relPath(base, target)
%RELPATH Path of target relative to base, with forward slashes.
base = char(base); target = char(target);
base = regexprep(base, '[/\\]+$', '');
if strcmpi(base, target)
    rel = '.';
    return
end
prefix = [base filesep];
if strncmpi(target, prefix, numel(prefix))
    rel = target(numel(prefix) + 1:end);
else
    rel = target;
end
rel = strrep(rel, '\', '/');
end
