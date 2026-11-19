% test_integration_fit_tools.m
% =========================================================================
% Integration test: parameter-uncertainty / sensitivity / identifiability
% / cross-validation tool surface on the enzyme example model.
%
% Chain: validate -> build -> simulate -> fit -> profile -> sensitivity
%        -> identifiability -> cross-validation
%
% Contract: docs/DESIGN.md sections 4.4 (fit.*, validate.*), 5.4, 5.5.
% Owner: qa-acceptance.
% =========================================================================
qaRunFitTools();

% -------------------------------------------------------------------------
function qaRunFitTools()
% Keep the acceptance log readable: fitting emits many ode15s warnings.
oldWarn = warning('off', 'all');
warnCleaner = onCleanup(@() warning(oldWarn)); %#ok<NASGU>
projRoot = bma.util.projectRoot();
workDir = fullfile(projRoot, '.qa', 'test-artifacts', char(bma.util.newId('it-fittools')));
bma.util.ensureDir(workDir);
fprintf('[fit-tools] work dir: %s\n', workDir);
req = struct('schema', 'bma.rpc.v1', 'id', 'qa-fit-tools', 'work_dir', workDir);

spec = bma.util.readJson(fullfile(projRoot, 'spec', 'examples', 'enzyme_mm.json'));
dataAbs = fullfile(projRoot, 'spec', 'examples', 'data', 'enzyme_progress.csv');
outMap = struct('P_obs', 'P_obs', 'S_obs', 'S_obs');

runInfo = bma.server.dispatch('run.init', struct('name', ''), req);
runDir = char(runInfo.run_dir);

v = bma.server.dispatch('spec.validate', struct('spec', spec, 'run_dir', runDir), req);
qaAssert(logical(v.valid), 'enzyme_mm spec failed validation');
normSpec = v.normalized_spec;
b = bma.server.dispatch('model.build', struct('spec', normSpec, 'run_dir', runDir), req);
qaAssert(isfield(b, 'model_dir'), 'model.build returned no model_dir');

% ---- baseline fit -------------------------------------------------------
fprintf('[fit-tools] fit.estimate\n');
fitOpts = struct('multistart', 3, 'max_iter', 150, 'seed', 7);
f = bma.server.dispatch('fit.estimate', struct('spec', normSpec, 'run_dir', runDir, ...
    'data_csv', dataAbs, 'output_map', outMap, 'options', fitOpts), req);
qaAssert(isfield(f, 'fit_result_path') && qaPathExists(workDir, f.fit_result_path), ...
    'fit.estimate produced no fit result');
qaAssert(isfield(f, 'metrics') && isfield(f.metrics, 'r2') && double(f.metrics.r2) > 0.95, ...
    'baseline enzyme fit R2 is unexpectedly low');

% ---- fit.profile --------------------------------------------------------
fprintf('[fit-tools] fit.profile (kcat)\n');
prof = bma.server.dispatch('fit.profile', struct('spec', normSpec, 'run_dir', runDir, ...
    'data_csv', dataAbs, 'output_map', outMap, 'param', 'kcat', ...
    'fit_result_path', f.fit_result_path, ...
    'options', struct('n', 5, 'max_iter', 60)), req);
qaAssert(isfield(prof, 'param') && strcmpi(char(prof.param), 'kcat'), ...
    'fit.profile did not echo the profiled parameter');
qaAssert(isfield(prof, 'values') && numel(prof.values) >= 5, ...
    'fit.profile returned too few profile points');
qaAssert(isfield(prof, 'nll') && numel(prof.nll) >= 5, ...
    'fit.profile returned no negative log-likelihood profile');
qaAssert(isfield(prof, 'ci') && isfield(prof.ci, 'low') && isfield(prof.ci, 'high'), ...
    'fit.profile returned no confidence interval');
qaAssert(isfield(prof, 'profile_path') && qaPathExists(workDir, prof.profile_path), ...
    'fit.profile did not persist profile.json');
qaAssert(double(prof.ci.low) < double(prof.ci.high), 'fit.profile CI is not ordered');
fprintf('[fit-tools]   kcat profile CI = [%.4g, %.4g]\n', ...
    double(prof.ci.low), double(prof.ci.high));

% ---- fit.sensitivity ----------------------------------------------------
fprintf('[fit-tools] fit.sensitivity (local)\n');
sens = bma.server.dispatch('fit.sensitivity', struct('spec', normSpec, 'run_dir', runDir, ...
    'params', {{'kf', 'kr', 'kcat'}}, 'method', 'local'), req);
qaAssert(isfield(sens, 'indices') && ~isempty(sens.indices), ...
    'fit.sensitivity returned no indices');
qaAssert(isfield(sens, 'method') && ~isempty(char(sens.method)), ...
    'fit.sensitivity returned no method name');
qaAssert(isfield(sens, 'table_path') && qaAnyPathExists(workDir, sens.table_path), ...
    'fit.sensitivity did not persist its table');
idxNames = sens.indices;
requested = {'kf', 'kr', 'kcat'};
if isfield(idxNames, 'param_ids')
    got = qaStrList(idxNames.param_ids);
    covers = all(ismember(requested, got));
else
    covers = all(cellfun(@(p) isfield(idxNames, p), requested));
end
qaAssert(covers, sprintf('fit.sensitivity indices (%s) do not cover the requested parameters', ...
    strjoin(qaStructFields(idxNames), ',')));
if isfield(sens, 'figure') && ~isempty(sens.figure) && ischar(sens.figure)
    qaAssert(qaAnyPathExists(workDir, sens.figure), 'fit.sensitivity figure is missing');
end

% ---- fit.identifiability ------------------------------------------------
fprintf('[fit-tools] fit.identifiability\n');
ident = bma.server.dispatch('fit.identifiability', struct('spec', normSpec, ...
    'run_dir', runDir, 'data_csv', dataAbs, 'output_map', outMap, ...
    'options', struct()), req);
qaAssert(isfield(ident, 'structural') && isstruct(ident.structural), ...
    'fit.identifiability returned no structural analysis');
qaAssert(isfield(ident, 'practical') && isstruct(ident.practical), ...
    'fit.identifiability returned no practical analysis');
qaAssert(isfield(ident, 'correlations') && ~isempty(ident.correlations), ...
    'fit.identifiability returned no correlation information');
qaAssert(isfield(ident, 'rank') && isfinite(double(ident.rank)), ...
    'fit.identifiability returned no rank');
qaAssert(isfield(ident, 'table_path') && qaAnyPathExists(workDir, ident.table_path), ...
    'fit.identifiability did not persist its table');
fprintf('[fit-tools]   identifiability rank = %g / %d\n', double(ident.rank), numel(normSpec.parameters));

% ---- validate.cross_validation -----------------------------------------
fprintf('[fit-tools] validate.cross_validation (k=3)\n');
cv = bma.server.dispatch('validate.cross_validation', struct('spec', normSpec, ...
    'run_dir', runDir, 'data_csv', dataAbs, 'output_map', outMap, 'k', 3, ...
    'options', struct('multistart', 1, 'max_iter', 80)), req);
qaAssert(isfield(cv, 'folds') && numel(cv.folds) == 3, ...
    sprintf('validate.cross_validation returned %d folds, expected 3', qaNumelOr(cv, 'folds')));
qaAssert(isfield(cv, 'summary') && isstruct(cv.summary), ...
    'validate.cross_validation returned no summary');
foldItems = qaItems(cv.folds);
for k = 1:numel(foldItems)
    fold = foldItems{k};
    qaAssert(isfield(fold, 'train_r2') && isfield(fold, 'test_r2'), ...
        sprintf('cross-validation fold %d is missing train_r2/test_r2', k));
end
if isfield(cv, 'figure') && ~isempty(cv.figure) && ischar(cv.figure)
    qaAssert(qaAnyPathExists(workDir, cv.figure), 'cross-validation figure is missing');
end

warning(oldWarn); %#ok<NASGU>
fprintf('\n[fit-tools] PASS; artifacts: %s\n', workDir);
end

% =========================================================================
function c = qaItems(v)
if iscell(v)
    c = v(:)';
elseif isstruct(v)
    c = num2cell(v);
    c = c(:)';
elseif isempty(v)
    c = {};
else
    c = {v};
end
end

function c = qaStrList(v)
% Normalize an id list (cellstr / string / char / struct array) to cellstr.
items = qaItems(v);
c = cell(1, numel(items));
for k = 1:numel(items)
    it = items{k};
    if isstruct(it)
        if isfield(it, 'id')
            c{k} = char(it.id);
        elseif isfield(it, 'name')
            c{k} = char(it.name);
        else
            c{k} = '';
        end
    else
        c{k} = char(it);
    end
end
end

function f = qaStructFields(s)
if isstruct(s)
    f = fieldnames(s);
else
    f = {'<not-a-struct>'};
end
end

function n = qaNumelOr(st, field)
n = 0;
if isstruct(st) && isfield(st, field)
    v = st.(field);
    if iscell(v) || isnumeric(v) || isstruct(v), n = numel(v); end
end
end

function tf = qaPathExists(base, rel)
p = bma.util.absPath(base, rel);
tf = isfile(p) || isfolder(p);
end

function tf = qaAnyPathExists(workDir, rel)
% Artifact paths are documented as work_dir-relative, but some modules emit
% project-root-relative paths. Accept either convention (tracked in ACCEPTANCE).
p = bma.util.absPath(workDir, rel);
if isfile(p) || isfolder(p), tf = true; return; end
p2 = bma.util.absPath(bma.util.projectRoot(), rel);
tf = isfile(p2) || isfolder(p2);
end

function qaAssert(cond, msg)
if ~logical(cond)
    error('qa:assert:failed', '%s', msg);
end
end
