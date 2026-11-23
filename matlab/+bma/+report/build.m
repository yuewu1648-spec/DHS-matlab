function r = build(runDir, spec, fr, analysis, opts)
%BUILD 生成自包含实验报告（report.html + report.md + model_card.json）。
%   r = bma.report.build(runDir, spec, fr, analysis, opts)
%
% 输入：
%   runDir    运行目录（绝对路径；报告写到 <runDir>/report/）
%   spec      模型规格 struct 或 JSON 路径（必需）
%   fr        拟合结果 struct 或 fit.json 路径（可为空）
%   analysis  模型分析结果 struct 或 analysis.json 路径（可为空）
%   opts      title、references、extra_sections、figures、work_dir、spec_path、
%             identifiability、sensitivity、validation、model_selection、
%             fit_result_path、run_id
%
% 产物（RD 布局 §7）：
%   report/report.html   自包含（内嵌 CSS + base64 PNG）
%   report/report.md     Markdown 版本（图用相对路径）
%   report/model_card.json
%   report/figures/*.png 报告使用的图
%
% 返回 r：report_html / report_md / model_card_path / figures_used / warnings
% （均相对 work_dir）。

if nargin < 5 || isempty(opts)
    opts = struct();
end
if nargin < 4
    analysis = [];
end
if nargin < 3
    fr = [];
end
warnings = {};
runDir = char(runDir);
if ~isfolder(runDir)
    error('bma:report:runDir', '运行目录不存在：%s', runDir);
end
reportDir = fullfile(runDir, 'report');
figOutDir = fullfile(reportDir, 'figures');
bma.util.ensureDir(reportDir);
bma.util.ensureDir(figOutDir);
workDir = resolveWorkDir(runDir, opts);

% ---------------- 输入解析 ----------------
spec = resolveObject(spec, opts, 'spec', 'spec_path', runDir, 'models', 'spec.json');
if isempty(spec)
    error('bma:report:noSpec', 'report.build 需要模型规格 spec 或 spec_path。');
end
fr = resolveObject(fr, opts, 'fr', 'fit_result_path', runDir, 'fits', 'fit.json');
if ~isempty(fr)
    fr = normalizeFit(fr);
end
analysis = resolveObject(analysis, opts, 'analysis', 'analysis_path', runDir, 'models', 'analysis.json');
ident = [];
if isfield(opts, 'identifiability') && ~isempty(opts.identifiability)
    ident = loadMaybeJson(opts.identifiability);
end
sens = [];
if isfield(opts, 'sensitivity') && ~isempty(opts.sensitivity)
    sens = loadMaybeJson(opts.sensitivity);
end
validation = struct();
if isfield(opts, 'validation') && ~isempty(opts.validation)
    validation = loadMaybeJson(opts.validation);
end
modelSel = [];
if isfield(opts, 'model_selection') && ~isempty(opts.model_selection)
    modelSel = loadMaybeJson(opts.model_selection);
end
if isempty(ident) && ~isempty(fr) && isfield(fr, 'identifiability') && ~isempty(fr.identifiability)
    ident = fr.identifiability;
end

title = reportTitle(opts, spec, fr);
references = collectReferences(opts, spec);
extraSections = {};
extraWarnings = {};
if isfield(opts, 'extra_sections') && ~isempty(opts.extra_sections)
    [extraSections, extraWarnings] = normalizeExtraSections(opts.extra_sections);
end
warnings = [warnings, extraWarnings];
% Embed images referenced from extra sections. Markdown ![](path) is copied
% into report/figures and converted to a data URI for HTML, while report.md
% gets a relative figures/... path. External absolute paths no longer leak into
% the delivered HTML (issue I5).
extraPrepared = cell(1, numel(extraSections));
extraSources = {};
for k = 1:numel(extraSections)
    [htmlBody, mdBody, imgWarnings, imgSources] = prepareExtraBody(extraSections(k).body, ...
        runDir, reportDir, figOutDir, workDir, k);
    warnings = [warnings, imgWarnings]; %#ok<AGROW>
    extraSources = [extraSources, imgSources]; %#ok<AGROW>
    extraPrepared{k} = struct('title', extraSections(k).title, ...
        'htmlBody', htmlBody, 'mdBody', mdBody);
end
extraHashes = {};
for k = 1:numel(extraSources)
    h = hashFile(char(extraSources{k}));
    if ~isempty(h)
        extraHashes{end+1} = h; %#ok<AGROW>
    end
end
gates = loadGates(runDir);

% 残差诊断（若有 fit 结果则现场诊断，保证与报告自洽）
residDiag = [];
if ~isempty(fr)
    try
        if isfield(fr, 'residuals') && isfield(fr.residuals, 'summary')
            residDiag = fr.residuals.summary;
        end
        if isfield(fr, 'residuals') && isfield(fr.residuals, 'values') ...
                && exist('bma.validate.residuals', 'file') == 2
            rr = bma.validate.residuals(fr, struct('make_figure', false));
            if isstruct(rr) && isfield(rr, 'diagnostics')
                residDiag = rr.diagnostics;
            end
        end
    catch err
        warnings{end+1} = sprintf('残差诊断失败：%s', err.message); %#ok<AGROW>
    end
end

% ---------------- 图 ----------------
[figs, w] = collectFigures(runDir, reportDir, figOutDir, fr, opts, extraSources, extraHashes);
warnings = [warnings, w];

% ---------------- 内容块 ----------------
sections = {};
equations = renderEquations(spec);
paramRows = parameterRows(spec, fr);
assumptions = specAssumptions(spec);
methodsLines = methodLines(fr);
metricRows = metricTableRows(fr);
identContent = identifiabilityBlock(ident);
sensTable = sensitivityRows(sens);
valContent = validationBlock(validation, modelSel, residDiag);
limitations = limitationLines(spec, fr, ident, residDiag, warnings, figs);
if isfield(spec, 'pde') && isstruct(spec.pde)
    domain = getF(spec.pde, 'domain', struct());
    approx = getF(domain, 'approximation', '');
    if double(getF(spec.pde, 'dim', 1)) >= 2
        limitations{end+1} = 'PDE 由 MATLAB PDE Toolbox 原生求解（非 MOL）；本报告不对该 2D/3D 模型做参数拟合/可辨识性，相关结论需降维或单独数据。'; %#ok<AGROW>
    elseif ~isempty(approx)
        limitations{end+1} = sprintf('PDE 几何为规则 1D MOL（approximation: %s），不代表任意几何/自由边界。', ...
            charIfy(approx)); %#ok<AGROW>
    else
        limitations{end+1} = 'PDE 由 1D 规则网格 MOL 展开；不代表任意几何/自由边界。'; %#ok<AGROW>
    end
end
if ~isempty(gates)
    for k = 1:numel(gates.waivers)
        w = gates.waivers{k};
        limitations{end+1} = sprintf('质量门 %s 已豁免：%s（替代：%s）。', ...
            charIfy(w.gate), charIfy(w.reason), charIfy(getF(w, 'substitute', '未说明'))); %#ok<AGROW>
    end
end
refs = references;
commands = reproducibleCommands(workDir, runDir, spec, fr, opts);

sections{end+1} = struct('id', 'overview', 'title', '1. 概要', ...
    'html', overviewHtml(title, spec, fr, analysis), 'md', overviewMd(title, spec, fr, analysis));
sections{end+1} = struct('id', 'equations', 'title', '2. 模型方程', ...
    'html', equationsHtml(equations, spec), 'md', equationsMd(equations, spec));
if isfield(spec, 'pde') && isstruct(spec.pde)
    sections{end+1} = struct('id', 'pde', 'title', '2B. PDE 离散与边界条件', ...
        'html', pdeHtml(spec), 'md', pdeMd(spec));
end
sections{end+1} = struct('id', 'assumptions', 'title', '3. 建模假设', ...
    'html', assumptionsHtml(assumptions), 'md', assumptionsMd(assumptions));
if ~isempty(analysis)
    sections{end+1} = struct('id', 'analysis', 'title', '4. 模型分析（守恒律/稳态/量纲）', ...
        'html', analysisHtml(analysis), 'md', analysisMd(analysis));
end
if ~isempty(gates)
    sections{end+1} = struct('id', 'gates', 'title', '4B. 质量门与豁免（显式记录）', ...
        'html', gatesHtml(gates), 'md', gatesMd(gates));
end
sections{end+1} = struct('id', 'params', 'title', '5. 参数与文献证据', ...
    'html', paramsHtml(paramRows), 'md', paramsMd(paramRows));
sections{end+1} = struct('id', 'methods', 'title', '6. 参数估计方法', ...
    'html', methodsHtml(methodsLines), 'md', methodsMd(methodsLines));
sections{end+1} = struct('id', 'fit', 'title', '7. 拟合结果与优度', ...
    'html', fitHtml(metricRows, fr), 'md', fitMd(metricRows, fr));
sections{end+1} = struct('id', 'ident', 'title', '8. 可辨识性分析', ...
    'html', identContent.html, 'md', identContent.md);
if ~isempty(sens)
    sections{end+1} = struct('id', 'sens', 'title', '9. 敏感性分析', ...
        'html', sensitivityHtml(sensTable, sens), 'md', sensitivityMd(sensTable, sens));
end
sections{end+1} = struct('id', 'validation', 'title', '10. 模型验证与残差诊断', ...
    'html', valContent.html, 'md', valContent.md);
sections{end+1} = struct('id', 'figures', 'title', '11. 图表', ...
    'html', figuresHtml(figs), 'md', figuresMd(figs));
for k = 1:numel(extraPrepared)
    s = extraPrepared{k};
    sections{end+1} = struct('id', sprintf('extra_%d', k), ...
        'title', s.title, 'html', extraHtml(s.title, s.htmlBody), ...
        'md', extraMd(s.title, s.mdBody)); %#ok<AGROW>
end
sections{end+1} = struct('id', 'references', 'title', '12. 参考文献', ...
    'html', referencesHtml(refs), 'md', referencesMd(refs));
sections{end+1} = struct('id', 'limitations', 'title', '13. 局限性与风险', ...
    'html', listHtml(limitations), 'md', listMd(limitations));
sections{end+1} = struct('id', 'reproduce', 'title', '14. 可复现命令', ...
    'html', codeHtml(commands), 'md', codeMd(commands));
sections{end+1} = struct('id', 'files', 'title', '15. 文件与元数据', ...
    'html', filesHtml(runDir, spec, fr, analysis, figs), ...
    'md', filesMd(runDir, spec, fr, analysis, figs));

% ---------------- 写 HTML / MD ----------------
htmlPath = fullfile(reportDir, 'report.html');
mdPath = fullfile(reportDir, 'report.md');
htmlTxt = htmlDocument(title, sections, spec, fr, commands);
mdTxt = mdDocument(title, sections, spec, fr);
bma.util.writeTextAtomic(htmlPath, htmlTxt);
bma.util.writeTextAtomic(mdPath, mdTxt);

% ---------------- model card ----------------
card = buildModelCard(title, spec, fr, analysis, ident, sens, validation, ...
    modelSel, residDiag, figs, refs, limitations, commands, gates, runDir, workDir);
cardPath = fullfile(reportDir, 'model_card.json');
bma.util.writeJsonAtomic(cardPath, card);

figuresUsed = arrayfun(@(f) bma.util.relPath(workDir, f.abs), figs, ...
    'UniformOutput', false);
r = struct();
r.report_html = bma.util.relPath(workDir, htmlPath);
r.report_md = bma.util.relPath(workDir, mdPath);
r.model_card_path = bma.util.relPath(workDir, cardPath);
r.figures_used = figuresUsed;
r.warnings = warnings;
end

% ======================================================================
% 输入解析
% ======================================================================

function workDir = resolveWorkDir(runDir, opts)
workDir = '';
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
    workDir = char(opts.work_dir);
elseif isfield(opts, 'workDir') && ~isempty(opts.workDir)
    workDir = char(opts.workDir);
else
    idx = strfind(runDir, [filesep '.bma' filesep 'runs']);
    if ~isempty(idx)
        workDir = runDir(1:idx(1) - 1);
    else
        workDir = bma.util.projectRoot();
    end
end
if ~isfolder(workDir)
    workDir = bma.util.projectRoot();
end
end

function obj = resolveObject(obj, opts, argField, pathField, runDir, folder, fileName)
if ischar(obj) || isstring(obj)
    obj = loadMaybeJson(char(obj));
    return
end
if ~isempty(obj)
    return
end
if isfield(opts, argField) && ~isempty(opts.(argField))
    obj = loadMaybeJson(opts.(argField));
    return
end
if isfield(opts, pathField) && ~isempty(opts.(pathField))
    obj = loadMaybeJson(char(opts.(pathField)));
    return
end
% 运行目录中自动寻找
pattern = fullfile(runDir, folder, '*', fileName);
d = dir(pattern);
if ~isempty(d)
    obj = loadMaybeJson(fullfile(d(1).folder, d(1).name));
end
end

function v = loadMaybeJson(v)
if ischar(v) || isstring(v)
    v = char(v);
    if isfolder(v)
        candidates = {'report.json', 'fit.json', 'spec.json', 'analysis.json'};
        for k = 1:numel(candidates)
            f = fullfile(v, candidates{k});
            if isfile(f)
                v = bma.util.readJson(f);
                return
            end
        end
    end
    if isfile(v)
        [~, ~, ext] = fileparts(v);
        if strcmpi(ext, '.mat')
            S = load(v);
            if isfield(S, 'fr')
                v = S.fr;
            else
                v = S;
            end
        else
            v = bma.util.readJson(v);
        end
        return
    end
end
end

function fr = normalizeFit(fr)
if ~isstruct(fr)
    fr = [];
    return
end
if isfield(fr, 'params') && iscell(fr.params)
    try
        fr.params = [fr.params{:}];
    catch
    end
end
if isfield(fr, 'params') && isstruct(fr.params) && ~isfield(fr.params, 'id') ...
        && numel(fr.params) == 1
    f = fieldnames(fr.params);
    if ismember('value', f) && numel(f) > 1
        % 单参数被解成标量 struct 的字段容器
    end
end
if isfield(fr, 'warnings')
    fr.warnings = toCellstr(fr.warnings);
end
if isfield(fr, 'figures')
    fr.figures = toCellstr(fr.figures);
end
if isfield(fr, 'pnames')
    fr.pnames = toCellstr(fr.pnames);
end
end

function title = reportTitle(opts, spec, fr)
title = '';
if isfield(opts, 'title') && ~isempty(opts.title)
    title = char(opts.title);
elseif isfield(spec, 'title') && ~isempty(spec.title)
    title = char(spec.title);
 elseif isfield(spec, 'name') && ~isempty(spec.name)
    title = char(spec.name);
end
if isempty(title)
    title = '生物系统建模报告';
end
if ~isempty(fr) && isfield(fr, 'spec_title') && ~isempty(fr.spec_title) ...
        && isempty(strfind(title, char(fr.spec_title)))
    title = [title ' — ' char(fr.spec_title)];
end
end

function refs = collectReferences(opts, spec)
refs = {};
if isfield(opts, 'references') && ~isempty(opts.references)
    refs = normalizeReferences(opts.references);
end
if isfield(spec, 'metadata') && isstruct(spec.metadata)
    if isfield(spec.metadata, 'source_docs') && ~isempty(spec.metadata.source_docs)
        docs = toCellstr(spec.metadata.source_docs);
        for k = 1:numel(docs)
            refs{end+1} = docs{k}; %#ok<AGROW>
        end
    end
end
% 参数证据中的 source 也列入参考资料
if isfield(spec, 'parameters') && ~isempty(spec.parameters)
    for k = 1:numel(spec.parameters)
        p = spec.parameters(k);
        if isfield(p, 'evidence') && ~isempty(p.evidence)
            for e = 1:numel(p.evidence)
                ev = p.evidence(e);
                if isfield(ev, 'source') && ~isempty(ev.source)
                    refs{end+1} = char(ev.source); %#ok<AGROW>
                end
            end
        end
    end
end
refs = uniqueStable(refs);
end

function s = refString(x)
s = '';
if ischar(x) || isstring(x)
    s = char(x);
elseif isstruct(x)
    if isfield(x, 'citation') && ~isempty(x.citation)
        s = char(x.citation);
    end
    if isfield(x, 'doi') && ~isempty(x.doi)
        s = sprintf('%s doi:%s', s, char(x.doi));
    end
    if isfield(x, 'url') && ~isempty(x.url)
        s = sprintf('%s %s', s, char(x.url));
    end
end
end

function [extra, warnings] = normalizeExtraSections(x)
%NORMALIZEEXTRASECTIONS Accept structs, Markdown/JSON file paths, or mixes.
%   A JSON file path is decoded as an array of extra sections; a Markdown
%   file is read as one section titled by its basename. Missing bodies are
%   reported in warnings instead of being silently rendered empty.
extra = struct('title', {}, 'body', {});
warnings = {};
if ischar(x) || isstring(x)
    x = {char(x)};
end
if iscell(x)
    for k = 1:numel(x)
        if isstruct(x{k})
            title = sprintf('补充材料 %d', k);
            if isfield(x{k}, 'title') && ~isempty(x{k}.title)
                title = char(x{k}.title);
            end
            body = extraBody(x{k});
            if isempty(strtrim(body))
                warnings{end+1} = sprintf('额外章节 "%s" 没有正文（body/markdown/content/file），已渲染为空节。', title); %#ok<AGROW>
            end
            extra(end+1) = struct('title', title, 'body', body); %#ok<AGROW>
        elseif ischar(x{k}) || isstring(x{k})
            txt = char(x{k});
            if isfile(txt)
                [~, nm, ext] = fileparts(txt);
                if strcmpi(ext, '.json')
                    try
                        data = jsondecode(fileread(txt));
                        [sub, w] = normalizeExtraSections(data);
                        extra = [extra, sub]; %#ok<AGROW>
                        warnings = [warnings, w]; %#ok<AGROW>
                    catch err
                        warnings{end+1} = sprintf('额外章节 JSON 解析失败 %s：%s', txt, err.message); %#ok<AGROW>
                    end
                else
                    body = fileread(txt);
                    if isempty(strtrim(body))
                        warnings{end+1} = sprintf('额外章节文件为空：%s', txt); %#ok<AGROW>
                    end
                    extra(end+1) = struct('title', nm, 'body', body); %#ok<AGROW>
                end
            else
                if isempty(strtrim(txt))
                    warnings{end+1} = sprintf('第 %d 条额外章节为空字符串。', k); %#ok<AGROW>
                end
                extra(end+1) = struct('title', sprintf('补充材料 %d', k), 'body', txt); %#ok<AGROW>
            end
        end
    end
elseif isstruct(x)
    for k = 1:numel(x)
        title = sprintf('补充材料 %d', k);
        if isfield(x(k), 'title') && ~isempty(x(k).title)
            title = char(x(k).title);
        end
        body = extraBody(x(k));
        if isempty(strtrim(body))
            warnings{end+1} = sprintf('额外章节 "%s" 没有正文（body/markdown/content/file），已渲染为空节。', title); %#ok<AGROW>
        end
        extra(end+1) = struct('title', title, 'body', body); %#ok<AGROW>
    end
end
end

function b = extraBody(s)
%EXTRA BODY Read the first available body field; accept a file path too.
b = '';
names = {'markdown', 'body', 'body_md', 'content', 'text'};
for k = 1:numel(names)
    if isfield(s, names{k}) && ~isempty(s.(names{k}))
        b = char(s.(names{k}));
        break
    end
end
if isempty(b) && isfield(s, 'file') && ~isempty(s.file)
    b = char(s.file);
end
if ~isempty(b) && isfile(b)
    b = fileread(b);
end
if isempty(b)
    warning('bma:report:emptyExtraSection', ...
        '额外章节 "%s" 没有正文（body/markdown/content），已渲染为空节。', ...
        char(string(s.title)));
end
end

% ======================================================================
% 图收集
% ======================================================================

function cand = preferPlainNames(cand)
% Prefer the canonical name (fit.png) over importer collision copies
% (fit-2.png) or hash-suffixed names, so content dedup keeps the name users
% and tests expect.
n = numel(cand);
rank = zeros(1, n);
for k = 1:n
    [~, stem] = fileparts(char(cand{k}));
    if ~isempty(regexp(stem, '-\d+$', 'once')) || ~isempty(regexp(stem, '_[0-9a-f]{8}$', 'once'))
        rank(k) = 1;
    end
end
[~, order] = sort(rank);
cand = cand(order);
end

function [figs, warnings] = collectFigures(runDir, reportDir, figOutDir, fr, opts, extraSources, extraHashes) %#ok<INUSD>
warnings = {};
cand = {};
if isfield(opts, 'figures') && ~isempty(opts.figures)
    cand = [cand, toCellstr(opts.figures)]; %#ok<AGROW>
end
if ~isempty(fr)
    if isfield(fr, 'figure') && ~isempty(fr.figure)
        cand = [cand, toCellstr(fr.figure)]; %#ok<AGROW>
    end
    if isfield(fr, 'figures') && ~isempty(fr.figures)
        cand = [cand, toCellstr(fr.figures)]; %#ok<AGROW>
    end
end
globs = {fullfile(runDir, 'figures', '*.png'), ...
    fullfile(runDir, 'fits', '*', 'figures', '*.png'), ...
    fullfile(runDir, 'artifacts', '**', '*.png'), ...
    fullfile(runDir, 'artifacts', '**', '*.jpg'), ...
    fullfile(runDir, 'artifacts', '**', '*.jpeg'), ...
    fullfile(runDir, 'artifacts', '**', '*.gif'), ...
    fullfile(runDir, 'artifacts', '**', '*.webp')};
for g = 1:numel(globs)
    d = dir(globs{g});
    for k = 1:numel(d)
        cand{end+1} = fullfile(d(k).folder, d(k).name); %#ok<AGROW>
    end
end
cand = preferPlainNames(cand);
figs = struct('abs', {}, 'name', {}, 'caption', {}, 'base64', {}, 'mime', {});
seen = {};
excludePaths = {};
for k = 1:numel(extraSources)
    excludePaths{end+1} = pathKey(char(extraSources{k})); %#ok<AGROW>
end
excludeHashes = {};
for k = 1:numel(extraHashes)
    excludeHashes{end+1} = char(extraHashes{k}); %#ok<AGROW>
end
baseAbs = bma.util.projectRoot();
for k = 1:numel(cand)
    p = char(cand{k});
    if ~isfile(p)
        if isfile(bma.util.absPath(baseAbs, p))
            p = bma.util.absPath(baseAbs, p);
        else
            warnings{end+1} = sprintf('报告图不存在，已跳过：%s', p); %#ok<AGROW>
            continue
        end
    end
    if ismember(pathKey(p), excludePaths)
        continue
    end
    [~, stem, ext] = fileparts(p);
    mime = mimeOf(lower(ext));
    if isempty(mime)
        continue
    end
    h = hashFile(p);
    if ~isempty(h) && ismember(h, excludeHashes)
        % Already shown verbatim by an extra section; do not repeat it in
        % the generic "figures" section.
        continue
    end
    key = h;
    if isempty(key), key = [stem ext]; end
    if ismember(key, seen)
        continue
    end
    seen{end+1} = key; %#ok<AGROW>
    dstName = [stem ext];
    dst = fullfile(figOutDir, dstName);
    if isfile(dst) && ~isempty(h) && ~strcmpi(hashFile(dst), h)
        % Different image with the same filename: keep both by suffixing the
        % content hash instead of silently overwriting the first one.
        dstName = sprintf('%s_%s%s', stem, h(1:min(8, numel(h))), ext);
        dst = fullfile(figOutDir, dstName);
    end
    try
        if ~strcmpi(normalizePath(p), normalizePath(dst))
            copyfile(p, dst, 'f');
        end
        figs(end+1) = struct('abs', dst, 'name', dstName, ...
            'caption', captionFor(stem), 'base64', base64Of(dst), ...
            'mime', mime); %#ok<AGROW>
    catch err
        warnings{end+1} = sprintf('复制报告图失败 %s：%s', p, err.message); %#ok<AGROW>
    end
end
end

function c = captionFor(stem)
c = stem;
map = {'fit', '拟合曲线：观测（散点）与模型预测（曲线）及残差';
    'timeseries', '模型输出时间序列';
    'profile', '剖面似然曲线与 95% 置信区间';
    'sensitivity', '参数敏感性指数排序';
    'residuals', '残差诊断（残差-拟合值、分布、ACF、Q-Q）';
    'cross_validation', 'k 折时序交叉验证各折测试集 R²';
    'phase', '相平面轨迹'};
for k = 1:size(map, 1)
    if strcmp(stem, map{k, 1}) || strncmp(stem, [map{k, 1} '_'], numel(map{k, 1}) + 1)
        c = map{k, 2};
        if strncmp(stem, 'profile_', 8)
            c = sprintf('剖面似然：%s', stem(9:end));
        end
        return
    end
end
end

function b64 = base64Of(absPath)
fid = fopen(absPath, 'r');
if fid < 0
    b64 = '';
    return
end
cleaner = onCleanup(@() fclose(fid));
raw = fread(fid, Inf, '*uint8');
try
    b64 = char(matlab.net.base64encode(raw));
catch
    try
        encoder = java.util.Base64.getEncoder();
        b64 = char(encoder.encodeToString(raw));
    catch
        b64 = '';
    end
end
end

function p = normalizePath(p)
p = strrep(char(p), '/', filesep);
p = strrep(p, [filesep filesep], filesep);
end

function k = pathKey(p)
k = lower(normalizePath(p));
end

function h = hashFile(p)
% SHA-256 of a local figure; used to avoid embedding the same image twice.
h = '';
try
    fid = fopen(p, 'r');
    if fid < 0
        return
    end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    raw = fread(fid, Inf, '*uint8');
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(uint8(raw(:)));
    digest = typecast(md.digest(), 'uint8');
    h = lower(sprintf('%02x', digest));
catch
    h = '';
end
end

% ======================================================================
% 内容渲染小工具
% ======================================================================

function out = uniqueStable(c)
out = {};
for k = 1:numel(c)
    if ~any(strcmp(out, c{k}))
        out{end+1} = c{k}; %#ok<AGROW>
    end
end
end

function eqs = renderEquations(spec)
%RENDEREQUATIONS 从 spec 渲染 ODE 方程文本（cellstr）。
eqs = {};
if ~isfield(spec, 'variables') || isempty(spec.variables) ...
        || ~isfield(spec, 'reactions') || isempty(spec.reactions)
    return
end
varIds = arrayfun(@(v) char(v.id), spec.variables, 'UniformOutput', false);
for k = 1:numel(varIds)
    vid = varIds{k};
    terms = {};
    for r = 1:numel(spec.reactions)
        rx = spec.reactions(r);
        coef = 0;
        if isfield(rx, 'stoichiometry') && isstruct(rx.stoichiometry) ...
                && isfield(rx.stoichiometry, vid)
            coef = double(rx.stoichiometry.(vid));
        end
        if coef == 0
            continue
        end
        rate = rateText(rx.rate);
        if coef == 1
            terms{end+1} = ['+ ' rate]; %#ok<AGROW>
        elseif coef == -1
            terms{end+1} = ['- ' rate]; %#ok<AGROW>
        elseif coef > 0
            terms{end+1} = sprintf('+ %g·%s', coef, rate); %#ok<AGROW>
        else
            terms{end+1} = sprintf('- %g·%s', abs(coef), rate); %#ok<AGROW>
        end
    end
    if isempty(terms)
        rhs = '0';
    else
        rhs = strjoin(terms, ' ');
        rhs = regexprep(rhs, '^\+ ', '');
    end
    eqs{end+1} = sprintf('d%s/dt = %s', vid, rhs); %#ok<AGROW>
end
if isfield(spec, 'outputs') && ~isempty(spec.outputs)
    for k = 1:numel(spec.outputs)
        o = spec.outputs(k);
        expr = char(o.id);
        if isfield(o, 'expression') && ~isempty(o.expression)
            expr = char(o.expression);
        end
        eqs{end+1} = sprintf('%s = %s', char(o.id), expr); %#ok<AGROW>
    end
end
end

function id = paramIdOf(p, field, fallback)
id = fallback;
if isfield(p, field) && ~isempty(p.(field))
    id = char(p.(field));
end
end

function rows = parameterRows(spec, fr)
%PARAMETERROWS 参数证据表：值/单位/CI/证据类型/引文。
rows = {};
if ~isfield(spec, 'parameters') || isempty(spec.parameters)
    return
end
fitValues = struct();
if ~isempty(fr) && isfield(fr, 'params')
    P = fr.params;
    for k = 1:numel(P)
        try
            fitValues.(char(P(k).id)) = P(k);
        catch
        end
    end
end
for k = 1:numel(spec.parameters)
    p = spec.parameters(k);
    id = char(p.id);
    name = id;
    if isfield(p, 'name') && ~isempty(p.name), name = char(p.name); end
    unit = '';
    if isfield(p, 'unit') && ~isempty(p.unit), unit = char(p.unit); end
    value = paramValueOf(p);
    ciStr = '—';
    status = '固定';
    if isfield(fitValues, id)
        q = fitValues.(id);
        value = q.value;
        if isfield(q, 'fixed') && ~q.fixed
            status = '拟合';
            ciStr = sprintf('[%s, %s]', num(q.ci_low), num(q.ci_high));
        else
            status = '固定';
        end
    elseif isfield(p, 'estimate') && ~isempty(p.estimate) && logical(p.estimate)
        status = '待估计';
    end
    [evType, evQuote] = evidenceOf(p);
    rows{end+1, 1} = id; %#ok<AGROW>
    rows{end, 2} = name;
    rows{end, 3} = unit;
    rows{end, 4} = num(value);
    rows{end, 5} = ciStr;
    rows{end, 6} = status;
    rows{end, 7} = evType;
    rows{end, 8} = evQuote;
end
end

function [types, quotes] = evidenceOf(p)
types = 'assumed（无文献证据，按领域默认）';
quotes = '—';
evList = evidenceCell(p);
if ~isempty(evList)
    tParts = {};
    qParts = {};
    for k = 1:numel(evList)
        e = evList{k};
        if isfield(e, 'type') && ~isempty(e.type)
            tParts{end+1} = char(e.type); %#ok<AGROW>
        else
            tParts{end+1} = 'unspecified'; %#ok<AGROW>
        end
        q = '';
        if isfield(e, 'quote') && ~isempty(e.quote)
            q = char(e.quote);
        elseif isfield(e, 'note') && ~isempty(e.note)
            q = char(e.note);
        end
        if isfield(e, 'section_id') && ~isempty(e.section_id)
            q = sprintf('%s（%s）', q, char(e.section_id));
        end
        qParts{end+1} = q; %#ok<AGROW>
    end
    if ~isempty(tParts)
        types = strjoin(uniqueStable(tParts), ', ');
        quotes = strjoin(qParts(~cellfun(@isempty, qParts)), '；');
    end
end
end

function a = specAssumptions(spec)
a = {};
if isfield(spec, 'assumptions') && ~isempty(spec.assumptions)
    a = toCellstr(spec.assumptions);
end
if isempty(a)
    a = {'（规格中未显式列出建模假设，建议补充）'};
end
end

function lines = methodLines(fr)
lines = {};
if isempty(fr) || ~isfield(fr, 'method') || isempty(fr.method)
    lines = {'本报告未包含参数估计结果。'};
    return
end
m = fr.method;
f = fieldnames(m);
for k = 1:numel(f)
    v = m.(f{k});
    if isnumeric(v)
        v = num(v);
    else
        v = charIfy(v);
    end
    lines{end+1} = sprintf('%s：%s', fieldLabel(f{k}), v); %#ok<AGROW>
end
lines{end+1} = '目标函数为加权残差平方和；协方差由最优点残差雅可比估计（Cov = σ²·pinv(JᵀJ)），95% CI 用 t 分位数。';
lines{end+1} = '多起点使用固定随机种子以保证可复现；每个起点失败时自动回退 fmincon，再失败回退 fminsearch+边界罚函数。';
end

function content = identifiabilityBlock(ident)
%IDENTIFIABILITYBLOCK 渲染可辨识性小节。
html = {'<p>未进行可辨识性分析（可通过 bma.fit.identifiability 生成后传入 opts.identifiability）。</p>'};
md = {'> 未进行可辨识性分析。'};
if isempty(ident) || ~isstruct(ident)
    content = struct('html', strjoin(html, newline), 'md', strjoin(md, newline));
    return
end
html = {};
md = {};
if isfield(ident, 'structural') && isstruct(ident.structural)
    s = ident.structural;
    rank = getF(s, 'rank', NaN);
    nP = getF(s, 'n_params', NaN);
    def = getF(s, 'deficient', NaN);
    html{end+1} = sprintf(['<p>结构可辨识性（灵敏度矩阵数值秩诊断）：参数灵敏度矩阵秩 ' ...
        '<b>%d/%d</b>，%s。</p>'], rank, nP, ...
        ternary(def > 0, sprintf('存在 %d 个结构秩亏方向', def), '未发现结构秩亏'));
    md{end+1} = sprintf('- 结构可辨识性：灵敏度矩阵秩 %d/%d，%s。', rank, nP, ...
        ternary(def > 0, sprintf('结构秩亏 %d', def), '无结构秩亏'));
    if isfield(s, 'combinations') && ~isempty(s.combinations)
        c = toCellstr(s.combinations);
        html{end+1} = '<p>不可辨识组合：</p><ul>';
        for k = 1:numel(c)
            html{end+1} = sprintf('<li>%s</li>', esc(c{k})); %#ok<AGROW>
            md{end+1} = sprintf('  - %s', c{k}); %#ok<AGROW>
        end
        html{end+1} = '</ul>';
    end
    if isfield(s, 'collinear_pairs') && ~isempty(s.collinear_pairs)
        html{end+1} = '<p>相关列诊断（|r| ≥ 0.95）：</p><ul>';
        for k = 1:numel(s.collinear_pairs)
            p = s.collinear_pairs(k);
            html{end+1} = sprintf('<li>%s 与 %s，r = %s</li>', ...
                esc(p.param), esc(p.other), num(p.r, 3)); %#ok<AGROW>
            md{end+1} = sprintf('  - %s 与 %s 强相关（r=%s）', p.param, p.other, num(p.r, 3)); %#ok<AGROW>
        end
        html{end+1} = '</ul>';
    end
end
if isfield(ident, 'practical') && isstruct(ident.practical)
    pr = ident.practical;
    condN = getF(pr, 'condition_number', NaN);
    html{end+1} = sprintf(['<p>实用可辨识性：Fisher 信息矩阵条件数 <b>%s</b>。' ...
        '条件数越大，参数越难同时精确估计。</p>'], num(condN, 4));
    md{end+1} = sprintf('- 实用可辨识性：FIM 条件数 %s。', num(condN, 4)); %#ok<AGROW>
    if isfield(pr, 'relative_se') && ~isempty(pr.relative_se)
        ids = {};
        if isfield(ident, 'param_ids')
            ids = toCellstr(ident.param_ids);
        end
        rows = {};
        for k = 1:numel(pr.relative_se)
            id = sprintf('p%d', k);
            if k <= numel(ids), id = ids{k}; end
            rows{end+1, 1} = id; %#ok<AGROW>
            rows{end, 2} = num(pr.relative_se(k), 3);
            if isfield(pr, 'correlation') && isfield(ident, 'param_ids') ...
                    && numel(ids) == size(pr.correlation, 1)
                r = pr.correlation(k, :);
                r(k) = NaN;
                [mx, j] = max(abs(r));
                rows{end, 3} = ids{j}; %#ok<AGROW>
                rows{end, 4} = num(pr.correlation(k, j), 3);
            else
                rows{end, 3} = '—';
                rows{end, 4} = NaN;
            end
        end
        html{end+1} = tableHtml({'参数', '相对标准误（对数尺度）', '最强相关参数', '相关系数'}, rows);
        md{end+1} = tableMd({'参数', '相对 SE(对数)', '最强相关参数', '相关系数'}, rows);
    end
end
if isfield(ident, 'suggestions') && ~isempty(ident.suggestions)
    sg = toCellstr(ident.suggestions);
    html{end+1} = '<p>改进建议：</p><ul>';
    for k = 1:numel(sg)
        html{end+1} = sprintf('<li>%s</li>', esc(sg{k})); %#ok<AGROW>
        md{end+1} = sprintf('  - %s', sg{k}); %#ok<AGROW>
    end
    html{end+1} = '</ul>';
end
content = struct('html', strjoin(html, newline), 'md', strjoin(md, newline));
end

function commands = reproducibleCommands(workDir, runDir, spec, fr, opts)
%REPRODUCIBLECOMMANDS 生成可复现的 MATLAB 命令（相对工作目录）。
root = workDir;
commands = {
    '% 在 MATLAB R2024a 中复现本报告（开源代码 + 固定随机种子）'
    sprintf('addpath(fullfile(''%s'', ''matlab''));', root)
    sprintf('cd(''%s'');', root)
    };
specPath = '';
if isfield(opts, 'spec_path') && ~isempty(opts.spec_path)
    specPath = char(opts.spec_path);
elseif isfield(spec, 'name') && ~isempty(spec.name)
    cand = fullfile(runDir, 'models', char(spec.name), 'spec.json');
    if isfile(cand)
        specPath = cand;
    end
end
if ~isempty(specPath)
    commands{end+1} = sprintf('spec = bma.spec.load(''%s'');', escForCode(specPath));
else
    commands{end+1} = 'spec = bma.spec.load(''<spec.json 路径>'');';
end
if isfield(spec, 'pde') && isstruct(spec.pde) && double(getF(spec.pde, 'dim', 1)) >= 2
    commands{end+1} = ['r = bma.pde.simulate(spec, struct(''run_dir'', ''<run_dir>'', ' ...
        '''work_dir'', ''<work_dir>''));'];
else
    commands{end+1} = 'm = bma.model.build(spec);';
    commands{end+1} = 'data = struct(''csv'', ''<data.csv 路径>'');  % 或 dispatch 的 loadDataset 结构';
    commands{end+1} = ['opts = struct(''multistart'', 8, ''seed'', 42, ''solver'', ''ode15s'', ' ...
        '''save_artifacts'', true);'];
    if ~isempty(fr) && isfield(fr, 'method') && isfield(fr.method, 'seed')
        commands{end+1} = sprintf('opts.seed = %d;', round(double(fr.method.seed)));
    end
    commands{end+1} = 'fr = bma.fit.estimate(m, data, opts);';
    commands{end+1} = 'pr = bma.fit.profile(m, data, fr, ''<参数 id>'', struct());';
    commands{end+1} = 'si = bma.fit.sensitivity(m, struct());';
    commands{end+1} = 'idr = bma.fit.identifiability(m, data, fr, struct());';
    commands{end+1} = 'cv = bma.validate.crossValidation(m, data, struct(''k'', 5));';
    commands{end+1} = ['rep = bma.report.build(''<run_dir>'', spec, fr, [], ' ...
        'struct(''title'', ''<标题>''));'];
end
end

function html = htmlDocument(title, sections, spec, fr, commands)
parts = {};
parts{end+1} = '<!DOCTYPE html>';
parts{end+1} = '<html lang="zh-CN">';
parts{end+1} = '<head>';
parts{end+1} = '<meta charset="UTF-8">';
parts{end+1} = '<meta name="viewport" content="width=device-width, initial-scale=1.0">';
parts{end+1} = sprintf('<title>%s</title>', esc(title));
parts{end+1} = '<style>';
parts{end+1} = cssText();
parts{end+1} = '</style>';
parts{end+1} = '</head><body>';
parts{end+1} = '<div class="page">';
parts{end+1} = sprintf('<header><h1>%s</h1>', esc(title));
meta = {};
if isfield(spec, 'name') && ~isempty(spec.name)
    meta{end+1} = sprintf('模型：%s', char(spec.name)); %#ok<AGROW>
end
if isfield(spec, 'schema_version') && ~isempty(spec.schema_version)
    meta{end+1} = sprintf('规格版本：%s', char(spec.schema_version)); %#ok<AGROW>
end
meta{end+1} = sprintf('生成时间：%s', bma.util.nowIso()); %#ok<AGROW>
meta{end+1} = sprintf('MATLAB：%s', version); %#ok<AGROW>
parts{end+1} = sprintf('<p class="meta">%s</p></header>', esc(strjoin(meta, ' ｜ ')));
% 目录
parts{end+1} = '<nav class="toc"><h2>目录</h2><ol>';
for k = 1:numel(sections)
    parts{end+1} = sprintf('<li><a href="#%s">%s</a></li>', ...
        sections{k}.id, esc(sections{k}.title)); %#ok<AGROW>
end
parts{end+1} = '</ol></nav>';
for k = 1:numel(sections)
    s = sections{k};
    parts{end+1} = sprintf('<section id="%s"><h2>%s</h2>', s.id, esc(s.title)); %#ok<AGROW>
    parts{end+1} = s.html; %#ok<AGROW>
    parts{end+1} = '</section>'; %#ok<AGROW>
end
parts{end+1} = '<footer><p>本报告由 BioModel-MATLAB（bma.report.build）自动生成；所有结论可回溯到模型规格与数据文件。</p></footer>';
parts{end+1} = '</div></body></html>';
html = strjoin(parts, newline);
end

function md = mdDocument(title, sections, spec, fr)
parts = {};
parts{end+1} = sprintf('# %s', title);
parts{end+1} = '';
meta = {};
if isfield(spec, 'name') && ~isempty(spec.name)
    meta{end+1} = sprintf('模型 `%s`', char(spec.name)); %#ok<AGROW>
end
meta{end+1} = sprintf('生成时间 %s', bma.util.nowIso()); %#ok<AGROW>
meta{end+1} = sprintf('MATLAB %s', version); %#ok<AGROW>
parts{end+1} = strjoin(meta, ' ｜ ');
parts{end+1} = '';
for k = 1:numel(sections)
    s = sections{k};
    parts{end+1} = ['## ' s.title]; %#ok<AGROW>
    parts{end+1} = ''; %#ok<AGROW>
    parts{end+1} = s.md; %#ok<AGROW>
    parts{end+1} = ''; %#ok<AGROW>
end
md = strjoin(parts, newline);
end

function css = cssText()
css = [ ...
'body{font-family:"Microsoft YaHei","PingFang SC","Segoe UI",Arial,sans-serif;' ...
'background:#f6f8fb;color:#1f2937;margin:0;padding:0;line-height:1.7;}' ...
'img{max-width:100%;height:auto;}' ...
'.page{max-width:1080px;margin:0 auto;background:#fff;padding:40px 48px;' ...
'box-shadow:0 2px 18px rgba(0,0,0,.07);}' ...
'h1{font-size:28px;color:#123a6b;border-bottom:3px solid #2d6cdf;padding-bottom:10px;}' ...
'h2{font-size:21px;color:#123a6b;margin-top:34px;border-left:5px solid #2d6cdf;padding-left:12px;}' ...
'h3.sub{font-size:17px;color:#334155;margin-top:22px;}' ...
'.meta{color:#5b6b7f;font-size:13px;}' ...
'nav.toc{background:#f1f5fb;border:1px solid #dbe6f6;border-radius:8px;padding:14px 24px;margin:22px 0;}' ...
'nav.toc h2{margin:0 0 8px 0;font-size:16px;border:none;padding:0;}' ...
'nav.toc ol{margin:0;padding-left:20px;columns:2;}' ...
'table.tbl{border-collapse:collapse;width:100%;margin:14px 0;font-size:13.5px;}' ...
'table.tbl th{background:#e8f0fb;color:#123a6b;text-align:left;padding:8px 10px;' ...
'border:1px solid #cdd9ea;}' ...
'table.tbl td{padding:7px 10px;border:1px solid #dfe6f0;vertical-align:top;}' ...
'table.tbl tr:nth-child(even) td{background:#f8fafd;}' ...
'table.md{border-collapse:collapse;width:100%;table-layout:fixed;margin:14px 0;font-size:13.5px;}' ...
'table.md th,table.md td{border:1px solid #dfe6f0;padding:7px 10px;vertical-align:top;' ...
'overflow-wrap:anywhere;word-break:break-word;}' ...
'table.md th{background:#e8f0fb;color:#123a6b;text-align:left;}' ...
'table.md td img{max-width:100%;height:auto;}' ...
'pre.eq{background:#f4f7fc;border:1px solid #d9e3f2;border-radius:6px;padding:14px 18px;' ...
'font-family:Consolas,"Courier New",monospace;font-size:13.5px;overflow-x:auto;}' ...
'pre.code{background:#0f172a;color:#d6e4ff;border-radius:6px;padding:14px 18px;' ...
'font-family:Consolas,"Courier New",monospace;font-size:13px;overflow-x:auto;white-space:pre-wrap;}' ...
'ul,ol{padding-left:26px;}' ...
'figure{margin:18px 0;text-align:center;}' ...
'figure img{max-width:100%;border:1px solid #dbe4f0;border-radius:6px;}' ...
'figcaption{color:#5b6b7f;font-size:13px;margin-top:6px;}' ...
'footer{margin-top:40px;border-top:1px solid #e2e8f0;padding-top:15px;color:#64748b;font-size:12.5px;}' ...
'.badge{display:inline-block;padding:1px 8px;border-radius:10px;background:#e8f0fb;color:#123a6b;font-size:12px;}' ...
];
end

function h = mdToHtml(md)
%MDTOHTML Minimal Markdown renderer: headings/lists/tables/code/emphasis/links.
lines = regexp(char(md), '\r?\n', 'split');
h = '';
i = 1;
inCode = false;
codeBuf = {};
listType = '';
while i <= numel(lines)
    line = lines{i};
    if inCode
        if ~isempty(regexp(line, '^\s*```', 'once'))
            h = [h '<pre><code>' esc(strjoin(codeBuf, newline)) '</code></pre>' newline]; %#ok<AGROW>
            codeBuf = {};
            inCode = false;
        else
            codeBuf{end+1} = line; %#ok<AGROW>
        end
        i = i + 1;
        continue
    end
    if ~isempty(regexp(line, '^\s*```', 'once'))
        inCode = true;
        i = i + 1;
        continue
    end
    % table block: header row + separator row
    if i + 1 <= numel(lines) && ~isempty(regexp(line, '^\s*\|.*\|\s*$', 'once')) ...
            && ~isempty(regexp(lines{i+1}, '^\s*\|?\s*:?-{3,}', 'once'))
        [tbl, i] = parseTable(lines, i);
        h = [h tbl newline]; %#ok<AGROW>
        continue
    end
    if ~isempty(regexp(line, '^\s*(?:---+|\*\*\*+|___+)\s*$', 'once'))
        h = [h '<hr/>' newline]; %#ok<AGROW>
        i = i + 1;
        continue
    end
    tok = regexp(line, '^\s*(#{1,6})\s+(.*)$', 'tokens', 'once');
    if ~isempty(tok)
        lvl = min(4, numel(tok{1}) + 1);
        h = [h sprintf('<h%d>%s</h%d>', lvl, inlineMd(tok{2}), lvl) newline]; %#ok<AGROW>
        i = i + 1;
        continue
    end
    if ~isempty(regexp(line, '^\s*[-*+]\s+', 'once'))
        if ~strcmp(listType, 'ul')
            h = [h '<ul>' newline]; listType = 'ul'; %#ok<AGROW>
        end
        txt = regexprep(line, '^\s*[-*+]\s+', '');
        h = [h '<li>' inlineMd(txt) '</li>' newline]; %#ok<AGROW>
        i = i + 1;
        continue
    elseif ~isempty(regexp(line, '^\s*\d+[.)]\s+', 'once'))
        if ~strcmp(listType, 'ol')
            h = [h '<ol>' newline]; listType = 'ol'; %#ok<AGROW>
        end
        txt = regexprep(line, '^\s*\d+[.)]\s+', '');
        h = [h '<li>' inlineMd(txt) '</li>' newline]; %#ok<AGROW>
        i = i + 1;
        continue
    elseif ~isempty(listType)
        h = [h '</' listType '>' newline]; listType = '';
    end
    if isempty(strtrim(line))
        i = i + 1;
        continue
    end
    h = [h '<p>' inlineMd(line) '</p>' newline]; %#ok<AGROW>
    i = i + 1;
end
if ~isempty(listType)
    h = [h '</' listType '>' newline];
end
if inCode && ~isempty(codeBuf)
    h = [h '<pre><code>' esc(strjoin(codeBuf, newline)) '</code></pre>' newline];
end
end

function [tbl, next] = parseTable(lines, start)
header = splitRow(lines{start});
tbl = '<table class="md"><thead><tr>';
for k = 1:numel(header)
    tbl = [tbl sprintf('<th>%s</th>', inlineMd(header{k}))]; %#ok<AGROW>
end
tbl = [tbl '</tr></thead><tbody>'];
i = start + 2;
while i <= numel(lines) && ~isempty(regexp(lines{i}, '^\s*\|.*\|\s*$', 'once'))
    cells = splitRow(lines{i});
    tbl = [tbl '<tr>']; %#ok<AGROW>
    for k = 1:numel(cells)
        tbl = [tbl sprintf('<td>%s</td>', inlineMd(cells{k}))]; %#ok<AGROW>
    end
    tbl = [tbl '</tr>']; %#ok<AGROW>
    i = i + 1;
end
tbl = [tbl '</tbody></table>'];
next = i;
end

function card = buildModelCard(title, spec, fr, analysis, ident, sens, ...
    validation, modelSel, residDiag, figs, refs, limitations, commands, gates, runDir, workDir)
card = struct();
card.schema_version = 'bma.modelCard.v1';
card.title = title;
card.name = charIfy(getF(spec, 'name', 'model'));
card.description = charIfy(getF(spec, 'description', ''));
card.created_at = bma.util.nowIso();
card.software = struct('matlab', version, 'generator', 'BioModel-MATLAB', ...
    'report_builder', 'bma.report.build');
card.run_dir = bma.util.relPath(workDir, runDir);
card.spec = struct('schema_version', charIfy(getF(spec, 'schema_version', '')), ...
    'name', charIfy(getF(spec, 'name', '')), ...
    'title', charIfy(getF(spec, 'title', '')), ...
    'kind', charIfy(getF(spec, 'kind', '')), ...
    'time', getF(spec, 'time', struct()));
card.equations = renderEquations(spec);
card.assumptions = specAssumptions(spec);
card.reactions = cardReactions(spec);
card.parameters = cardParameters(spec, fr);
card.fitting = cardFitting(fr);
card.identifiability = cardIdentifiability(ident);
card.sensitivity = cardSensitivity(sens);
card.validation = cardValidation(validation, modelSel, residDiag);
card.analysis = cardAnalysis(analysis);
if ~isempty(gates)
    card.gates = gates;
else
    card.gates = struct('schema', 'bma.gates.v1', 'waivers', {{}});
end
card.figures = {};
for k = 1:numel(figs)
    card.figures{end+1} = struct('file', ['figures/' figs(k).name], ...
        'caption', figs(k).caption); %#ok<AGROW>
end
card.references = refs;
card.limitations = limitations;
card.reproducible_commands = commands;
card.files = struct('report_html', 'report.html', 'report_md', 'report.md', ...
    'model_card', 'model_card.json');
end

function e = cardEvidence(p)
e = {};
evList = evidenceCell(p);
for k = 1:numel(evList)
    ev = evList{k};
    item = struct();
    f = fieldnames(ev);
    for i = 1:numel(f)
        v = ev.(f{i});
        if ischar(v) || isnumeric(v)
            item.(f{i}) = v;
        end
    end
    if ~isempty(item)
        e{end+1} = item; %#ok<AGROW>
    end
end
if isempty(e)
    e = {struct('type', 'assumed', 'note', '规格未提供文献证据')};
end
end
% =========================================================================
% 通用小工具（升级补齐）
% =========================================================================
function v = getF(s, f, d)
v = d;
if ~isstruct(s) || isempty(s)
    return
end
if isfield(s, f)
    try
        x = s(1).(f);
    catch
        return
    end
    if ~isempty(x)
        v = x;
    end
end
end

function s = charIfy(v)
if ischar(v)
    s = v;
elseif isstring(v) && isscalar(v)
    s = char(v);
elseif isnumeric(v) && isscalar(v) && isfinite(v)
    s = sprintf('%.6g', v);
else
    try
        s = char(string(v));
    catch
        s = '';
    end
end
end

function c = toCellstr(x)
if iscell(x)
    c = cellfun(@charIfy, x, 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    c = {x};
else
    c = {};
end
end

function s = esc(s)
s = charIfy(s);
s = strrep(s, '&', '&amp;');
s = strrep(s, '<', '&lt;');
s = strrep(s, '>', '&gt;');
s = strrep(s, '"', '&quot;');
end

function s = escForCode(s)
s = strrep(charIfy(s), '''', '''''');
end

function s = num(x, sig)
if nargin < 2
    sig = 4;
end
if ~isnumeric(x) || isempty(x) || ~isfinite(x)
    s = '—';
else
    s = sprintf('%.*g', sig, double(x));
end
end

function r = ternary(cond, a, b)
if cond
    r = a;
else
    r = b;
end
end

function v = paramValueOf(p)
v = NaN;
if isfield(p, 'value') && ~isempty(p.value)
    if isnumeric(p.value) && isscalar(p.value)
        v = double(p.value);
    elseif isstruct(p.value) && isfield(p.value, 'value')
        v = double(p.value.value);
    end
end
end

function s = fieldLabel(f)
switch f
    case 'r2', s = 'R²';
    case 'rmse', s = 'RMSE';
    case 'nrmse', s = 'NRMSE';
    case 'aicc', s = 'AICc';
    case 'bic', s = 'BIC';
    case 'loglik', s = '对数似然';
    case 'n_observations', s = '观测点数';
    case 'n_parameters', s = '拟合参数数';
    otherwise, s = f;
end
end

function s = rateText(rate)
s = '—';
if ~isstruct(rate)
    return
end
kind = '';
if isfield(rate, 'kind') && ~isempty(rate.kind)
    kind = lower(char(rate.kind));
end
switch kind
    case 'mass_action'
        parts = {};
        if isfield(rate, 'parameters') && isstruct(rate.parameters)
            fn = fieldnames(rate.parameters);
            for k = 1:numel(fn)
                parts{end+1} = fn{k}; %#ok<AGROW>
            end
        end
        if isfield(rate, 'species') && isstruct(rate.species)
            fn = fieldnames(rate.species);
            for k = 1:numel(fn)
                parts{end+1} = fn{k}; %#ok<AGROW>
            end
        end
        if isempty(parts), s = 'k'; else, s = strjoin(parts, '·'); end
    case 'michaelis_menten'
        s = 'Vmax·S/(Km + S)';
    case 'hill'
        s = 'Vmax·S^n/(K^n + S^n)';
    case 'constant'
        if isfield(rate, 'value') && ~isempty(rate.value)
            s = num(rate.value);
        end
    case 'expression'
        if isfield(rate, 'expression') && ~isempty(rate.expression)
            s = char(rate.expression);
        end
    case 'matlab'
        if isfield(rate, 'display') && ~isempty(rate.display)
            s = char(rate.display);
        elseif isfield(rate, 'function') && ~isempty(rate.function)
            s = sprintf('%s(…)', char(rate.function));
        else
            s = '自定义 MATLAB 函数';
        end
end
end

function refs = normalizeReferences(x)
refs = {};
if iscell(x)
    for k = 1:numel(x)
        refs{end+1} = refString(x{k}); %#ok<AGROW>
    end
elseif isstruct(x)
    for k = 1:numel(x)
        refs{end+1} = refString(x(k)); %#ok<AGROW>
    end
elseif ischar(x) || isstring(x)
    refs = {char(x)};
end
refs = refs(~cellfun(@isempty, refs));
end

function c = splitRow(line)
c = strtrim(strsplit(strtrim(line), '|'));
if ~isempty(c) && isempty(c{1}), c = c(2:end); end
if ~isempty(c) && isempty(c{end}), c = c(1:end-1); end
c = cellfun(@strtrim, c, 'UniformOutput', false);
end

function s = inlineMd(s)
s = esc(s);
s = regexprep(s, [char(96) '([^' char(96) ']+)' char(96)], '<code>$1</code>');
s = regexprep(s, '\*\*([^*]+)\*\*', '<strong>$1</strong>');
s = regexprep(s, '(?<!\*)\*([^*]+)\*(?!\*)', '<em>$1</em>');
% Markdown image must be handled before the generic link rule; otherwise
% ![alt](url) becomes an <a> link and the figure disappears from the report.
s = regexprep(s, '!\[([^\]]*)\]\(([^)]+)\)', '<img alt="$1" src="$2">');
s = regexprep(s, '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2" rel="noopener">$1</a>');
end

function s = tableHtml(headers, rows, cls)
if nargin < 3 || isempty(cls)
    cls = 'tbl';
end
s = sprintf('<table class="%s"><thead><tr>', cls);
for k = 1:numel(headers)
    s = [s sprintf('<th>%s</th>', esc(headers{k}))]; %#ok<AGROW>
end
s = [s '</tr></thead><tbody>'];
if isempty(rows)
    s = [s sprintf('<tr><td colspan="%d">无数据</td></tr>', numel(headers))];
else
    for i = 1:size(rows, 1)
        s = [s '<tr>']; %#ok<AGROW>
        for j = 1:numel(headers)
            v = '';
            if j <= size(rows, 2)
                v = rows{i, j};
            end
            if isnumeric(v)
                v = num(v);
            else
                v = esc(v);
            end
            s = [s sprintf('<td>%s</td>', v)]; %#ok<AGROW>
        end
        s = [s '</tr>']; %#ok<AGROW>
    end
end
s = [s '</tbody></table>'];
end

function s = tableMd(headers, rows)
parts = {};
hdr = cell(1, numel(headers));
for k = 1:numel(headers)
    hdr{k} = charIfy(headers{k});
end
parts{end+1} = ['| ' strjoin(hdr, ' | ') ' |'];
sep = '|';
for k = 1:numel(headers)
    sep = [sep ' --- |']; %#ok<AGROW>
end
parts{end+1} = sep;
if isempty(rows)
    parts{end+1} = '| 无数据 |';
else
    for i = 1:size(rows, 1)
        cells = cell(1, numel(headers));
        for j = 1:numel(headers)
            v = '';
            if j <= size(rows, 2)
                v = rows{i, j};
            end
            if isnumeric(v)
                v = num(v);
            end
            cells{j} = strrep(charIfy(v), '|', '\|');
        end
        parts{end+1} = ['| ' strjoin(cells, ' | ') ' |']; %#ok<AGROW>
    end
end
s = strjoin(parts, newline);
end

function c = evidenceCell(p)
c = {};
if ~isfield(p, 'evidence') || isempty(p.evidence)
    return
end
x = p.evidence;
if iscell(x)
    c = x(cellfun(@isstruct, x));
elseif isstruct(x)
    c = num2cell(x);
end
end

% =========================================================================
% 各小节渲染
% =========================================================================
function s = overviewHtml(title, spec, fr, analysis)
parts = {'<p>' esc(title) '</p>'};
parts{end+1} = '<ul>';
parts{end+1} = sprintf('<li>模型：<b>%s</b>（%s）</li>', esc(getF(spec, 'name', '')), esc(getF(spec, 'kind', 'ode')));
nV = 0; nP = 0; nR = 0; nO = 0;
if isfield(spec, 'variables'), nV = numel(spec.variables); end
if isfield(spec, 'parameters'), nP = numel(spec.parameters); end
if isfield(spec, 'reactions'), nR = numel(spec.reactions); end
if isfield(spec, 'outputs'), nO = numel(spec.outputs); end
parts{end+1} = sprintf('<li>规模：%d 变量，%d 参数，%d 反应，%d 输出</li>', nV, nP, nR, nO);
if ~isempty(fr) && isstruct(fr)
    m = getF(fr, 'metrics', struct());
    if isstruct(m) && isfield(m, 'r2')
        parts{end+1} = sprintf('<li>拟合：R² = %s，RMSE = %s</li>', num(m.r2), num(getF(m, 'rmse', NaN)));
    else
        parts{end+1} = '<li>包含参数拟合结果。</li>';
    end
end
if ~isempty(analysis) && isstruct(analysis)
    c = getF(analysis, 'conservation', struct());
    parts{end+1} = sprintf('<li>分析：%d 个守恒律，%d 个稳态</li>', ...
        getF(c, 'n_laws', 0), getF(analysis, 'steady_state_count', 0));
end
parts{end+1} = '</ul>';
s = strjoin(parts, newline);
end

function s = overviewMd(title, spec, fr, analysis) %#ok<INUSD>
lines = {sprintf('# %s', title), ''};
lines{end+1} = sprintf('- 模型 `%s`（%s）', getF(spec, 'name', ''), getF(spec, 'kind', 'ode'));
lines{end+1} = sprintf('- 变量 %d，参数 %d，反应 %d，输出 %d', ...
    numel(getF(spec, 'variables', [])), numel(getF(spec, 'parameters', [])), ...
    numel(getF(spec, 'reactions', [])), numel(getF(spec, 'outputs', [])));
if ~isempty(fr) && isstruct(fr)
    m = getF(fr, 'metrics', struct());
    if isstruct(m) && isfield(m, 'r2')
        lines{end+1} = sprintf('- 拟合：R² = %s，RMSE = %s', num(m.r2), num(getF(m, 'rmse', NaN)));
    end
end
s = strjoin(lines, newline);
end

function s = equationsHtml(equations, spec) %#ok<INUSD>
s = '<pre class="eq">';
if isempty(equations)
    s = [s '模型规格未提供方程。'];
else
    s = [s esc(strjoin(equations, newline))];
end
s = [s '</pre>'];
end

function s = equationsMd(equations, spec) %#ok<INUSD>
if isempty(equations)
    s = '模型规格未提供方程。';
else
    s = ['```' newline strjoin(equations, newline) newline '```'];
end
end

function s = pdeHtml(spec)
p = spec.pde;
d = getF(p, 'domain', struct());
if double(getF(p, 'dim', 1)) >= 2
    mesh = getF(d, 'mesh', struct());
    rows = {
        '几何', charIfy(getF(d, 'geometry', '')), ...
        '维度', sprintf('%d', getF(p, 'dim', 2)), ...
        '尺寸/半径/文件', nativeGeomDesc(d), ...
        '网格', sprintf('hmax=%s hgrad=%s', ...
            charIfy(getF(mesh, 'hmax', 'auto')), charIfy(getF(mesh, 'hgrad', '1.3'))), ...
        '求解器', 'PDE Toolbox solvepde（原生，不转 ODE）'
        };
    parts = {'<p>该模型由 MATLAB PDE Toolbox 直接求解（geometry → mesh → coefficients → solvepde），不是 MOL/ODE 展开。</p>'};
    parts{end+1} = tableHtml({'项', '设置'}, rows, 'tbl');
    bc = getF(p, 'bc', {});
    if isstruct(bc) || iscell(bc)
        items = {};
        for k = 1:numel(bc)
            if iscell(bc), b = bc{k}; else, b = bc(k); end
            items{end+1} = sprintf('%s: %s', ...
                charIfy(getF(b, 'edge', getF(b, 'face', 'all'))), ...
                charIfy(getF(b, 'type', ''))); %#ok<AGROW>
        end
        parts{end+1} = sprintf('<p>边界条件：%s</p>', esc(strjoin(items, '；')));
    end
    probes = getF(p, 'probes', {});
    if isstruct(probes) || iscell(probes)
        parts{end+1} = sprintf('<p>探针：<b>%d</b> 个（最近网格节点时间序列）。</p>', numel(probes));
    end
    s = strjoin(parts, newline);
    return
end
rows = {
    '几何', charIfy(getF(d, 'geometry', '')), ...
    '维度', sprintf('%d', getF(p, 'dim', 1)), ...
    '范围', sprintf('%s %s', charIfy(getF(getF(d, 'extent', struct()), 'value', '')), ...
        charIfy(getF(getF(d, 'extent', struct()), 'unit', ''))), ...
    '网格', sprintf('%s n=%d', charIfy(getF(getF(d, 'grid', struct()), 'type', 'uniform')), ...
        getF(getF(d, 'grid', struct()), 'n', 0)), ...
    '近似', charIfy(getF(d, 'approximation', '(未声明)')), ...
    '离散', charIfy(getF(getF(p, 'discretization', struct()), 'scheme', 'finite_volume'))
    };
parts = {'<p>该模型以有限体积方法线（MOL）展开为 ODE；以下为空间离散与边界条件。</p>'};
parts{end+1} = tableHtml({'项', '设置'}, rows, 'tbl');
bc = getF(p, 'bc', {});
if isstruct(bc) || iscell(bc)
    items = {};
    for k = 1:numel(bc)
        if iscell(bc), b = bc{k}; else, b = bc(k); end
        items{end+1} = sprintf('%s: %s%s', charIfy(getF(b, 'face', '')), ...
            charIfy(getF(b, 'type', '')), ...
            ternaryStr(strcmpi(charIfy(getF(b, 'type', '')), 'dirichlet'), ...
            [' = ' charIfy(getF(b, 'value', ''))], '')); %#ok<AGROW>
    end
    parts{end+1} = sprintf('<p>边界条件：%s</p>', esc(strjoin(items, '；')));
end
s = strjoin(parts, newline);
end

function s = pdeMd(spec)
p = spec.pde;
d = getF(p, 'domain', struct());
if double(getF(p, 'dim', 1)) >= 2
    s = strjoin({'- PDE Toolbox 原生求解（不转 ODE）', ...
        sprintf('- 几何 `%s`，%s', charIfy(getF(d, 'geometry', '')), nativeGeomDesc(d)), ...
        sprintf('- 网格 hmax=%s hgrad=%s', charIfy(getF(getF(d, 'mesh', struct()), 'hmax', 'auto')), ...
        charIfy(getF(getF(d, 'mesh', struct()), 'hgrad', '1.3')))}, newline);
    return
end
lines = {'- PDE 空间离散：有限体积 MOL（1D 规则网格）', ...
    sprintf('- 几何 `%s`，范围 `%s %s`，网格 `%s n=%d`', ...
    charIfy(getF(d, 'geometry', '')), ...
    charIfy(getF(getF(d, 'extent', struct()), 'value', '')), ...
    charIfy(getF(getF(d, 'extent', struct()), 'unit', '')), ...
    charIfy(getF(getF(d, 'grid', struct()), 'type', 'uniform')), ...
    getF(getF(d, 'grid', struct()), 'n', 0)), ...
    sprintf('- 近似：`%s`', charIfy(getF(d, 'approximation', '(未声明)')))};
s = strjoin(lines, newline);
end

function out = ternaryStr(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end

function s = nativeGeomDesc(d)
g = lower(charIfy(getF(d, 'geometry', '')));
switch g
    case 'rectangle'
        s = sprintf('rectangle size=%s', mat2str(getF(d, 'size', [])));
    case 'circle'
        s = sprintf('circle radius=%s', charIfy(getF(d, 'radius', '')));
    case 'polygon'
        pts = getF(d, 'points', []);
        s = sprintf('polygon %d points', size(pts, 1));
    case 'box'
        s = sprintf('box size=%s', mat2str(getF(d, 'size', [])));
    case 'stl'
        s = sprintf('STL file=%s', charIfy(getF(d, 'file', '')));
    otherwise
        s = g;
end
end

function s = assumptionsHtml(assumptions)
if isempty(assumptions)
    s = '<p>规格未显式给出建模假设。</p>';
    return
end
parts = {'<ul>'};
for k = 1:numel(assumptions)
    parts{end+1} = sprintf('<li>%s</li>', esc(assumptions{k})); %#ok<AGROW>
end
parts{end+1} = '</ul>';
s = strjoin(parts, newline);
end

function s = assumptionsMd(assumptions)
if isempty(assumptions)
    s = '规格未显式给出建模假设。';
    return
end
parts = {};
for k = 1:numel(assumptions)
    parts{end+1} = sprintf('- %s', assumptions{k}); %#ok<AGROW>
end
s = strjoin(parts, newline);
end

function s = analysisHtml(a)
if isempty(a) || ~isstruct(a)
    s = '<p>未进行模型分析。</p>';
    return
end
parts = {};
c = getF(a, 'conservation', struct());
if isstruct(c)
    parts{end+1} = sprintf('<p>守恒律：<b>%d</b> 个。</p>', getF(c, 'n_laws', 0));
end
parts{end+1} = sprintf('<p>稳态：找到 <b>%d</b> 个非负物理稳态。</p>', getF(a, 'steady_state_count', 0));
uc = getF(a, 'units', struct());
if isstruct(uc)
    parts{end+1} = sprintf('<p>量纲检查：%s（%d errors / %d warnings）。</p>', ...
        ternary(logical(getF(uc, 'ok', 0)), '通过', '存在问题'), ...
        getF(uc, 'n_errors', 0), getF(uc, 'n_warnings', 0));
end
if isfield(a, 'guard_substitution') && isfield(a.guard_substitution, 'stripped') ...
        && ~isempty(a.guard_substitution.stripped)
    parts{end+1} = sprintf('<p>数值护栏：为符号分析剥离了 %d 处数值 min/max（数值稳态仍用原始 RHS）。</p>', ...
        numel(a.guard_substitution.stripped));
end
if isfield(a, 'notes') && ~isempty(a.notes)
    parts{end+1} = '<ul>';
    for k = 1:min(8, numel(a.notes))
        parts{end+1} = sprintf('<li>%s</li>', esc(charIfy(a.notes{k}))); %#ok<AGROW>
    end
    parts{end+1} = '</ul>';
end
s = strjoin(parts, newline);
end

function s = analysisMd(a)
if isempty(a) || ~isstruct(a)
    s = '未进行模型分析。';
    return
end
c = getF(a, 'conservation', struct());
lines = {sprintf('- 守恒律：%d 个', getF(c, 'n_laws', 0))};
lines{end+1} = sprintf('- 稳态：%d 个', getF(a, 'steady_state_count', 0));
uc = getF(a, 'units', struct());
if isstruct(uc)
    lines{end+1} = sprintf('- 量纲检查：%s（%d errors / %d warnings）', ...
        ternary(logical(getF(uc, 'ok', 0)), '通过', '存在问题'), ...
        getF(uc, 'n_errors', 0), getF(uc, 'n_warnings', 0));
end
s = strjoin(lines, newline);
end

function s = paramsHtml(rows)
if isempty(rows)
    s = '<p>模型没有参数。</p>';
    return
end
s = tableHtml({'参数', '名称', '单位', '值', '95% CI', '状态', '证据类型', '证据/引文'}, rows);
s = [s newline '<p class="meta">证据来自规格 evidence 字段；未提供证据的参数显式标为 assumed。</p>'];
end

function s = paramsMd(rows)
if isempty(rows)
    s = '模型没有参数。';
    return
end
s = tableMd({'参数', '名称', '单位', '值', '95% CI', '状态', '证据类型', '证据/引文'}, rows);
s = [s newline '' newline '> 证据来自规格 evidence 字段；未提供证据的参数显式标为 assumed。'];
end

function s = methodsHtml(lines)
if isempty(lines)
    s = '<p>使用默认参数估计流程（有界多起点最小二乘）。</p>';
    return
end
parts = {'<ul>'};
for k = 1:numel(lines)
    parts{end+1} = sprintf('<li>%s</li>', esc(lines{k})); %#ok<AGROW>
end
parts{end+1} = '</ul>';
s = strjoin(parts, newline);
end

function s = methodsMd(lines)
if isempty(lines)
    s = '使用默认参数估计流程（有界多起点最小二乘）。';
    return
end
parts = {};
for k = 1:numel(lines)
    parts{end+1} = sprintf('- %s', lines{k}); %#ok<AGROW>
end
s = strjoin(parts, newline);
end

function rows = metricTableRows(fr)
rows = {};
if isempty(fr) || ~isstruct(fr)
    return
end
m = getF(fr, 'metrics', struct());
if ~isstruct(m), return; end
fields = {'r2', 'rmse', 'nrmse', 'aicc', 'bic', 'loglik', 'n_observations', 'n_parameters'};
for k = 1:numel(fields)
    f = fields{k};
    if isfield(m, f) && ~isempty(m.(f)) && isnumeric(m.(f)) && isfinite(m.(f))
        rows{end+1, 1} = fieldLabel(f); %#ok<AGROW>
        rows{end, 2} = num(m.(f)); %#ok<AGROW>
        note = '';
        switch f
            case 'r2', note = '越接近 1 越好';
            case 'rmse', note = '与输出同单位';
            case 'aicc', note = '小样本校正 AIC，越小越好';
            case 'bic', note = '贝叶斯信息准则，越小越好';
        end
        rows{end, 3} = note; %#ok<AGROW>
    end
end
end

function s = fitHtml(rows, fr)
if isempty(fr) || ~isstruct(fr)
    s = '<p>本报告未包含参数拟合结果（或拟合未收敛）。</p>';
    return
end
parts = {};
if isfield(fr, 'converged') && logical(fr.converged)
    parts{end+1} = '<p>拟合状态：<b>收敛</b>。</p>';
else
    parts{end+1} = '<p>拟合状态：<b>未确认收敛</b>，请检查 solver_info。</p>';
end
if ~isempty(rows)
    parts{end+1} = tableHtml({'指标', '值', '说明'}, rows);
end
if isfield(fr, 'warnings') && ~isempty(fr.warnings)
    parts{end+1} = '<p>拟合警告：</p><ul>';
    for k = 1:numel(fr.warnings)
        parts{end+1} = sprintf('<li>%s</li>', esc(charIfy(fr.warnings{k}))); %#ok<AGROW>
    end
    parts{end+1} = '</ul>';
end
if isfield(fr, 'solver_info') && isstruct(fr.solver_info)
    parts{end+1} = sprintf('<p class="meta">多起点：%d 个起点，目标函数最好值 %s；求解器 %s。</p>', ...
        getF(fr.solver_info, 'n_starts', 0), ...
        num(getF(fr.solver_info, 'best_objective', NaN)), ...
        esc(charIfy(getF(fr.solver_info, 'solver', ''))));
end
s = strjoin(parts, newline);
end

function s = fitMd(rows, fr)
if isempty(fr) || ~isstruct(fr)
    s = '本报告未包含参数拟合结果。';
    return
end
parts = {sprintf('拟合状态：%s。', ternary(logical(getF(fr, 'converged', false)), '收敛', '未确认收敛'))};
if ~isempty(rows)
    parts{end+1} = tableMd({'指标', '值', '说明'}, rows);
end
s = strjoin(parts, newline);
end

function rows = sensitivityRows(sens)
rows = {};
if isempty(sens) || ~isstruct(sens)
    return
end
if isfield(sens, 'table') && ~isempty(sens.table)
    T = sens.table;
    for k = 1:numel(T)
        r = T(k);
        rows{end+1, 1} = charIfy(getF(r, 'param', '')); %#ok<AGROW>
        rows{end, 2} = charIfy(getF(r, 'output', '')); %#ok<AGROW>
        rows{end, 3} = num(getF(r, 'sobol_total', NaN)); %#ok<AGROW>
        rows{end, 4} = num(getF(r, 'sobol_first', NaN)); %#ok<AGROW>
        rows{end, 5} = num(getF(r, 'local_max_abs_elasticity', NaN)); %#ok<AGROW>
    end
    return
end
ids = toCellstr(getF(sens, 'param_ids', {}));
outs = toCellstr(getF(sens, 'output_ids', {}));
if isfield(sens, 'indices') && isstruct(sens.indices)
    tot = getF(sens.indices, 'total', []);
    fst = getF(sens.indices, 'first', []);
    for i = 1:numel(ids)
        for j = 1:min(numel(outs), size(tot, 2))
            rows{end+1, 1} = ids{i}; %#ok<AGROW>
            rows{end, 2} = outs{j}; %#ok<AGROW>
            if ~isempty(tot), rows{end, 3} = num(tot(i, j)); end %#ok<AGROW>
            if ~isempty(fst) && size(fst, 2) >= j, rows{end, 4} = num(fst(i, j)); end %#ok<AGROW>
            rows{end, 5} = '—'; %#ok<AGROW>
        end
    end
end
end

function s = sensitivityHtml(rows, sens)
parts = {'<p>敏感性分析结果（Sobol 总效应/一阶效应，或局部弹性）。</p>'};
if isstruct(sens) && isfield(sens, 'budget') && isstruct(sens.budget)
    b = sens.budget;
    parts{end+1} = sprintf('<p class="meta">成本：估算 %s s，实际 %s s；样本 %s/%s（N=%s）。</p>', ...
        num(getF(b, 'estimated_seconds', NaN), 1), ...
        num(getF(b, 'actual_seconds', NaN), 1), ...
        charIfy(getF(b, 'executed_samples', '—')), charIfy(getF(b, 'sample_count', '—')), ...
        charIfy(getF(b, 'sobol_n', '—')));
    if logical(getF(b, 'partial', false))
        parts{end+1} = '<p>注意：达到墙钟上限，返回部分结果。</p>';
    end
end
if isempty(rows)
    parts{end+1} = '<p>敏感性结果为空（可能因预算跳过）。</p>';
else
    parts{end+1} = tableHtml({'参数', '输出', 'Sobol 总效应', 'Sobol 一阶', '局部 |E|max'}, rows);
end
if isstruct(sens) && isfield(sens, 'warnings') && ~isempty(sens.warnings)
    parts{end+1} = '<ul>';
    for k = 1:numel(sens.warnings)
        parts{end+1} = sprintf('<li>%s</li>', esc(charIfy(sens.warnings{k}))); %#ok<AGROW>
    end
    parts{end+1} = '</ul>';
end
s = strjoin(parts, newline);
end

function s = sensitivityMd(rows, sens) %#ok<INUSD>
parts = {'敏感性分析结果。'};
if isempty(rows)
    parts{end+1} = '敏感性结果为空（可能因预算跳过）。';
else
    parts{end+1} = tableMd({'参数', '输出', 'Sobol 总效应', 'Sobol 一阶', '局部 |E|max'}, rows);
end
s = strjoin(parts, newline);
end

function content = validationBlock(validation, modelSel, residDiag)
html = {};
md = {};
html{end+1} = '<p>模型验证（残差诊断 / 交叉验证 / 模型选择）如下。</p>';
md{end+1} = '- 模型验证：残差诊断 / 交叉验证 / 模型选择。';
if isstruct(residDiag) && ~isempty(fieldnames(residDiag))
    if isfield(residDiag, 'summary') && isstruct(residDiag.summary)
        rd = residDiag.summary;
    else
        rd = residDiag;
    end
    html{end+1} = '<h3 class="sub">残差诊断</h3><ul>';
    fn = fieldnames(rd);
    for k = 1:numel(fn)
        v = rd.(fn{k});
        if isnumeric(v) && isscalar(v)
            html{end+1} = sprintf('<li>%s：%s</li>', esc(fn{k}), num(v)); %#ok<AGROW>
            md{end+1} = sprintf('  - %s：%s', fn{k}, num(v)); %#ok<AGROW>
        elseif ischar(v)
            html{end+1} = sprintf('<li>%s：%s</li>', esc(fn{k}), esc(v)); %#ok<AGROW>
            md{end+1} = sprintf('  - %s：%s', fn{k}, v); %#ok<AGROW>
        end
    end
    html{end+1} = '</ul>';
else
    html{end+1} = '<p>无残差诊断（需提供拟合结果）。</p>';
    md{end+1} = '  - 无残差诊断。';
end
if isstruct(validation) && ~isempty(fieldnames(validation))
    if isfield(validation, 'summary') && ischar(validation.summary)
        html{end+1} = sprintf('<p>%s</p>', esc(validation.summary));
        md{end+1} = ['  - ' validation.summary];
    end
    if isfield(validation, 'warnings') && ~isempty(validation.warnings)
        for k = 1:numel(validation.warnings)
            html{end+1} = sprintf('<p>警告：%s</p>', esc(charIfy(validation.warnings{k}))); %#ok<AGROW>
        end
    end
end
if ~isempty(modelSel) && isstruct(modelSel)
    html{end+1} = '<h3 class="sub">模型选择</h3>';
    html{end+1} = '<pre class="eq">';
    html{end+1} = esc(jsonencode(modelSel));
    html{end+1} = '</pre>';
end
content = struct('html', strjoin(html, newline), 'md', strjoin(md, newline));
end

function lines = limitationLines(spec, fr, ident, residDiag, warnings, figs) %#ok<INUSD>
lines = {};
if isfield(spec, 'assumptions') && ~isempty(spec.assumptions)
    lines{end+1} = '模型结论依赖规格中的建模假设；假设改变会改变参数解释。';
end
if ~isempty(fr) && isstruct(fr)
    if isfield(fr, 'params')
        nFix = 0;
        for k = 1:numel(fr.params)
            if isfield(fr.params(k), 'fixed') && logical(fr.params(k).fixed)
                nFix = nFix + 1;
            end
        end
        if nFix > 0
            lines{end+1} = sprintf('有 %d 个参数固定为文献/假设值，其不确定性未传播到输出。', nFix); %#ok<AGROW>
        end
    end
    if isfield(fr, 'warnings') && ~isempty(fr.warnings)
        for k = 1:numel(fr.warnings)
            lines{end+1} = sprintf('拟合警告：%s', charIfy(fr.warnings{k})); %#ok<AGROW>
        end
    end
end
if ~isempty(ident) && isstruct(ident) && isfield(ident, 'structural') ...
        && isfield(ident.structural, 'deficient') && ident.structural.deficient > 0
    lines{end+1} = sprintf('存在 %d 个不可辨识方向，相关参数不能单独解释。', ident.structural.deficient);
end
if ~isempty(warnings)
    for k = 1:numel(warnings)
        lines{end+1} = sprintf('报告警告：%s', charIfy(warnings{k})); %#ok<AGROW>
    end
end
if isempty(lines)
    lines = {'未发现额外限制；但模型结论仍受数据范围与实验条件约束。'};
end
end

function s = figuresHtml(figs)
if isempty(figs)
    s = '<p>无图。</p>';
    return
end
parts = {};
for k = 1:numel(figs)
    f = figs(k);
    if isempty(getF(f, 'base64', ''))
        continue
    end
    parts{end+1} = '<figure>'; %#ok<AGROW>
    mime = getF(f, 'mime', 'image/png');
    if isempty(mime)
        mime = 'image/png';
    end
    parts{end+1} = sprintf('<img alt="%s" src="data:%s;base64,%s">', ...
        esc(getF(f, 'name', '')), mime, f.base64); %#ok<AGROW>
    parts{end+1} = sprintf('<figcaption>图 %d：%s</figcaption>', k, esc(getF(f, 'caption', ''))); %#ok<AGROW>
    parts{end+1} = '</figure>'; %#ok<AGROW>
end
s = strjoin(parts, newline);
end

function s = figuresMd(figs)
if isempty(figs)
    s = '无图。';
    return
end
parts = {};
for k = 1:numel(figs)
    f = figs(k);
    parts{end+1} = sprintf('![%s](figures/%s)', getF(f, 'caption', ''), getF(f, 'name', '')); %#ok<AGROW>
    parts{end+1} = ''; %#ok<AGROW>
end
s = strjoin(parts, newline);
end

function s = extraHtml(title, body) %#ok<INUSD>
s = ['<div class="extra">' newline mdToHtml(char(body)) newline '</div>'];
end

function s = extraMd(title, body) %#ok<INUSD>
s = char(body);
end

% ======================================================================
% 质量门豁免（gates.json，由 bma_gate_waive 写入）
% ======================================================================
function gates = loadGates(runDir)
gates = [];
p = fullfile(runDir, 'gates.json');
if ~isfile(p)
    return
end
try
    doc = bma.util.readJson(p);
catch
    return
end
if ~isstruct(doc) || ~isfield(doc, 'waivers') || isempty(doc.waivers)
    return
end
if isstruct(doc.waivers) && ~iscell(doc.waivers)
    doc.waivers = num2cell(doc.waivers);
end
if ~iscell(doc.waivers) || isempty(doc.waivers)
    return
end
gates = doc;
end

function s = gatesHtml(gates)
parts = {'<table class="tbl"><thead><tr><th>质量门</th><th>豁免理由</th><th>替代证据</th><th>记录时间</th></tr></thead><tbody>'};
for k = 1:numel(gates.waivers)
    w = gates.waivers{k};
    parts{end+1} = sprintf('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>', ...
        esc(charIfy(getF(w, 'gate', ''))), esc(charIfy(getF(w, 'reason', ''))), ...
        esc(charIfy(getF(w, 'substitute', ''))), esc(charIfy(getF(w, 'recorded_at', '')))); %#ok<AGROW>
end
parts{end+1} = '</tbody></table>';
s = strjoin(parts, newline);
end

function s = gatesMd(gates)
parts = {'| 质量门 | 豁免理由 | 替代证据 | 记录时间 |', '| --- | --- | --- | --- |'};
for k = 1:numel(gates.waivers)
    w = gates.waivers{k};
    parts{end+1} = sprintf('| %s | %s | %s | %s |', ...
        strrep(charIfy(getF(w, 'gate', '')), '|', '\|'), ...
        strrep(charIfy(getF(w, 'reason', '')), '|', '\|'), ...
        strrep(charIfy(getF(w, 'substitute', '')), '|', '\|'), ...
        strrep(charIfy(getF(w, 'recorded_at', '')), '|', '\|')); %#ok<AGROW>
end
s = strjoin(parts, newline);
end

% ======================================================================
% 额外章节图片：拷贝进 report/figures 并转为 data URI
% ======================================================================
function [htmlBody, mdBody, warnings, sources] = prepareExtraBody(body, runDir, reportDir, figOutDir, workDir, idx)
htmlBody = char(body);
mdBody = htmlBody;
warnings = {};
sources = {};
pat = '!\[([^\]]*)\]\(([^)]+)\)';
[tokens, starts, ends] = regexp(htmlBody, pat, 'tokens', 'start', 'end');
if isempty(tokens)
    return
end
for k = numel(tokens):-1:1
    alt = tokens{k}{1};
    url = tokens{k}{2};
    [newUrl, newMd, w, srcPath] = resolveExtraImage(url, runDir, reportDir, figOutDir, workDir, idx);
    warnings = [warnings, w]; %#ok<AGROW>
    if ~isempty(srcPath)
        sources{end+1} = srcPath; %#ok<AGROW>
    end
    if isempty(newUrl)
        replacementHtml = alt;
        replacementMd = alt;
    else
        replacementHtml = ['![' alt '](' newUrl ')'];
        replacementMd = ['![' alt '](' newMd ')'];
    end
    htmlBody = [htmlBody(1:starts(k) - 1) replacementHtml htmlBody(ends(k) + 1:end)]; %#ok<AGROW>
    mdBody = [mdBody(1:starts(k) - 1) replacementMd mdBody(ends(k) + 1:end)]; %#ok<AGROW>
end
end

function [htmlUrl, mdUrl, warnings, srcPath] = resolveExtraImage(url, runDir, reportDir, figOutDir, workDir, idx)
htmlUrl = '';
mdUrl = '';
warnings = {};
srcPath = '';
u = strtrim(char(url));
u = regexprep(u, '\s+"[^"]*"\s*$', '');
if isempty(u)
    warnings{end+1} = '额外章节含空图片路径，已忽略。'; %#ok<AGROW>
    return
end
if startsWith(u, 'data:')
    htmlUrl = u;
    mdUrl = u;
    return
end
if ~isempty(regexp(u, '^https?://', 'once'))
    % Remote images cannot be embedded without network access; keep the URL
    % but tell the author that the report is not fully self-contained.
    htmlUrl = u;
    mdUrl = u;
    warnings{end+1} = sprintf('额外章节图片为远程 URL，未内嵌（报告不自包含）：%s', u); %#ok<AGROW>
    return
end
p = resolveImagePath(u, runDir, reportDir, workDir);
if isempty(p)
    warnings{end+1} = sprintf('额外章节图片不存在，已用 alt 文本代替：%s', u); %#ok<AGROW>
    return
end
srcPath = p;
[~, base, ext] = fileparts(p);
ext = lower(ext);
mime = mimeOf(ext);
if isempty(mime)
    warnings{end+1} = sprintf('额外章节图片格式不支持（%s），已跳过：%s', ext, p); %#ok<AGROW>
    return
end
name = sprintf('extra_%d_%s%s', idx, sanitizeFile(base), ext);
dst = fullfile(figOutDir, name);
if ~strcmpi(normalizePath(p), normalizePath(dst))
    try
        copyfile(p, dst, 'f');
    catch err
        warnings{end+1} = sprintf('复制额外章节图片失败 %s：%s', p, err.message); %#ok<AGROW>
        return
    end
end
b64 = base64Of(dst);
if isempty(b64)
    warnings{end+1} = sprintf('额外章节图片读取/base64 失败：%s', p); %#ok<AGROW>
    return
end
htmlUrl = sprintf('data:%s;base64,%s', mime, b64);
mdUrl = ['figures/' name];
end

function p = resolveImagePath(u, runDir, reportDir, workDir)
p = '';
u = strrep(u, '/', filesep);
if ~isempty(regexp(u, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    if isfile(u)
        p = u;
    end
    return
end
cands = {fullfile(workDir, u), fullfile(runDir, u), fullfile(reportDir, u)};
for k = 1:numel(cands)
    if isfile(cands{k})
        p = cands{k};
        return
    end
end
end

function mime = mimeOf(ext)
switch lower(ext)
    case '.png'
        mime = 'image/png';
    case {'.jpg', '.jpeg'}
        mime = 'image/jpeg';
    case '.gif'
        mime = 'image/gif';
    case '.webp'
        mime = 'image/webp';
    case '.svg'
        mime = 'image/svg+xml';
    otherwise
        mime = '';
end
end

function s = sanitizeFile(s)
s = regexprep(char(s), '[^A-Za-z0-9._-]+', '_');
if isempty(s)
    s = 'image';
end
end

function s = referencesHtml(refs)
if isempty(refs)
    s = '<p>无参考文献（规格未提供 evidence source / source_docs）。</p>';
    return
end
parts = {'<ol>'};
for k = 1:numel(refs)
    parts{end+1} = sprintf('<li>%s</li>', esc(refs{k})); %#ok<AGROW>
end
parts{end+1} = '</ol>';
s = strjoin(parts, newline);
end

function s = referencesMd(refs)
if isempty(refs)
    s = '无参考文献。';
    return
end
parts = {};
for k = 1:numel(refs)
    parts{end+1} = sprintf('%d. %s', k, refs{k}); %#ok<AGROW>
end
s = strjoin(parts, newline);
end

function s = listHtml(items)
if isempty(items)
    s = '<p>无。</p>';
    return
end
parts = {'<ul>'};
for k = 1:numel(items)
    parts{end+1} = sprintf('<li>%s</li>', esc(charIfy(items{k}))); %#ok<AGROW>
end
parts{end+1} = '</ul>';
s = strjoin(parts, newline);
end

function s = listMd(items)
if isempty(items)
    s = '无。';
    return
end
parts = {};
for k = 1:numel(items)
    parts{end+1} = sprintf('- %s', charIfy(items{k})); %#ok<AGROW>
end
s = strjoin(parts, newline);
end

function s = codeHtml(commands)
s = ['<pre class="code">' esc(strjoin(toCellstr(commands), newline)) '</pre>'];
end

function s = codeMd(commands)
s = ['```matlab' newline strjoin(toCellstr(commands), newline) newline '```'];
end

function s = filesHtml(runDir, spec, fr, analysis, figs) %#ok<INUSD>
parts = {'<ul>'};
parts{end+1} = '<li>report.html（本文件，自包含）</li>';
parts{end+1} = '<li>report.md（Markdown 版本）</li>';
parts{end+1} = '<li>model_card.json（机器可读模型卡）</li>';
if ~isempty(figs)
    parts{end+1} = sprintf('<li>figures/：%d 个 PNG</li>', numel(figs));
end
parts{end+1} = '</ul>';
parts{end+1} = sprintf('<p class="meta">运行目录：%s</p>', esc(runDir));
s = strjoin(parts, newline);
end

function s = filesMd(runDir, spec, fr, analysis, figs) %#ok<INUSD>
lines = {'- `report.html`（自包含）', '- `report.md`', '- `model_card.json`'};
if ~isempty(figs)
    lines{end+1} = sprintf('- `figures/`：%d 个 PNG', numel(figs));
end
lines{end+1} = sprintf('- 运行目录：`%s`', runDir);
s = strjoin(lines, newline);
end

% =========================================================================
% 模型卡辅助
% =========================================================================
function c = cardReactions(spec)
c = {};
if ~isfield(spec, 'reactions') || isempty(spec.reactions)
    return
end
for k = 1:numel(spec.reactions)
    r = spec.reactions(k);
    item = struct('id', charIfy(getF(r, 'id', '')), ...
        'name', charIfy(getF(r, 'name', '')), ...
        'rate_kind', charIfy(getF(getF(r, 'rate', struct()), 'kind', '')), ...
        'rate', rateText(getF(r, 'rate', struct())));
    if isfield(r, 'stoichiometry') && isstruct(r.stoichiometry)
        item.stoichiometry = r.stoichiometry;
    end
    c{end+1} = item; %#ok<AGROW>
end
end

function c = cardParameters(spec, fr)
c = {};
if ~isfield(spec, 'parameters') || isempty(spec.parameters)
    return
end
fitValues = struct();
if ~isempty(fr) && isfield(fr, 'params')
    P = fr.params;
    for k = 1:numel(P)
        try
            fitValues.(char(P(k).id)) = P(k);
        catch
        end
    end
end
for k = 1:numel(spec.parameters)
    p = spec.parameters(k);
    id = char(p.id);
    item = struct('id', id, 'name', charIfy(getF(p, 'name', id)), ...
        'unit', charIfy(getF(p, 'unit', '')), ...
        'value', paramValueOf(p), 'fixed', true, ...
        'evidence', {cardEvidence(p)});
    if isfield(p, 'estimate') && ~isempty(p.estimate)
        item.estimate = logical(p.estimate);
    end
    if isfield(p, 'bounds') && ~isempty(p.bounds)
        item.bounds = double(p.bounds(:).');
    end
    if isfield(fitValues, id)
        q = fitValues.(id);
        item.value = q.value;
        if isfield(q, 'fixed'), item.fixed = logical(q.fixed); end
        if isfield(q, 'se'), item.se = q.se; end
        if isfield(q, 'ci_low'), item.ci_low = q.ci_low; end
        if isfield(q, 'ci_high'), item.ci_high = q.ci_high; end
    end
    c{end+1} = item; %#ok<AGROW>
end
end

function c = cardFitting(fr)
c = struct('included', false);
if isempty(fr) || ~isstruct(fr)
    return
end
c.included = true;
c.converged = logical(getF(fr, 'converged', false));
if isfield(fr, 'metrics') && isstruct(fr.metrics)
    c.metrics = fr.metrics;
end
if isfield(fr, 'warnings') && ~isempty(fr.warnings)
    c.warnings = fr.warnings;
end
end

function c = cardIdentifiability(ident)
c = struct('included', false);
if isempty(ident) || ~isstruct(ident)
    return
end
c.included = true;
if isfield(ident, 'structural') && isstruct(ident.structural)
    c.structural = ident.structural;
end
if isfield(ident, 'practical') && isstruct(ident.practical)
    c.practical = ident.practical;
end
if isfield(ident, 'suggestions')
    c.suggestions = ident.suggestions;
end
end

function c = cardSensitivity(sens)
c = struct('included', false);
if isempty(sens) || ~isstruct(sens)
    return
end
c.included = true;
if isfield(sens, 'method'), c.method = sens.method; end
if isfield(sens, 'param_ids'), c.param_ids = sens.param_ids; end
if isfield(sens, 'indices'), c.indices = sens.indices; end
if isfield(sens, 'budget'), c.budget = sens.budget; end
if isfield(sens, 'skipped'), c.skipped = sens.skipped; end
end

function c = cardValidation(validation, modelSel, residDiag)
c = struct();
if isstruct(validation) && ~isempty(fieldnames(validation))
    c.validation = validation;
end
if ~isempty(modelSel) && isstruct(modelSel)
    c.model_selection = modelSel;
end
if ~isempty(residDiag) && isstruct(residDiag)
    c.residual_diagnostics = residDiag;
end
end

function c = cardAnalysis(analysis)
c = struct('included', false);
if isempty(analysis) || ~isstruct(analysis)
    return
end
c.included = true;
keep = {'conservation', 'steady_state_count', 'units', 'guard_substitution', 'warnings', 'notes'};
for k = 1:numel(keep)
    if isfield(analysis, keep{k})
        c.(keep{k}) = analysis.(keep{k});
    end
end
end

