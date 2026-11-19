function p = phase3d(mOrSpec, res, opts)
%PHASE3D 三维相图（三个状态/输出的投影）。
%   p = bma.plot.phase3d(m, res, opts)
% opts.x/opts.y/opts.z 指定轴；默认前三个 species/outputs。支持 species id，
% 不只 outputs。返回相对路径（与 bma.plot.phase 一致）。
if nargin < 3 || isempty(opts)
    opts = struct();
end
[m, ~] = bma.fit.resolveModel(mOrSpec);
o = bma.plot.internal.resolveOpts(opts, 'phase3d.png');
[t, series, ids] = bma.plot.internal.extractSeries(m, res); %#ok<ASGLU>
if isfield(m, 'species') && isfield(res, 'Y') && ~isempty(res.Y)
    sp = cellstr(m.species);
    for k = 1:min(numel(sp), size(res.Y, 2))
        if ~isfield(series, sp{k})
            series.(sp{k}) = double(res.Y(:, k));
            ids{end+1} = sp{k}; %#ok<AGROW>
        end
    end
end
if numel(ids) < 3
    error('bma:plot:phase3dOutputs', '三维相图需要至少三个输出/状态，当前 %d 个。', numel(ids));
end
xId = ids{1}; yId = ids{2}; zId = ids{3};
if isfield(opts, 'x') && ~isempty(opts.x), xId = char(opts.x); end
if isfield(opts, 'y') && ~isempty(opts.y), yId = char(opts.y); end
if isfield(opts, 'z') && ~isempty(opts.z), zId = char(opts.z); end
if ~isfield(series, xId) || ~isfield(series, yId) || ~isfield(series, zId)
    error('bma:plot:phase3dUnknown', '相图轴不存在：%s / %s / %s', xId, yId, zId);
end
x = series.(xId)(:); y = series.(yId)(:); z = series.(zId)(:);
n = min([numel(x), numel(y), numel(z)]);
x = x(1:n); y = y(1:n); z = z(1:n);
fig = bma.plot.internal.newFigure();
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
plot3(x, y, z, '-', 'LineWidth', 0.8, 'Color', [0.65 0.70 0.78]);
hold on
frac = 0.4;
if isfield(opts, 'transient_fraction') && ~isempty(opts.transient_fraction)
    frac = max(0, min(0.9, double(opts.transient_fraction)));
end
c0 = max(1, floor(frac * n) + 1);
plot3(x(c0:end), y(c0:end), z(c0:end), '-', 'LineWidth', 2.4, 'Color', [0.12 0.42 0.82]);
plot3(x(1), y(1), z(1), 'o', 'MarkerSize', 7, 'MarkerFaceColor', [0.2 0.7 0.3], 'MarkerEdgeColor', 'k');
plot3(x(end), y(end), z(end), 's', 'MarkerSize', 7, 'MarkerFaceColor', [0.85 0.33 0.20], 'MarkerEdgeColor', 'k');
hold off; grid on; view(3);
xlabel(labelOf(m, xId), 'Interpreter', 'none');
ylabel(labelOf(m, yId), 'Interpreter', 'none');
zlabel(labelOf(m, zId), 'Interpreter', 'none');
title(sprintf('三维相图：%s / %s / %s', xId, yId, zId), 'Interpreter', 'none');
try
    legend({'完整轨迹', '后段', '起点', '终点'}, 'Location', 'best');
catch
end
try, bma.plot.internal.styleAxes(gca()); catch, end
p = bma.plot.internal.exportFig(fig, o);
end

function s = labelOf(m, id)
s = id;
if isfield(m, 'species') && any(strcmp(cellstr(m.species), id))
    return
end
if isfield(m, 'outputs') && ~isempty(m.outputs)
    q = find(strcmp({m.outputs.id}, id), 1);
    if ~isempty(q)
        nm = m.outputs(q).name; un = m.outputs(q).unit;
        if isempty(nm), s = id; elseif isempty(un), s = nm; else, s = sprintf('%s (%s)', nm, un); end
    end
end
end
