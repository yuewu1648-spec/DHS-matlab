function p = cases(results, names, mOrSpec, opts)
%CASES 多工况对比图：每个输出一个面板，每条工况一条曲线。
%   p = bma.plot.cases(results, names, m, opts)
%
% results  仿真结果 struct 数组 / cell（bma.model.simulate 的返回）
% names    工况名 cellstr（与 results 等长）
% opts     work_dir/out_dir/name/outputs
% 返回相对 work_dir 的 PNG 路径；使用 MATLAB 内置图形系统。
if nargin < 4 || isempty(opts)
    opts = struct();
end
if isstruct(results)
    results = num2cell(results);
end
if ischar(names) || isstring(names)
    names = cellstr(names);
end
if numel(names) ~= numel(results)
    names = arrayfun(@(k) sprintf('case %d', k), 1:numel(results), 'UniformOutput', false);
end
[m, spec] = bma.fit.resolveModel(mOrSpec);
o = bma.plot.internal.resolveOpts(opts, 'cases.png');
if isfield(opts, 'name') && ~isempty(opts.name)
    o = bma.plot.internal.resolveOpts(opts, char(opts.name));
end
outs = {};
try
    [~, ~, outs] = bma.plot.internal.extractSeries(m, results{1});
catch err
    error('bma:plot:casesInput', '无法从第一个工况提取输出序列：%s', err.message);
end
if isfield(opts, 'outputs') && ~isempty(opts.outputs)
    want = cellfun(@char, num2cell(opts.outputs), 'UniformOutput', false);
    outs = outs(ismember(outs, want));
end
nO = min(numel(outs), 4);
if nO < 1
    error('bma:plot:casesNoOutputs', '没有可对比的输出。');
end
fig = bma.plot.internal.newFigure(920, 300 * nO + 120);
cleaner = onCleanup(@() close(fig)); %#ok<NASGU>
tl = tiledlayout(fig, nO, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
colors = [0.15 0.45 0.80; 0.85 0.33 0.20; 0.20 0.65 0.35; ...
    0.55 0.35 0.75; 0.90 0.60 0.10; 0.30 0.70 0.75];
for j = 1:nO
    ax = nexttile(tl, j);
    hold(ax, 'on');
    for k = 1:numel(results)
        try
            [t, ser, ~] = bma.plot.internal.extractSeries(m, results{k});
            y = ser.(outs{j})(:);
            n = min(numel(t), numel(y));
            plot(ax, t(1:n), y(1:n), '-', 'LineWidth', 1.5, ...
                'Color', colors(mod(k - 1, size(colors, 1)) + 1, :));
        catch
        end
    end
    hold(ax, 'off');
    bma.plot.internal.styleAxes(ax);
    title(ax, ['输出 ' outs{j}], 'Interpreter', 'none');
    ylabel(ax, outs{j}, 'Interpreter', 'none');
    if j == nO
        xlabel(ax, '时间', 'Interpreter', 'none');
    end
    legend(ax, names, 'Location', 'best', 'Interpreter', 'none');
end
title(tl, '多工况对比', 'Interpreter', 'none');
p = bma.plot.internal.exportFig(fig, o);
end
