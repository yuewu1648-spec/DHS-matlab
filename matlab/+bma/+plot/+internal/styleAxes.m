function styleAxes(ax)
%STYLEAXES Apply the shared MATLAB axes style used by all report figures.
%   bma.plot.internal.styleAxes(ax)
%   Keeps the built-in MATLAB look (grid, box, tick direction) consistent
%   across timeseries/fit/phase/profile/sensitivity panels.
if nargin < 1 || isempty(ax)
    ax = gca();
end
try
    set(ax, 'Box', 'on', 'LineWidth', 0.8, 'TickDir', 'out', ...
        'GridAlpha', 0.15, 'FontSize', 10);
catch
end
grid(ax, 'on');
end
