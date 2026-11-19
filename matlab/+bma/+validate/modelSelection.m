function r = modelSelection(candidates, opts)
%MODELSELECTION 多模型 AICc 比较与权重（Akaike weights）。
%   r = bma.validate.modelSelection(candidates, opts)
%
% candidates：struct array 或 cell，每个候选：
%   {name, spec_path, data_csv, output_map}        —— 现场拟合
%   或 {name, aicc, k, bic?, r2?, rmse?, n?}       —— 直接给已有指标
%   或 {name, spec(struct), data(struct/CSV)}      —— 内存对象
% opts：work_dir / run_dir / run_dir_abs / table_path / options（拟合选项）
%
% 返回 r.table（按 AICc 升序的 struct array：name,k,aicc,bic,r2,rmse,loglik,n,
% delta_aicc,aicc_weight,best）、r.best、r.table_path、r.warnings。

if nargin < 1 || isempty(candidates)
    error('bma:validate:noCandidates', 'modelSelection 需要 candidates 列表。');
end
if nargin < 2 || isempty(opts)
    opts = struct();
end
opts = mergeNestedOptions(opts);
workDir = '';
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
    workDir = char(opts.work_dir);
elseif isfield(opts, 'workDir') && ~isempty(opts.workDir)
    workDir = char(opts.workDir);
else
    workDir = bma.util.projectRoot();
end
workDir = absDir(workDir);
runDirAbs = resolveRunDir(workDir, opts);
candList = normalizeCandidates(candidates);
nCand = numel(candList);
warnings = {};
fitOpts = struct();
if isfield(opts, 'options') && isstruct(opts.options)
    fitOpts = opts.options;
end
fitOpts.save_artifacts = false;
fitOpts.make_figure = false;
fitOpts.work_dir = workDir;
if isfield(opts, 'multistart') && ~isempty(opts.multistart)
    fitOpts.multistart = opts.multistart;
end
% Per-candidate budget: a slow candidate must not consume the whole tool
% call and discard results already computed (ISSUE-004).
candidateSeconds = getNum(opts, 'candidate_seconds', 300);
candidateSeconds = max(10, candidateSeconds);
fitOpts.candidate_seconds = candidateSeconds;
fitOpts.fit_seconds = min(getNum(fitOpts, 'fit_seconds', candidateSeconds), candidateSeconds);
fitOpts.start_seconds = min(getNum(fitOpts, 'start_seconds', 45), max(5, candidateSeconds / 4));
candStatus = struct('name', {}, 'status', {}, 'seconds', {}, 'aicc', {}, 'error', {});
partialPath = fullfile(runDirAbs, 'fits', 'model_selection.partial.json');

rows = struct('name', {}, 'k', {}, 'aicc', {}, 'bic', {}, 'r2', {}, ...
    'rmse', {}, 'loglik', {}, 'n', {}, 'delta_aicc', {}, ...
    'aicc_weight', {}, 'best', {});
for i = 1:nCand
    cand = candList{i};
    name = candName(cand, i);
    tCand = tic;
    status = 'ok';
    statusErr = '';
    row = struct('name', name, 'k', NaN, 'aicc', NaN, 'bic', NaN, ...
        'r2', NaN, 'rmse', NaN, 'loglik', NaN, 'n', NaN, ...
        'delta_aicc', NaN, 'aicc_weight', NaN, 'best', false);
    try
        if isfield(cand, 'metrics') && isstruct(cand.metrics) ...
                && isfield(cand.metrics, 'aicc') && isfinite(cand.metrics.aicc)
            m = cand.metrics;
            row.k = getNum(m, 'k', getNum(m, 'n_parameters', NaN));
            row.aicc = m.aicc;
            row.bic = getNum(m, 'bic', NaN);
            row.r2 = getNum(m, 'r2', NaN);
            row.rmse = getNum(m, 'rmse', NaN);
            row.loglik = getNum(m, 'loglik', NaN);
            row.n = getNum(m, 'n', getNum(m, 'n_observations', NaN));
        elseif isfield(cand, 'aicc') && ~isempty(cand.aicc) && isfinite(cand.aicc)
            row.aicc = double(cand.aicc);
            row.k = getNum(cand, 'k', 0);
            row.bic = getNum(cand, 'bic', NaN);
            row.r2 = getNum(cand, 'r2', NaN);
            row.rmse = getNum(cand, 'rmse', NaN);
            row.loglik = getNum(cand, 'loglik', NaN);
            row.n = getNum(cand, 'n', NaN);
        else
            fr = fitCandidate(cand, workDir, fitOpts);
            row.k = fr.n_parameters;
            row.aicc = fr.metrics.aicc;
            row.bic = fr.metrics.bic;
            row.r2 = fr.metrics.r2;
            row.rmse = fr.metrics.rmse;
            row.loglik = fr.metrics.loglik;
            row.n = fr.metrics.n;
        end
    catch err
        status = 'failed';
        statusErr = err.message;
        warnings{end+1} = sprintf('候选模型 "%s" 拟合失败：%s', name, err.message); %#ok<AGROW>
    end
    rows(i) = row;
    candStatus(i) = struct('name', name, 'status', status, ...
        'seconds', toc(tCand), 'aicc', row.aicc, 'error', statusErr);
    % Persist partial results after every candidate so a timeout/restart does
    % not lose completed AICc rows.
    try
        bma.util.ensureDir(fileparts(partialPath));
        bma.util.writeJsonAtomic(partialPath, struct( ...
            'schema', 'bma.modelSelection.partial.v1', ...
            'candidate_status', candStatus, 'table', rows, ...
            'n_total', nCand, 'n_done', i));
    catch
    end
end

% AICc 权重
aicc = [rows.aicc];
ok = isfinite(aicc);
best = '';
if any(ok)
    bestAicc = min(aicc(ok));
    delta = NaN(size(aicc));
    delta(ok) = aicc(ok) - bestAicc;
    w = zeros(size(aicc));
    w(ok) = exp(-0.5 * delta(ok));
    sw = sum(w(ok));
    if sw > 0
        w(ok) = w(ok) / sw;
    end
    for k = 1:nCand
        rows(k).delta_aicc = delta(k);
        rows(k).aicc_weight = w(k);
    end
    [~, ib] = min(aicc);
    best = rows(ib).name;
    rows(ib).best = true;
else
    warnings{end+1} = '所有候选模型均无有效 AICc，无法比较。';
end
% 按 AICc 升序、无效值置后
key = aicc;
key(~isfinite(key)) = Inf;
[~, order] = sort(key, 'ascend');
rows = rows(order);

r = struct();
r.table = rows;
r.best = best;
r.table_path = '';
r.warnings = warnings;
r.candidate_status = candStatus;
r.candidate_budget_seconds = candidateSeconds;
r.partial_path = '';
try
    if isfile(partialPath)
        r.partial_path = bma.util.relPath(workDir, partialPath);
    end
catch
end

% 产物 CSV
csvPath = '';
if isfield(opts, 'table_path') && ~isempty(opts.table_path)
    csvPath = bma.util.absPath(workDir, char(opts.table_path));
else
    csvPath = fullfile(runDirAbs, 'fits', 'model_selection.csv');
end
try
    bma.util.ensureDir(fileparts(csvPath));
    writeSelectionCsv(csvPath, rows);
    r.table_path = bma.util.relPath(workDir, csvPath);
catch err
    r.warnings{end+1} = sprintf('模型选择表写入失败：%s', err.message);
end
end

% ======================================================================
% 局部函数
% ======================================================================
function opts = mergeNestedOptions(opts)
if isfield(opts, 'options') && isstruct(opts.options) && ~isempty(opts.options)
    nested = opts.options;
    f = fieldnames(nested);
    for k = 1:numel(f)
        if ~isfield(opts, f{k}) || isempty(opts.(f{k}))
            opts.(f{k}) = nested.(f{k});
        end
    end
end
end

function list = normalizeCandidates(candidates)
if iscell(candidates)
    list = candidates(:).';
elseif isstruct(candidates)
    list = num2cell(candidates(:).');
else
    error('bma:validate:candidatesType', 'candidates 必须是 struct array 或 cell。');
end
for k = 1:numel(list)
    if ~isstruct(list{k})
        error('bma:validate:candidateStruct', '第 %d 个候选不是 struct。', k);
    end
end
end

function name = candName(cand, idx)
name = sprintf('candidate_%d', idx);
if isfield(cand, 'name') && ~isempty(cand.name)
    name = char(cand.name);
end
end

function fr = fitCandidate(cand, workDir, fitOpts)
%FITCANDIDATE 对单个候选模型做一次估计，返回含 metrics 的 fit 结果。
% 兼容两种候选格式：
%   A) dispatch 预处理格式：{name, model(已 build 的 m), data(loadDataset), options}
%   B) 通用格式：{name, spec/spec_path, data/data_csv, output_map}
if isfield(cand, 'model') && isstruct(cand.model) && ~isempty(cand.model) ...
        && (isfield(cand.model, 'rhs') || isfield(cand.model, 'kind'))
    m = cand.model;
elseif isfield(cand, 'spec') && isstruct(cand.spec) && ~isempty(cand.spec)
    m = bma.fit.resolveModel(cand.spec);
elseif isfield(cand, 'spec_path') && ~isempty(cand.spec_path)
    specPath = bma.util.absPath(workDir, char(cand.spec_path));
    m = bma.fit.resolveModel(bma.util.readJson(specPath));
else
    error('bma:validate:candidateSpec', '候选 "%s" 缺少 model/spec/spec_path。', ...
        candName(cand, 0));
end
dataInput = candidateData(cand, workDir);
localOpts = fitOpts;
if isfield(cand, 'options') && isstruct(cand.options) && ~isempty(cand.options)
    f = fieldnames(cand.options);
    for k = 1:numel(f)
        localOpts.(f{k}) = cand.options.(f{k});
    end
end
% Enforce the candidate-level wall-clock budget even if a candidate supplied
% its own fit_seconds/start_seconds.
if isfield(localOpts, 'candidate_seconds') && ~isempty(localOpts.candidate_seconds)
    cap = double(localOpts.candidate_seconds);
    localOpts.fit_seconds = min(getNum(localOpts, 'fit_seconds', cap), cap);
    localOpts.start_seconds = min(getNum(localOpts, 'start_seconds', 45), max(5, cap / 4));
end
fr = bma.fit.estimate(m, dataInput, localOpts);
end

function dataInput = candidateData(cand, workDir)
if isfield(cand, 'data') && isstruct(cand.data) && ~isempty(fieldnames(cand.data))
    dataInput = cand.data;
elseif isfield(cand, 'data_csv') && ~isempty(cand.data_csv)
    dataInput = struct();
    dataInput.csv = bma.util.absPath(workDir, char(cand.data_csv));
    if isfield(cand, 'output_map') && ~isempty(cand.output_map)
        dataInput.outputMap = cand.output_map;
    end
else
    error('bma:validate:candidateData', '候选缺少 data/data_csv。');
end
end

function runDirAbs = resolveRunDir(workDir, opts)
if isfield(opts, 'run_dir_abs') && ~isempty(opts.run_dir_abs)
    runDirAbs = char(opts.run_dir_abs);
elseif isfield(opts, 'runDirAbs') && ~isempty(opts.runDirAbs)
    runDirAbs = char(opts.runDirAbs);
elseif isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    runDirAbs = bma.util.absPath(workDir, char(opts.run_dir));
else
    runDirAbs = fullfile(workDir, '.bma', 'runs', bma.util.newId('r'));
end
bma.util.ensureDir(runDirAbs);
end

function writeSelectionCsv(csvPath, rows)
fid = fopen(csvPath, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:validate:csvWrite', '无法写入 %s', csvPath);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, 'name,k,aicc,bic,r2,rmse,loglik,n,delta_aicc,aicc_weight,best\n');
for k = 1:numel(rows)
    t = rows(k);
    fprintf(fid, '%s,%d,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%d\n', ...
        t.name, t.k, t.aicc, t.bic, t.r2, t.rmse, t.loglik, t.n, ...
        t.delta_aicc, t.aicc_weight, t.best);
end
end

function p = absDir(p)
p = char(p);
if ~isfolder(p)
    bma.util.ensureDir(p);
end
end

function v = getNum(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = double(s.(name));
else
    v = default;
end
end
