function fig = newFigure(width, height)
%NEWFIGURE Create a styled, invisible MATLAB figure for headless reporting.
%   fig = bma.plot.internal.newFigure(width, height)
%   Uses MATLAB's own graphics system (figure/axes/plot/exportgraphics), with a
%   consistent white background, Chinese-capable font when available, and
%   compact panel defaults. The caller keeps ownership of closing the figure.
if nargin < 1 || isempty(width), width = 900; end
if nargin < 2 || isempty(height), height = 520; end
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [80 80 width height]);
try
    fn = cjkFontName();
    if ~isempty(fn)
        set(fig, 'DefaultAxesFontName', fn, 'DefaultTextFontName', fn);
    end
    set(fig, 'DefaultAxesFontSize', 10, 'DefaultTextFontSize', 10, ...
        'DefaultLineLineWidth', 1.5, 'DefaultAxesLineWidth', 0.8, ...
        'DefaultAxesBox', 'on', 'DefaultAxesTickDir', 'out', ...
        'DefaultAxesGridAlpha', 0.15);
catch
    % Cosmetic defaults only; never fail a report because of a font.
end
end

function name = cjkFontName()
%CJKFONTNAME Pick an installed font that can render Chinese labels.
candidates = {'Microsoft YaHei', 'SimHei', 'Noto Sans CJK SC', ...
    'Source Han Sans SC', 'Arial Unicode MS'};
name = '';
try
    installed = listfonts();
    for k = 1:numel(candidates)
        if any(strcmpi(installed, candidates{k}))
            name = candidates{k};
            return
        end
    end
catch
end
end
