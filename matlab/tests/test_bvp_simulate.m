% test_bvp_simulate.m — 0.9.0 BVP (bvp4c) regression
%
% u'' = -1, u(0)=u(1)=0, solved as the first-order system
% u' = v, v' = -1; exact u(0.5)=0.125.
root = bma.util.projectRoot();
specPath = fullfile(root, 'tests', 'fixtures', 'upgrade', 'bvp', 'poisson_1d.json');
v = bma.spec.validate(specPath);
assert(v.valid, 'BVP spec 校验失败：%s', localFirst(v));
assert(strcmp(v.kind, 'bvp'), 'BVP validate kind 错误');
m = bma.model.build(specPath);
assert(strcmp(m.kind, 'bvp') && m.n_species == 2, 'BVP 编译结构错误');
r = bma.model.simulate(m, struct('n', 101));
assert(r.success && strcmp(r.solver, 'bvp4c'), 'bvp4c 求解失败：%s', strjoin(r.warnings, '; '));
uMid = interp1(r.t, r.Y(:, 1), 0.5);
assert(abs(uMid - 0.125) < 1e-3, 'u(0.5)=%.6g，解析值 0.125', uMid);
fprintf('[PASS] BVP bvp4c: u(0.5)=%.6f\n', uMid);

% Missing BC count is rejected by compile/validation, not silently solved.
bad = bma.spec.load(specPath);
bad.bc = bad.bc(1);
vb = bma.spec.validate(bad);
assert(~vb.valid, 'BC 数量不足未被拒绝');
fprintf('[PASS] BVP BC count gate\n');

uc = bma.spec.checkUnits(specPath);
assert(isfield(uc, 'note') && contains(uc.note, 'BVP'), 'BVP checkUnits 应给明确说明');
threw = false;
try, bma.model.analyze(m); catch err, threw = strcmp(err.identifier, 'bma:bvp:analysisUnsupported'); end
assert(threw, 'BVP analyze 应明确拒绝');
fprintf('[PASS] BVP units note + analyze guard\n');

% BVP simulation-based fit: recover c=1 from the spatial profile.
d = struct('t', r.t, 'Y', r.Y(:, 1), 'outputs', {{'u'}});
fr = bma.fit.estimate(m, d, struct('params_to_fit', {{'c'}}, ...
    'multistart', 1, 'max_iter', 8, 'save_artifacts', false));
assert(abs(fr.params(1).value - 1) < 0.05, 'BVP 拟合 c=%.4f 偏离 1', fr.params(1).value);
fprintf('[PASS] BVP fit: c=%.4f\n', fr.params(1).value);
ia = bma.fit.identifiability(m, d, struct('params_to_fit', {{'c'}}, 'save_artifacts', false));
assert(isfield(ia, 'rank') && ia.rank >= 1, 'BVP identifiability 未返回 rank');
fprintf('[PASS] BVP identifiability: rank=%d\n', ia.rank);
fprintf('[test_bvp_simulate] 全部通过\n');

function e = localFirst(r)
e = 'unknown';
try
    if isfield(r, 'errors') && ~isempty(r.errors)
        e = sprintf('%s: %s', r.errors{1}.code, r.errors{1}.message);
    end
catch
end
end
