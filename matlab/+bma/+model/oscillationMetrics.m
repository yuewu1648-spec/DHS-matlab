function met = oscillationMetrics(t, Y, names, opts)
%OSCILLATIONMETRICS Period/amplitude/min/max/mean from the late-time trace.
%   met = bma.model.oscillationMetrics(t, Y, names, opts)
%
% Used for oscillator models where end-time values are phase-dependent.
% Peak detection is deliberately dependency-free (no Signal Processing
% Toolbox); it expects an approximately periodic late segment.
if nargin < 4 || isempty(opts), opts = struct(); end
if nargin < 3 || isempty(names), names = arrayfun(@(k) sprintf('y%d', k), 1:size(Y, 2), 'UniformOutput', false); end
t = double(t(:));
Y = double(Y);
n = min(numel(t), size(Y, 1));
t = t(1:n); Y = Y(1:n, :);
met = struct('id', {}, 'period', {}, 'amplitude', {}, 'min', {}, 'max', ...
    {}, 'mean', {}, 'oscillation_exists', {}, 'n_cycles', {}, 'peak_times', {});
frac = 0.5;
if isfield(opts, 'late_fraction') && ~isempty(opts.late_fraction)
    frac = max(0, min(0.9, double(opts.late_fraction)));
end
start = max(2, floor(frac * n) + 1);
for j = 1:size(Y, 2)
    y = Y(:, j);
    tail = y(start:end);
    tt = t(start:end);
    if isempty(tail) || any(~isfinite(tail))
        p = NaN; amp = NaN; nCyc = 0; peaks = [];
    else
        peaks = find(tail(2:end-1) > tail(1:end-2) & tail(2:end-1) >= tail(3:end)) + 1;
        % Drop peaks too close to the start/end of the late segment.
        peaks = peaks(peaks > 1 & peaks < numel(tail));
        nCyc = numel(peaks);
        if nCyc >= 2
            p = median(diff(tt(peaks)));
            amp = max(tail) - min(tail);
        else
            p = NaN; amp = max(tail) - min(tail);
        end
    end
    met(end+1) = struct('id', char(names{j}), 'period', p, 'amplitude', amp, ...
        'min', min(tail), 'max', max(tail), 'mean', mean(tail), ...
        'oscillation_exists', nCyc >= 2 && isfinite(p) && p > 0 && amp > 1e-10 * max(1, max(abs(tail))), ...
        'n_cycles', nCyc, 'peak_times', tt(peaks)); %#ok<AGROW>
end
end
