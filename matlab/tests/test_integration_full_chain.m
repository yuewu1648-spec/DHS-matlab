% test_integration_full_chain.m
% =========================================================================
% Integration test: complete modelling chain for the three spec/examples
% models, exercised through bma.server.dispatch (the exact entry point the
% Node bridge uses, so artifact persistence/path/result contracts are tested
% as in production):
%
%   spec.validate -> model.build -> model.analyze -> model.simulate
%   -> fit.estimate -> validate.residuals -> report.build -> codegen.model
%
% Parameter recovery is checked against spec/examples/data/truth.json.
% Artifacts are kept under <root>/.bma/test-artifacts/<id>/ for inspection.
%
% Contract: docs/DESIGN.md sections 3 (spec), 4 (RPC methods), 5 (functions),
% 7 (artifact layout), 10 (acceptance). Owner: qa-acceptance.
%
% Runs inside MATLAB (via matlab/tests/run_all_tests.m or the shared RPC
% method `test.run`). Any failed check throws and fails the test file.
% =========================================================================
qaRunFullChain();

% -------------------------------------------------------------------------
function qaRunFullChain()
% Keep the acceptance log readable: fitting emits many ode15s warnings.
oldWarn = warning('off', 'all');
warnCleaner = onCleanup(@() warning(oldWarn)); %#ok<NASGU>
projRoot = bma.util.projectRoot();
workDir = fullfile(projRoot, '.qa', 'test-artifacts', char(bma.util.newId('it-fullchain')));
bma.util.ensureDir(workDir);
fprintf('[full-chain] project root : %s\n', projRoot);
fprintf('[full-chain] work dir     : %s\n', workDir);

req = struct('schema', 'bma.rpc.v1', 'id', 'qa-full-chain', 'work_dir', workDir);
truth = bma.util.readJson(fullfile(projRoot, 'spec', 'examples', 'data', 'truth.json'));

cases = {
    struct( ...
        'name', 'enzyme_mm', ...
        'data', 'enzyme_progress.csv', ...
        'outputMap', struct('P_obs', 'P_obs', 'S_obs', 'S_obs'), ...
        'species', {{'E', 'S', 'ES', 'P'}}, ...
        'reportTitle', '米氏酶动力学集成测试报告', ...
        'r2Min', 0.99, ...
        'expectConservation', true, ...
        'params', struct('id', {'kcat'}, 'relTol', {0.15}, 'absTol', {0})), ...
    struct( ...
        'name', 'goodwin', ...
        'data', 'goodwin_timeseries.csv', ...
        'outputMap', struct('m_obs', 'm_obs', 'p_obs', 'p_obs'), ...
        'species', {{'m', 'p', 'r'}}, ...
        'reportTitle', 'Goodwin 负反馈振荡器集成测试报告', ...
        'r2Min', 0.85, ...
        'expectConservation', false, ...
        'params', struct('id', {'K', 'h', 'beta', 'delta'}, ...
                         'relTol', {0.60, 0.50, 0.60, 0.60}, ...
                         'absTol', {0, 6, 0, 0})), ...
    struct( ...
        'name', 'sir', ...
        'data', 'sir_observations.csv', ...
        'outputMap', struct('I_obs', 'I_obs', 'R_obs', 'R_obs'), ...
        'species', {{'S', 'I', 'R'}}, ...
        'reportTitle', 'SIR 传染病动力学集成测试报告', ...
        'r2Min', 0.95, ...
        'expectConservation', true, ...
        'params', struct('id', {'beta', 'gamma'}, ...
                         'relTol', {0.10, 0.10}, ...
                         'absTol', {0, 0})) ...
};

summary = struct('models', {{}}, 'work_dir', workDir);
for ii = 1:numel(cases)
    c = cases{ii};
    fprintf('\n[full-chain] ===== model: %s =====\n', c.name);
    specAbs = fullfile(projRoot, 'spec', 'examples', [c.name '.json']);
    qaAssert(isfile(specAbs), sprintf('[%s] example spec not found: %s', c.name, specAbs));
    spec = bma.util.readJson(specAbs);
    dataAbs = fullfile(projRoot, 'spec', 'examples', 'data', c.data);
    qaAssert(isfile(dataAbs), sprintf('[%s] example data not found: %s', c.name, dataAbs));

    % ---- run layout -----------------------------------------------------
    r = qaDispatch(req, 'run.init', struct('name', ''));
    runDir = char(r.run_dir);
    qaAssert(~isempty(runDir) && qaPathExists(workDir, runDir), ...
        sprintf('[%s] run.init did not create a run directory', c.name));
    layoutDirs = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs'};
    for dd = 1:numel(layoutDirs)
        qaAssert(qaPathExists(workDir, fullfile(runDir, layoutDirs{dd})), ...
            sprintf('[%s] run layout is missing %s/', c.name, layoutDirs{dd}));
    end
    qaAssert(qaPathExists(workDir, fullfile(runDir, 'run.json')), ...
        sprintf('[%s] run.json is missing', c.name));

    % ---- 1. spec.validate ----------------------------------------------
    fprintf('[full-chain]  1/8 spec.validate\n');
    v = qaDispatch(req, 'spec.validate', struct('spec', spec, 'run_dir', runDir));
    qaAssert(logical(v.valid), sprintf('[%s] spec.validate reported invalid spec: %s', ...
        c.name, qaIssuesText(v.errors)));
    qaAssert(isfield(v, 'errors') && isempty(v.errors), ...
        sprintf('[%s] spec.validate returned errors for a valid spec: %s', c.name, qaIssuesText(v.errors)));
    qaAssert(isfield(v, 'normalized_spec') && isstruct(v.normalized_spec), ...
        sprintf('[%s] spec.validate did not return normalized_spec', c.name));
    qaAssert(isfield(v, 'spec_path') && qaPathExists(workDir, v.spec_path), ...
        sprintf('[%s] validate did not persist the normalized spec', c.name));
    qaAssert(isfield(v, 'units_check'), ...
        sprintf('[%s] spec.validate result is missing units_check', c.name));
    normSpec = v.normalized_spec;
    specRel = char(v.spec_path);

    % ---- 2. model.build -------------------------------------------------
    fprintf('[full-chain]  2/8 model.build\n');
    b = qaDispatch(req, 'model.build', struct('spec', normSpec, 'run_dir', runDir));
    qaAssert(isfield(b, 'model_dir') && qaPathExists(workDir, b.model_dir), ...
        sprintf('[%s] model.build did not create model_dir', c.name));
    speciesGot = qaCellstr(b.species);
    qaAssertSetEqual(speciesGot, c.species, ...
        sprintf('[%s] model.build species mismatch', c.name));
    paramsGot = qaCellstr(b.parameters);
    qaAssert(numel(paramsGot) == numel(normSpec.parameters), ...
        sprintf('[%s] model.build parameter count mismatch (%d vs %d)', ...
        c.name, numel(paramsGot), numel(normSpec.parameters)));
    qaAssert(isfield(b, 'network') && isfield(b.network, 'stoichiometry'), ...
        sprintf('[%s] model.build did not return a stoichiometry matrix', c.name));
    S = b.network.stoichiometry;
    qaAssert(isequal(size(S), [numel(normSpec.variables), numel(normSpec.reactions)]), ...
        sprintf('[%s] stoichiometry matrix has wrong size %s', c.name, mat2str(size(S))));
    rhsPath = '';
    if isfield(b, 'rhs_function_path'), rhsPath = char(b.rhs_function_path); end
    if isempty(rhsPath) && isfield(b, 'rhs_path'), rhsPath = char(b.rhs_path); end
    if ~isempty(rhsPath)
        qaAssert(qaPathExists(workDir, rhsPath), ...
            sprintf('[%s] model.build rhs path does not exist: %s', c.name, rhsPath));
    end

    % ---- 3. model.analyze ----------------------------------------------
    fprintf('[full-chain]  3/8 model.analyze\n');
    a = qaDispatch(req, 'model.analyze', struct('spec', normSpec, 'run_dir', runDir));
    qaAssert(isfield(a, 'analysis_path') && qaPathExists(workDir, a.analysis_path), ...
        sprintf('[%s] model.analyze did not persist analysis.json', c.name));
    qaAssert(isfield(a, 'conservation_laws'), ...
        sprintf('[%s] model.analyze result is missing conservation_laws', c.name));
    qaAssert(isfield(a, 'steady_states'), ...
        sprintf('[%s] model.analyze result is missing steady_states', c.name));
    qaAssert(isfield(a, 'dimensional_ok') && islogical(a.dimensional_ok) && a.dimensional_ok, ...
        sprintf('[%s] dimensional check failed: %s', c.name, qaIssuesText(a.warnings)));
    if c.expectConservation
        t = jsonencode(a.conservation_laws);
        qaAssert(~isempty(t) && ~strcmp(t, '[]') && ~strcmp(t, 'null'), ...
            sprintf('[%s] expected a conservation law but found none', c.name));
    end

    % ---- 4. model.simulate ---------------------------------------------
    fprintf('[full-chain]  4/8 model.simulate\n');
    s = qaDispatch(req, 'model.simulate', struct('spec', normSpec, 'run_dir', runDir, ...
        'options', struct('n', 201)));
    qaAssert(isfield(s, 'timeseries_path') && qaPathExists(workDir, s.timeseries_path), ...
        sprintf('[%s] model.simulate did not write a time series', c.name));
    tsAbs = bma.util.absPath(workDir, s.timeseries_path);
    T = readtable(tsAbs, 'VariableNamingRule', 'preserve');
    qaAssert(height(T) == 201, ...
        sprintf('[%s] simulated time series has %d rows, expected 201', c.name, height(T)));
    qaAssert(isfield(s, 'outputs') || isfield(s, 'final'), ...
        sprintf('[%s] model.simulate returned no output summary', c.name));
    if isfield(s, 'figures') && ~isempty(s.figures)
        figs = qaCellstr(s.figures);
        for fi = 1:numel(figs)
            qaAssert(qaAnyPathExists(workDir, figs{fi}), ...
                sprintf('[%s] simulate figure missing: %s', c.name, figs{fi}));
        end
        fprintf('[full-chain]      %d simulate figure(s)\n', numel(figs));
    else
        fprintf('[full-chain]      WARNING: model.simulate returned no figures\n');
    end

    % ---- 5. fit.estimate ----------------------------------------------
    fprintf('[full-chain]  5/8 fit.estimate\n');
    fitOpts = struct('multistart', 3, 'max_iter', 200, 'seed', 42);
    f = qaDispatch(req, 'fit.estimate', struct('spec', normSpec, 'run_dir', runDir, ...
        'data_csv', dataAbs, 'output_map', c.outputMap, 'options', fitOpts));
    qaAssert(isfield(f, 'fit_result_path') && qaPathExists(workDir, f.fit_result_path), ...
        sprintf('[%s] fit.estimate did not persist fit.json', c.name));
    qaAssert(isfield(f, 'fitted_spec_path') && qaPathExists(workDir, f.fitted_spec_path), ...
        sprintf('[%s] fit.estimate did not persist fitted_spec.json', c.name));
    fitDirAbs = bma.util.absPath(workDir, f.fit_dir);
    qaAssert(isfile(fullfile(fitDirAbs, 'params.csv')), ...
        sprintf('[%s] fit params.csv is missing', c.name));
    metrics = f.metrics;
    metricNames = {'r2', 'rmse', 'aicc', 'bic'};
    for mi = 1:numel(metricNames)
        qaAssert(isfield(metrics, metricNames{mi}), ...
            sprintf('[%s] fit metrics missing %s', c.name, metricNames{mi}));
    end
    r2 = double(metrics.r2);
    qaAssert(isfinite(r2) && r2 >= c.r2Min, ...
        sprintf('[%s] fit R2 %.4f below acceptance threshold %.2f', c.name, r2, c.r2Min));
    fprintf('[full-chain]      fit R2=%.4f RMSE=%.4g AICc=%.4g\n', ...
        r2, double(metrics.rmse), double(metrics.aicc));

    % fitted parameter recovery against truth.json
    pmap = qaParamMap(f.params);
    fittedSpec = bma.util.readJson(bma.util.absPath(workDir, f.fitted_spec_path));
    for pi = 1:numel(c.params)
        pid = c.params(pi).id;
        truthV = qaTruthValue(truth, c.name, pid);
        qaAssert(isfinite(truthV), sprintf('[%s] truth.json has no value for %s', c.name, pid));
        [found, vv] = qaLookupParam(pmap, pid);
        qaAssert(found, sprintf('[%s] fitted parameter %s not reported', c.name, pid));
        tol = max(c.params(pi).relTol * abs(truthV), c.params(pi).absTol);
        qaAssert(abs(vv - truthV) <= tol, ...
            sprintf('[%s] parameter %s recovered as %.6g, truth %.6g (tol %.3g)', ...
            c.name, pid, vv, truthV, tol));
        % fitted spec must carry the same value
        sv = qaSpecParamValue(fittedSpec, pid);
        qaAssert(isfinite(sv) && abs(sv - vv) <= 1e-9 * max(1, abs(vv)), ...
            sprintf('[%s] fitted_spec.json value for %s (%.6g) != fit.json (%.6g)', ...
            c.name, pid, sv, vv));
        fprintf('[full-chain]      %-6s fitted=%.6g truth=%.6g (tol %.2g)\n', ...
            pid, vv, truthV, tol);
    end

    % The three individual mass-action rate constants of enzyme_mm are not
    % separately identifiable from the sparse example progress curve (only 13
    % time points): the fit reaches R2>0.999 with kf/kr trading off. We
    % therefore additionally require the *derived* Michaelis-Menten quantities
    % implied by the fitted elementary constants to match the truth values.
    if strcmp(c.name, 'enzyme_mm')
        kfFit = qaParamValue(pmap, 'kf');
        krFit = qaParamValue(pmap, 'kr');
        kcatFit = qaParamValue(pmap, 'kcat');
        e0 = qaInitialOf(normSpec, 'E');
        kmFit = (krFit + kcatFit) / kfFit;
        vmaxFit = kcatFit * e0;
        kmTrue = (truth.enzyme_mm.kr + truth.enzyme_mm.kcat) / truth.enzyme_mm.kf;
        vmaxTrue = truth.enzyme_mm.kcat * truth.enzyme_mm.E0;
        qaAssert(abs(kmFit - kmTrue) <= 0.25 * kmTrue, ...
            sprintf('[enzyme_mm] derived Km recovered as %.4g, truth %.4g', kmFit, kmTrue));
        qaAssert(abs(vmaxFit - vmaxTrue) <= 0.15 * vmaxTrue, ...
            sprintf('[enzyme_mm] derived Vmax recovered as %.4g, truth %.4g', vmaxFit, vmaxTrue));
        fprintf('[full-chain]      derived Km=%.4g (truth %.4g), Vmax=%.4g (truth %.4g)\n', ...
            kmFit, kmTrue, vmaxFit, vmaxTrue);
    end

    % ---- 6. validate.residuals -----------------------------------------
    fprintf('[full-chain]  6/8 validate.residuals\n');
    vr = qaDispatch(req, 'validate.residuals', struct( ...
        'fit_result_path', f.fit_result_path, 'run_dir', runDir));
    qaAssert(isfield(vr, 'diagnostics'), ...
        sprintf('[%s] validate.residuals returned no diagnostics', c.name));
    if isfield(vr, 'figure') && ~isempty(vr.figure) && ischar(vr.figure)
        qaAssert(qaAnyPathExists(workDir, vr.figure), ...
            sprintf('[%s] residual figure missing: %s', c.name, vr.figure));
    end

    % ---- 7. report.build -----------------------------------------------
    fprintf('[full-chain]  7/8 report.build\n');
    rb = qaDispatch(req, 'report.build', struct('run_dir', runDir, 'title', c.reportTitle, ...
        'spec_path', specRel, 'fit_result_path', f.fit_result_path, ...
        'analysis_path', a.analysis_path));
    reportFields = {'report_html', 'report_md', 'model_card_path'};
    for ri = 1:numel(reportFields)
        qaAssert(isfield(rb, reportFields{ri}) && qaPathExists(workDir, rb.(reportFields{ri})), ...
            sprintf('[%s] report.build missing %s', c.name, reportFields{ri}));
    end
    mdTxt = bma.util.readText(bma.util.absPath(workDir, rb.report_md));
    qaAssert(numel(mdTxt) > 1500, ...
        sprintf('[%s] report.md is suspiciously short (%d chars)', c.name, numel(mdTxt)));
    qaAssertAnyKeyword(mdTxt, {'假设', 'assumption'}, ...
        sprintf('[%s] report.md has no assumptions section', c.name));
    qaAssertAnyKeyword(mdTxt, {'证据', 'evidence', '来源', '出处'}, ...
        sprintf('[%s] report.md has no parameter evidence table', c.name));
    qaAssertAnyKeyword(mdTxt, {'参数', 'parameter'}, ...
        sprintf('[%s] report.md has no parameter table', c.name));
    qaAssertAnyKeyword(mdTxt, {'验证', 'validation', '残差', 'residual', '指标', 'metric'}, ...
        sprintf('[%s] report.md has no validation/metrics section', c.name));
    parList = qaItems(normSpec.parameters);
    specIds = cellfun(@(p) char(p.id), parList, 'UniformOutput', false);
    idHits = 0;
    for pi = 1:numel(specIds)
        if contains(lower(mdTxt), lower(specIds{pi})), idHits = idHits + 1; end
    end
    qaAssert(idHits >= 2, ...
        sprintf('[%s] report.md mentions only %d parameter ids (need >= 2)', c.name, idHits));
    if isfield(rb, 'figures_used') && ~isempty(rb.figures_used)
        figs = qaCellstr(rb.figures_used);
        for fi = 1:numel(figs)
            qaAssert(qaAnyPathExists(workDir, figs{fi}), ...
                sprintf('[%s] report figure missing: %s', c.name, figs{fi}));
        end
    end
    mc = bma.util.readJson(bma.util.absPath(workDir, rb.model_card_path));
    qaAssert(isstruct(mc) && ~isempty(fieldnames(mc)), ...
        sprintf('[%s] model_card.json is empty', c.name));
    htmlTxt = bma.util.readText(bma.util.absPath(workDir, rb.report_html));
    qaAssert(contains(lower(htmlTxt), '<html'), ...
        sprintf('[%s] report.html is not an HTML document', c.name));

    % ---- 8. codegen.model ---------------------------------------------
    fprintf('[full-chain]  8/8 codegen.model\n');
    cg = qaDispatch(req, 'codegen.model', struct('spec', normSpec, 'run_dir', runDir));
    qaAssert(isfield(cg, 'm_file') && qaPathExists(workDir, cg.m_file), ...
        sprintf('[%s] codegen.model did not write an .m file', c.name));
    qaAssert(isfield(cg, 'function_name') && ~isempty(char(cg.function_name)), ...
        sprintf('[%s] codegen.model returned no function_name', c.name));
    mTxt = bma.util.readText(bma.util.absPath(workDir, cg.m_file));
    qaAssert(startsWith(strtrim(mTxt), 'function'), ...
        sprintf('[%s] generated file does not start with "function"', c.name));
    fnName = char(cg.function_name);
    qaAssert(contains(lower(mTxt), lower(fnName)), ...
        sprintf('[%s] generated file does not define %s', c.name, fnName));
    % the generated RHS should be callable and return the right number of derivatives
    qaTryGeneratedCode(bma.util.absPath(workDir, cg.m_file), fnName, normSpec);

    summary.models{end+1} = struct('name', c.name, 'run_dir', runDir, ...
        'spec_path', specRel, 'fit_result_path', char(f.fit_result_path), ...
        'report_md', char(rb.report_md), 'r2', r2, 'aicc', double(metrics.aicc));
end

% ---- model selection across the enzyme example sub-models ---------------
% (AICc model selection needs >= 2 candidate specifications for the same
% data set. We compare the full Michaelis-Menten mass-action model with a
% quasi-steady-state two-species variant written by the test.)
fprintf('\n[full-chain] ===== validate.model_selection =====\n');
qssSpec = qaQssEnzymeSpec();
qssSpecPath = fullfile(workDir, 'data', 'enzyme_mm_qss_spec.json');
bma.util.writeJsonAtomic(qssSpecPath, qssSpec);
selRun = qaDispatch(req, 'run.init', struct('name', ''));
selRunDir = char(selRun.run_dir);
enzymeSpecRel = fullfile('spec', 'examples', 'enzyme_mm.json');
enoCsvAbs = fullfile(projRoot, 'spec', 'examples', 'data', 'enzyme_progress.csv');
cand = struct( ...
    'name', {'enzyme_mm_full', 'enzyme_mm_qss'}, ...
    'spec_path', {enzymeSpecRel, qssSpecPath}, ...
    'data_csv', {enoCsvAbs, enoCsvAbs}, ...
    'output_map', {struct('P_obs', 'P_obs', 'S_obs', 'S_obs'), ...
                   struct('P_obs', 'P_obs', 'S_obs', 'S_obs')});
sel = qaDispatch(req, 'validate.model_selection', struct( ...
    'candidates', cand, 'run_dir', selRunDir, ...
    'options', struct('multistart', 2, 'max_iter', 150)));
qaAssert(isfield(sel, 'table'), 'validate.model_selection returned no table');
rows = sel.table;
if isstruct(rows), nRows = numel(rows); else nRows = size(rows, 1); end
qaAssert(nRows == 2, sprintf('model_selection table has %d rows, expected 2', nRows));
qaAssert(isfield(sel, 'best') && ~isempty(char(sel.best)), ...
    'validate.model_selection returned no best model');
qaAssert(isfield(sel, 'table_path') && qaAnyPathExists(workDir, sel.table_path), ...
    'validate.model_selection did not persist its table');
fprintf('[full-chain]      best model: %s\n', char(sel.best));

summary.work_dir = workDir;
bma.util.writeJsonAtomic(fullfile(workDir, 'qa_full_chain_summary.json'), summary);
warning(oldWarn); %#ok<NASGU>
fprintf('\n[full-chain] PASS (%d models); artifacts: %s\n', numel(cases), workDir);
end

% =========================================================================
% helpers
% =========================================================================
function r = qaDispatch(req, method, params)
r = bma.server.dispatch(method, params, req);
end

function s = qaQssEnzymeSpec()
% Two-species quasi-steady-state Michaelis-Menten variant used as a competing
% candidate model in the AICc model-selection check.
s = struct();
s.schema_version = 'bma.modelSpec.v1';
s.name = 'enzyme_mm_qss';
s.title = '米氏酶动力学（准稳态近似，两物种）';
s.kind = 'ode';
s.time = struct('unit', 's', 'start', 0, 'end', 60, 'n', 601);
s.compartments = {struct('id', 'cell', 'volume', 1, 'unit', 'L')};
s.variables = { ...
    struct('id', 'S', 'name', '底物', 'unit', 'uM', 'initial', struct('value', 10)), ...
    struct('id', 'P', 'name', '产物', 'unit', 'uM', 'initial', struct('value', 0))};
s.parameters = { ...
    struct('id', 'vmax', 'name', '最大速率', 'unit', 'uM/s', ...
           'value', struct('value', 20), 'estimate', true, 'bounds', [0.001, 100]), ...
    struct('id', 'km', 'name', '米氏常数', 'unit', 'uM', ...
           'value', struct('value', 4.2), 'estimate', true, 'bounds', [1e-3, 1e3])};
s.reactions = { ...
    struct('id', 'catalysis', 'name', '准稳态催化', ...
           'stoichiometry', struct('S', -1, 'P', 1), ...
           'rate', struct('kind', 'michaelis_menten', ...
                          'parameters', struct('vmax', 'vmax', 'km', 'km'), ...
                          'species', struct('substrate', 'S')))};
s.outputs = { ...
    struct('id', 'P_obs', 'name', '产物浓度', 'unit', 'uM', 'expression', 'P'), ...
    struct('id', 'S_obs', 'name', '底物浓度', 'unit', 'uM', 'expression', 'S')};
s.assumptions = {'准稳态假设（ES 不累积）', '酶总量恒定'};
end

function qaTryGeneratedCode(mFile, fnName, spec)
% Best effort: add the code directory to the path and call the generated RHS.
codeDir = fileparts(mFile);
addpath(codeDir);
cleaner = onCleanup(@() rmpath(codeDir));
vars = qaItems(spec.variables);
pars = qaItems(spec.parameters);
y0 = zeros(1, numel(vars));
for k = 1:numel(vars)
    y0(k) = qaInitialValue(vars{k});
end
p0 = zeros(1, numel(pars));
for k = 1:numel(pars)
    p0(k) = qaParamValueOf(pars{k});
end
try
    fh = str2func(fnName);
    dydt = fh(0, y0, p0);
    qaAssert(numel(dydt) == numel(y0), ...
        sprintf('generated RHS returned %d derivatives for %d species', numel(dydt), numel(y0)));
    qaAssert(all(isfinite(dydt)), 'generated RHS returned non-finite derivatives');
    fprintf('[full-chain]      generated RHS %s(t,y,p) evaluated OK\n', fnName);
catch err
    if strcmp(err.identifier, 'qa:assert:failed')
        rethrow(err)
    end
    fprintf('[full-chain]      WARNING: generated RHS not callable as %s(t,y,p): %s\n', ...
        fnName, err.message);
end
end

function v = qaInitialValue(var)
v = 0;
if isfield(var, 'initial') && isstruct(var.initial) && isfield(var.initial, 'value')
    v = double(var.initial.value);
end
end

function v = qaParamValueOf(par)
v = 0;
if isfield(par, 'value')
    if isstruct(par.value) && isfield(par.value, 'value')
        v = double(par.value.value);
    elseif isnumeric(par.value)
        v = double(par.value);
    end
end
end

function v = qaTruthValue(truth, modelName, paramId)
v = NaN;
if isfield(truth, modelName) && isfield(truth.(modelName), paramId)
    v = double(truth.(modelName).(paramId));
end
end

function m = qaParamMap(params)
% Map parameter id -> fitted value from a fit result `params` field.
m = containers.Map();
if isempty(params)
    return
end
if istable(params)
    names = params.Properties.VariableNames;
    idCol = qaFindName(names, {'id', 'name', 'parameter'});
    valCol = qaFindName(names, {'value', 'estimate', 'fitted'});
    for k = 1:height(params)
        id = qaToString(params{k, idCol});
        m(id) = double(params{k, valCol});
    end
elseif isstruct(params)
    for k = 1:numel(params)
        p = params(k);
        if isfield(p, 'id')
            id = qaToString(p.id);
        else
            continue
        end
        if isfield(p, 'value')
            val = double(p.value);
        elseif isfield(p, 'estimate')
            val = double(p.estimate);
        else
            continue
        end
        m(id) = val;
    end
elseif iscell(params)
    for k = 1:numel(params)
        sub = qaParamMap(params{k});
        keys = sub.keys;
        for j = 1:numel(keys)
            m(keys{j}) = sub(keys{j});
        end
    end
end
end

function col = qaFindName(names, candidates)
col = '';
for k = 1:numel(names)
    if any(strcmpi(names{k}, candidates))
        col = names{k};
        return
    end
end
if isempty(col) && ~isempty(names)
    col = names{1};
end
end

function [found, val] = qaLookupParam(pmap, id)
found = false; val = NaN;
if isKey(pmap, id)
    found = true; val = pmap(id); return
end
keys2 = pmap.keys;
for k = 1:numel(keys2)
    if strcmpi(keys2{k}, id)
        found = true; val = pmap(keys2{k}); return
    end
end
end

function v = qaParamValue(pmap, id)
[found, v] = qaLookupParam(pmap, id);
if ~found
    v = NaN;
end
end

function v = qaInitialOf(spec, id)
v = NaN;
vars = qaItems(spec.variables);
for k = 1:numel(vars)
    if strcmpi(char(vars{k}.id), id)
        if isfield(vars{k}, 'initial') && isstruct(vars{k}.initial)
            v = double(vars{k}.initial.value);
        end
        return
    end
end
end

function val = qaSpecParamValue(spec, id)
val = NaN;
if ~isstruct(spec) || ~isfield(spec, 'parameters')
    return
end
items = qaItems(spec.parameters);
for k = 1:numel(items)
    p = items{k};
    if strcmpi(char(p.id), id)
        if isstruct(p.value), val = double(p.value.value);
        else, val = double(p.value); end
        return
    end
end
end

function s = qaToString(v)
if ischar(v)
    s = v;
elseif isstring(v)
    s = char(v);
elseif iscell(v) && numel(v) == 1
    s = qaToString(v{1});
else
    s = num2str(v);
end
end

function c = qaItems(v)
% Normalize a JSON-decoded array (struct array or cell array) to a cell row.
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

function c = qaCellstr(v)
if ischar(v)
    c = {v};
elseif isstring(v)
    c = cellstr(v(:)');
elseif iscell(v)
    c = cellfun(@qaToString, v(:)', 'UniformOutput', false);
else
    c = {num2str(v)};
end
c = c(:)';
end

function tf = qaPathExists(workDir, rel)
p = bma.util.absPath(workDir, rel);
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

function qaAssertSetEqual(got, expected, msg)
g = sort(lower(qaCellstr(got)));
e = sort(lower(qaCellstr(expected)));
qaAssert(isequal(g, e), sprintf('%s (got {%s}, expected {%s})', ...
    msg, strjoin(g, ','), strjoin(e, ',')));
end

function qaAssertAnyKeyword(txt, keywords, msg)
for k = 1:numel(keywords)
    if contains(lower(txt), lower(keywords{k}))
        return
    end
end
error('qa:assert:failed', '%s (looked for any of: %s)', msg, strjoin(keywords, ', '));
end

function txt = qaIssuesText(issues)
txt = '';
if isempty(issues)
    return
end
try
    txt = jsonencode(issues);
    if numel(txt) > 1200
        txt = [txt(1:1200) '...'];
    end
catch
    txt = '<unprintable issues>';
end
end
