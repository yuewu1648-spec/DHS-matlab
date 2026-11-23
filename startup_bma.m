function startup_bma()
%STARTUP_BMA Add the BioModel-MATLAB MATLAB source tree to the path.
%   The project root is located by the VERSION marker: this file is documented
%   at the root, but the lookup also tolerates being one directory below it.
%   (0.14.0: the previous version stripped two levels, so with the file at the
%   root it resolved to the drive and added a non-existent "E:\matlab" path.)
here = fileparts(mfilename('fullpath'));
root = here;
if ~isfile(fullfile(root, 'VERSION'))
    up = fileparts(here);
    if isfile(fullfile(up, 'VERSION'))
        root = up;
    end
end
ml = fullfile(root, 'matlab');
if ~contains(path, ml)
    addpath(ml);
end
fprintf('BioModel-MATLAB project root: %s\n', root);
fprintf('MATLAB sources on path:      %s\n', ml);
end
