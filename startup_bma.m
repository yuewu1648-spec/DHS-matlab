function startup_bma()
%STARTUP_BMA Add the BioModel-MATLAB MATLAB source tree to the path.
root = fileparts(fileparts(mfilename('fullpath')));
ml = fullfile(root, 'matlab');
if ~contains(path, ml)
    addpath(ml);
end
fprintf('BioModel-MATLAB project root: %s\n', root);
fprintf('MATLAB sources on path:      %s\n', ml);
end
