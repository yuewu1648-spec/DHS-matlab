function p = timeseries(mOrSpec, res, opts)
%TIMESERIES 绘制模型仿真输出时间序列。
%   p = bma.plot.timeseries(m, res, opts)
%
% m 为 build 结果（或 spec），res 为 bma.model.simulate 或
% bma.fit.simulatePredictions 的返回。opts.outputs 可筛选输出；
% opts.out_dir / opts.name / opts.work_dir 控制产物位置。
% 返回相对 work_dir 的 PNG 路径（opts.relative=false 时返回绝对路径）。

if nargin < 3 || isempty(opts)
    opts = struct();
end
[m, spec] = bma.fit.resolveModel(mOrSpec);
o = bma.plot.internal.resolveOpts(opts, 'timeseries.png');
[t, series, ids] = bma.plot.internal.extractSeries(m, res);
if isempty(ids)
    error('bma:plot:noOutputs', '模型没有可绘制的 output。');
end
if isfield(opts, 'outputs') && ~isempty(opts.outputs)
    want = toCellstr(opts.outputs);
    ids = ids(ismember(ids, want));
end
if isempty(ids)
    error('bma:plot:noSelectedOutputs', '所选 outputs 没有可绘制序列。');
end
nO = min(numel(ids), 6);

fig = bma.plot.internal.newFigure(920, 190 * nO + 130);
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
tl = tiledlayout(fig, nO, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
for j = 1:nO
    id = ids{j};
    ax = nexttile(tl, j);
    plot(ax, t, series.(id), 'LineWidth', 1.6, 'Color', lineColor(j));
    bma.plot.internal.styleAxes(ax);
    ylabel(ax, shortAxisLabel(spec, id), 'Interpreter', 'none');
    title(ax, wrapLabel(outputTitle(spec, id), 28), 'Interpreter', 'none');
    if j == nO
        xlabel(ax, timeAxisLabel(spec), 'Interpreter', 'none');
    end
end
titleStr = '模型输出时间序列';
if isfield(spec, 'title') && ~isempty(spec.title)
    titleStr = char(spec.title);
end
try
    title(tl, titleStr, 'Interpreter', 'none');
catch
    sgtitle(fig, titleStr, 'Interpreter', 'none');
end
p = bma.plot.internal.exportFig(fig, o);
end

% ======================================================================
function c = lineColor(j)
palette = [0.15 0.45 0.80; 0.85 0.33 0.20; 0.20 0.65 0.35; ...
    0.55 0.35 0.75; 0.90 0.60 0.10; 0.30 0.70 0.75];
c = palette(mod(j - 1, size(palette, 1)) + 1, :);
end

function s = shortAxisLabel(spec, id)
% Keep the y-axis short: id + unit. Long human descriptions move to title
% (ISSUE-018: 10-output CJK labels overlapped).
s = id;
if isfield(spec, 'outputs') && ~isempty(spec.outputs)
    q = find(strcmp({spec.outputs.id}, id), 1);
    if ~isempty(q) && isfield(spec.outputs(q), 'unit') && ~isempty(spec.outputs(q).unit)
        s = sprintf('%s [%s]', id, char(spec.outputs(q).unit));
    end
end
end

function s = outputTitle(spec, id)
s = id;
if isfield(spec, 'outputs') && ~isempty(spec.outputs)
    q = find(strcmp({spec.outputs.id}, id), 1);
    if ~isempty(q) && isfield(spec.outputs(q), 'name') && ~isempty(spec.outputs(q).name)
        s = char(spec.outputs(q).name);
    end
end
end

function s = wrapLabel(s, width)
s = char(s);
if numel(s) <= width
    return
end
parts = {};
while numel(s) > width
    cut = width;
    parts{end+1} = strtrim(s(1:cut)); %#ok<AGROW>
    s = strtrim(s(cut+1:end));
end
parts{end+1} = s;
s = strjoin(parts, newline);
end

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

function s = timeAxisLabel(spec)
s = 'time';
if isfield(spec, 'time') && isstruct(spec.time) && isfield(spec.time, 'unit') ...
        && ~isempty(spec.time.unit)
    s = sprintf('时间 (%s)', char(spec.time.unit));
end
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
