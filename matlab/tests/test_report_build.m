% test_report：report.build 自包含 HTML + MD + model_card.json
% 断言：
%   - 返回的三个产物路径存在
%   - HTML 自包含（内联 <style> + base64 PNG，无外部图片引用），含关键小节与参数 id
%   - MD > 1500 字符，含「假设」「证据」「参数」「参考文献」「局限性」
%   - model_card.json 结构完整（name/parameters/fitting/metrics/equations/assumptions）
%   - figures_used 中每个文件真实存在

root = bma.util.projectRoot();
addpath(fullfile(root, 'matlab'));
workRoot = fullfile(root, '.bma', 'test-runs', bma.util.newId('test-report'));
runDir = fullfile(workRoot, 'run');
bma.util.ensureDir(runDir);

% 模型 + 数据 + 拟合
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
rep = bma.spec.validate(spec, root);
assert(rep.valid, 'enzyme 规格校验失败');
m = bma.model.build(rep.normalized_spec);
analysis = [];
try
    analysis = bma.model.analyze(m);
catch err
    fprintf('[INFO] model.analyze 不可用（%s），报告中省略分析小节\n', err.message);
end
csvPath = fullfile(root, 'spec', 'examples', 'data', 'enzyme_progress.csv');
T = readtable(csvPath, 'VariableNamingRule', 'preserve');
data = struct('path', csvPath, 'table', T, 'time', T{:, 1}, ...
    'time_unit', '', 'output_map', struct('P_obs', 'P_obs', 'S_obs', 'S_obs'));
rng(7, 'twister');
p0 = struct();
pNames = cellstr(m.params);
for k = 1:numel(pNames)
    p0.(pNames{k}) = m.paramValues(k) * (0.85 + 0.3 * rand);
end
fr = bma.fit.estimate(m, data, struct('work_dir', root, ...
    'run_dir', fullfile(runDir, 'fits'), 'multistart', 4, 'p0', p0));
si = bma.fit.sensitivity(m, struct('params', {{'kf', 'kr', 'kcat'}}, ...
    'method', 'local', 'work_dir', root, ...
    'run_dir', fullfile(runDir, 'sens')));
idr = bma.fit.identifiability(m, data, fr, struct('work_dir', root));

opts = struct();
opts.title = '米氏酶动力学参数估计与验证报告';
opts.references = {'示例参考文献 A：Enzyme kinetics review (2020).', ...
    '示例参考文献 B：Michaelis-Menten 原始论文 (1913).'};
opts.extra_sections = {struct('title', '补充说明', ...
    'body', '本节用于验证 report.build 对额外小节的支持。')};
opts.identifiability = idr;
opts.sensitivity = si;
r = bma.report.build(runDir, spec, fr, analysis, opts);

% ---- 产物存在性 ----
assert(isfield(r, 'report_html') && isfield(r, 'report_md') ...
    && isfield(r, 'model_card_path'), 'report 返回字段不全');
htmlPath = localAbs(root, r.report_html);
mdPath = localAbs(root, r.report_md);
cardPath = localAbs(root, r.model_card_path);
assert(isfile(htmlPath), sprintf('report.html 不存在：%s', htmlPath));
assert(isfile(mdPath), sprintf('report.md 不存在：%s', mdPath));
assert(isfile(cardPath), sprintf('model_card.json 不存在：%s', cardPath));

% ---- HTML 自包含 + 关键内容 ----
html = bma.util.readText(htmlPath);
assert(~isempty(strfind(html, '<style>')), 'HTML 缺少内联 CSS');
assert(~isempty(strfind(html, 'data:image/png;base64,')), 'HTML 缺少内嵌 base64 PNG');
assert(isempty(regexp(html, '<img[^>]+src="https?://', 'once')), ...
    'HTML 不应引用外部图片');
keysHtml = {'参数', '证据', '假设', '可辨识', '残差', '参考文献', '局限', '可复现'};
for k = 1:numel(keysHtml)
    assert(~isempty(strfind(html, keysHtml{k})), ...
        sprintf('HTML 缺少关键小节内容：%s', keysHtml{k}));
end
assert(~isempty(strfind(html, 'kcat')) && ~isempty(strfind(html, 'kf')), ...
    'HTML 参数表缺少参数 id');
assert(~isempty(strfind(html, '米氏酶动力学')), 'HTML 缺少标题');

% ---- Markdown ----
md = bma.util.readText(mdPath);
assert(numel(md) > 1500, sprintf('report.md 过短：%d 字符', numel(md)));
keysMd = {'假设', '证据', '参数', '参考文献', '局限性'};
for k = 1:numel(keysMd)
    assert(~isempty(strfind(md, keysMd{k})), ...
        sprintf('Markdown 缺少关键内容：%s', keysMd{k}));
end
assert(~isempty(strfind(md, 'figures/')), 'Markdown 应包含图相对路径引用');

% ---- model card ----
card = bma.util.readJson(cardPath);
assert(isfield(card, 'name') && strcmp(char(card.name), 'enzyme_mm'), ...
    'model_card.name 应为 enzyme_mm');
assert(isfield(card, 'parameters') && numel(card.parameters) >= 2, ...
    'model_card 参数表不足 2 个');
assert(isfield(card, 'fitting') && isstruct(card.fitting) ...
    && isfield(card.fitting, 'included') && logical(card.fitting.included), ...
    'model_card 缺少拟合信息');
assert(isfield(card.fitting, 'metrics') && isfield(card.fitting.metrics, 'r2'), ...
    'model_card 缺少拟合指标');
assert(isfield(card, 'equations') && ~isempty(card.equations), ...
    'model_card 缺少方程');
assert(isfield(card, 'assumptions') && ~isempty(card.assumptions), ...
    'model_card 缺少假设');
assert(isfield(card, 'identifiability') && logical(card.identifiability.included), ...
    'model_card 缺少可辨识性');
assert(isfield(card, 'reproducible_commands') && ~isempty(card.reproducible_commands), ...
    'model_card 缺少可复现命令');
assert(isfield(card, 'references') && numel(card.references) >= 2, ...
    'model_card 参考文献不足');
% 参数证据：不允许空（无证据时应显式标 assumed）
for k = 1:numel(card.parameters)
    pq = card.parameters(k);
    assert(isfield(pq, 'evidence') && ~isempty(pq.evidence), ...
        sprintf('参数 %s 缺少 evidence 字段', char(pq.id)));
end

% ---- figures_used 文件真实存在 ----
assert(isfield(r, 'figures_used') && numel(r.figures_used) >= 1, ...
    'figures_used 为空');
for k = 1:numel(r.figures_used)
    p = localAbs(root, r.figures_used{k});
    assert(isfile(p), sprintf('figures_used 中的文件不存在：%s', p));
end
fprintf('[PASS] report.build => html %d 字符 / md %d 字符 / card %d 参数 / %d 图\n', ...
    numel(html), numel(md), numel(card.parameters), numel(r.figures_used));

% =====================================================================
% 辅助函数
% =====================================================================
function p = localAbs(root, relOrAbs)
if isfile(relOrAbs)
    p = relOrAbs;
else
    p = fullfile(root, relOrAbs);
end
end
