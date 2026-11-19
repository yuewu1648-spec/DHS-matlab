% test_fit_figure_isolation.m — ISSUE-010 fit figures must not collide
root = bma.util.projectRoot();
work = fullfile(root, '.bma', 'test_tmp', bma.util.newId('fit_iso'));
runDir = fullfile(work, 'run');
bma.util.ensureDir(runDir);
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
m = bma.model.build(spec);
r = bma.model.simulate(m, struct('n', 101));
d = struct('t', r.t, 'Y', r.Y(:, 2), 'outputs', {{'P_obs'}});
opts = struct('work_dir', work, 'run_dir', runDir, ...
    'params_to_fit', {{'kcat'}}, 'multistart', 1, 'max_iter', 3, ...
    'save_artifacts', true);
fr1 = bma.fit.estimate(m, d, opts);
fr2 = bma.fit.estimate(m, d, opts);
assert(~isempty(fr1.figure) && ~isempty(fr2.figure), '拟合图路径为空');
assert(~strcmp(fr1.figure, fr2.figure), '两次拟合图路径相同：%s', fr1.figure);
assert(isfile(fullfile(work, fr1.figure)), '第一次拟合图不存在');
assert(isfile(fullfile(work, fr2.figure)), '第二次拟合图不存在');
assert(contains(fr1.figure, 'fits/') && contains(fr2.figure, 'fits/'), ...
    '拟合图应写入各自 fit 目录');
fprintf('[PASS] fit figure isolation: %s | %s\n', fr1.figure, fr2.figure);
fprintf('[test_fit_figure_isolation] 全部通过\n');
