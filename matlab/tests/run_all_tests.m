function allPassed = run_all_tests(varargin)
%RUN_ALL_TESTS Run every matlab/tests/test_*.m file in a fresh workspace.
%   allPassed = run_all_tests()
%   allPassed = run_all_tests('Filter', 'test_spec_')
%
% Each test file is a script that asserts its own behaviour and throws on
% failure. Files are executed with the MATLAB source tree on the path and the
% project root as the initial working directory.
p = inputParser;
p.addParameter('Filter', '', @ischar);
p.parse(varargin{:});

root = fileparts(fileparts(fileparts(mfilename('fullpath'))));  % matlab/tests -> project root
ml = fullfile(root, 'matlab');
addpath(ml);
here = fullfile(ml, 'tests');
files = dir(fullfile(here, 'test_*.m'));
files = files(~[files.isdir]);
if ~isempty(p.Results.Filter)
    files = files(contains({files.name}, p.Results.Filter));
end
files = sort({files.name});
if isempty(files)
    warning('bma:tests:none', 'No test_*.m files found under %s', here);
    allPassed = true;
    return
end
old = pwd;
cleaner = onCleanup(@() cd(old));
cd(root);
fprintf('=== BioModel-MATLAB test run: %d file(s) ===\n', numel(files));
results = struct('name', {}, 'passed', {}, 'seconds', {}, 'message', {});
for k = 1:numel(files)
    name = files{k};
    t0 = tic;
    passed = true;
    msg = '';
    try
        run(fullfile(here, name));
        fprintf('[PASS] %-42s %6.1fs\n', name, toc(t0));
    catch err
        passed = false;
        raw = err.message;
        if iscell(raw)
            raw = strjoin(cellfun(@char, raw, 'UniformOutput', false), ' | ');
        end
        msg = sprintf('%s: %s', err.identifier, char(raw));
        disp(getReport(err, 'extended', 'hyperlinks', 'off'));
        fprintf('[FAIL] %-42s %6.1fs\n       %s\n', name, toc(t0), msg);
    end
    results(end+1) = struct('name', name, 'passed', passed, ...
        'seconds', toc(t0), 'message', msg); %#ok<AGROW>
end
nPass = sum([results.passed]);
allPassed = nPass == numel(results);
fprintf('=== %d/%d passed, %.1fs total ===\n', nPass, numel(results), ...
    sum([results.seconds]));
if ~allPassed
    fprintf('--- failures ---\n');
    for k = 1:numel(results)
        if ~results(k).passed
            fprintf('  %s\n      %s\n', results(k).name, results(k).message);
        end
    end
end
if nargout == 0 && ~allPassed
    error('bma:tests:failed', '%d test file(s) failed', numel(results) - nPass);
end
end
