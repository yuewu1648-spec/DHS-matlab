% test_dde_simulate.m — 0.9.0 DDE (constant-delay dde23) regression
%
% Covers validation/compile/simulate, output series, dispatch path, delay unit
% rejection, checkUnits note, and analyze guard.
root = bma.util.projectRoot();
specPath = fullfile(root, 'tests', 'fixtures', 'upgrade', 'dde', 'delayed_feedback.json');
v = bma.spec.validate(specPath);
assert(v.valid, 'DDE spec 校验失败：%s', localFirst(v));
assert(strcmp(v.kind, 'dde'), 'DDE validate kind 错误');
assert(isfield(v, 'units_check') && v.units_check.ok && v.units_check.applicable == false, ...
    'DDE 未检查量纲必须标记 applicable=false/ok=true，而不是 ok=false');
m = bma.model.build(specPath);
assert(strcmp(m.kind, 'dde') && m.n_species == 1, 'DDE 编译结构错误');
assert(isequal(m.delays, 2), 'delay 值错误');
r = bma.model.simulate(m, struct('n', 201));
assert(r.success && strcmp(r.solver, 'dde23'), 'dde23 求解失败：%s', strjoin(r.warnings, '; '));
assert(all(isfinite(r.Y(:))) && all(isfinite([r.outputs.final])), 'DDE 输出含 NaN/Inf');
assert(r.outputs(1).final > 0 && r.outputs(1).final < 1, 'DDE 衰减结果不合理');
fprintf('[PASS] DDE dde23: final=%.5f solver=%s\n', r.outputs(1).final, r.solver);

% ISSUE-001: a constant-valued expression delay must behave exactly like lag.
exprPath = fullfile(root, 'tests', 'fixtures', 'upgrade', 'dde', 'delayed_feedback_expr.json');
me = bma.model.build(exprPath);
re = bma.model.simulate(me, struct('n', 201));
assert(strcmp(me.mode, 'constant'), '常量表达式延迟应归一到 dde23（实际 mode=%s）', me.mode);
dEq = max(abs(re.Y(:, 1) - r.Y(:, 1)));
assert(dEq < 1e-10, '表达式延迟 vs 常量 lag 轨迹不一致：maxdiff=%g', dEq);
fprintf('[PASS] DDE expression-delay equivalence: maxdiff=%.2e\n', dEq);

% Tool/dispatch path: build + simulate through the model.simulate switch.
workDir = fullfile(root, '.bma', 'test_tmp', bma.util.newId('dde_dispatch'));
bma.util.ensureDir(workDir);
out = bma.server.dispatch('model.simulate', struct('spec', bma.spec.load(specPath), ...
    'options', struct('n', 201)), struct('work_dir', workDir));
assert(isfield(out, 'outputs') && ~isempty(out.outputs), 'dispatch DDE 输出缺失');
assert(isfield(out, 'timeseries_path'), 'dispatch DDE 缺少 CSV');
fprintf('[PASS] DDE dispatch + CSV\n');

% Delay unit mismatch must be rejected (no silent conversion in v1).
bad = bma.spec.load(specPath);
bad.delays(1).unit = 's';
vb = bma.spec.validate(bad);
assert(~vb.valid && vb.n_errors >= 1, 'delay 单位不一致未被拒绝');
fprintf('[PASS] DDE delay unit gate\n');

uc = bma.spec.checkUnits(specPath);
assert(isfield(uc, 'note') && contains(uc.note, 'DDE'), 'DDE checkUnits 应给明确说明');
assertThrows(@() bma.model.analyze(m), 'bma:dde:analysisUnsupported');
fprintf('[PASS] DDE units note + analyze guard\n');

% ddesd: state/time-dependent delay
sdPath = fullfile(root, 'tests', 'fixtures', 'upgrade', 'dde', 'state_dependent.json');
vs = bma.spec.validate(sdPath);
assert(vs.valid, 'ddesd spec 校验失败：%s', localFirst(vs));
ms = bma.model.build(sdPath);
rs = bma.model.simulate(ms, struct('n', 201));
assert(rs.success && strcmp(rs.solver, 'ddesd') && all(isfinite(rs.Y(:))), ...
    'ddesd 求解失败：%s', strjoin(rs.warnings, '; '));
fprintf('[PASS] ddesd state-dependent delay: final=%.5f\n', rs.outputs(1).final);

% ddensd: neutral DDE with derivative delay (tStart > tau)
nPath = fullfile(root, 'tests', 'fixtures', 'upgrade', 'dde', 'neutral.json');
vn = bma.spec.validate(nPath);
assert(vn.valid, 'ddensd spec 校验失败：%s', localFirst(vn));
mn = bma.model.build(nPath);
rn = bma.model.simulate(mn, struct('n', 201));
assert(rn.success && strcmp(rn.solver, 'ddensd') && all(isfinite(rn.Y(:))), ...
    'ddensd 求解失败：%s', strjoin(rn.warnings, '; '));
fprintf('[PASS] ddensd neutral DDE: final=%.5f\n', rn.outputs(1).final);

% DDE simulation-based fit (no analytic sensitivity) and identifiability
d = struct('t', r.t(1:10:end), 'Y', r.Y(1:10:end, 1), 'outputs', {{'x'}});
fr = bma.fit.estimate(m, d, struct('params_to_fit', {{'k'}}, 'multistart', 1, ...
    'max_iter', 8, 'save_artifacts', false));
assert(abs(fr.params(1).value - 0.5) < 0.1, 'DDE 拟合 k=%.3f 偏离 0.5', fr.params(1).value);
fprintf('[PASS] DDE fit (simulation objective): k=%.4f\n', fr.params(1).value);
ia = bma.fit.identifiability(m, d, struct('params_to_fit', {{'k', 'd'}}, ...
    'save_artifacts', false));
assert(isfield(ia, 'rank') && ia.rank >= 1, 'DDE identifiability 未返回 rank');
fprintf('[PASS] DDE identifiability: rank=%d\n', ia.rank);
iaAlias = bma.fit.identifiability(m, d, struct('param', 'k', ...
    'save_artifacts', false));
assert(isfield(iaAlias, 'rank') && iaAlias.rank >= 1, 'options.param 别名未生效');
pr = bma.fit.profile(m, d, [], 'k', struct('n_points', 3, 'max_iter', 3, ...
    'save_artifacts', false));
assert(numel(pr.values) >= 3, 'profile likelihood 未产出扫描点');
fprintf('[PASS] DDE identifiability param alias + profile: n=%d\n', numel(pr.values));

% Standalone DDE code generation (constant/state-dependent/neutral).
codeRoot = fullfile(root, '.bma', 'test_tmp', bma.util.newId('dde_codegen'));
for item = {m, ms, mn}
    mi = item{1};
    cr = bma.codegen.model(mi, codeRoot);
    assert(isfile(cr.m_file) && isfile(cr.run_file), 'DDE codegen 文件缺失');
    addpath(cr.code_dir);
    [ct, cY, cO] = feval(cr.run_function_name);
    assert(numel(ct) >= 5 && all(isfinite(cY(:))) && all(isfinite(cO(:))), ...
        '生成的 DDE 代码运行失败');
end
fprintf('[PASS] DDE codegen: dde23/ddesd/ddensd templates\n');
fprintf('[test_dde_simulate] 全部通过\n');

% =========================================================================
function e = localFirst(r)
e = 'unknown';
try
    if isfield(r, 'errors') && ~isempty(r.errors)
        e = sprintf('%s: %s', r.errors{1}.code, r.errors{1}.message);
    end
catch
end
end

function assertThrows(fn, id)
threw = false;
try
    fn();
catch err
    threw = strcmp(err.identifier, id);
end
assert(threw, '应抛出 %s', id);
end
