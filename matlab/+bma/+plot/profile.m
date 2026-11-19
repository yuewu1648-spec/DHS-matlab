function p = profile(pr, opts)
%PROFILE 绘制剖面似然曲线（含 95% 置信区间与阈值线）。
%   p = bma.plot.profile(pr, opts)
%
% pr 为 bma.fit.profile 的结果 struct，或 profile_*.csv 路径。
% opts.out_dir / opts.name / opts.work_dir 控制输出；返回相对路径。

if nargin < 2 || isempty(opts)
    opts = struct();
end
if ischar(pr) || isstring(pr)
    pr = readProfileCsv(char(pr));
end
if ~isstruct(pr) || ~isfield(pr, 'values') || ~isfield(pr, 'nll')
    error('bma:plot:profileInput', 'bma.plot.profile 需要 fit.profile 结果 struct 或 CSV。');
end
values = double(pr.values(:));
nll = double(pr.nll(:));
delta = nll - min(nll);
paramId = 'param';
if isfield(pr, 'param') && ~isempty(pr.param)
    paramId = char(pr.param);
end
thr = NaN;
if isfield(pr, 'ci') && isstruct(pr.ci) && isfield(pr.ci, 'delta_nll') ...
        && ~isempty(pr.ci.delta_nll)
    thr = double(pr.ci.delta_nll);
elseif isfield(pr, 'ci') && isstruct(pr.ci) && isfield(pr.ci, 'threshold') ...
        && ~isempty(pr.ci.threshold)
    thr = double(pr.ci.threshold) - min(nll);
else
    thr = 1.920729;   % chi2inv(0.95,1)/2
end
lo = NaN;
hi = NaN;
if isfield(pr, 'ci') && isstruct(pr.ci)
    if isfield(pr.ci, 'low') && ~isempty(pr.ci.low), lo = double(pr.ci.low); end
    if isfield(pr.ci, 'high') && ~isempty(pr.ci.high), hi = double(pr.ci.high); end
end
v0 = NaN;
if isfield(pr, 'param_value') && ~isempty(pr.param_value)
    v0 = double(pr.param_value);
end
o = bma.plot.internal.resolveOpts(opts, ['profile_' paramId '.png']);

fig = bma.plot.internal.newFigure();
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
plot(values, delta, '-o', 'LineWidth', 1.4, 'Color', [0.15 0.45 0.80], ...
    'MarkerSize', 4, 'MarkerFaceColor', [0.15 0.45 0.80]);
hold on
if isfinite(thr)
    yline(thr, 'r--', 'LineWidth', 1.3);
    text(max(values), thr, sprintf('  95%% 阈值 Δ=%.2f', thr), ...
        'VerticalAlignment', 'bottom', 'Interpreter', 'none');
end
if isfinite(lo) && isfinite(hi)
    area([lo hi], [thr thr], 'FaceColor', [0.3 0.6 0.85], ...
        'FaceAlpha', 0.12, 'EdgeColor', 'none');
    xline(lo, 'k:', 'LineWidth', 1.0);
    xline(hi, 'k:', 'LineWidth', 1.0);
end
if isfinite(v0)
    xline(v0, 'g-', 'LineWidth', 1.2);
end
hold off
grid on
xlabel(sprintf('参数 %s 的扫描值', paramId), 'Interpreter', 'none');
ylabel('ΔNLL（剖面负对数似然差）');
title(sprintf('剖面似然：%s（95%% CI = [%.4g, %.4g]）', paramId, lo, hi), ...
    'Interpreter', 'none');
try
    bma.plot.internal.styleAxes(gca());
catch
end
p = bma.plot.internal.exportFig(fig, o);
end

% ======================================================================
function pr = readProfileCsv(path)
if ~isfile(path)
    error('bma:plot:profileCsv', '剖面 CSV 不存在：%s', path);
end
M = readmatrix(path, 'NumHeaderLines', 1);
if isempty(M) || size(M, 2) < 3
    error('bma:plot:profileCsvShape', '剖面 CSV 至少需要 value,sse,nll 三列：%s', path);
end
pr = struct();
pr.values = M(:, 1).';
pr.sse = M(:, 2).';
pr.nll = M(:, 3).';
if size(M, 2) >= 4
    pr.delta_nll = M(:, 4).';
else
    pr.delta_nll = pr.nll - min(pr.nll);
end
end
