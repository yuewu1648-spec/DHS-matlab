% test_upgrade_050.m — 0.5.0 升级回归（Buchwald 2009 issue I1/I2/I4/I5/I6/I7/I8）
%
% 覆盖：
%   - analyze 符号难度预判 + 数值降级（不进入 vpasolve 长搜索）
%   - report extra_sections 文件路径 + Markdown 图片内嵌
%   - bma.run.importArtifact 把 run_dir 外产物导入 artifacts/ 并登记 SHA-256
%   - bma.run.waiveGate 记录质量门豁免，报告/model card 显式呈现
%   - 双栏碎片标题的 section_confidence=low
%   - 新 KB 条目可检索
root = bma.util.projectRoot();
workRoot = fullfile(root, '.bma', 'test_tmp', bma.util.newId('upgrade050'));
bma.util.ensureDir(workRoot);
runDir = fullfile(workRoot, '.bma', 'runs', 'r-050');
bma.util.ensureDir(runDir);

% ---------- 1. analyze 符号难度预判：8 状态开放链 --------------------------
spec8 = struct();
spec8.schema_version = 'bma.modelSpec.v1';
spec8.name = 'chain8_numeric_fallback';
spec8.title = '8 状态开放链（符号求解应被预判跳过）';
spec8.kind = 'ode';
spec8.time = struct('unit', 's', 'start', 0, 'end', 10, 'n', 21);
vars = cell(1, 8);
for i = 1:8
    vars{i} = struct('id', sprintf('X%d', i), 'name', sprintf('状态 %d', i), ...
        'unit', 'uM', 'initial', struct('value', 10 - i));
end
spec8.variables = vars;
spec8.parameters = {struct('id', 'k', 'name', '速率常数', 'unit', '1/s', ...
    'value', struct('value', 0.1), 'estimate', false)};
reactions = cell(1, 8);
for i = 1:7
    reactions{i} = struct('id', sprintf('r%d', i), 'name', sprintf('转移 %d', i), ...
        'stoichiometry', struct(sprintf('X%d', i), -1, sprintf('X%d', i + 1), 1), ...
        'rate', struct('kind', 'mass_action', ...
        'parameters', struct('k', 'k'), ...
        'species', struct(sprintf('X%d', i), 1)));
end
reactions{8} = struct('id', 'r8', 'name', '降解', ...
    'stoichiometry', struct('X8', -1), ...
    'rate', struct('kind', 'mass_action', 'parameters', struct('k', 'k'), ...
    'species', struct('X8', 1)));
spec8.reactions = reactions;
spec8.outputs = {struct('id', 'X1_obs', 'name', 'X1', 'unit', 'uM', 'expression', 'X1')};
rep8 = bma.spec.validate(spec8, workRoot);
assert(rep8.valid, '8 状态规格校验失败：%s', ...
    strjoin(cellfun(@(e) e.message, rep8.errors, 'UniformOutput', false), '；'));
m8 = bma.model.build(spec8);
t0 = tic;
a8 = bma.model.analyze(m8, struct('run_dir', runDir, 'multistart', 4, ...
    'numeric_budget_seconds', 30));
elapsed = toc(t0);
assert(a8.symbolic_skipped, '8 状态模型未跳过符号求解');
assert(strcmp(a8.analysis_mode, 'numeric_fallback'), ...
    'analysis_mode 应为 numeric_fallback，实际 %s', a8.analysis_mode);
assert(~isempty(strfind(a8.symbolic.reason, '状态数')), ...
    'symbolic.reason 应说明状态数超限，实际：%s', a8.symbolic.reason);
assert(elapsed < 60, 'analyze 数值降级耗时过长：%.1f s', elapsed);
fprintf('[PASS] analyze numeric fallback: 8 states, %.1fs, reason=%s\n', ...
    elapsed, a8.symbolic.reason);

% ---------- 2. report extra_sections 文件路径 + 图片内嵌 -------------------
spec = bma.util.readJson(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
imgDir = fullfile(workRoot, 'external_src');
bma.util.ensureDir(imgDir);
imgPath = fullfile(imgDir, 'extra_curve.png');
imwrite(uint8(255 * ones(24, 24, 3)), imgPath);
sectionDoc = struct('title', '图像测试', 'markdown', ...
    sprintf('![x](%s)\n\n这是一段从 JSON 文件读入的正文。', imgPath));
sectionJson = fullfile(workRoot, 'report_sections.json');
bma.util.writeJsonAtomic(sectionJson, sectionDoc);
opts = struct();
opts.title = '0.5.0 报告图片测试';
opts.extra_sections = {sectionJson};
r = bma.report.build(runDir, spec, [], [], opts);
htmlPath = bma.util.absPath(workRoot, r.report_html);
mdPath = bma.util.absPath(workRoot, r.report_md);
html = fileread(htmlPath);
md = fileread(mdPath);
assert(~isempty(strfind(html, 'data:image/png;base64,')), ...
    'report.html 未内嵌 extra_sections 图片');
assert(~isempty(strfind(html, 'alt="x"')), 'report.html 未渲染 <img alt="x">');
assert(isempty(strfind(html, imgPath)), ...
    'report.html 仍泄漏 run_dir 之外的绝对图片路径');
assert(~isempty(strfind(md, 'figures/extra_1_')), ...
    'report.md 未使用 report/figures 相对路径');
fprintf('[PASS] report extra_sections path + image embedding (%d warnings)\n', numel(r.warnings));

% ---------- 3. artifact import ---------------------------------------------
artSrc = fullfile(imgDir, 'fig_art.png');
imwrite(uint8(128 * ones(32, 32, 3)), artSrc);
ai = bma.run.importArtifact(workRoot, runDir, artSrc, struct('kind', 'figure'));
assert(ai.ok && ai.imported == 1, 'artifact import 失败：imported=%d', ai.imported);
assert(isfile(fullfile(runDir, 'artifacts.json')), 'artifacts.json 未生成');
assert(numel(ai.artifacts{1}.sha256) == 64, 'artifact SHA-256 长度错误');
% 走一次 dispatch 路径，确认工具层参数名与 RPC case 对得上
req = struct('work_dir', workRoot);
rpcArt = bma.server.dispatch('run.import_artifact', ...
    struct('run_dir', runDir, 'source_path', artSrc, 'kind', 'figure-rpc'), req);
assert(rpcArt.ok && rpcArt.imported >= 1, 'RPC run.import_artifact 失败');
rpcGate = bma.server.dispatch('run.waive_gate', ...
    struct('run_dir', runDir, 'gate', 'G6', 'reason', 'RPC 路径测试'), req);
assert(rpcGate.waived && rpcGate.count >= 1, 'RPC run.waive_gate 失败');
r2 = bma.report.build(runDir, spec, [], [], struct('title', '0.5.0 artifact report'));
html2 = fileread(bma.util.absPath(workRoot, r2.report_html));
assert(~isempty(strfind(html2, 'fig_art.png')), '报告未收集 artifacts/ 图片');
fprintf('[PASS] artifact import + report scan (sha256=%s...)\n', ai.artifacts{1}.sha256(1:12));

% ---------- 4. gate waiver ------------------------------------------------
gw = bma.run.waiveGate(workRoot, runDir, 'G6', ...
    '8 状态有理非线性模型的符号稳态不可行；已用数值多起点替代。', ...
    'numeric conservation nullspace + numerical Jacobian', struct('analysis', 'analysis.json'));
assert(gw.waived && gw.count >= 1, 'gate waiver 未记录');
assert(isfile(fullfile(runDir, 'gates.json')), 'gates.json 未生成');
r3 = bma.report.build(runDir, spec, [], [], struct('title', '0.5.0 gate report'));
html3 = fileread(bma.util.absPath(workRoot, r3.report_html));
assert(~isempty(strfind(html3, '质量门与豁免')), '报告缺少质量门与豁免章节');
assert(~isempty(strfind(html3, 'G6')), '报告未显示 G6 豁免');
card = bma.util.readJson(fullfile(runDir, 'report', 'model_card.json'));
assert(isfield(card, 'gates') && isfield(card.gates, 'waivers'), ...
    'model card 缺少 gates.waivers');
fprintf('[PASS] gate waiver + report/model card (%d waiver)\n', gw.count);

% ---------- 5. section confidence ----------------------------------------
txt = sprintf(['Abstract\n\nThis abstract is long enough to be a real section body ' ...
    'with enough words for the heuristic.\n\n1DG\n\nfragment body from a two-column layout.\n\n' ...
    'S[A]\n\nanother fragment body that is also short.\n\nMethods\n\nWe measured the signal ' ...
    'in a properly recognized Methods section with enough text.']);
secs = bma.io.sectionize(txt);
low = 0;
for k = 1:numel(secs)
    if isfield(secs(k), 'section_confidence') && strcmp(secs(k).section_confidence, 'low')
        low = low + 1;
    end
end
assert(low >= 2, '碎片标题未被标记为 low confidence（low=%d）', low);
fprintf('[PASS] section confidence: %d low-confidence headings\n', low);

% ---------- 6. KB entries -------------------------------------------------
[hitsPde, totalPde] = bma.kb.search('MATLAB PDE decsg geometry mesh', {}, 10);
assert(totalPde >= 1 && any(arrayfun(@(h) strcmp(h.id, 'matlab_pde_toolbox_pitfalls'), hitsPde)), ...
    'KB 未检索到 matlab_pde_toolbox_pitfalls');
[hitsConv, totalConv] = bma.kb.search('convergence residual analytic limit', {}, 10);
assert(totalConv >= 1 && any(arrayfun(@(h) strcmp(h.id, 'numerical_convergence_checklist'), hitsConv)), ...
    'KB 未检索到 numerical_convergence_checklist');
entry = bma.kb.get('matlab_pde_toolbox_pitfalls');
assert(strcmp(entry.id, 'matlab_pde_toolbox_pitfalls'), 'KB get 新条目失败');
fprintf('[PASS] KB new entries searchable (PDE hits=%d, convergence hits=%d)\n', ...
    totalPde, totalConv);

fprintf('[test_upgrade_050] 全部通过\n');
