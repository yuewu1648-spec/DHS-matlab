% test_integration_contracts.m
% =========================================================================
% Integration test: service-level contracts and error handling.
%
% Verified here (docs/DESIGN.md sections 3-5):
%   * unknown RPC method / missing parameters produce actionable MATLAB errors;
%   * an invalid model spec is reported as valid:false with structured
%     {code,path,message} errors instead of an unhandled crash;
%   * a variable without `initial` triggers a warning and defaults to 0;
%   * bma.server.jsonSafe() always yields JSON-encodable output;
%   * spec.load/save round-trips, util read/write helpers are UTF-8 safe;
%   * run.init creates the documented artifact layout and is idempotent.
%
% Owner: qa-acceptance.
% =========================================================================
qaRunContracts();

% -------------------------------------------------------------------------
function qaRunContracts()
projRoot = bma.util.projectRoot();
workDir = fullfile(projRoot, '.qa', 'test-artifacts', char(bma.util.newId('it-contract')));
bma.util.ensureDir(workDir);
fprintf('[contracts] work dir: %s\n', workDir);
req = struct('schema', 'bma.rpc.v1', 'id', 'qa-contracts', 'work_dir', workDir);

% ---- util-level contracts ---------------------------------------------
fprintf('[contracts] util helpers\n');
qaAssert(isfolder(fullfile(projRoot, 'matlab')), 'projectRoot() does not point at the project');
id1 = char(bma.util.newId('qa'));
id2 = char(bma.util.newId('qa'));
qaAssert(~strcmp(id1, id2), 'newId() is not unique');
qaAssert(startsWith(id1, 'qa-'), 'newId() ignores the requested prefix');
tmpJson = fullfile(workDir, 'util_roundtrip.json');
payload = struct('name', '米氏动力学', 'values', [1 2 3], 'nested', struct('ok', true));
bma.util.writeJsonAtomic(tmpJson, payload);
back = bma.util.readJson(tmpJson);
qaAssert(strcmp(back.name, payload.name), 'writeJsonAtomic/readJson lost UTF-8 text');
qaAssert(isequal(double(back.values(:))', [1 2 3]), 'writeJsonAtomic/readJson lost numeric data');
tmpTxt = fullfile(workDir, 'util_roundtrip.txt');
bma.util.writeTextAtomic(tmpTxt, '中文 UTF-8 测试');
qaAssert(strcmp(bma.util.readText(tmpTxt), '中文 UTF-8 测试'), 'writeTextAtomic/readText lost UTF-8 text');
rel = bma.util.relPath(workDir, tmpTxt);
qaAssert(strcmpi(bma.util.absPath(workDir, rel), tmpTxt), 'relPath/absPath do not round-trip');

% ---- spec.load / spec.save round trip ----------------------------------
fprintf('[contracts] spec.load / spec.save\n');
specAbs = fullfile(projRoot, 'spec', 'examples', 'enzyme_mm.json');
spec = bma.spec.load(specAbs);
qaAssert(isstruct(spec) && isfield(spec, 'name') && strcmp(spec.name, 'enzyme_mm'), ...
    'bma.spec.load does not return the expected spec');
savedPath = fullfile(workDir, 'data', 'enzyme_mm_saved.json');
bma.spec.save(spec, savedPath);
qaAssert(isfile(savedPath), 'bma.spec.save did not write the spec');
saved = bma.util.readJson(savedPath);
qaAssert(numel(saved.parameters) == numel(spec.parameters), 'spec.save lost parameters');

% ---- unknown method / missing parameters -------------------------------
fprintf('[contracts] dispatch error paths\n');
qaExpectError(@() bma.server.dispatch('no.such.method', struct(), req), ...
    {'bma:server:unknownMethod'}, 'unknown RPC method');
qaExpectError(@() bma.server.dispatch('spec.validate', struct('run_dir', ''), req), ...
    {'bma:server:missingSpec'}, 'spec.validate without a spec');
qaExpectError(@() bma.server.dispatch('literature.ingest', ...
    struct('path', fullfile(workDir, 'does_not_exist.pdf')), req), ...
    {'bma:io:fileNotFound'}, 'ingest of a missing file');
qaExpectError(@() bma.server.dispatch('report.build', ...
    struct('run_dir', '', 'spec_path', specAbs), req), ...
    {'bma:server:missingParam'}, 'report.build without a title');

% ---- invalid specs are reported, not crashed ---------------------------
fprintf('[contracts] invalid spec diagnostics\n');
badSpecs = qaBadSpecs(spec);
for k = 1:numel(badSpecs)
    bs = badSpecs{k};
    reported = false;
    try
        v = bma.server.dispatch('spec.validate', struct('spec', bs.spec), req);
        reported = true;
    catch err
        qaAssert(startsWith(err.identifier, 'bma:spec') || contains(lower(err.identifier), 'spec'), ...
            sprintf('%s produced an unexpected error identifier: %s', bs.label, err.identifier));
    end
    if reported
        qaAssert(isfield(v, 'valid') && ~logical(v.valid), ...
            sprintf('%s was accepted by spec.validate', bs.label));
        qaAssert(isfield(v, 'errors') && ~isempty(v.errors), ...
            sprintf('%s produced no structured errors', bs.label));
        errItems = qaItems(v.errors);
        first = errItems{1};
        qaAssert(isfield(first, 'code') && ~isempty(char(first.code)), ...
            sprintf('%s: error object has no code', bs.label));
        qaAssert(isfield(first, 'message') && ~isempty(char(first.message)), ...
            sprintf('%s: error object has no message', bs.label));
        qaAssert(isfield(first, 'path'), ...
            sprintf('%s: error object has no path', bs.label));
        fprintf('[contracts]   %-22s -> valid=false, code=%s\n', bs.label, char(first.code));
    else
        fprintf('[contracts]   %-22s -> structured error thrown\n', bs.label);
    end
end

% ---- missing initial values produce a warning and default to 0 ---------
fprintf('[contracts] missing initial warning\n');
warnSpec = qaWarningSpec();
vw = bma.server.dispatch('spec.validate', struct('spec', warnSpec), req);
qaAssert(logical(vw.valid), 'minimal spec with a missing initial value should still validate');
qaAssert(isfield(vw, 'warnings') && ~isempty(vw.warnings), ...
    'spec.validate did not warn about a variable without an initial value');
nw = vw.normalized_spec;
nwVars = qaItems(nw.variables);
qaAssert(isfinite(double(nwVars{1}.initial.value)), ...
    'normalize did not default the missing initial value');
qaAssert(double(nwVars{1}.initial.value) == 0, ...
    'normalize defaulted the missing initial value to a non-zero number');

% ---- jsonSafe ----------------------------------------------------------
fprintf('[contracts] bma.server.jsonSafe\n');
complex = struct();
complex.handle = @(x) x + 1;
complex.notFinite = [NaN, Inf];
complex.tab = table([1; 2], {'a'; 'b'});
complex.map = containers.Map({'k1'}, {42});
complex.stamp = datetime('now');
complex.mixed = {1, 'two', true};
safe = bma.server.jsonSafe(complex);
txt = jsonencode(safe);
qaAssert(ischar(txt) && numel(txt) > 10, 'jsonSafe output is not JSON encodable');
structArr = [struct('a', 1); struct('a', 2)];
safeArr = bma.server.jsonSafe(structArr);
qaAssert(iscell(safeArr) && numel(safeArr) == 2, ...
    'jsonSafe does not convert struct arrays to JS arrays');

% ---- run layout --------------------------------------------------------
fprintf('[contracts] run layout\n');
rr = bma.server.dispatch('run.init', struct('name', 'qa-contract-run'), req);
qaAssert(isfield(rr, 'run_dir') && isfolder(bma.util.absPath(workDir, rr.run_dir)), ...
    'run.init did not create the run directory');
dirs = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs'};
for k = 1:numel(dirs)
    qaAssert(isfolder(bma.util.absPath(workDir, fullfile(char(rr.run_dir), dirs{k}))), ...
        sprintf('run layout missing %s/', dirs{k}));
end
qaAssert(isfile(bma.util.absPath(workDir, fullfile(char(rr.run_dir), 'run.json'))), ...
    'run layout missing run.json');
rr2 = bma.server.dispatch('run.init', struct('name', 'qa-contract-run'), req);
qaAssert(strcmp(char(rr.run_dir), char(rr2.run_dir)), 'run.init is not idempotent for equal names');
rl = bma.server.dispatch('run.list', struct(), req);
qaAssert(isfield(rl, 'runs') && numel(rl.runs) >= 1, 'run.list does not list the created run');

fprintf('\n[contracts] PASS; artifacts: %s\n', workDir);
end

% =========================================================================
% helpers
% =========================================================================
function specs = qaBadSpecs(good)
% Each entry is a spec that must be rejected with a structured diagnostic.
specs = {};
s = good; s = rmfield(s, 'name');
specs{end+1} = struct('label', 'missing name', 'spec', s);
s = good; s.kind = 'dae';
specs{end+1} = struct('label', 'unsupported kind', 'spec', s);
s = good;
rx = qaItems(s.reactions);
rx{1}.rate.kind = 'not_a_rate_law';
s.reactions = rx;
specs{end+1} = struct('label', 'unknown rate kind', 'spec', s);
s = good; s = rmfield(s, 'variables');
specs{end+1} = struct('label', 'missing variables', 'spec', s);
s = good;
pr = qaItems(s.parameters);
pr{1}.unit = 'furlongs';
s.parameters = pr;
specs{end+1} = struct('label', 'unknown unit', 'spec', s);
end

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

function s = qaWarningSpec()
s = struct();
s.schema_version = 'bma.modelSpec.v1';
s.name = 'qa_warning_spec';
s.kind = 'ode';
s.time = struct('unit', 's', 'start', 0, 'end', 10, 'n', 11);
s.variables = {struct('id', 'X', 'name', 'X 浓度', 'unit', 'uM')};
s.parameters = {struct('id', 'k', 'name', '降解速率', 'unit', '1/s', ...
    'value', struct('value', 1), 'estimate', false)};
s.reactions = {struct('id', 'decay', 'name', '降解', ...
    'stoichiometry', struct('X', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('X', 1)))};
end

function qaExpectError(fn, identifiers, label)
threw = false;
try
    fn();
catch err
    threw = true;
    ok = any(strcmp(err.identifier, identifiers)) || ...
        any(cellfun(@(id) startsWith(err.identifier, id), identifiers));
    qaAssert(ok, sprintf('%s threw unexpected identifier %s (expected %s)', ...
        label, err.identifier, strjoin(identifiers, ' | ')));
end
qaAssert(threw, sprintf('%s did not raise an error', label));
end

function qaAssert(cond, msg)
if ~logical(cond)
    error('qa:assert:failed', '%s', msg);
end
end
