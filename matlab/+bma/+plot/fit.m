function p = fit(fr, data, opts)
%FIT 绘制拟合结果：观测 vs 预测时间序列 + 残差图。
%   p = bma.plot.fit(fr, data, opts)
%
% fr 为 bma.fit.estimate 结果（struct 或 fit.json/fit.mat 路径）；data 可为空
% （居中绘制依赖 fr.pred）。opts.out_dir / opts.name / opts.work_dir 控制输出。
% 返回相对 work_dir 的 PNG 路径。

if nargin < 2
    data = [];
end
if nargin < 3 || isempty(opts)
    opts = struct();
end
if ischar(fr) || isstring(fr)
    fr = bma.fit.load(char(fr));
end
if ~isstruct(fr) || ~isfield(fr, 'pred') || isempty(fr.pred)
    error('bma:plot:fitNoPred', ...
        'bma.plot.fit 需要 fr.pred（Y/Yhat）。请传入完整 fit 结果或 fit.json。');
end
P = fr.pred;
if ~isfield(P, 'Y') || ~isfield(P, 'Yhat') || isempty(P.Y) || isempty(P.Yhat)
    error('bma:plot:fitNoArrays', 'fr.pred 缺少 Y/Yhat 数组。');
end
Y = double(P.Y);
Yhat = double(P.Yhat);
t = [];
if isfield(P, 't') && ~isempty(P.t)
    t = double(P.t(:));
else
    t = (1:size(Y, 1)).';
end
ids = P.colIds;
if iscell(ids) == false
    ids = cellstr(string(ids));
end
ids = ids(:).';
colNames = ids;
if isfield(P, 'colNames') && ~isempty(P.colNames)
    colNames = cellfun(@(s) char(s), P.colNames(:).', 'UniformOutput', false);
end
nO = min(numel(ids), 5);
if nO < 1
    error('bma:plot:fitNoOutputs', 'fit 结果没有输出列。');
end
o = bma.plot.internal.resolveOpts(opts, 'fit.png');

fig = bma.plot.internal.newFigure(960, 220 * (nO + 1) + 90);
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
tl = tiledlayout(fig, nO + 1, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
for j = 1:nO
    ax = nexttile(tl, j);
    hold(ax, 'on');
    plot(ax, t, Yhat(:, j), '-', 'LineWidth', 1.6, 'Color', [0.15 0.45 0.80]);
    idxObs = isfinite(Y(:, j));
    scatter(ax, t(idxObs), Y(idxObs, j), 14, [0.85 0.33 0.20], 'filled');
    hold(ax, 'off');
    bma.plot.internal.styleAxes(ax);
    ylabel(ax, colNames{j}, 'Interpreter', 'none');
    legend(ax, {'模型预测', '观测数据'}, 'Location', 'best', 'Interpreter', 'none');
    title(ax, ['输出 ' ids{j}], 'Interpreter', 'none');
end
ax = nexttile(tl, nO + 1);
R = Y - Yhat;
for j = 1:nO
    plot(ax, t, R(:, j), '-', 'LineWidth', 1.1);
    hold(ax, 'on');
end
hold(ax, 'off');
bma.plot.internal.styleAxes(ax);
yline(ax, 0, 'k--');
xlabel(ax, '时间');
ylabel(ax, '残差');
title(ax, '拟合残差', 'Interpreter', 'none');
if nO > 1
    legend(ax, colNames(1:nO), 'Location', 'best', 'Interpreter', 'none');
end
try
    ttl = '参数拟合结果';
    if isfield(fr, 'spec_name') && ~isempty(fr.spec_name)
        ttl = sprintf('%s：参数拟合结果', char(fr.spec_name));
    end
    if isfield(fr, 'metrics') && isstruct(fr.metrics)
        part = '';
        if isfield(fr.metrics, 'r2') && isfinite(fr.metrics.r2)
            part = sprintf('%sR^2 = %.4f', part, fr.metrics.r2);
        end
        if isfield(fr.metrics, 'rmse') && isfinite(fr.metrics.rmse)
            part = sprintf('%s，RMSE = %.4g', part, fr.metrics.rmse);
        end
        if ~isempty(part)
            ttl = [ttl '（' part '）'];
        end
    end
    try
        title(tl, ttl, 'Interpreter', 'none');
    catch
        sgtitle(fig, ttl, 'Interpreter', 'none');
    end
catch
end
p = bma.plot.internal.exportFig(fig, o);
end
