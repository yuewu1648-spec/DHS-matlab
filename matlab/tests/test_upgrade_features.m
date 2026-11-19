% test_upgrade_features.m — 0.3.0 升级能力回归（issue ISS-01/03/07/08/09 + 报告）
%
% 覆盖：
%   - 代数/辅助变量（kind=algebraic）编译与仿真（ISS-03）
%   - signed 变量不触发负浓度告警（ISS-09）
%   - 热力学/功率/压强/质量摩尔浓度单位可校验（ISS-08）
%   - 数值 min/max 护栏在符号稳态前被剥离（ISS-07）
%   - Sobol 预算前置拒绝（ISS-01，绝不长时间运行）
%   - report extra_sections 正文完整渲染 + 多 evidence 不崩溃（ISS-04/05）

root = bma.util.projectRoot();
workRoot = fullfile(root, '.bma', 'test_tmp', bma.util.newId('upgrade'));
bma.util.ensureDir(workRoot);

% ---------- 1. 代数变量 ----------------------------------------------------
auxSpec = struct();
auxSpec.schema_version = 'bma.modelSpec.v1';
auxSpec.name = 'aux_demo';
auxSpec.kind = 'ode';
auxSpec.time = struct('unit', 's', 'start', 0, 'end', 10, 'n', 51);
auxSpec.variables = {
    struct('id', 'S', 'name', '底物', 'unit', 'uM', 'initial', struct('value', 10))
    struct('id', 'P', 'name', '产物', 'unit', 'uM', 'initial', struct('value', 0))
    struct('id', 'Km', 'kind', 'algebraic', 'name', '米氏常数', 'unit', 'uM', ...
        'expression', '(kr + kcat) / kf')
    struct('id', 'Vmax', 'kind', 'algebraic', 'name', '最大速率', 'unit', 'uM/s', ...
        'expression', 'kcat * S / Km')};
auxSpec.parameters = {
    struct('id', 'kf', 'unit', '1/(uM*s)', 'value', struct('value', 0.5), ...
        'estimate', true, 'bounds', [0.001 100])
    struct('id', 'kr', 'unit', '1/s', 'value', struct('value', 0.1), ...
        'estimate', true, 'bounds', [1e-4 100])
    struct('id', 'kcat', 'unit', '1/s', 'value', struct('value', 2), ...
        'estimate', true, 'bounds', [1e-4 1000])};
auxSpec.reactions = {struct('id', 'conv', 'name', '转化', ...
    'stoichiometry', struct('S', -1, 'P', 1), ...
    'rate', struct('kind', 'expression', 'expression', 'Vmax * S / (Km + S)'))};
auxSpec.outputs = {struct('id', 'P_obs', 'unit', 'uM', 'expression', 'P')};
rep = bma.spec.validate(auxSpec, root);
assert(rep.valid, 'aux 规格校验失败：%s', strjoin(cellfun(@(e) e.message, rep.errors, 'UniformOutput', false), '；'));
assert(rep.summary.n_species == 2 && rep.summary.n_algebraic == 2, ...
    'aux 计数错误：%d states / %d algebraic', rep.summary.n_species, rep.summary.n_algebraic);
m = bma.model.build(auxSpec);
assert(isequal(m.species, {'S', 'P'}) && numel(m.aux.ids) == 2, 'aux 编译结果错误');
res = bma.model.simulate(m, struct('n', 51, 'run_dir', workRoot));
assert(res.success && isfinite(res.outputs(1).final) && res.outputs(1).final > 0, ...
    'aux 模型仿真失败');
fprintf('[PASS] algebraic variables: 2 states + 2 aux, P_end=%.4f\n', res.outputs(1).final);

% ---------- 2. signed 变量 -------------------------------------------------
sigSpec = struct();
sigSpec.schema_version = 'bma.modelSpec.v1';
sigSpec.name = 'signed_demo';
sigSpec.kind = 'ode';
sigSpec.time = struct('unit', 's', 'start', 0, 'end', 5, 'n', 21);
sigSpec.variables = struct('id', 'dG', 'unit', 'kJ/mol', 'signed', true, ...
    'initial', struct('value', -30));
sigSpec.parameters = struct('id', 'k', 'unit', '1/s', 'value', struct('value', 0.1), ...
    'estimate', false);
sigSpec.reactions = struct('id', 'drift', 'stoichiometry', struct('dG', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('dG', 1)));
sigSpec.outputs = struct('id', 'dG_obs', 'unit', 'kJ/mol', 'expression', 'dG');
rep2 = bma.spec.validate(sigSpec, root);
assert(rep2.valid, 'signed 规格校验失败');
m2 = bma.model.build(sigSpec);
res2 = bma.model.simulate(m2, struct('n', 21));
neg = res2.warnings(~cellfun(@isempty, strfind(res2.warnings, '负浓度')));
assert(isempty(neg), 'signed 变量仍触发负浓度告警');
fprintf('[PASS] signed variable: negative values allowed without warning\n');

% ---------- 3. 热力学/功率/压强/质量摩尔浓度单位 ---------------------------
unitSpec = sigSpec;
unitSpec.name = 'units_demo';
unitSpec.variables = struct('id', 'X', 'unit', 'uM', 'initial', struct('value', 1));
unitSpec.parameters = {
    struct('id', 'dG', 'unit', 'kJ/mol', 'value', struct('value', -30), ...
        'estimate', false, 'bounds', [-100 100])
    struct('id', 'pwr', 'unit', 'W/kg', 'value', struct('value', 2.5), 'estimate', false)
    struct('id', 'pres', 'unit', 'mmHg', 'value', struct('value', 40), 'estimate', false)
    struct('id', 'molal', 'unit', 'mmol/kg', 'value', struct('value', 5), 'estimate', false)
    struct('id', 'k', 'unit', '1/s', 'value', struct('value', 0.1), ...
        'estimate', true, 'bounds', [0.001 10])};
unitSpec.reactions = struct('id', 'decay', 'stoichiometry', struct('X', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('X', 1)));
unitSpec.outputs = struct('id', 'X_obs', 'unit', 'uM', 'expression', 'X');
rep3 = bma.spec.validate(unitSpec, root);
assert(rep3.valid && rep3.units_check.ok, '热力学单位校验失败：%s', rep3.units_check.note);
fprintf('[PASS] units: J/kJ/mol/W/kg/mmHg/mmol/kg accepted, units_ok=1\n');

% ---------- 4. min/max 护栏剥离（符号稳态） -------------------------------
guardSpec = struct();
guardSpec.schema_version = 'bma.modelSpec.v1';
guardSpec.name = 'guard_demo';
guardSpec.kind = 'ode';
guardSpec.time = struct('unit', 's', 'start', 0, 'end', 5, 'n', 21);
guardSpec.variables = struct('id', 'X', 'unit', 'uM', 'initial', struct('value', 1));
guardSpec.parameters = struct('id', 'k', 'unit', '1/s', 'value', struct('value', 0.2), ...
    'estimate', false);
guardSpec.reactions = struct('id', 'decay', 'stoichiometry', struct('X', -1), ...
    'rate', struct('kind', 'expression', 'expression', 'max(k, 0.01) * X'));
guardSpec.outputs = struct('id', 'X_obs', 'unit', 'uM', 'expression', 'X');
mg = bma.model.build(guardSpec);
ag = bma.model.analyze(mg, struct('multistart', 4));
assert(isfield(ag, 'guard_substitution') && ...
    numel(ag.guard_substitution.stripped) >= 1, '未剥离数值护栏');
fprintf('[PASS] guard substitution: %d numeric guard(s) stripped for symbolic path\n', ...
    numel(ag.guard_substitution.stripped));

% ---------- 5. Sobol 预算前置拒绝 -----------------------------------------
mEnz = bma.model.build(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
si = bma.fit.sensitivity(mEnz, struct('method', 'sobol', 'sobol_n', 128, ...
    'budget_seconds', 1e-6, 'work_dir', root, 'run_dir', workRoot));
assert(isfield(si, 'skipped') && si.skipped, 'Sobol 预算超限未跳过');
assert(isfield(si, 'budget') && si.budget.estimated_seconds > 0, '缺少预算估计');
assert(isempty(si.sobol) || ~isfield(si.sobol, 'first') || isempty(si.sobol.first), ...
    '预算超限时不应产生 Sobol 指数');
fprintf('[PASS] Sobol budget: skipped (estimated %.1f s > %.0e s)\n', ...
    si.budget.estimated_seconds, si.budget.budget_seconds);

% ---------- 6. report extra sections + 多 evidence -------------------------
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
spec.parameters(1).evidence = {struct('type', 'measured', 'quote', 'paper A', ...
    'section_id', 's1'), struct('type', 'derived', 'quote', 'derived B', ...
    'section_id', 's2')};
runDir = fullfile(workRoot, 'report');
bma.util.ensureDir(runDir);
extra = {struct('title', '补充：热力学一致性', 'markdown', sprintf( ...
    '# 检查\n\n- ΔG = -30 kJ/mol\n\n| 参数 | 值 |\n|---|---|\n| dG | -30 |\n\n```\ncheck = dG + 30\n```'))};
rr = bma.report.build(runDir, spec, [], [], struct('title', '升级测试报告', ...
    'work_dir', root, 'extra_sections', extra));
html = bma.util.readText(fullfile(root, rr.report_html));
md = bma.util.readText(fullfile(root, rr.report_md));
assert(~isempty(strfind(html, '<h2>检查</h2>')), 'extra section 标题未渲染为 Markdown');
assert(~isempty(strfind(html, 'ΔG = -30 kJ/mol')), 'extra section 正文丢失');
assert(~isempty(strfind(html, '<table')), 'extra section 表格未渲染');
assert(~isempty(strfind(md, 'ΔG = -30 kJ/mol')), 'Markdown 报告正文丢失');
card = bma.util.readJson(fullfile(root, rr.model_card_path));
assert(numel(card.parameters(1).evidence) == 2, '多 evidence 未全部进入模型卡');
assert(~isempty(strfind(html, 'paper A')), '模型卡/报告缺少 evidence quote');
fprintf('[PASS] report: extra markdown body + 2 evidence entries rendered\n');

fprintf('[test_upgrade_features] 全部通过\n');
