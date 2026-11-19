function p = sensitivity(si, opts)
%SENSITIVITY 绘制敏感性指数排序条形图（Sobol 总效应/一阶效应或局部弹性）。
%   p = bma.plot.sensitivity(si, opts)
%
% si 为 bma.fit.sensitivity 的结果 struct。返回相对路径。

if nargin < 2 || isempty(opts)
    opts = struct();
end
if ~isstruct(si)
    error('bma:plot:sensitivityInput', 'bma.plot.sensitivity 需要 fit.sensitivity 结果 struct。');
end
paramIds = {};
if isfield(si, 'param_ids') && ~isempty(si.param_ids)
    paramIds = cellfun(@(s) char(s), si.param_ids(:).', 'UniformOutput', false);
end
total = [];
first = [];
if isfield(si, 'sobol') && isstruct(si.sobol) && isfield(si.sobol, 'total') ...
        && ~isempty(si.sobol.total)
    total = double(si.sobol.total);
    if isfield(si.sobol, 'first') && ~isempty(si.sobol.first)
        first = double(si.sobol.first);
    end
    metricLabel = 'Sobol 指数（输出时间平均）';
elseif isfield(si, 'local') && isstruct(si.local) && isfield(si.local, 'max_abs') ...
        && ~isempty(si.local.max_abs)
    total = abs(double(si.local.max_abs));
    metricLabel = '局部弹性系数 |E| 最大值';
else
    error('bma:plot:sensitivityNoData', '敏感性结果中没有可绘制的指数。');
end
if isempty(paramIds)
    paramIds = arrayfun(@(k) sprintf('p%d', k), 1:size(total, 1), ...
        'UniformOutput', false);
end
score = maxAbsRows(total);
scoreFirst = [];
if ~isempty(first)
    scoreFirst = maxAbsRows(first);
end
o = bma.plot.internal.resolveOpts(opts, 'sensitivity.png');

fig = bma.plot.internal.newFigure();
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
[~, order] = sort(score, 'ascend');
y = 1:numel(order);
vals = score(order);
if isempty(scoreFirst)
    barh(y, vals, 0.6, 'FaceColor', [0.20 0.55 0.85]);
else
    valsF = scoreFirst(order);
    barh(y, [vals(:), valsF(:)], 0.75);
    legend({'总效应（Total）', '一阶效应（First）'}, 'Location', 'best');
end
set(gca, 'YTick', y, 'YTickLabel', paramIds(order), 'TickLabelInterpreter', 'none');
xlabel(metricLabel, 'Interpreter', 'none');
title('参数敏感性排序', 'Interpreter', 'none');
grid on
try
    bma.plot.internal.styleAxes(gca());
catch
end
p = bma.plot.internal.exportFig(fig, o);
end

% ======================================================================
function s = maxAbsRows(M)
M = double(M);
n = size(M, 1);
s = zeros(n, 1);
for i = 1:n
    row = M(i, :);
    row = row(isfinite(row));
    if isempty(row)
        s(i) = 0;
    else
        s(i) = max(abs(row));
    end
end
end
