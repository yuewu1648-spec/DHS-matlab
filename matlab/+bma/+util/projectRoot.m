function root = projectRoot()
%PROJECTROOT Absolute path of the BioModel-MATLAB project root.
%   root = bma.util.projectRoot()
%   The project root is four levels above this file:
%   <root>/matlab/+bma/+util/projectRoot.m
root = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
end
