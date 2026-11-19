function pr = profile(mOrSpec, dataIn, fr, paramId, opts)
%PROFILE 剖面似然分析（逐参数扫描 + chi2 阈值置信区间）。
%   pr = bma.fit.profile(m, data, fr, paramId, opts)
%
% 原理：把参数 paramId 固定在一系列扫描值上，其余待拟合参数从上一格的最优解
% 热启动重新优化，得到剖面残差平方和 SSE(v)。剖面负对数似然
%   NLL(v) = n/2 * log(SSE(v)/n)
% 以 ΔNLL = chi2inv(0.95,1)/2 ≈ 1.921 为阈值（似然比 / 卡方近似）给出 95% CI。
%
% 输入：
%   m        build 结果（或 spec）
%   data     数据（struct / CSV，见 bma.fit.normalizeData）
%   fr       bma.fit.estimate 的结果（可为 struct；为空则先做一次估计）
%   paramId  要扫描的参数 id
%   opts     字段：n_points(默认 21)、range_frac(默认 0.6)、range([low high])、
%            max_iter(剖面内部默认 150)、work_dir、out_dir、confidence(0.95)
%
% 输出 pr：
%   param/param_value, values, sse, nll, delta_nll, ci{low,high,threshold},
%   n_points, confidence, profile_path, figure, warnings, method

if nargin < 5 || isempty(opts)
    opts = struct();
end
opts = mergeNestedOptions(opts);
if nargin < 4 || isempty(paramId)
    error('bma:fit:profileParam', '必须指定要扫描的参数 id。');
end
paramId = char(paramId);

[m, spec] = bma.fit.resolveModel(mOrSpec);
if nargin < 2 || isempty(dataIn)
    error('bma:fit:profileNoData', '剖面似然需要数据。');
end
data = bma.fit.normalizeData(dataIn, m, opts);
allNames = cellstr(m.params);
if ~ismember(paramId, allNames)
    error('bma:fit:profileUnknownParam', ...
        '参数 "%s" 不在模型中（可用：%s）。', paramId, strjoin(allNames, ', '));
end

workDir = getStr(opts, 'work_dir', bma.util.projectRoot());
workDir = absDir(workDir);
if isempty(fr)
    try
        fr = bma.fit.estimate(m, data, opts);
    catch err
        if contains(err.message, '没有需要拟合的参数') || contains(err.message, 'no parameters')
            % ISSUE-008: profile likelihood can run with all other parameters
            % fixed and no estimated parameters at all. Use the spec defaults
            % as the full parameter vector instead of failing.
            fr = struct('p_all', m.paramValues(:), 'pnames', {{}});
        else
            rethrow(err);
        end
    end
end
if ischar(fr) || isstring(fr)
    fr = bma.fit.load(char(fr));
end
pAll = frFullParams(fr, allNames, spec, m);
v0 = pAll(strcmp(allNames, paramId));
[lb, ub] = paramBounds(spec, m, paramId);

% 待拟合的其余参数
fitNames = {};
if isfield(fr, 'pnames') && ~isempty(fr.pnames)
    fitNames = toCellstr(fr.pnames);
elseif isfield(fr, 'params')
    fitNames = cellfun(@(p) char(p.id), num2cell(fr.params), 'UniformOutput', false);
    fitNames = fitNames(~[fr.params.fixed]);
end
fitNames = fitNames(~strcmp(fitNames, paramId));
fitNames = fitNames(ismember(fitNames, allNames));

% 其余参数全部以当前最优值固定，保证剖面与 fr 完全一致
fixedVals = struct();
for k = 1:numel(allNames)
    if ~ismember(allNames{k}, fitNames)
        fixedVals.(allNames{k}) = pAll(k);
    end
end
pFit0 = zeros(numel(fitNames), 1);
for k = 1:numel(fitNames)
    pFit0(k) = pAll(strcmp(allNames, fitNames{k}));
end
pFit0 = clipToBounds(pFit0, boundsOf(fitNames, spec, m));

% 扫描网格
[values, warnings] = buildGrid(v0, lb, ub, opts);
nPts = numel(values);
mask = isfinite(data.Y);
nEff = sum(mask(:));

baseOpts = struct('max_iter', getNum(opts, 'max_iter', 150), 'solver', ...
    getStr(opts, 'solver', 'ode15s'));
if isfield(opts, 'rtol'), baseOpts.rtol = opts.rtol; end
if isfield(opts, 'atol'), baseOpts.atol = opts.atol; end
if isfield(opts, 'n') && ~isempty(opts.n), baseOpts.n = opts.n; end

sse = nan(nPts, 1);
conv = false(nPts, 1);
pFit = pFit0;
pBestAll = pAll;
bestSse = Inf;
curFit = pFit0;
% 从初始值附近向外扫描，热启动更稳：按 |value - v0| 升序计算
[~, order] = sort(abs(values - v0));
for ii = 1:nPts
    k = order(ii);
    fv = fixedVals;
    fv.(paramId) = values(k);
    try
        out = bma.fit.optLocal(m, data, curFit, fitNames, fv, baseOpts);
        sse(k) = out.sse;
        conv(k) = out.converged;
        if isfinite(out.sse)
            curFit = out.pFit;
            if out.sse < bestSse
                bestSse = out.sse;
                pBestAll = out.pAll;
            end
        end
    catch err
        sse(k) = Inf;
        warnings{end+1} = sprintf( ...
            '扫描值 %.6g 处优化失败：%s', values(k), err.message); %#ok<AGROW>
    end
end

% NLL（忽略常数项）
nll = 0.5 * nEff * log(max(sse, realmin) / max(nEff, 1));
nll(~isfinite(sse)) = Inf;
[minNll, iMin] = min(nll);
if ~isfinite(minNll)
    error('bma:fit:profileFailed', '剖面扫描全部失败，无法给出置信区间。');
end
conf = getNum(opts, 'confidence', 0.95);
threshold = minNll + 0.5 * chi2Quantile(conf);
delta = nll - minNll;

% 若在扫描端点仍未越过阈值，自适应扩展一次（最多 2 轮）
for attempt = 1:2
    needLow = iMin > 1 && ~any(nll(1:iMin - 1) >= threshold) && ...
        values(1) > lb * 1.0001 && lb > 0;
    needLow = needLow || (iMin == 1 && nll(1) < threshold && values(1) > lb + 1e-12);
    needHigh = iMin < nPts && ~any(nll(iMin + 1:end) >= threshold) && ...
        values(end) < ub * 0.9999;
    needHigh = needHigh || (iMin == nPts && nll(end) < threshold && values(end) < ub - 1e-12);
    if ~needLow && ~needHigh
        break
    end
    [values, sse, conv, nll] = extendGrid(values, sse, conv, nll, v0, lb, ub, ...
        needLow, needHigh, mask, m, data, fitNames, fixedVals, paramId, ...
        baseOpts, nEff, warnings);
    [minNll, iMin] = min(nll);
    threshold = minNll + 0.5 * chi2Quantile(conf);
    delta = nll - minNll;
end

% 置信区间：从最小点向两侧找第一个越过阈值的区间并线性插值
[ciLow, wl] = crossing(values, nll, threshold, iMin, -1, lb);
[ciHigh, wh] = crossing(values, nll, threshold, iMin, +1, ub);
warnings = [warnings, wl, wh];

pr = struct();
pr.schema_version = 'bma.fitProfile.v1';
pr.param = paramId;
pr.param_value = v0;
pr.values = values(:).';
pr.sse = sse(:).';
pr.nll = nll(:).';
pr.delta_nll = delta(:).';
pr.converged = conv(:).';
pr.ci = struct('low', ciLow, 'high', ciHigh, 'threshold', threshold, ...
    'confidence', conf, 'delta_nll', 0.5 * chi2Quantile(conf));
pr.n_points = numel(values);
pr.n_effective_observations = nEff;
pr.best_sse = min(sse);
pr.p_all_best = pBestAll;
pr.profile_path = '';
pr.figure = '';
pr.method = struct('estimator', '剖面似然（其余参数重优化）', ...
    'ci_method', 'chi2 阈值（ΔNLL = chi2inv(conf,1)/2）', ...
    'warm_start', '按 |value-v0| 由近及远热启动', ...
    'max_iter', getNum(opts, 'max_iter', 150));
pr.warnings = warnings;

% 产物：CSV + 图
fitDirAbs = resolveOutDir(workDir, fr, opts);
if ~isempty(fitDirAbs)
    try
        csvPath = fullfile(fitDirAbs, ['profile_' safeName(paramId) '.csv']);
        writeProfileCsv(csvPath, pr);
        pr.profile_path = bma.util.relPath(workDir, csvPath);
    catch err
        pr.warnings{end+1} = sprintf('剖面 CSV 写入失败：%s', err.message);
    end
    try
        figDir = fullfile(fitDirAbs, 'figures');
        figPath = bma.plot.profile(pr, struct('out_dir', figDir, ...
            'work_dir', workDir, 'name', ['profile_' safeName(paramId) '.png']));
        pr.figure = figPath;
    catch err
        pr.warnings{end+1} = sprintf('剖面图生成失败：%s', err.message);
    end
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

function pAll = frFullParams(fr, allNames, spec, m)
%FRFULLPARAMS 从 fit 结果还原完整参数向量。
pAll = zeros(numel(allNames), 1);
for k = 1:numel(allNames)
    pAll(k) = defaultParamValue(spec, m, allNames{k});
end
if isfield(fr, 'p_all') && numel(fr.p_all) == numel(allNames)
    pAll = double(fr.p_all(:));
elseif isfield(fr, 'params') && ~isempty(fr.params)
    try
        for k = 1:numel(fr.params)
            id = char(fr.params(k).id);
            idx = find(strcmp(allNames, id), 1);
            if ~isempty(idx)
                pAll(idx) = double(fr.params(k).value);
            end
        end
    catch
    end
end
end

function v = defaultParamValue(spec, m, id)
v = 0;
idx = find(strcmp(cellstr(m.params), id), 1);
if ~isempty(idx) && isfield(m, 'paramValues') && numel(m.paramValues) >= idx
    v = double(m.paramValues(idx));
end
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    idx = find(strcmp({spec.parameters.id}, id), 1);
    if ~isempty(idx)
        sp = spec.parameters(idx);
        if isfield(sp, 'value') && isstruct(sp.value) && isfield(sp.value, 'value')
            v = double(sp.value.value);
        elseif isfield(sp, 'value') && isnumeric(sp.value)
            v = double(sp.value);
        end
    end
end
end

function [lb, ub] = paramBounds(spec, m, id)
lb = 0;
ub = 1e6;
idx = find(strcmp(cellstr(m.params), id), 1);
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    q = find(strcmp({spec.parameters.id}, id), 1);
    if ~isempty(q) && isfield(spec.parameters(q), 'bounds') ...
            && ~isempty(spec.parameters(q).bounds)
        b = double(spec.parameters(q).bounds(:));
        lb = b(1);
        ub = b(2);
        return
    end
end
if ~isempty(idx) && isfield(m, 'lb') && isfield(m, 'ub') ...
        && isfinite(m.lb(idx)) && isfinite(m.ub(idx))
    lb = double(m.lb(idx));
    ub = double(m.ub(idx));
    return
end
v = defaultParamValue(spec, m, id);
if v > 0
    lb = max(1e-12, v * 1e-3);
    ub = max(1e3 * v, 1e-9);
else
    lb = -1e6;
    ub = 1e6;
end
end

function b = boundsOf(names, spec, m)
n = numel(names);
b = zeros(n, 2);
for k = 1:n
    [lo, hi] = paramBounds(spec, m, names{k});
    b(k, :) = [lo, hi];
end
end

function x = clipToBounds(x, b)
x = double(x(:));
x = min(max(x, b(:, 1)), b(:, 2));
end

function [values, warnings] = buildGrid(v0, lb, ub, opts)
%BUILDGRID 以 v0 为中心构建扫描网格（默认 ±60% 且限制在边界内）。
warnings = {};
nPts = max(5, round(getNum(opts, 'n_points', 21)));
if isfield(opts, 'range') && numel(opts.range) == 2
    lo = double(opts.range(1));
    hi = double(opts.range(2));
else
    frac = getNum(opts, 'range_frac', 0.6);
    if lb > 0
        lo = max(lb, v0 * (1 - frac));
        hi = min(ub, v0 * (1 + frac));
    else
        span = max(abs(v0), 1);
        lo = max(lb, v0 - frac * span);
        hi = min(ub, v0 + frac * span);
    end
end
if ~(lo < hi)
    if lb < ub
        lo = lb;
        hi = ub;
        warnings{end+1} = '剖面扫描范围退化，已扩展到参数边界。';
    else
        error('bma:fit:profileRange', '参数边界无效，无法构建剖面扫描范围。');
    end
end
values = linspace(lo, hi, nPts).';
values = sort(unique([values; v0]));
values = values(values >= lb & values <= ub);
end

function [values, sse, conv, nll] = extendGrid(values, sse, conv, nll, v0, lb, ub, ...
    needLow, needHigh, mask, m, data, fitNames, fixedVals, paramId, baseOpts, nEff, warnings)
%EXTENDGRID 在未闭合的一侧追加扫描点。
addVals = [];
if needLow
    lo = values(1);
    newLo = max(lb, lo - 0.5 * (values(end) - values(1)));
    if newLo < lo - 1e-12
        addVals = [addVals; linspace(newLo, lo, 6).']; %#ok<AGROW>
    end
end
if needHigh
    hi = values(end);
    newHi = min(ub, hi + 0.5 * (values(end) - values(1)));
    if newHi > hi + 1e-12
        addVals = [addVals; linspace(hi, newHi, 6).']; %#ok<AGROW>
    end
end
addVals = setdiff(sort(addVals), values, 'stable');
if isempty(addVals)
    return
end
baseOpts2 = baseOpts;
baseOpts2.max_iter = max(60, round(baseOpts.max_iter * 0.6));
curFit = nearestFit(values, sse, m, data, fitNames, fixedVals, paramId, baseOpts2);
newSse = nan(numel(addVals), 1);
newConv = false(numel(addVals), 1);
[~, ord] = sort(abs(addVals - v0));
for ii = 1:numel(ord)
    k = ord(ii);
    fv = fixedVals;
    fv.(paramId) = addVals(k);
    try
        out = bma.fit.optLocal(m, data, curFit, fitNames, fv, baseOpts2);
        newSse(k) = out.sse;
        newConv(k) = out.converged;
        if isfinite(out.sse)
            curFit = out.pFit;
        end
    catch err
        warnings{end+1} = sprintf('扩展扫描 %.6g 失败：%s', addVals(k), err.message); %#ok<AGROW>
    end
end
values = [values; addVals];
sse = [sse; newSse];
conv = [conv; newConv];
nll = [nll; 0.5 * nEff * log(max(newSse, realmin) / max(nEff, 1))];
nll(~isfinite(sse)) = Inf;
[values, idx] = sort(values);
sse = sse(idx);
conv = conv(idx);
nll = nll(idx);
end

function curFit = nearestFit(values, sse, m, data, fitNames, fixedVals, paramId, baseOpts)
%CURFIT 取已计算网格中 SSE 最小的点的解作为热启动（重新算一次保证对齐）。
[~, k] = min(sse);
curFit = zeros(numel(fitNames), 1);
fv = fixedVals;
fv.(paramId) = values(k);
try
    out = bma.fit.optLocal(m, data, curFit, fitNames, fv, baseOpts);
    curFit = out.pFit;
catch
    curFit = zeros(numel(fitNames), 1);
end
end

function [ci, warns] = crossing(values, nll, threshold, iMin, direction, bound)
%CROSSING 从最小点向指定方向找阈值交叉并线性插值。
ci = NaN;
warns = {};
n = numel(values);
ks = iMin + direction * (1:n);
ks = ks(ks >= 1 & ks <= n);
for j = 1:numel(ks)
    k = ks(j);
    if nll(k) >= threshold
        prev = k - direction;
        if prev < 1 || prev > n
            ci = values(k);
        else
            x1 = values(prev);
            x2 = values(k);
            y1 = nll(prev);
            y2 = nll(k);
            if y2 > y1
                ci = x1 + (threshold - y1) * (x2 - x1) / (y2 - y1);
            else
                ci = x2;
            end
        end
        return
    end
end
% 未闭合：退到扫描端点并告警
if direction < 0
    ci = max(values(1), bound);
    warns{end+1} = sprintf( ...
        '剖面 95%% CI 下界未在扫描范围内闭合（端点 %.6g），可能触及边界或参数弱可辨识。', values(1));
else
    ci = min(values(end), bound);
    warns{end+1} = sprintf( ...
        '剖面 95%% CI 上界未在扫描范围内闭合（端点 %.6g），可能触及边界或参数弱可辨识。', values(end));
end
end

function q = chi2Quantile(conf)
if exist('chi2inv', 'file') == 2
    try
        q = chi2inv(conf, 1);
        return
    catch
    end
end
% 常用置信度的卡方分位数兜底（自由度 1）
table = [0.80, 1.6424; 0.90, 2.7055; 0.95, 3.8415; 0.99, 6.6349];
if conf <= 0.5
    q = 1.0;
else
    [~, idx] = min(abs(table(:, 1) - conf));
    q = table(idx, 2);
end
end

function writeProfileCsv(csvPath, pr)
fid = fopen(csvPath, 'w', 'n', 'UTF-8');
if fid < 0
    error('bma:fit:csvWrite', '无法写入 %s', csvPath);
end
cleaner = onCleanup(@() fclose(fid));
fprintf(fid, 'value,sse,nll,delta_nll,converged\n');
for k = 1:numel(pr.values)
    fprintf(fid, '%.10g,%.10g,%.10g,%.10g,%d\n', ...
        pr.values(k), pr.sse(k), pr.nll(k), pr.delta_nll(k), pr.converged(k));
end
end

function d = resolveOutDir(workDir, fr, opts)
%RESOLVEOUTDIR 剖面产物目录：优先 opts.out_dir，其次 fit 目录，最后临时 run 目录。
d = '';
if isfield(opts, 'out_dir') && ~isempty(opts.out_dir)
    d = bma.util.absPath(workDir, char(opts.out_dir));
elseif isstruct(fr) && isfield(fr, 'fit_dir') && ~isempty(fr.fit_dir)
    d = bma.util.absPath(workDir, char(fr.fit_dir));
else
    d = fullfile(workDir, '.bma', 'runs', bma.util.newId('r'), 'fits', ...
        bma.util.newId('profile'));
end
bma.util.ensureDir(d);
end

function s = safeName(id)
s = regexprep(char(id), '[^A-Za-z0-9_.-]', '_');
end

function c = toCellstr(x)
if iscell(x)
    c = cellfun(@(s) char(s), x(:).', 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    c = {x};
else
    c = {};
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

function p = absDir(p)
p = char(p);
if ~isfolder(p)
    bma.util.ensureDir(p);
end
end
