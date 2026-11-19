function v = version()
%VERSION Agent/bundle/MATLAB version facts for reproducibility.
%   v = bma.version()
%   Fields: agent_version, bundle_version, spec_schema, matlab_version,
%   project_root. The agent version is read from <projectRoot>/VERSION; the
%   bundle version from bridge/package.json.
root = bma.util.projectRoot();
v = struct();
v.agent_version = readVersionFile(fullfile(root, 'VERSION'), '0.0.0-dev');
v.bundle_version = readBundleVersion(fullfile(root, 'bridge', 'package.json'));
v.spec_schema = 'bma.modelSpec.v1';
v.matlab_version = builtin('version');
v.project_root = root;
end

function s = readVersionFile(file, fallback)
s = fallback;
try
    if isfile(file)
        txt = strtrim(bma.util.readText(file));
        if ~isempty(txt)
            s = strtrim(strsplit(txt, newline));
            s = s{1};
        end
    end
catch
end
end

function s = readBundleVersion(pkgFile)
s = '0.0.0-dev';
try
    if isfile(pkgFile)
        pkg = bma.util.readJson(pkgFile);
        if isfield(pkg, 'version') && ~isempty(pkg.version)
            s = char(pkg.version);
        end
    end
catch
end
end
