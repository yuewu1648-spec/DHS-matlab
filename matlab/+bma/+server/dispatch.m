function result = dispatch(method, params, req)
%DISPATCH Execute one RPC method. Called by bma.server.start.
%   result = bma.server.dispatch(method, params, req)
% The dispatcher is intentionally thin: it resolves paths, calls the owning
% module and persists its artifacts. Modules that are not installed yet fail
% with BMA_NOT_IMPLEMENTED so the server stays useful during development.
ctx = buildContext(params, req);
switch lower(char(method))
    case 'server.ping'
        result = struct('matlab_version', version, 'pid', feature('getpid'), ...
            'work_dir', ctx.workDir, 'project_root', bma.util.projectRoot(), ...
            'heartbeat', bma.util.nowIso());
        result.methods = dispatchableMethods();
        result = addVersionFields(result);
    case 'server.info'
        result = serverInfo(ctx);
    case 'server.stop'
        stopFlag = fullfile(serverDirOf(ctx), 'stop.flag');
        bma.util.writeTextAtomic(stopFlag, 'stop');
        result = struct('stopped', true);
    case 'server.cancel'
        cancelFlag = fullfile(serverDirOf(ctx), 'cancel.flag');
        bma.util.writeTextAtomic(cancelFlag, 'cancel');
        % Modules such as Sobol check the canonical control-server flag.
        try
            bma.util.writeTextAtomic(fullfile(ctx.workDir, '.bma', 'server', 'cancel.flag'), 'cancel');
        catch
        end
        result = struct('cancel_requested', true, 'flag', cancelFlag);

    case 'dev.eval'
        requireField(params, 'code');
        code = char(params.code);
        code = regexprep(code, '^\x{FEFF}', '');  % strip a UTF-8 BOM
        txt = evalc(code);
        result = struct('output', txt);

    case 'test.run'
        result = runTests(params);

    case 'run.init'
        name = '';
        if isfield(params, 'name'), name = char(params.name); end
        result = initRun(ctx.workDir, name);
    case 'run.list'
        result = listRuns(ctx.workDir);
    case 'run.info'
        requireField(params, 'run_dir');
        rd = bma.util.absPath(ctx.workDir, params.run_dir);
        info = struct('run_dir', bma.util.relPath(ctx.workDir, rd), ...
            'exists', isfolder(rd));
        runJson = fullfile(rd, 'run.json');
        if isfile(runJson)
            info.run = bma.util.readJson(runJson);
        end
        result = info;
    case 'run.import_artifact'
        ctx = ensureRun(ctx, params);
        requireField(params, 'source_path');
        iOpts = struct();
        if isfield(params, 'name'), iOpts.name = params.name; end
        if isfield(params, 'kind'), iOpts.kind = params.kind; end
        if isfield(params, 'recursive'), iOpts.recursive = params.recursive; end
        result = bma.run.importArtifact(ctx.workDir, ctx.runDirAbs, ...
            char(params.source_path), iOpts);
    case 'run.waive_gate'
        ctx = ensureRun(ctx, params);
        requireField(params, 'gate');
        requireField(params, 'reason');
        substitute = '';
        if isfield(params, 'substitute'), substitute = params.substitute; end
        evidence = struct();
        if isfield(params, 'evidence'), evidence = params.evidence; end
        result = bma.run.waiveGate(ctx.workDir, ctx.runDirAbs, params.gate, ...
            params.reason, substitute, evidence);

    case 'kb.list'
        fn = requireFn('bma.kb.list');
        tag = getStr(params, 'tag', '');
        limit = getNum(params, 'limit', 50);
        [items, total] = callTwoOutput(fn, tag, limit);
        result = struct('items', {items}, 'total', total);
    case 'kb.search'
        fn = requireFn('bma.kb.search');
        [hits, total] = callTwoOutput(fn, char(params.query), ...
            getFieldDefault(params, 'tags', {}), getNum(params, 'limit', 10));
        result = struct('hits', {hits}, 'total', total);
    case 'kb.get'
        fn = requireFn('bma.kb.get');
        requireField(params, 'id');
        result = fn(char(params.id));

    case 'literature.ingest'
        fn = requireFn('bma.io.ingest');
        requireField(params, 'path');
        ctx = ensureRun(ctx, params);
        src = resolveInputPath(ctx, params.path);
        if ~isfile(src)
            error('bma:io:fileNotFound', 'Literature file not found: %s', src);
        end
        doc = fn(src, ctx.runDirAbs);
        result = doc;
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'blind.start'
        ctx = ensureRun(ctx, params);
        requireField(params, 'primary_path');
        src = resolveInputPath(ctx, params.primary_path);
        if ~isfile(src)
            error('bma:blind:primary_not_found', 'Primary literature file not found: %s', src);
        end
        opts = struct();
        optNames = {'abstract_path', 'references_dir', 'title', ...
            'min_rounds', 'budget_seconds', 'max_references', 'max_bytes', ...
            'from_primary', 'force'};
        for k = 1:numel(optNames)
            if isfield(params, optNames{k}) && ~isempty(params.(optNames{k}))
                opts.(optNames{k}) = params.(optNames{k});
            end
        end
        if isfield(params, 'references_json') && ~isempty(params.references_json)
            opts.references_json = params.references_json;
        end
        result = bma.blind.start(ctx.workDir, ctx.runDirAbs, src, opts);
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'blind.note'
        requireRunDirParam(params);
        ctx = ensureRun(ctx, params);
        requireField(params, 'reference_id');
        requireField(params, 'note');
        result = bma.blind.note(ctx.workDir, ctx.runDirAbs, ...
            char(params.reference_id), params.note, struct());
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'blind.check'
        requireRunDirParam(params);
        ctx = ensureRun(ctx, params);
        result = bma.blind.check(ctx.workDir, ctx.runDirAbs, params);
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'blind.reveal'
        requireRunDirParam(params);
        ctx = ensureRun(ctx, params);
        result = bma.blind.reveal(ctx.workDir, ctx.runDirAbs, params);
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'spec.validate'
        fn = requireFn('bma.spec.validate');
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        report = fn(spec, ctx.workDir);
        if isfield(report, 'normalized_spec') && ~isempty(report.normalized_spec)
            specDir = fullfile(ctx.runDirAbs, 'models', char(report.normalized_spec.name));
            bma.util.ensureDir(specDir);
            bma.util.writeJsonAtomic(fullfile(specDir, 'spec.json'), report.normalized_spec);
            report.spec_path = bma.util.relPath(ctx.workDir, fullfile(specDir, 'spec.json'));
        end
        report.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);
        result = report;

    case 'model.build'
        fnBuild = requireFn('bma.model.build');
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = fnBuild(spec);
        specDir = fullfile(ctx.runDirAbs, 'models', char(spec.name));
        bma.util.ensureDir(specDir);
        bma.util.writeJsonAtomic(fullfile(specDir, 'spec.json'), spec);
        result = struct('model_dir', bma.util.relPath(ctx.workDir, specDir), ...
            'species', {m.species}, 'parameters', {m.params}, ...
            'n_reactions', numel(m.reactions), ...
            'network', struct('stoichiometry', m.S), ...
            'rhs_function_path', '', 'rhs_path', '');
        if ~isempty(which('bma.codegen.model'))
            cg = bma.codegen.model(spec, ctx.runDirAbs);
            result.rhs_function_path = cg.m_file;
            result.rhs_path = cg.m_file;
            if isfield(cg, 'function_name')
                result.function_name = cg.function_name;
            end
        end

    case 'model.analyze'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        aOpts = getFieldDefault(params, 'options', struct());
        a = callModule('bma.model.analyze', m, aOpts);
        specDir = fullfile(ctx.runDirAbs, 'models', char(spec.name));
        bma.util.ensureDir(specDir);
        bma.util.writeJsonAtomic(fullfile(specDir, 'analysis.json'), a);
        result = a;
        result.analysis_path = bma.util.relPath(ctx.workDir, fullfile(specDir, 'analysis.json'));
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'pde.simulate'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        opts = getFieldDefault(params, 'options', struct());
        opts.run_dir = ctx.runDirAbs;
        opts.work_dir = ctx.workDir;
        result = callModule('bma.pde.simulate', spec, opts);
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'advanced.solve'
        ctx = ensureRun(ctx, params);
        requireField(params, 'method');
        method = char(params.method);
        problem = getFieldDefault(params, 'problem', struct());
        opts = getFieldDefault(params, 'options', struct());
        opts.run_dir = ctx.runDirAbs;
        opts.work_dir = ctx.workDir;
        result = callModule('bma.advanced.solve', method, problem, opts);
        result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);

    case 'model.simulate'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        % Native PDE Toolbox path (0.8.0): 2D/irregular geometry; not MOL.
        if isfield(spec, 'kind') && strcmpi(char(spec.kind), 'pde') ...
                && isfield(spec, 'pde') && isstruct(spec.pde) ...
                && isfield(spec.pde, 'dim') && double(spec.pde.dim) >= 2
            opts = getFieldDefault(params, 'options', struct());
            opts.run_dir = ctx.runDirAbs;
            opts.work_dir = ctx.workDir;
            result = callModule('bma.pde.simulate', spec, opts);
            result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);
        else
            m = callModule('bma.model.build', spec);
            opts = getFieldDefault(params, 'options', struct());
            % Always carry output series locally so the CSV and summary include
            % observables, not only states (ISS-06). Series are stripped before the
            % RPC result so responses stay small.
            if ~isfield(opts, 'include_series') || isempty(opts.include_series)
                opts.include_series = true;
            end
            res = callModule('bma.model.simulate', m, opts);
            result = summarizeSimulation(res, ctx, spec, params);
            if isfield(res, 'outputSeries')
                res = rmfield(res, 'outputSeries');
            end
            % Canonical plot selection: time series always available; a
            % two-output/two-state model also gets a phase portrait, where the
            % last closed cycle is highlighted (limit-cycle canonical form).
            plotKinds = {'timeseries'};
            if isfield(opts, 'plots') && ~isempty(opts.plots)
                rawPlots = opts.plots;
                if ischar(rawPlots) || isstring(rawPlots)
                    plotKinds = cellstr(rawPlots);
                elseif iscell(rawPlots)
                    plotKinds = rawPlots;
                end
                plotKinds = plotKinds(cellfun(@(x) ischar(x) || isstring(x), plotKinds));
                plotKinds = cellfun(@(x) lower(char(x)), plotKinds, 'UniformOutput', false);
            elseif numel(m.species) == 2 && numel(m.outputs) >= 2
                plotKinds = {'timeseries', 'phase'};
            end
            figures = {};
            if any(strcmp(plotKinds, 'timeseries')) && ~isempty(which('bma.plot.timeseries'))
                try
                    figOpts = struct('outDir', fullfile(ctx.runDirAbs, 'figures'), ...
                        'name', ['timeseries_' result.sim_id '.png']);
                    if isfield(opts, 'outputs'), figOpts.outputs = opts.outputs; end
                    if isfield(opts, 'figure_name'), figOpts.name = opts.figure_name; end
                    figures{end+1} = bma.plot.timeseries(m, res, figOpts); %#ok<AGROW>
                catch err
                    result.figure_warning = err.message;
                end
            end
            if any(strcmp(plotKinds, 'phase')) && ~isempty(which('bma.plot.phase'))
                try
                    figOpts = struct('outDir', fullfile(ctx.runDirAbs, 'figures'), ...
                        'name', ['phase_' result.sim_id '.png'], 'limit_cycle', true);
                    if isfield(opts, 'phase_x'), figOpts.x = opts.phase_x; end
                    if isfield(opts, 'phase_y'), figOpts.y = opts.phase_y; end
                    figures{end+1} = bma.plot.phase(m, res, figOpts); %#ok<AGROW>
                catch err
                    if isfield(result, 'figure_warning')
                        result.figure_warning = [result.figure_warning ' | ' err.message];
                    else
                        result.figure_warning = err.message;
                    end
                end
            end
            if any(strcmp(plotKinds, 'phase3d')) && ~isempty(which('bma.plot.phase3d'))
                try
                    figOpts = struct('outDir', fullfile(ctx.runDirAbs, 'figures'), ...
                        'name', ['phase3d_' result.sim_id '.png']);
                    if isfield(opts, 'phase_x'), figOpts.x = opts.phase_x; end
                    if isfield(opts, 'phase_y'), figOpts.y = opts.phase_y; end
                    if isfield(opts, 'phase_z'), figOpts.z = opts.phase_z; end
                    figures{end+1} = bma.plot.phase3d(m, res, figOpts); %#ok<AGROW>
                catch err
                    if isfield(result, 'figure_warning')
                        result.figure_warning = [result.figure_warning ' | ' err.message];
                    else
                        result.figure_warning = err.message;
                    end
                end
            end
            if ~isempty(figures)
                result.figures = figures;
            end
        end

    case 'model.simulate_cases'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        cases = getFieldDefault(params, 'cases', {});
        if isstruct(cases) && ~iscell(cases)
            cases = num2cell(cases);
        end
        out = simulateCases(m, spec, cases, ctx);
        result = out;

    case 'fit.estimate'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        data = loadDataset(params, ctx);
        opts = getFieldDefault(params, 'options', struct());
        opts.run_dir = ctx.runDirAbs;
        opts.work_dir = ctx.workDir;
        fr = callModule('bma.fit.estimate', m, data, opts);
        result = persistFit(fr, ctx, spec);

    case 'fit.profile'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        data = loadDataset(params, ctx);
        fr = [];
        if isfield(params, 'fit_result_path') && ~isempty(params.fit_result_path)
            fr = callModule('bma.fit.load', resolveInputPath(ctx, params.fit_result_path));
        else
            fr = callModule('bma.fit.estimate', m, data, struct());
        end
        requireField(params, 'param');
        profOpts = getFieldDefault(params, 'options', struct());
        profOpts.run_dir = ctx.runDirAbs;
        profOpts.work_dir = ctx.workDir;
        prof = callModule('bma.fit.profile', m, data, fr, char(params.param), profOpts);
        result = persistProfile(prof, ctx, params);

    case 'fit.sensitivity'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        opts = getFieldDefault(params, 'options', struct());
        if isfield(params, 'params'), opts.params = params.params; end
        if isfield(params, 'outputs'), opts.outputs = params.outputs; end
        if isfield(params, 'method'), opts.method = params.method; end
        opts.run_dir = ctx.runDirAbs;
        result = callModule('bma.fit.sensitivity', m, opts);

    case 'fit.identifiability'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        data = struct();
        if isfield(params, 'data_csv') && ~isempty(params.data_csv)
            data = loadDataset(params, ctx);
        end
        opts = getFieldDefault(params, 'options', struct());
        opts.run_dir = ctx.runDirAbs;
        opts.work_dir = ctx.workDir;
        result = callModule('bma.fit.identifiability', m, data, opts);
        result.profile_requested = false;
        if isfield(opts, 'param') && ~isempty(opts.param)
            result.profile_requested = true;
            if isempty(data) || ~isstruct(data) || isempty(fieldnames(data))
                result.profile_reason = '请求了剖面似然，但未提供 data_csv（无法重拟合）。';
            else
                try
                    profOpts = opts;
                    profOpts.run_dir = ctx.runDirAbs;
                    prof = callModule('bma.fit.profile', m, data, [], char(opts.param), profOpts);
                    result.profile = persistProfile(prof, ctx, params);
                    result.profile.param = char(opts.param);
                catch err
                    result.profile_reason = sprintf('剖面似然执行失败：%s', err.message);
                end
            end
        end
    case 'validate.model_selection'
        ctx = ensureRun(ctx, params);
        candidates = getFieldDefault(params, 'candidates', {});
        if isstruct(candidates) && ~iscell(candidates)
            candidates = num2cell(candidates);
        end
        prepared = {};
        for k = 1:numel(candidates)
            c = candidates{k};
            item = struct('name', sprintf('candidate_%d', k), ...
                'options', getFieldDefault(c, 'options', struct()));
            if isfield(c, 'name'), item.name = char(c.name); end
            if isfield(c, 'spec')
                specK = c.spec;
            elseif isfield(c, 'spec_path')
                specK = bma.util.readJson(resolveInputPath(ctx, c.spec_path));
            else
                error('bma:server:badCandidate', ...
                    'Candidate %d needs spec or spec_path.', k);
            end
            item.model = callModule('bma.model.build', specK);
            cParams = params;
            if isfield(c, 'data_csv'), cParams.data_csv = c.data_csv; end
            if isfield(c, 'output_map'), cParams.output_map = c.output_map; end
            if isfield(cParams, 'data_csv') && ~isempty(cParams.data_csv)
                item.data = loadDataset(cParams, ctx);
            else
                item.data = struct();
            end
            prepared{end+1} = item; %#ok<AGROW>
        end
        msOpts = getFieldDefault(params, 'options', struct());
        msOpts.run_dir = ctx.runDirAbs;
        result = callModule('bma.validate.modelSelection', prepared, msOpts);
    case 'validate.cross_validation'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        m = callModule('bma.model.build', spec);
        data = loadDataset(params, ctx);
        k = getNum(params, 'k', 5);
        result = callModule('bma.validate.crossValidation', m, data, ...
            struct('k', k, 'options', getFieldDefault(params, 'options', struct())));
    case 'validate.residuals'
        ctx = ensureRun(ctx, params);
        requireField(params, 'fit_result_path');
        fr = callModule('bma.fit.load', resolveInputPath(ctx, params.fit_result_path));
        result = callModule('bma.validate.residuals', fr);

    case 'report.build'
        ctx = ensureRun(ctx, params);
        result = buildReport(params, ctx);
    case 'codegen.model'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        result = callModule('bma.codegen.model', spec, ctx.runDirAbs);
    case 'simbiology.export'
        spec = resolveSpec(params, ctx);
        ctx = ensureRun(ctx, params);
        if ~isempty(which('bma.simbiology.export'))
            result = bma.simbiology.export(spec, ctx.runDirAbs);
        else
            result = struct('ok', false, 'warnings', ...
                {{'SimBiology export module is not installed.'}});
        end

    otherwise
        error('bma:server:unknownMethod', 'Unknown RPC method: %s', char(method));
end
end

% ---------------------------------------------------------------------------
function ctx = buildContext(params, req)
ctx = struct();
if isfield(req, 'work_dir') && ~isempty(req.work_dir)
    ctx.workDir = char(req.work_dir);
else
    ctx.workDir = pwd;
end
if ~isfolder(ctx.workDir)
    if isfield(params, 'work_dir') && ~isempty(params.work_dir)
        ctx.workDir = char(params.work_dir);
    end
end
try
    ctx.workDir = normalizeDir(ctx.workDir);
catch
    ctx.workDir = pwd;
end
ctx.runDirAbs = '';
ctx.serverSubdir = 'server';
if isfield(req, 'server_subdir') && ~isempty(req.server_subdir)
    ctx.serverSubdir = regexprep(char(req.server_subdir), '/', filesep);
end
if isfield(params, 'run_dir') && ~isempty(params.run_dir)
    ctx.runDirAbs = bma.util.absPath(ctx.workDir, params.run_dir);
end
end

function d = normalizeDir(d)
old = pwd;
cd(d);
d = pwd;
cd(old);
end

function ctx = ensureRun(ctx, params)
if isfield(params, 'run_dir') && ~isempty(params.run_dir)
    ctx.runDirAbs = bma.util.absPath(ctx.workDir, params.run_dir);
    assertInsideWorkspace(ctx.workDir, ctx.runDirAbs);
    bma.util.ensureDir(ctx.runDirAbs);
    ensureRunLayout(ctx.runDirAbs);
    return
end
r = initRun(ctx.workDir, '');
ctx.runDirAbs = bma.util.absPath(ctx.workDir, r.run_dir);
end

function ensureRunLayout(runDir)
dirs = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs', 'artifacts'};
for k = 1:numel(dirs)
    bma.util.ensureDir(fullfile(runDir, dirs{k}));
end
if ~isfile(fullfile(runDir, 'run.json'))
    meta = struct('schema', 'bma.run.v1', 'run_id', ...
        char(regexprep(runDir, '^.*[\\/]', '')), ...
        'created_at', bma.util.nowIso(), 'work_dir', ...
        fileparts(fileparts(runDir)));
    meta = addVersionFields(meta);
    bma.util.writeJsonAtomic(fullfile(runDir, 'run.json'), meta);
end
end

function result = initRun(workDir, name)
if isempty(name)
    name = bma.util.newId('r');
end
runId = char(name);
runDir = fullfile(workDir, '.bma', 'runs', runId);
assertInsideWorkspace(workDir, runDir);
bma.util.ensureDir(runDir);
ensureRunLayout(runDir);
metaFile = fullfile(runDir, 'run.json');
if isfile(metaFile)
    meta = bma.util.readJson(metaFile);
else
    meta = struct('schema', 'bma.run.v1', 'run_id', runId, ...
        'created_at', bma.util.nowIso(), 'work_dir', workDir);
    meta = addVersionFields(meta);
    bma.util.writeJsonAtomic(metaFile, meta);
end
result = struct('run_id', runId, 'run_dir', bma.util.relPath(workDir, runDir), ...
    'created', true, 'meta', meta);
end

function result = listRuns(workDir)
runsDir = fullfile(workDir, '.bma', 'runs');
result = struct('runs', {{}}, 'total', 0);
if ~isfolder(runsDir)
    return
end
d = dir(runsDir);
d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
items = {};
for k = 1:numel(d)
    rd = fullfile(runsDir, d(k).name);
    item = struct('run_id', d(k).name, ...
        'run_dir', bma.util.relPath(workDir, rd));
    metaFile = fullfile(rd, 'run.json');
    if isfile(metaFile)
        try
            meta = bma.util.readJson(metaFile);
            if isfield(meta, 'created_at')
                item.created_at = meta.created_at;
            end
        catch
        end
    end
    items{end+1} = item; %#ok<AGROW>
end
result = struct('runs', {items}, 'total', numel(items));
end

function result = runTests(params)
runner = which('run_all_tests');
if isempty(runner)
    ml = fullfile(bma.util.projectRoot(), 'matlab');
    runner = fullfile(ml, 'tests', 'run_all_tests.m');
    if ~isfile(runner)
        error('bma:server:tests', 'run_all_tests.m not found.');
    end
    addpath(fileparts(runner));
end
filter = getStr(params, 'filter', '');
txt = evalc('passed = run_all_tests(''Filter'', filter);');
result = struct('passed', passed, 'filter', filter, 'log', txt);
end

function specPath = resolveInputPath(ctx, maybeRel)
%RESOLVEINPUTPATH Resolve a user-supplied path against workDir, then project root.
p = bma.util.absPath(ctx.workDir, maybeRel);
if ~isfile(p) && ischar(maybeRel) && isempty(regexp(maybeRel, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    alt = fullfile(bma.util.projectRoot(), strrep(maybeRel, '/', filesep));
    if isfile(alt)
        p = alt;
    end
end
specPath = p;
end

function spec = resolveSpec(params, ctx)
if isfield(params, 'spec') && ~isempty(params.spec)
    spec = params.spec;
    if iscell(spec) && numel(spec) == 1
        spec = spec{1};
    end
elseif isfield(params, 'spec_path') && ~isempty(params.spec_path)
    spec = bma.util.readJson(resolveInputPath(ctx, params.spec_path));
else
    error('bma:server:missingSpec', ...
        'Either "spec" (object) or "spec_path" is required.');
end
if isfield(spec, 'schema_version') && strcmp(spec.schema_version, 'bma.modelSpec.v1')
    % ok
end
end

function data = loadDataset(params, ctx)
requireField(params, 'data_csv');
csvPath = resolveInputPath(ctx, params.data_csv);
if ~isfile(csvPath)
    error('bma:server:dataNotFound', 'Data CSV not found: %s', csvPath);
end
T = readtable(csvPath, 'VariableNamingRule', 'preserve');
data = struct();
data.path = csvPath;
data.table = T;
data.time = T{:, 1};
data.time_unit = '';
data.output_map = getFieldDefault(params, 'output_map', struct());
if ischar(data.output_map) || isstring(data.output_map)
    data.output_map = jsondecode(char(data.output_map));
end
end

function result = summarizeSimulation(res, ctx, spec, params)
result = struct();
result.sim_id = bma.util.newId('sim');
if isfield(res, 'species') && ~isempty(res.species)
    result.species = cellstr(res.species);
else
    result.species = {spec.variables.id};
end
result.algebraic = {};
try
    for vk = 1:numel(spec.variables)
        if isfield(spec.variables(vk), 'algebraic') && logical(spec.variables(vk).algebraic)
            result.algebraic{end+1} = spec.variables(vk).id; %#ok<AGROW>
        end
    end
catch
end
if isfield(res, 't')
    result.time = struct('t0', res.t(1), 't1', res.t(end), 'n', numel(res.t));
end
if isfield(res, 'Y')
    if isfield(res, 'species') && ~isempty(res.species)
        names = cellstr(res.species);
    else
        names = {spec.variables.id};
    end
    nShow = min(12, numel(names));
    finals = struct();
    mins = struct();
    maxs = struct();
    for k = 1:nShow
        finals.(names{k}) = res.Y(end, k);
        mins.(names{k}) = min(res.Y(:, k));
        maxs.(names{k}) = max(res.Y(:, k));
    end
    result.final = finals;
    result.min = mins;
    result.max = maxs;
end
if isfield(res, 'outputs')
    result.outputs = res.outputs;
    outFinal = struct();
    for oi = 1:numel(res.outputs)
        try
            outFinal.(res.outputs(oi).id) = res.outputs(oi).final;
        catch
        end
    end
    result.outputs_final = outFinal;
end
% persist full time series: states + outputs (ISS-06)
simDir = fullfile(ctx.runDirAbs, 'data', result.sim_id);
bma.util.ensureDir(simDir);
if isfield(res, 't') && isfield(res, 'Y')
    if isfield(res, 'species') && ~isempty(res.species)
        stateIds = cellstr(res.species);
    else
        stateIds = {spec.variables.id};
    end
    header = ['time', stateIds];
    M = [res.t(:), res.Y];
    if isfield(res, 'outputSeries')
        os = res.outputSeries;
        for oi = 1:numel(os)
            if iscell(os)
                item = os{oi};
            else
                item = os(oi);
            end
            oid = char(item.id);
            if any(strcmp(header, oid))
                continue
            end
            yv = item.y(:);
            if numel(yv) == numel(res.t)
                header{end+1} = oid; %#ok<AGROW>
                M(:, end+1) = yv; %#ok<AGROW>
            end
        end
        result.series_columns = header(2:end);
    end
    csvPath = fullfile(simDir, 'timeseries.csv');
    writeCsv(csvPath, header, M);
    result.timeseries_path = bma.util.relPath(ctx.workDir, csvPath);
end
if isfield(res, 'warnings') && ~isempty(res.warnings)
    result.warnings = res.warnings;
end
end

function result = simulateCases(m, spec, cases, ctx)
result = struct('cases', {{}}, 'comparison_figure', '', ...
    'sim_id', bma.util.newId('cases'));
figs = {};
summaries = {};
resList = {};
nameList = {};
for k = 1:numel(cases)
    c = cases{k};
    opts = struct();
    if isfield(c, 'initial_overrides'), opts.initial_overrides = c.initial_overrides; end
    if isfield(c, 'param_overrides'), opts.param_overrides = c.param_overrides; end
    if isfield(c, 'time_overrides')
        to = c.time_overrides;
        if isfield(to, 'end'), opts.time_end = to.end; end
        if isfield(to, 'n'), opts.n = to.n; end
    end
    if isfield(c, 'name')
        opts.scenario_name = c.name;
    end
    res = callModule('bma.model.simulate', m, opts);
    if isfield(res, 'outputSeries')
        res = rmfield(res, 'outputSeries');
    end
    s = summarizeSimulation(res, ctx, spec, struct());
    if isfield(c, 'name')
        s.name = c.name;
    else
        s.name = sprintf('case_%d', k);
    end
    summaries{end+1} = s; %#ok<AGROW>
    resList{end+1} = res; %#ok<AGROW>
    nameList{end+1} = s.name; %#ok<AGROW>
end
result.cases = summaries;
result.cases_path = '';
result.n_cases = numel(summaries);
result.cases_summary_path = '';
try
    casesJson = struct('schema', 'bma.simulateCases.v1', 'cases', {summaries});
    cp = fullfile(ctx.runDirAbs, 'data', [result.sim_id '_cases.json']);
    bma.util.writeJsonAtomic(cp, casesJson);
    result.cases_path = bma.util.relPath(ctx.workDir, cp);
catch
end
% ISSUE-009: keep a full summary CSV for >12 scenarios, so callers never
% mistake display truncation for missing results.
try
    sp = cellstr(m.species);
    csvPath = fullfile(ctx.runDirAbs, 'data', [result.sim_id '_cases_summary.csv']);
    fid = fopen(csvPath, 'w');
    if fid >= 0
        cleaner = onCleanup(@() fclose(fid));
        fprintf(fid, 'case,success');
        for q = 1:numel(sp)
            fprintf(fid, ',%s_initial,%s_final,%s_min,%s_max', sp{q}, sp{q}, sp{q}, sp{q});
        end
        fprintf(fid, '\n');
        for k = 1:numel(summaries)
            s = summaries{k};
            resK = resList{k};
            fprintf(fid, '%s,%d', s.name, double(isfield(resK, 'success') && resK.success));
            for q = 1:numel(sp)
                if isfield(resK, 'Y') && size(resK.Y, 2) >= q
                    v0 = resK.Y(1, q); vf = resK.Y(end, q);
                    vmin = min(resK.Y(:, q)); vmax = max(resK.Y(:, q));
                else
                    v0 = NaN; vf = NaN; vmin = NaN; vmax = NaN;
                end
                fprintf(fid, ',%.12g,%.12g,%.12g,%.12g', v0, vf, vmin, vmax);
            end
            fprintf(fid, '\n');
        end
        result.cases_summary_path = bma.util.relPath(ctx.workDir, csvPath);
    end
catch
end
if ~isempty(which('bma.plot.cases'))
    try
        figs = bma.plot.cases(resList, nameList, m, ...
            struct('outDir', fullfile(ctx.runDirAbs, 'figures'), ...
            'name', ['cases_' result.sim_id '.png']));
        result.comparison_figure = figs;
    catch err
        result.comparison_figure_warning = err.message;
    end
end
end

function result = persistFit(fr, ctx, spec)
fitId = bma.util.newId('fit');
fitDir = fullfile(ctx.runDirAbs, 'fits', fitId);
bma.util.ensureDir(fitDir);
bma.util.writeJsonAtomic(fullfile(fitDir, 'fit.json'), stripHandles(fr));
if isfield(fr, 'params')
    writeParamsTable(fullfile(fitDir, 'params.csv'), fr.params);
end
if isfield(fr, 'fittedSpec') && ~isempty(fr.fittedSpec)
    bma.util.writeJsonAtomic(fullfile(fitDir, 'fitted_spec.json'), fr.fittedSpec);
end
result = struct('fit_id', fitId, ...
    'fit_dir', bma.util.relPath(ctx.workDir, fitDir), ...
    'fit_result_path', bma.util.relPath(ctx.workDir, fullfile(fitDir, 'fit.json')));
fields = {'params', 'metrics', 'warnings', 'n_observations', 'n_parameters', ...
    'aicc', 'bic', 'r2', 'rmse', 'solver_info', 'identifiability'};
for k = 1:numel(fields)
    if isfield(fr, fields{k})
        result.(fields{k}) = fr.(fields{k});
    end
end
if isfield(fr, 'fittedSpec') && ~isempty(fr.fittedSpec)
    result.fitted_spec_path = bma.util.relPath(ctx.workDir, ...
        fullfile(fitDir, 'fitted_spec.json'));
end
if ~isempty(which('bma.plot.fit'))
    try
        % ISSUE-010: fit figures belong to the unique fit dir, never shared
        % run/figures/fit.png (two fits would overwrite each other).
        fitFigDir = fullfile(fitDir, 'figures');
        result.figures = bma.plot.fit(fr, struct(), ...
            struct('outDir', fitFigDir, 'name', 'fit.png', 'work_dir', ctx.workDir));
    catch err
        result.figure_warning = err.message;
    end
end
end

function result = persistProfile(prof, ctx, params)
fitDir = fullfile(ctx.runDirAbs, 'fits', bma.util.newId('profile'));
bma.util.ensureDir(fitDir);
bma.util.writeJsonAtomic(fullfile(fitDir, 'profile.json'), stripHandles(prof));
result = prof;
result.profile_dir = bma.util.relPath(ctx.workDir, fitDir);
result.profile_path = bma.util.relPath(ctx.workDir, fullfile(fitDir, 'profile.json'));
end

function result = buildReport(params, ctx)
requireField(params, 'title');
spec = [];
if isfield(params, 'spec') && ~isempty(params.spec)
    spec = params.spec;
elseif isfield(params, 'spec_path') && ~isempty(params.spec_path)
    spec = bma.util.readJson(resolveInputPath(ctx, params.spec_path));
else
    error('bma:server:missingSpec', 'report.build requires spec or spec_path.');
end
fr = [];
if isfield(params, 'fit_result_path') && ~isempty(params.fit_result_path)
    fr = bma.util.readJson(resolveInputPath(ctx, params.fit_result_path));
end
analysis = [];
if isfield(params, 'analysis_path') && ~isempty(params.analysis_path)
    analysis = bma.util.readJson(resolveInputPath(ctx, params.analysis_path));
end
references = getFieldDefault(params, 'references', {});
extra = getFieldDefault(params, 'extra_sections', {});
if isstruct(references) && ~iscell(references)
    references = num2cell(references);
end
if isstruct(extra) && ~iscell(extra)
    extra = num2cell(extra);
end
result = callModule('bma.report.build', ctx.runDirAbs, spec, fr, analysis, ...
    struct('title', char(params.title), 'references', {references}, ...
    'extra_sections', {extra}));
result.run_dir = bma.util.relPath(ctx.workDir, ctx.runDirAbs);
end

function v = stripHandles(v)
%STRIPHANDLES Remove function handles/handles so the value can be JSON encoded.
if isstruct(v)
    if isscalar(v)
        names = fieldnames(v);
        for k = 1:numel(names)
            try
                v.(names{k}) = stripHandles(v.(names{k}));
            catch
                % Keep the original value when a field cannot be converted.
            end
        end
    else
        for k = 1:numel(v)
            v(k) = stripHandles(v(k));
        end
    end
elseif iscell(v)
    for k = 1:numel(v)
        v{k} = stripHandles(v{k}); %#ok<AGROW>
    end
elseif isa(v, 'function_handle')
    v = func2str(v);
elseif isa(v, 'table')
    v = jsonSafe(table2struct(v));
elseif isa(v, 'datetime') || isa(v, 'duration')
    v = char(v);
elseif isa(v, 'string')
    v = cellstr(v);
end
end

function fn = requireFn(name)
%REQUIRN Resolve a package function; exist(...,'file') is unreliable for
% package functions inside a running session, which() is not.
if isempty(which(name))
    error('bma:server:notImplemented', ...
        'MATLAB module not implemented yet: %s', name);
end
fn = str2func(name);
end

function requireField(params, field)
if ~isfield(params, field) || isempty(params.(field))
    error('bma:server:missingParam', 'Missing required parameter: %s', field);
end
end

function requireRunDirParam(params)
% Blind-protocol tools must never silently create a fresh run: a typo would
% start an empty protocol and lose the sealed inventory.
if ~isfield(params, 'run_dir') || isempty(params.run_dir)
    error('bma:blind:run_required', ...
        '盲建模工具必须显式给 run_dir（用 bma_blind_start 返回的 run_dir）；不会自动新建 run。');
end
end

function v = getFieldDefault(params, field, fallback)
if isfield(params, field) && ~isempty(params.(field))
    v = params.(field);
else
    v = fallback;
end
end

function v = getStr(params, field, fallback)
if isfield(params, field) && ~isempty(params.(field))
    v = char(params.(field));
else
    v = fallback;
end
end

function v = getNum(params, field, fallback)
if isfield(params, field) && ~isempty(params.(field))
    v = double(params.(field));
else
    v = fallback;
end
end

function writeCsv(path, header, M)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:server:csv', 'Cannot write %s', path);
end
c = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', strjoin(header, ','));
fmt = [strjoin(repmat({'%.10g'}, 1, size(M, 2)), ','), '\n'];
fprintf(fid, fmt, M');
end

function writeParamsTable(path, params)
fid = fopen(path, 'w', 'n', 'UTF-8');
if fid < 0
    return
end
c = onCleanup(@() fclose(fid));
fprintf(fid, 'id,value,se,ci_low,ci_high,fixed\n');
P = params;
if isstruct(P)
    P = num2cell(P);
end
for k = 1:numel(P)
    p = P{k};
    if isstruct(p)
        fprintf(fid, '%s,%g,%g,%g,%g,%d\n', char(p.id), ...
            getf(p, 'value', NaN), getf(p, 'se', NaN), ...
            getf(p, 'ci_low', NaN), getf(p, 'ci_high', NaN), ...
            getf(p, 'fixed', 0));
    end
end
end

function v = getf(s, f, d)
if isfield(s, f) && ~isempty(s.(f))
    v = double(s.(f));
else
    v = d;
end
end

function d = serverDirOf(ctx)
d = fullfile(ctx.workDir, '.bma', ctx.serverSubdir);
end

function result = serverInfo(ctx)
result = struct();
result.matlab_version = version;
result.pid = feature('getpid');
result.work_dir = ctx.workDir;
result.project_root = bma.util.projectRoot();
result.server_subdir = ctx.serverSubdir;
result.os = computer;
feats = {'SimBiology', 'Symbolic_Toolbox', 'Optimization_Toolbox', ...
    'Statistics_Toolbox', 'Text_Analytics_Toolbox', 'GADS_Toolbox', ...
    'Identification_Toolbox', 'PDE_Toolbox', 'MATLAB_Report_Gen', ...
    'Curve_Fitting_Toolbox'};
lic = struct();
for k = 1:numel(feats)
    try
        lic.(feats{k}) = license('test', feats{k}) == 1;
    catch
        lic.(feats{k}) = false;
    end
end
result.licensed = lic;
try
    stateFile = fullfile(serverDirOf(ctx), 'state.json');
    if isfile(stateFile)
        st = bma.util.readJson(stateFile);
        fields = {'started_at', 'heartbeat', 'busy', 'busy_since', ...
            'current_call', 'queue_depth', 'last_call', 'last_call_at', ...
            'last_method', 'last_elapsed_ms', 'last_timeout', 'last_error'};
        for k = 1:numel(fields)
            if isfield(st, fields{k})
                result.(fields{k}) = st.(fields{k});
            end
        end
    end
catch
end
result = addVersionFields(result);
end

% ---------------------------------------------------------------------------
function varargout = callModule(name, varargin)
%CALLMODULE Call a package function by name after checking it exists.
if isempty(which(name))
    error('bma:server:notImplemented', ...
        'MATLAB module not implemented yet: %s', name);
end
fh = str2func(name);
[varargout{1:nargout}] = fh(varargin{:});
end
% ---------------------------------------------------------------------------
function m = dispatchableMethods()
m = {'server.ping', 'server.info', 'server.stop', 'server.cancel', 'dev.eval', 'test.run', ...
    'run.init', 'run.list', 'run.info', 'run.import_artifact', 'run.waive_gate', ...
    'kb.list', 'kb.search', 'kb.get', ...
    'literature.ingest', 'blind.start', 'blind.note', 'blind.check', 'blind.reveal', ...
    'spec.validate', 'model.build', 'model.analyze', ...
    'model.simulate', 'pde.simulate', 'advanced.solve', 'model.simulate_cases', 'fit.estimate', 'fit.profile', ...
    'fit.sensitivity', 'fit.identifiability', 'validate.model_selection', ...
    'validate.cross_validation', 'validate.residuals', 'report.build', ...
    'codegen.model', 'simbiology.export'};
end
% ---------------------------------------------------------------------------
function [items, total] = callTwoOutput(fn, varargin)
%CALLTWOOUTPUT Call a function whose optional second output is the total count.
try
    [items, total] = fn(varargin{:});
catch err
    if contains(err.message, '输入参数太多') || contains(err.message, '输出参数太多') || ...
            contains(err.message, 'Too many output arguments') || ...
            contains(err.message, 'Too many input arguments')
        items = fn(varargin{:});
        total = numel(items);
    else
        rethrow(err);
    end
end
end

% ---------------------------------------------------------------------------
function s = addVersionFields(s)
%ADDVERSIONFIELDS Stamp agent/bundle/schema/MATLAB versions for reproducibility.
try
    if ~isempty(which('bma.version'))
        v = bma.version();
        s.agent_version = v.agent_version;
        s.bundle_version = v.bundle_version;
        s.spec_schema = v.spec_schema;
        s.matlab_version = v.matlab_version;
    else
        s.agent_version = '0.0.0-dev';
        s.spec_schema = 'bma.modelSpec.v1';
        s.matlab_version = builtin('version');
    end
catch
    s.agent_version = '0.0.0-dev';
end
end


% ---------------------------------------------------------------------------
function assertInsideWorkspace(workDir, target)
%ASSERTINSIDEWORKSPACE Reject artifact paths outside the session workspace.
%   Runtime outputs (runs, figures, reports) must stay inside <work_dir>/.bma
%   so one workspace can never modify another workspace or the agent install.
w = canonicalPath(workDir);
x = canonicalPath(target);
sep = filesep;
inside = strcmpi(x, w) || strncmpi(x, [w sep], numel(w) + 1);
if ~inside
    error('bma:workspace_escape', ...
        ['BMA_WORKSPACE_ESCAPE: artifact path must stay inside the session ' ...
         'workspace. work_dir=%s target=%s'], w, x);
end
end

function p = canonicalPath(p)
try
    p = char(java.io.File(p).getCanonicalPath());
catch
    p = char(p);
end
end
