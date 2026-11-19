% test_plot_outputs.m — 验证所有绘图函数使用 MATLAB 内置图形系统并产出有效 PNG。
%
% 覆盖：bma.plot.timeseries / phase / fit / profile / sensitivity，
% 以及 bma.plot.internal.exportFig 的 exportgraphics 路径（200 dpi PNG）。
% 断言：文件存在、PNG 魔数正确、大小合理、函数返回后无残留可见 figure。

root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
workDir = fullfile(root, '.bma', 'test_tmp', 'plot_outputs');
if isfolder(workDir)
    rmdir(workDir, 's');
end
mkdir(workDir);

spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
m = bma.model.build(spec);
res = bma.model.simulate(m, struct('time_end', 30, 'n', 101));
opts = struct('work_dir', workDir, 'relative', false, 'dpi', 200);

% --- 1. timeseries ---------------------------------------------------------
p1 = bma.plot.timeseries(m, res, opts);
assertFile(p1, 'timeseries');

% --- 2. phase --------------------------------------------------------------
p2 = bma.plot.phase(m, res, opts);
assertFile(p2, 'phase');

% --- 2a. phase_x/phase_y may name species, not only declared outputs --------
phaseSpec = struct();
phaseSpec.schema_version = 'bma.modelSpec.v1';
phaseSpec.name = 'phase_species_axes';
phaseSpec.kind = 'ode';
phaseSpec.time = struct('unit', '1', 'start', 0, 'end', 30, 'n', 301);
phaseSpec.variables = {struct('id', 'X', 'unit', '1', 'initial', struct('value', 1)), ...
    struct('id', 'Y', 'unit', '1', 'initial', struct('value', 1))};
phaseSpec.parameters = {};
phaseSpec.reactions = {struct('id', 'dX', 'stoichiometry', struct('X', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'Y-X')), ...
    struct('id', 'dY', 'stoichiometry', struct('Y', 1), ...
    'rate', struct('kind', 'expression', 'expression', '-X'))};
phaseSpec.outputs = {struct('id', 'X_obs', 'unit', '1', 'expression', 'X'), ...
    struct('id', 'Y_obs', 'unit', '1', 'expression', 'Y')};
mp = bma.model.build(phaseSpec);
rp = bma.model.simulate(mp, struct('n', 301));
optsP = opts;
optsP.name = 'phase_species.png';
optsP.x = 'X';
optsP.y = 'Y';
p2a = bma.plot.phase(mp, rp, optsP);
assertFile(p2a, 'phase_species');
fprintf('[PASS] phase axes by species id\n');
% ISSUE-003: dispatch must actually return figures for plots:["phase"].
phaseWork = fullfile(workDir, 'phase_dispatch');
bma.util.ensureDir(phaseWork);
outPhase = bma.server.dispatch('model.simulate', struct('spec', phaseSpec, ...
    'options', struct('n', 301, 'plots', {{'phase'}}, 'phase_x', 'X', 'phase_y', 'Y')), ...
    struct('work_dir', phaseWork));
assert(isfield(outPhase, 'figures') && ~isempty(outPhase.figures), ...
    'dispatch plots:["phase"] 未返回 figures');
fprintf('[PASS] dispatch phase figure: %s\n', outPhase.figures{1});

% --- 2c. 3D phase projection (ISSUE-012C) -----------------------------------
phase3 = phaseSpec;
phase3.name = 'phase3_species_axes';
phase3.variables{3} = struct('id', 'Z', 'unit', '1', 'initial', struct('value', 0.5));
phase3.reactions = {struct('id', 'dX', 'stoichiometry', struct('X', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'Y-X')), ...
    struct('id', 'dY', 'stoichiometry', struct('Y', 1), ...
    'rate', struct('kind', 'expression', 'expression', '-X+0.1*Z')), ...
    struct('id', 'dZ', 'stoichiometry', struct('Z', 1), ...
    'rate', struct('kind', 'expression', 'expression', '0.2-X*Z'))};
phase3.outputs = {struct('id', 'X_obs', 'unit', '1', 'expression', 'X'), ...
    struct('id', 'Y_obs', 'unit', '1', 'expression', 'Y'), ...
    struct('id', 'Z_obs', 'unit', '1', 'expression', 'Z')};
m3 = bma.model.build(phase3);
r3 = bma.model.simulate(m3, struct('n', 301));
opts3 = opts;
opts3.name = 'phase3_species.png';
opts3.x = 'X'; opts3.y = 'Y'; opts3.z = 'Z';
p3d = bma.plot.phase3d(m3, r3, opts3);
assertFile(p3d, 'phase3_species');
fprintf('[PASS] 3D phase projection\n');

% --- 2d. oscillator metrics (ISSUE-012A) -----------------------------------
tt = linspace(0, 40, 4001).';
met = bma.model.oscillationMetrics(tt, sin(tt), {'x'}, struct());
assert(met(1).oscillation_exists, '周期信号未被识别为振荡');
assert(abs(met(1).period - 2 * pi) < 0.05, '周期估计错误：%g', met(1).period);
assert(abs(met(1).amplitude - 2) < 0.05, '振幅估计错误：%g', met(1).amplitude);
fprintf('[PASS] oscillation metrics: period=%.4f amplitude=%.3f\n', met(1).period, met(1).amplitude);

% --- 2b. classic limit cycle: phase portrait with highlighted last cycle ----
selkov = struct();
selkov.schema_version = 'bma.modelSpec.v1';
selkov.name = 'selkov_limit_cycle_plot';
selkov.kind = 'ode';
selkov.time = struct('unit', '1', 'start', 0, 'end', 100, 'n', 2001);
selkov.variables = {struct('id', 'x', 'unit', '1', 'initial', struct('value', 1.01)), ...
    struct('id', 'y', 'unit', '1', 'initial', struct('value', 0.975))};
selkov.parameters = {struct('id', 'gamma', 'unit', '1', 'value', struct('value', 2)), ...
    struct('id', 'alpha', 'unit', '1', 'value', struct('value', 1.1))};
selkov.reactions = {struct('id', 'rx', 'stoichiometry', struct('x', 1), ...
    'rate', struct('kind', 'expression', 'expression', '1 - x*y^gamma')), ...
    struct('id', 'ry', 'stoichiometry', struct('y', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'alpha*y*(x*y^(gamma-1)-1)'))};
selkov.outputs = {struct('id', 'x', 'unit', '1', 'expression', 'x'), ...
    struct('id', 'y', 'unit', '1', 'expression', 'y')};
m2 = bma.model.build(selkov);
res2 = bma.model.simulate(m2, struct('n', 2001));
opts2 = opts;
opts2.name = 'phase_limit_cycle.png';
opts2.limit_cycle = true;
p2b = bma.plot.phase(m2, res2, opts2);
assertFile(p2b, 'phase_limit_cycle');
fprintf('[PASS] limit-cycle phase portrait: %s\n', p2b);

% --- 2c. dispatch auto-adds phase for a 2-state model ----------------------
rpcReq = struct('work_dir', workDir);
out = bma.server.dispatch('model.simulate', struct('spec', selkov, ...
    'options', struct('time_end', 100, 'n', 2001)), rpcReq);
assert(isfield(out, 'figures') && numel(out.figures) >= 2, ...
    '2-state simulate 应自动同时生成 timeseries 和 phase');
fprintf('[PASS] dispatch canonical plots: %d figures\n', numel(out.figures));

% --- 3. fit (synthetic fit result; no optimizer run) -----------------------
[tt, ser, ids] = bma.plot.internal.extractSeries(m, res);
colIds = cell(1, numel(ids));
Y = zeros(numel(tt), numel(ids));
for k = 1:numel(ids)
    Y(:, k) = ser.(ids{k})(:);
    colIds{k} = ids{k};
end
Yhat = Y + 0.01 * randn(size(Y));
fr = struct();
fr.spec_name = 'enzyme_mm';
fr.pred = struct('t', tt(:), 'Y', Y, 'Yhat', Yhat, 'colIds', {colIds}, ...
    'colNames', {colIds});
fr.metrics = struct('r2', 0.99, 'rmse', 0.05);
p3 = bma.plot.fit(fr, [], opts);
assertFile(p3, 'fit');

% --- 4. profile (synthetic profile result) --------------------------------
pr = struct();
pr.param = 'kcat';
pr.values = linspace(1.5, 2.5, 21)';
pr.nll = (pr.values - 1.95).^2 / 0.02 + 3;
pr.param_value = 1.95;
pr.ci = struct('low', 1.8, 'high', 2.1, 'threshold', min(pr.nll) + 1.92, 'delta_nll', 1.92);
p4 = bma.plot.profile(pr, opts);
assertFile(p4, 'profile');

% --- 5. sensitivity (local analysis of the built model) --------------------
si = bma.fit.sensitivity(m, struct('method', 'local'));
p5 = bma.plot.sensitivity(si, opts);
assertFile(p5, 'sensitivity');

% --- 6. no figures left open ---------------------------------------------
figs = findall(groot, 'Type', 'figure');
assert(isempty(figs), '绘图函数返回后仍有 %d 个 figure 未关闭', numel(figs));

% --- 7. export uses a real PNG at the requested resolution ----------------
info = imfinfo(p1);
assert(strcmpi(info.Format, 'png'), 'timeseries 不是 PNG');
if isfield(info, 'Width') && isfield(info, 'Height')
    assert(info.Width >= 600 && info.Height >= 200, '示意图分辨率异常：%dx%d', info.Width, info.Height);
end

fprintf('[test_plot_outputs] 全部通过（5 类图 × PNG + figure 清理 + 分辨率）\n');

% ======================================================================
function assertFile(p, label)
assert(ischar(p) && isfile(p), '%s 图未生成：%s', label, p);
d = dir(p);
assert(d.bytes > 3000, '%s 图文件过小（%d bytes）：%s', label, d.bytes, p);
fid = fopen(p, 'r');
assert(fid > 0, '%s 图无法打开：%s', label, p);
sig = fread(fid, 8, 'uint8')';
fclose(fid);
expected = uint8([137 80 78 71 13 10 26 10]);
assert(isequal(sig, expected), '%s 不是合法 PNG：%s', label, p);
fprintf('[test_plot_outputs]   %-12s %s (%d bytes)\n', label, p, d.bytes);
end
