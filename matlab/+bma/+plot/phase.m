function p = phase(mOrSpec, res, opts)
%PHASE 绘制相平面轨迹（两个输出的相图）。
%   p = bma.plot.phase(m, res, opts)
%
% opts.x / opts.y 指定两个输出 id（默认取前两个 output），opts.out_dir /
% opts.name / opts.work_dir 控制产物。对周期/极限环模型，默认把后段
% （另一个周期）加粗，便于在相图上直接看到闭合环；opts.limit_cycle=false
% 可关闭。opts.transient_fraction 控制丢弃的前段比例（默认 0.4）。

if nargin < 3 || isempty(opts)
    opts = struct();
end
[m, spec] = bma.fit.resolveModel(mOrSpec);
o = bma.plot.internal.resolveOpts(opts, 'phase.png');
[t, series, ids] = bma.plot.internal.extractSeries(m, res);
% Allow phase_x/phase_y to name state variables, not only declared outputs.
% This is what users naturally pass for an (X,Y) phase portrait.
if isfield(m, 'species') && isfield(res, 'Y') && ~isempty(res.Y)
    sp = cellstr(m.species);
    for k = 1:min(numel(sp), size(res.Y, 2))
        if ~isfield(series, sp{k})
            series.(sp{k}) = double(res.Y(:, k));
            ids{end+1} = sp{k}; %#ok<AGROW>
        end
    end
end
if numel(ids) < 2
    error('bma:plot:phaseOutputs', '相图需要至少两个输出，当前只有 %d 个。', numel(ids));
end
xId = ids{1};
yId = ids{2};
if isfield(opts, 'x') && ~isempty(opts.x)
    xId = char(opts.x);
end
if isfield(opts, 'y') && ~isempty(opts.y)
    yId = char(opts.y);
end
if ~isfield(series, xId) || ~isfield(series, yId)
    error('bma:plot:phaseUnknown', '相图输出不存在：%s / %s。', xId, yId);
end
x = series.(xId)(:);
y = series.(yId)(:);
n = min(numel(x), numel(y));
x = x(1:n);
y = y(1:n);

fig = bma.plot.internal.newFigure();
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
% Draw the full trajectory faintly; the last closed cycle (or the last
% segment when no period is detectable) is highlighted on top. This is the
% canonical phase-portrait form for an oscillator/limit-cycle model.
plot(x, y, '-', 'LineWidth', 0.8, 'Color', [0.65 0.70 0.78]);
hold on
showCycle = true;
if isfield(opts, 'limit_cycle') && ~isempty(opts.limit_cycle)
    showCycle = logical(opts.limit_cycle);
end
cycleLabel = '后段';
cyclePlotted = false;
if showCycle
    [c0, c1, isClosed] = tailCycle(x, y, opts);
    if c1 > c0
        plot(x(c0:c1), y(c0:c1), '-', 'LineWidth', 2.8, 'Color', [0.12 0.42 0.82]);
        cyclePlotted = true;
        if isClosed
            cycleLabel = '极限环（后段闭合）';
        else
            cycleLabel = '后段轨迹';
        end
    end
end
plot(x(1), y(1), 'o', 'MarkerSize', 7, 'MarkerFaceColor', [0.2 0.7 0.3], ...
    'MarkerEdgeColor', 'k');
plot(x(end), y(end), 's', 'MarkerSize', 7, 'MarkerFaceColor', [0.85 0.33 0.20], ...
    'MarkerEdgeColor', 'k');
hold off
grid on
xlabel(labelOf(spec, xId), 'Interpreter', 'none');
ylabel(labelOf(spec, yId), 'Interpreter', 'none');
title(sprintf('相平面：%s vs %s（%s）', yId, xId, cycleLabel), 'Interpreter', 'none');
try
    labels = {'完整轨迹'};
    if cyclePlotted, labels{end+1} = cycleLabel; end
    labels = [labels, {'起点', '终点'}];
    legend(labels, 'Location', 'best');
catch
end
try
    bma.plot.internal.styleAxes(gca());
catch
end
p = bma.plot.internal.exportFig(fig, o);
end

% ======================================================================
function [c0, c1, isClosed] = tailCycle(x, y, opts)
% Find the last upward mean-crossing cycle in the tail. If no crossing is
% found, highlight the last 25% of the trajectory as a fallback.
n = min(numel(x), numel(y));
frac = 0.4;
if isfield(opts, 'transient_fraction') && ~isempty(opts.transient_fraction)
    frac = max(0, min(0.9, double(opts.transient_fraction)));
end
start = max(1, floor(frac * n) + 1);
tail = start:n;
xm = mean(x(tail), 'omitnan');
if ~isfinite(xm)
    c0 = start; c1 = n; isClosed = false; return
end
cross = find(x(1:n-1) < xm & x(2:n) >= xm) + 0;
cross = cross(cross >= start);
if numel(cross) >= 2
    c0 = cross(end-1);
    c1 = cross(end);
    % A closed/near-closed cycle should return close to where it started,
    % relative to the explored range.
    span = max(max(x(tail)) - min(x(tail)), max(y(tail)) - min(y(tail)));
    d = hypot(x(c1) - x(c0), y(c1) - y(c0));
    isClosed = isfinite(span) && span > 0 && d < 0.15 * span;
else
    c0 = max(start, floor(0.75 * n));
    c1 = n;
    isClosed = false;
end
end

% ======================================================================
function s = labelOf(spec, id)
s = id;
if isfield(spec, 'outputs') && ~isempty(spec.outputs)
    q = find(strcmp({spec.outputs.id}, id), 1);
    if ~isempty(q)
        name = id;
        unit = '';
        if isfield(spec.outputs(q), 'name') && ~isempty(spec.outputs(q).name)
            name = char(spec.outputs(q).name);
        end
        if isfield(spec.outputs(q), 'unit') && ~isempty(spec.outputs(q).unit)
            unit = char(spec.outputs(q).unit);
        end
        if isempty(unit)
            s = sprintf('%s (%s)', name, id);
        else
            s = sprintf('%s (%s, %s)', name, id, unit);
        end
    end
end
end
