function r = identifiability(mOrSpec, dataIn, varargin)
%IDENTIFIABILITY 结构可辨识性与实用可辨识性分析。
%   r = bma.fit.identifiability(m, data, fr, opts)
%   r = bma.fit.identifiability(m, data, opts)      % 兼容 dispatch 3 参数调用
%
% 结构可辨识性（本实现用参数-输出灵敏度矩阵的数值秩诊断）：
%   J           观测输出的对数参数灵敏度矩阵（相对尺度归一）
%   rank(J)     数值秩（奇异值相对阈值）；< 参数个数 → 结构秩亏
%   null_space  右零空间基（每个基向量给出不可辨识的参数组合方向）
%   符号秩诊断   灵敏度列符号模式相同的参数对 → 可能不可单独辨识
%   相关列诊断   灵敏度列相关 |r| > 阈值的参数对
%
% 实用可辨识性（基于 Fisher 信息矩阵）：
%   FIM = J'J，条件数、特征值、参数相关矩阵、相对标准误 sqrt(diag(pinv(FIM)))。
%
% 输出 r：
%   structural {rank, n_params, deficient, singular_values, null_space,
%               combinations, collinear_pairs, sign_pairs, method}
%   practical {condition_number, eigenvalues, relative_se, correlation, fim}
%   correlations {param_ids, matrix}
%   rank, table_path, warnings

if nargin < 2 || isempty(dataIn)
    dataIn = struct();
end
if isempty(dataIn)
    dataIn = struct();
end
opts = struct();
fr = [];
if ~isempty(varargin)
    if isFitResult(varargin{1})
        fr = varargin{1};
        if numel(varargin) >= 2 && isstruct(varargin{2})
            opts = varargin{2};
        end
    elseif isstruct(varargin{1})
        opts = varargin{1};
    end
end
opts = mergeNestedOptions(opts);
[m, spec] = bma.fit.resolveModel(mOrSpec);
workDir = absDir(getStr(opts, 'work_dir', bma.util.projectRoot()));
allNames = cellstr(m.params);
baseAll = baseParams(spec, m);
if ~isempty(fr)
    if ischar(fr) || isstring(fr)
        fr = bma.fit.load(char(fr));
    end
    if isfield(fr, 'p_all') && numel(fr.p_all) == numel(allNames)
        baseAll = double(fr.p_all(:));
    end
end
if isfield(opts, 'param_overrides') && isstruct(opts.param_overrides)
    f = fieldnames(opts.param_overrides);
    for k = 1:numel(f)
        idx = find(strcmp(allNames, f{k}), 1);
        if ~isempty(idx)
            baseAll(idx) = double(opts.param_overrides.(f{k}));
        end
    end
end

% 参数列表：优先 fr 的拟合参数，其次 opts.params / opts.param，最后 spec estimate:true
if isfield(opts, 'param') && ~isempty(opts.param) ...
        && (~isfield(opts, 'params') || isempty(opts.params))
    opts.params = opts.param;
end
paramIds = {};
if ~isempty(fr) && isfield(fr, 'pnames') && ~isempty(fr.pnames)
    paramIds = toCellstr(fr.pnames);
end
if isfield(opts, 'params') && ~isempty(opts.params)
    paramIds = toCellstr(opts.params);
end
if isempty(paramIds)
    est = estimateFlags(spec, m, allNames);
    paramIds = allNames(est);
    if isempty(paramIds)
        paramIds = allNames;
    end
end
bad = setdiff(paramIds, allNames);
if ~isempty(bad)
    error('bma:fit:identUnknownParam', '未知参数：%s', strjoin(bad, ', '));
end
s = numel(paramIds);

% 观测网格
[obsT, outIds] = observationGrid(m, spec, dataIn, opts);
d = struct('t', obsT, 'Y', zeros(numel(obsT), numel(outIds)), ...
    'colIds', {outIds}, 'colNames', {outIds}, 'weights', []);
simOpts = struct('solver', getStr(opts, 'solver', 'ode15s'), 'n', numel(obsT));
if isfield(opts, 'rtol'), simOpts.rtol = opts.rtol; end
if isfield(opts, 'atol'), simOpts.atol = opts.atol; end
warnings = {};
pred0 = [];
try
    pred0 = bma.fit.simulatePredictions(m, d, baseAll, simOpts);
catch err
    error('bma:fit:identSim', '可辨识性分析的基本仿真失败：%s', err.message);
end
if any(~isfinite(pred0(:)))
    warnings{end+1} = '基准仿真含非有限值，灵敏度矩阵可能不可靠。';
end

% 灵敏度矩阵（对数参数、输出尺度归一）
relStep = getNum(opts, 'rel_step', 0.01);
J = zeros(numel(obsT) * numel(outIds), s);
colScale = zeros(1, numel(outIds));
for j = 1:numel(outIds)
    y = pred0(:, j);
    colScale(j) = max(1, max(abs(y(isfinite(y)))));
    if isempty(colScale(j)) || ~isfinite(colScale(j))
        colScale(j) = 1;
    end
end
for i = 1:s
    id = paramIds{i};
    idx = find(strcmp(allNames, id), 1);
    p = baseAll(idx);
    [lb, ub] = paramRange(spec, m, id, p);
    step = relStep;
    if p > 0
        pp = p * (1 + step);
        pm = p * (1 - step);
        if pp > ub || pm < lb
            hi = min(ub, max(pp, p));
            lo = max(lb, min(pm, p));
            if hi <= p || lo >= p
                J(:, i) = 0;
                continue
            end
            pp = hi;
            pm = lo;
            stepEff = 0.5 * ((pp - p) / p + (p - pm) / p);
        else
            stepEff = step;
        end
        dp = p * stepEff;
    else
        dp = step * max(1, abs(p));
        pp2 = p + dp;
        pm2 = p - dp;
        if pp2 > ub || pm2 < lb
            J(:, i) = 0;
            continue
        end
        dp = step * max(1, abs(p));
    end
    pP = baseAll;
    pM = baseAll;
    pP(idx) = p + dp;
    pM(idx) = p - dp;
    try
        yP = bma.fit.simulatePredictions(m, d, pP, simOpts);
        yM = bma.fit.simulatePredictions(m, d, pM, simOpts);
    catch err
        warnings{end+1} = sprintf('参数 %s 的灵敏度计算失败：%s', id, err.message); %#ok<AGROW>
        continue
    end
    dY = (yP - yM) / (2 * dp);       % dY/dp
    colJ = zeros(numel(obsT), numel(outIds));
    for j = 1:numel(outIds)
        colJ(:, j) = dY(:, j) * (p / colScale(j));   % 归一为相对灵敏度（p 因子）
    end
    J(:, i) = colJ(:);
end
J(~isfinite(J)) = 0;

% ---------------- 结构诊断 ----------------
[U, S, V] = svd(J, 'econ');
sv = diag(S);
if isempty(sv) || sv(1) <= 0
    rankJ = 0;
else
    rankTol = getNum(opts, 'rank_tol', 1e-6);
    rankJ = sum(sv > rankTol * sv(1));
end
deficient = max(s - rankJ, 0);
nullBasis = [];
if deficient > 0 && ~isempty(V)
    nullBasis = V(:, rankJ + 1:end);
end
combinations = nullCombinations(nullBasis, paramIds);
collinearPairs = collinearPairsOf(J, paramIds, getNum(opts, 'collin_thresh', 0.95));
signPairs = signPatternPairs(J, paramIds);

% ---------------- 实用诊断 ----------------
practical = struct('condition_number', 1e15, 'eigenvalues', [], ...
    'relative_se', NaN(s, 1), 'correlation', zeros(s), 'fim', zeros(s), ...
    'singular', true);
if rankJ > 0
    FIM = full(J.' * J);
    ev = eig((FIM + FIM.') / 2);
    ev = sort(real(ev), 'descend');
    practical.fim = FIM;
    practical.eigenvalues = ev(:).';
    if rankJ < s || ev(end) <= 0 || ~isfinite(ev(1))
        % 秩亏/奇异：条件数用有限大值表示（Inf 经 JSON 会变成 null，不便消费）
        practical.condition_number = 1e15;
        practical.singular = true;
    else
        c = ev(1) / ev(end);
        if ~isfinite(c)
            c = 1e15;
        end
        practical.condition_number = min(c, 1e15);
        practical.singular = c > 1e12;
    end
    C = pinv(FIM);
    relSe = sqrt(max(diag(C), 0));
    relSe(~isfinite(relSe)) = NaN;
    practical.relative_se = relSe;
    seMat = relSe * relSe.';
    corrMat = C ./ max(seMat, eps());
    corrMat(~isfinite(corrMat)) = 0;
    corrMat(1:s + 1:end) = 1;
    practical.correlation = corrMat;
else
    practical.condition_number = 1e15;
    practical.singular = true;
end

% ---------------- 汇总表与建议 ----------------
corrPairs = topCorrelationPairs(practical.correlation, paramIds, ...
    getNum(opts, 'corr_warn', 0.9));
table = struct('param', {}, 'relative_se', {}, 'max_corr_param', {}, ...
    'max_corr', {}, 'in_null_space', {}, 'note', {});
for i = 1:s
    entry = struct('param', paramIds{i}, 'relative_se', practical.relative_se(i), ...
        'max_corr_param', '', 'max_corr', NaN, 'in_null_space', false, ...
        'note', '');
    if i <= numel(corrPairs)
        entry.max_corr_param = corrPairs(i).other;
        entry.max_corr = corrPairs(i).r;
    end
    if ~isempty(nullBasis)
        entry.in_null_space = any(abs(nullBasis(i, :)) > 0.2);
    end
    table(i) = entry;
end

% 不可辨识组合建议
suggestions = {};
for k = 1:numel(combinations)
    suggestions{end+1} = sprintf( ...
        '参数组合 %s 在结构上不可区分（灵敏度矩阵零空间方向），建议固定其中一个或补充可区分该组合的观测。', ...
        combinations{k}); %#ok<AGROW>
end
for k = 1:numel(corrPairs)
    if abs(corrPairs(k).r) >= 0.9
        suggestions{end+1} = sprintf( ...
            '参数 %s 与 %s 强相关（r=%.2f），估计方差会相互放大，建议固定其一或增加独立数据。', ...
            corrPairs(k).param, corrPairs(k).other, corrPairs(k).r); %#ok<AGROW>
    end
end
if isempty(suggestions)
    suggestions{end+1} = '在给定观测下未发现明显的结构/实用不可辨识组合。';
end

r = struct();
r.schema_version = 'bma.fitIdentifiability.v1';
r.structural = struct('rank', rankJ, 'n_params', s, 'deficient', deficient, ...
    'singular_values', sv(:).', 'null_space', nullBasis, ...
    'combinations', {combinations}, 'collinear_pairs', collinearPairs, ...
    'sign_pairs', signPairs, ...
    'method', '参数-输出灵敏度矩阵数值秩 + 零空间/相关列/符号秩诊断');
r.practical = practical;
r.correlations = struct('param_ids', {paramIds}, 'matrix', practical.correlation);
r.rank = rankJ;
r.n_observations = numel(obsT);
r.output_ids = outIds;
r.param_ids = paramIds;
r.suggestions = suggestions;
r.table = table;
r.table_path = '';
r.warnings = warnings;

% 产物
if isempty(fr) || ~isfield(fr, 'fit_dir') || isempty(fr.fit_dir)
    fitDir = fullfile(workDir, '.bma', 'runs', bma.util.newId('r'), ...
        'fits', ['ident-' bma.util.newId('x')]);
else
    fitDir = bma.util.absPath(workDir, char(fr.fit_dir));
end
tablePath = '';
if isfield(opts, 'table_path') && ~isempty(opts.table_path)
    tablePath = bma.util.absPath(workDir, char(opts.table_path));
else
    tablePath = fullfile(fitDir, 'identifiability.csv');
end
try
    bma.util.ensureDir(fileparts(tablePath));
    writeIdentCsv(tablePath, table);
    r.table_path = bma.util.relPath(workDir, tablePath);
catch err
    r.warnings{end+1} = sprintf('可辨识性表写入失败：%s', err.message);
end
end

% ======================================================================
% 局部函数
% ======================================================================
function tf = isFitResult(x)
tf = isstruct(x) && (isfield(x, 'p_all') || isfield(x, 'pnames') ...
    || isfield(x, 'fit_id') || isfield(x, 'metrics'));
end

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

function [t, outIds] = observationGrid(m, spec, dataIn, opts)
%OBSERVATIONGRID 有数据时用数据时间/输出，否则用 spec 时间网格与全部输出。
useSpec = isempty(dataIn) || (isstruct(dataIn) && ...
    (~isfield(dataIn, 't') || isempty(dataIn.t)) && ...
    (~isfield(dataIn, 'table') || isempty(dataIn.table)) && ...
    (~isfield(dataIn, 'csv') || isempty(dataIn.csv)) && ...
    (~isfield(dataIn, 'time') || isempty(dataIn.time)));
if ~useSpec
    try
        d = bma.fit.normalizeData(dataIn, m, opts);
        t = d.t;
        outIds = d.colIds;
        return
    catch
        useSpec = true;
    end
end
t0 = 0;
t1 = 100;
n = 201;
if isfield(spec, 'time') && isstruct(spec.time)
    if isfield(spec.time, 'start') && ~isempty(spec.time.start), t0 = double(spec.time.start); end
    if isfield(spec.time, 'end') && ~isempty(spec.time.end), t1 = double(spec.time.end); end
    if isfield(spec.time, 'n') && ~isempty(spec.time.n), n = double(spec.time.n); end
end
n = round(getNum(opts, 'n', min(n, 201)));
t = linspace(t0, t1, max(3, n)).';
outIds = {};
if isfield(m, 'outputs') && ~isempty(m.outputs)
    outIds = arrayfun(@(q) char(q.id), m.outputs, 'UniformOutput', false);
elseif isfield(spec, 'outputs') && ~isempty(spec.outputs)
    outIds = arrayfun(@(q) char(q.id), spec.outputs, 'UniformOutput', false);
end
if isempty(outIds)
    outIds = cellstr(m.species);
end
end

function flags = estimateFlags(spec, m, allNames)
flags = false(numel(allNames), 1);
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    for k = 1:numel(spec.parameters)
        id = char(spec.parameters(k).id);
        idx = find(strcmp(allNames, id), 1);
        if ~isempty(idx) && isfield(spec.parameters(k), 'estimate') ...
                && ~isempty(spec.parameters(k).estimate)
            flags(idx) = logical(spec.parameters(k).estimate);
        end
    end
end
if ~any(flags) && isfield(m, 'estimate') && numel(m.estimate) == numel(allNames)
    flags = logical(m.estimate(:));
end
end

function baseAll = baseParams(spec, m)
baseAll = zeros(numel(m.params), 1);
for k = 1:numel(m.params)
    baseAll(k) = defaultParamValue(spec, m, m.params{k});
end
end

function v = defaultParamValue(spec, m, id)
v = 0;
idx = find(strcmp(cellstr(m.params), id), 1);
if ~isempty(idx) && isfield(m, 'paramValues') && numel(m.paramValues) >= idx
    v = double(m.paramValues(idx));
end
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    q = find(strcmp({spec.parameters.id}, id), 1);
    if ~isempty(q)
        sp = spec.parameters(q);
        if isfield(sp, 'value') && isstruct(sp.value) && isfield(sp.value, 'value')
            v = double(sp.value.value);
        elseif isfield(sp, 'value') && isnumeric(sp.value)
            v = double(sp.value);
        end
    end
end
end

function [lb, ub] = paramRange(spec, m, id, v)
lb = NaN;
ub = NaN;
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    q = find(strcmp({spec.parameters.id}, id), 1);
    if ~isempty(q) && isfield(spec.parameters(q), 'bounds') ...
            && numel(spec.parameters(q).bounds) == 2
        b = double(spec.parameters(q).bounds(:));
        lb = b(1);
        ub = b(2);
    end
end
if (~isfinite(lb) || ~isfinite(ub)) && isfield(m, 'lb') && isfield(m, 'ub')
    idx = find(strcmp(cellstr(m.params), id), 1);
    if ~isempty(idx) && isfinite(m.lb(idx)) && isfinite(m.ub(idx))
        lb = double(m.lb(idx));
        ub = double(m.ub(idx));
    end
end
if ~isfinite(lb) || ~isfinite(ub) || lb >= ub
    span = max(abs(v), 1);
    lb = v - 0.5 * span;
    ub = v + 0.5 * span;
end
end

function combos = nullCombinations(nullBasis, paramIds)
%NULLCOMBINATIONS 把零空间方向翻译成“参数乘积/组合不可辨识”的中文描述。
combos = {};
if isempty(nullBasis)
    return
end
for k = 1:size(nullBasis, 2)
    v = nullBasis(:, k);
    thr = 0.2 * max(abs(v));
    sel = find(abs(v) >= thr);
    if numel(sel) < 2
        continue
    end
    parts = cell(1, numel(sel));
    for j = 1:numel(sel)
        i = sel(j);
        expo = v(i);
        if abs(expo - 1) < 1e-6
            parts{j} = paramIds{i};
        elseif abs(expo + 1) < 1e-6
            parts{j} = ['1/' paramIds{i}];
        else
            parts{j} = sprintf('%s^%.2f', paramIds{i}, expo);
        end
    end
    combos{end+1} = strjoin(parts, ' 与 '); %#ok<AGROW>
end
end

function pairs = collinearPairsOf(J, paramIds, thresh)
%COLLINEARPAIRSOF 灵敏度列相关诊断：|r| 超阈值的参数对。
pairs = struct('param', {}, 'other', {}, 'r', {});
if size(J, 2) < 2
    return
end
C = corrcoef(J);
C(~isfinite(C)) = 0;
s = numel(paramIds);
for i = 1:s - 1
    for j = i + 1:s
        if abs(C(i, j)) >= thresh
            pairs(end+1) = struct('param', paramIds{i}, 'other', ...
                paramIds{j}, 'r', C(i, j)); %#ok<AGROW>
        end
    end
end
end

function pairs = signPatternPairs(J, paramIds)
%SIGNPATTERNPAIRS 符号秩诊断：灵敏度符号模式完全相同的参数对。
pairs = struct('param', {}, 'other', {}, 'n_shared_signs', {});
nz = J ~= 0;
S = sign(J);
s = size(J, 2);
for i = 1:s - 1
    for j = i + 1:s
        both = nz(:, i) & nz(:, j);
        nBoth = sum(both);
        if nBoth < 3
            continue
        end
        if all(S(both, i) == S(both, j))
            pairs(end+1) = struct('param', paramIds{i}, 'other', ...
                paramIds{j}, 'n_shared_signs', nBoth); %#ok<AGROW>
        end
    end
end
end

function pairs = topCorrelationPairs(R, paramIds, warnThresh)
%TOPCORRELATIONPAIRS 每个参数相关最强的另一个参数。
s = numel(paramIds);
pairs = struct('param', {}, 'other', {}, 'r', {});
for i = 1:s
    r = R(i, :);
    r(i) = 0;
    [mx, j] = max(abs(r));
    if isempty(j) || s < 2
        pairs(end+1) = struct('param', paramIds{i}, 'other', '', 'r', NaN); %#ok<AGROW>
        continue
    end
    pairs(end+1) = struct('param', paramIds{i}, 'other', paramIds{j}, ...
        'r', R(i, j)); %#ok<AGROW>
end
end

function writeIdentCsv(csvPath, table)
fid = fopen(csvPath, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:fit:csvWrite', '无法写入 %s', csvPath);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, 'param,relative_se,max_corr_param,max_corr,in_null_space,note\n');
for k = 1:numel(table)
    t = table(k);
    fprintf(fid, '%s,%.10g,%s,%.10g,%d,%s\n', t.param, t.relative_se, ...
        t.max_corr_param, t.max_corr, t.in_null_space, t.note);
end
end

function c = toCellstr(x)
if iscell(x)
    c = cellfun(@(s) char(s), x(:).', 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    parts = strtrim(strsplit(x, ','));
    c = parts(~cellfun(@isempty, parts));
else
    c = {};
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

function v = getStr(s, name, default)
if isfield(s, name) && ~isempty(s.(name))
    v = char(s.(name));
else
    v = default;
end
end
