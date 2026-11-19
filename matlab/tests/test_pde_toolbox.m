% test_pde_toolbox.m — 0.8.0 native 2D PDE Toolbox path
%
% 覆盖：2D rectangle 瞬态、probe 时间序列、field stats、CSV/PNG、校验路由、
% 多组分 c 向量、预算拒绝、circle 几何。该路径不做 MOL 展开。
root = bma.util.projectRoot();
fix = fullfile(root, 'tests', 'fixtures', 'upgrade', 'pde_toolbox');

% ---------- 1) 2D rectangle decay ----------------------------------------
specPath = fullfile(fix, 'rectangle_2d.json');
vr = bma.spec.validate(specPath);
assert(vr.valid, '2D native spec 校验失败：%s', localFirst(vr));
assert(strcmp(vr.kind, 'pde') && isfield(vr, 'normalized_spec'), '2D validate 路由错误');
runDir = fullfile(root, '.bma', 'test_tmp', bma.util.newId('pde_toolbox_2d'));
bma.util.ensureDir(runDir);
r = bma.pde.simulate(specPath, struct('run_dir', runDir, 'work_dir', root, ...
    'max_dof', 50000, 'max_seconds', 120));
assert(r.success && strcmp(r.solver, 'pde_toolbox'), '2D PDE Toolbox 求解失败');
assert(r.stats.nodes > 100 && r.stats.elements > 100, '网格规模异常');
assert(numel(r.t) == 11 && numel(r.probes) == 1, '时间点/probe 数量异常');
v = r.probes{1}.values;
assert(all(isfinite(v)), 'probe 含 NaN/Inf');
assert(v(1) > 0.99 && v(end) < v(1), 'probe 未按预期衰减');
assert(isfile(r.timeseries_path), '缺少 PDE 时间序列 CSV');
assert(~isempty(dir(fullfile(runDir, 'figures', '*.png'))), '缺少 PDE 图');
assert(abs(r.field_stats(1).max(1) - 1) < 1e-6, 'field max 初值异常');
fprintf('[PASS] 2D PDE Toolbox: nodes=%d elems=%d probe_end=%.4g CSV+PNG\n', ...
    r.stats.nodes, r.stats.elements, v(end));

% ---------- 2) 多组分 native（c 为列向量） --------------------------------
spec = struct();
spec.schema_version = 'bma.modelSpec.v1';
spec.name = 'pde2d_two_species';
spec.kind = 'pde';
spec.time = struct('unit', 's', 'start', 0, 'end', 0.5, 'n', 6);
spec.variables = {struct('id', 'A', 'unit', '1', 'initial', struct('value', 1)), ...
    struct('id', 'B', 'unit', '1', 'initial', struct('value', 0))};
spec.pde = struct();
spec.pde.dim = 2;
spec.pde.solver = 'toolbox';
spec.pde.domain = struct('geometry', 'rectangle', 'size', [1 1], ...
    'mesh', struct('hmax', 0.25), 'approximation', 'two species');
spec.pde.diffusion = {struct('species', 'A', 'coeff', 'Da'), ...
    struct('species', 'B', 'coeff', 'Db')};
spec.pde.bc = {struct('edge', 'all', 'type', 'dirichlet', 'value', 0)};
spec.pde.probes = {struct('id', 'A_center', 'species', 'A', 'x', 0.5, 'y', 0.5), ...
    struct('id', 'B_center', 'species', 'B', 'x', 0.5, 'y', 0.5)};
spec.parameters = {struct('id', 'Da', 'unit', 'um^2/s', 'value', struct('value', 0.1)), ...
    struct('id', 'Db', 'unit', 'um^2/s', 'value', struct('value', 0.2)), ...
    struct('id', 'k', 'unit', '1/s', 'value', struct('value', 1))};
spec.reactions = {struct('id', 'convert', 'stoichiometry', struct('A', -1, 'B', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'k*A'))};
vr = bma.spec.validate(spec);
assert(vr.valid, '多组分 native spec 校验失败：%s', localFirst(vr));
r2 = bma.pde.simulate(spec, struct('run_dir', fullfile(runDir, 'two_species'), ...
    'work_dir', root, 'max_dof', 50000));
assert(r2.success && numel(r2.probes) == 2, '多组分 native 求解失败');
assert(all(isfinite(r2.probes{1}.values)) && all(isfinite(r2.probes{2}.values)), ...
    '多组分 probe 含 NaN');
assert(r2.probes{2}.values(end) > 0, 'B 未被生成');
fprintf('[PASS] 2D two-species: A_end=%.4g B_end=%.4g\n', ...
    r2.probes{1}.values(end), r2.probes{2}.values(end));

% ---------- 3) circle 几何 -------------------------------------------------
spec3 = spec;
spec3.name = 'pde2d_circle';
spec3.pde.domain = struct('geometry', 'circle', 'radius', 0.5, ...
    'mesh', struct('hmax', 0.2));
r3 = bma.pde.simulate(spec3, struct('run_dir', fullfile(runDir, 'circle'), ...
    'work_dir', root, 'max_dof', 50000));
assert(r3.success && r3.pde.geometry == "circle", 'circle 几何求解失败');
fprintf('[PASS] 2D circle: nodes=%d\n', r3.stats.nodes);

% ---------- 4) 3D box（geometryFromMesh + PDE Toolbox） -------------------
spec3d = fullfile(fix, 'box_3d.json');
v3d = bma.spec.validate(spec3d);
assert(v3d.valid, '3D box spec 校验失败：%s', localFirst(v3d));
r3d = bma.pde.simulate(spec3d, struct('run_dir', fullfile(runDir, 'box3d'), ...
    'work_dir', root, 'max_dof', 50000));
assert(r3d.success && r3d.pde.dim == 3 && r3d.stats.nodes > 100, '3D box 求解失败');
assert(all(isfinite(r3d.probes{1}.values)), '3D probe 含 NaN');
fprintf('[PASS] 3D box: nodes=%d elems=%d probe_end=%.4g\n', ...
    r3d.stats.nodes, r3d.stats.elements, r3d.probes{1}.values(end));

% ---------- 5) 预算拒绝 ----------------------------------------------------
budgetFailed = false;
try
    bma.pde.simulate(specPath, struct('run_dir', fullfile(runDir, 'budget'), ...
        'work_dir', root, 'max_dof', 10));
catch err
    budgetFailed = ~isempty(strfind(err.identifier, 'budget'));
end
assert(budgetFailed, 'max_dof 预算未触发');
fprintf('[PASS] PDE Toolbox budget gate (max_dof)\n');

fprintf('[test_pde_toolbox] 全部通过\n');

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
