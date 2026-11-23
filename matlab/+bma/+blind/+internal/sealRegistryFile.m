function f = sealRegistryFile(workDir)
%SEALREGISTRYFILE Workspace-level registry of sealed primary papers.
%   The run-scoped protocol protects one run; this registry prevents a second
%   run in the same workspace from ingesting the same primary paper through a
%   freshly created run directory.
f = fullfile(char(workDir), '.bma', 'blind', 'seals.json');
end
