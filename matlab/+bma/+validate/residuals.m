function r = residuals(fr, opts)
%RESIDUALS 残差诊断：正态性、滞后自相关、异方差、偏度/峰度。
%   r = bma.validate.residuals(fr, opts)
%
% 输入 fr：bma.fit.estimate 结果（struct，或 fit.json/fit.mat 路径）。
% opts：out_dir / work_dir / make_figure(默认 true)
%
% 输出 r：
%   diagnostics {n, mean, std, skewness, kurtosis, normality_method,
%                normality_p, normality_reject, autocorr_lag1,
%                autocorr_lag1_p, acf_lags, acf, durbin_watson,
%                heteroscedastic{flag,corr,p_value,variance_ratio,ratio_p},
%                runs_test?} 
%   figure（相对路径）、warnings
%
% 正态性：优先 Lilliefors（Statistics Toolbox），否则 Jarque-Bera；
% 自相关：lag-1 Pearson + 1.96/sqrt(n) 近似带；异方差：|残差| 与拟合值的
% 相关检验 + 前后半段方差比 F 检验。

if nargin < 2 || isempty(opts)
    opts = struct();
end
if ischar(fr) || isstring(fr)
    fr = bma.fit.load(char(fr));
end
if ~isstruct(fr)
    error('bma:validate:residualsInput', 'residuals 需要 fit 结果 struct 或路径。');
end
warnings = {};

% 残差向量
residVals = [];
if isfield(fr, 'residuals')
    if isfield(fr.residuals, 'values') && ~isempty(fr.residuals.values)
        residVals = double(fr.residuals.values(:));
    elseif isfield(fr.residuals, 'raw') && ~isempty(fr.residuals.raw)
        residVals = double(fr.residuals.raw(:));
    end
end
fitted = [];
times = [];
if isfield(fr, 'pred') && isstruct(fr.pred)
    if isfield(fr.pred, 'Y') && isfield(fr.pred, 'Yhat') ...
            && ~isempty(fr.pred.Y) && ~isempty(fr.pred.Yhat) ...
            && isequal(size(fr.pred.Y), size(fr.pred.Yhat))
        mask = isfinite(fr.pred.Y) & isfinite(fr.pred.Yhat);
        if isempty(residVals)
            residVals = double(fr.pred.Y(mask) - fr.pred.Yhat(mask));
        end
        fitted = double(fr.pred.Yhat(mask));
        if isfield(fr.pred, 't') && ~isempty(fr.pred.t)
            t = double(fr.pred.t(:));
            if numel(t) == size(mask, 1)
                tt = repmat(t, 1, size(mask, 2));
                times = tt(mask);
            end
        end
    end
end
if isempty(residVals)
    error('bma:validate:noResiduals', ...
        'fit 结果中没有残差（residuals.values）或 pred.Y/Yhat。');
end
residVals = residVals(isfinite(residVals));
n = numel(residVals);
if n < 3
    error('bma:validate:residualsFew', '有效残差样本太少（%d）。', n);
end

d = struct();
d.n = n;
d.mean = mean(residVals);
d.std = std(residVals);
d.variance = var(residVals);
d.skewness = skewnessOf(residVals);
d.kurtosis = kurtosisOf(residVals);
d.min = min(residVals);
d.max = max(residVals);
d.mae = mean(abs(residVals));

% 正态性
[d.normality_method, d.normality_p, d.normality_reject] = normalityTest(residVals);

% 自相关
if numel(residVals) > 2
    rr = corrcoef(residVals(1:end - 1), residVals(2:end));
    d.autocorr_lag1 = rr(1, 2);
else
    d.autocorr_lag1 = NaN;
end
d.autocorr_lag1_p = 2 * (1 - normCdfSafe(abs(d.autocorr_lag1) * sqrt(max(n, 2))));
maxLag = min(10, n - 1);
acf = zeros(1, maxLag);
r0 = sum((residVals - mean(residVals)).^2);
for lag = 1:maxLag
    x1 = residVals(1:end - lag);
    x2 = residVals(1 + lag:end);
    acf(lag) = sum((x1 - mean(residVals)) .* (x2 - mean(residVals))) / max(r0, realmin);
end
d.acf_lags = 1:maxLag;
d.acf = acf;
d.durbin_watson = sum(diff(residVals).^2) / max(sum(residVals.^2), realmin);

% 异方差
het = struct('flag', false, 'corr_absresid_fitted', NaN, 'p_value', NaN, ...
    'variance_ratio', NaN, 'ratio_p', NaN, 'method', 'none');
if ~isempty(fitted) && numel(fitted) == numel(residVals) && numel(fitted) > 3
    ar = abs(residVals);
    rp = corrcoef(ar, fitted);
    het.corr_absresid_fitted = rp(1, 2);
    % 相关系数的 t 检验
    if isfinite(het.corr_absresid_fitted) && abs(het.corr_absresid_fitted) < 1
        tstat = het.corr_absresid_fitted * sqrt((n - 2) / max(1 - het.corr_absresid_fitted^2, eps()));
        het.p_value = 2 * (1 - tCdfSafe(abs(tstat), n - 2));
    end
    % 前后半段方差比
    half = floor(n / 2);
    v1 = var(residVals(1:half));
    v2 = var(residVals(half + 1:end));
    if v1 > 0 && v2 > 0
        het.variance_ratio = max(v1, v2) / min(v1, v2);
        if exist('fcdf', 'file') == 2
            try
                if v1 >= v2
                    het.ratio_p = 1 - fcdf(het.variance_ratio, half - 1, n - half - 1);
                else
                    het.ratio_p = 1 - fcdf(het.variance_ratio, n - half - 1, half - 1);
                end
            catch
            end
        end
    end
    if isfinite(het.p_value) && het.p_value < 0.05
        het.flag = true;
        het.method = '|残差| 与拟合值相关的 t 检验';
    elseif isfinite(het.ratio_p) && het.ratio_p < 0.05
        het.flag = true;
        het.method = '前后半段方差比 F 检验';
    end
end
d.heteroscedastic = het;

% 总体提示
if isfinite(d.normality_p) && d.normality_p < 0.05
    warnings{end+1} = sprintf('残差正态性检验拒绝原假设（p=%.3g，%s），CI/AIC 解释需谨慎。', ...
        d.normality_p, d.normality_method);
end
if isfinite(d.autocorr_lag1) && abs(d.autocorr_lag1) > 2 / sqrt(n)
    warnings{end+1} = sprintf('残差存在显著滞后自相关（lag-1 r=%.3f），可能存在模型结构缺失。', ...
        d.autocorr_lag1);
end
if het.flag
    warnings{end+1} = '检测到异方差，普通最小二乘的协方差估计可能偏乐观。';
end

r = struct();
r.schema_version = 'bma.validateResiduals.v1';
r.diagnostics = d;
r.figure = '';
r.figure_path = '';
r.warnings = warnings;

% 图
makeFigure = true;
if isfield(opts, 'make_figure') && ~isempty(opts.make_figure)
    makeFigure = logical(opts.make_figure);
end
if makeFigure
    try
        outDir = resolveOutDir(fr, opts);
        absPath = fullfile(outDir, 'residuals.png');
        plotResiduals(absPath, residVals, fitted, acf);
        workDir = resolveWorkDir(fr, opts);
        r.figure = bma.util.relPath(workDir, absPath);
        r.figure_path = r.figure;
    catch err
        r.warnings{end+1} = sprintf('残差诊断图生成失败：%s', err.message);
    end
end
end

% ======================================================================
% 局部函数
% ======================================================================
function s = skewnessOf(x)
n = numel(x);
m = mean(x);
s2 = mean((x - m).^2);
if s2 <= 0
    s = 0;
else
    s = mean((x - m).^3) / s2^1.5;
end
end

function k = kurtosisOf(x)
n = numel(x);
m = mean(x);
s2 = mean((x - m).^2);
if s2 <= 0
    k = 3;
else
    k = mean((x - m).^4) / s2^2;
end
end

function [method, p, reject] = normalityTest(x)
method = 'Jarque-Bera';
p = NaN;
n = numel(x);
if exist('lillietest', 'file') == 2 && n >= 4
    try
        [h, pv] = lillietest(x);
        method = 'Lilliefors';
        p = pv;
        reject = logical(h);
        return
    catch
    end
end
% Jarque-Bera（卡方自由度 2）
s = skewnessOf(x);
k = kurtosisOf(x);
jb = n / 6 * (s^2 + (k - 3)^2 / 4);
method = 'Jarque-Bera';
if exist('chi2cdf', 'file') == 2
    try
        p = 1 - chi2cdf(jb, 2);
    catch
    end
end
if ~isfinite(p)
    % 卡方(2) 生存函数解析式：exp(-JB/2)
    p = exp(-jb / 2);
end
reject = p < 0.05;
end

function v = normCdfSafe(z)
if ~isfinite(z)
    v = 0.5;
    return
end
if exist('normcdf', 'file') == 2
    try
        v = normcdf(z);
        return
    catch
    end
end
v = 0.5 * (1 + erf(z / sqrt(2)));
end

function v = tCdfSafe(t, df)
if ~isfinite(t)
    v = 0.5;
    return
end
try
    if df > 0
        v = 1 - 0.5 * betainc(df / (df + t^2), df / 2, 0.5);
        if t < 0
            v = 1 - v;
        end
        return
    end
catch
end
v = normCdfSafe(t);
end

function outDir = resolveOutDir(fr, opts)
workDir = resolveWorkDir(fr, opts);
if isfield(opts, 'out_dir') && ~isempty(opts.out_dir)
    outDir = bma.util.absPath(workDir, char(opts.out_dir));
elseif isfield(fr, 'fit_dir') && ~isempty(fr.fit_dir)
    outDir = fullfile(bma.util.absPath(workDir, char(fr.fit_dir)), 'figures');
else
    outDir = fullfile(workDir, 'figures');
end
bma.util.ensureDir(outDir);
end

function workDir = resolveWorkDir(fr, opts)
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
    workDir = char(opts.work_dir);
elseif isfield(fr, 'work_dir') && ~isempty(fr.work_dir)
    workDir = char(fr.work_dir);
else
    workDir = bma.util.projectRoot();
end
end

function plotResiduals(absPath, resid, fitted, acf)
%PLOTRESIDUALS 四联图：残差-拟合值、直方图、ACF、QQ 图。
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 750]);
cleaner = onCleanup(@() close(fig));
n = numel(resid);

subplot(2, 2, 1);
if ~isempty(fitted) && numel(fitted) == n
    scatter(fitted, resid, 12, [0.2 0.45 0.8], 'filled');
    xlabel('拟合值');
else
    plot(resid, '.', 'Color', [0.2 0.45 0.8]);
    xlabel('样本序号');
end
ylabel('残差');
title('残差 vs 拟合值');
yline(0, 'k--');
grid on

subplot(2, 2, 2);
histogram(resid, max(6, min(30, round(sqrt(n) * 2))), ...
    'FaceColor', [0.3 0.6 0.85]);
xlabel('残差');
ylabel('频数');
title(sprintf('残差分布（偏度 %.2f，峰度 %.2f）', skewnessOf(resid), kurtosisOf(resid)));
grid on

subplot(2, 2, 3);
if ~isempty(acf)
    stem(1:numel(acf), acf, 'filled', 'Color', [0.2 0.45 0.8]);
    hold on
    yline(0, 'k--');
    band = 1.96 / sqrt(n);
    yline(band, 'r:'); yline(-band, 'r:');
    hold off
    xlabel('滞后');
    ylabel('自相关');
    title('残差自相关（ACF）');
    grid on
else
    text(0.1, 0.5, '自相关不可用');
    axis off
end

subplot(2, 2, 4);
try
    z = sort((resid - mean(resid)) / max(std(resid), eps()));
    q = ((1:n)' - 0.5) / n;
    qq = sqrt(2) * erfinv(2 * q - 1);
    plot(qq, z, '.', 'Color', [0.2 0.45 0.8]);
    hold on
    lims = [min([qq; z]), max([qq; z])];
    plot(lims, lims, 'k--');
    hold off
    xlabel('理论正态分位数');
    ylabel('样本分位数');
    title('Q-Q 图');
    grid on
catch
    text(0.1, 0.5, 'Q-Q 图不可用');
    axis off
end
exportgraphics(fig, absPath, 'Resolution', 150);
end
