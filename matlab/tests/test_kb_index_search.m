% test_kb_index_search.m — 验证 bma.kb.index/list/search/get/units 与 mtime 失效重建。
% 使用测试内自建的 fixture KB（tempname 临时目录），不依赖项目 kb/ 内容。
% 由 matlab/tests/run_all_tests.m 或 RPC test.run 调用，失败即抛异常。

fprintf('  [test_kb_index_search] start\n');
kbDir = tempname;
mkdir(kbDir);
cleaner = onCleanup(@() safeRmdir(kbDir));
bma.util.ensureDir(fullfile(kbDir, 'archetypes'));
bma.util.ensureDir(fullfile(kbDir, 'principles'));

% ---- 1) fixture KB 内容 ----
ontology = struct();
ontology.id = 'ontology';
ontology.type = 'ontology';
ontology.name = '生物系统建模本体';
ontology.name_en = 'BioModel-MATLAB ontology';
ontology.description = '层次、尺度与模型类别';
ontology.levels = { ...
    struct('id', 'molecule', 'name', '分子层', 'description', '单个大分子', ...
    'examples', {{'酶', '受体'}}, 'typical_questions', {{'结合亲和力 Kd'}}), ...
    struct('id', 'cell', 'name', '细胞层', 'description', '单细胞整合单元', ...
    'examples', {{'神经元'}}, 'typical_questions', {{'细胞命运'}})};
ontology.model_classes = { ...
    struct('id', 'ode', 'name', '常微分方程', 'when', '浓度随时间变化', ...
    'matlab_impl', 'ode15s')};
ontology.scales = { ...
    struct('id', 'molecular', 'name', '分子尺度', 'description', 'nm 与 us-s')};
bma.util.writeJsonAtomic(fullfile(kbDir, 'ontology.json'), ontology);

% units.json 故意使用非法 MATLAB 字段名（"1/s"、"%"), 验证正则解析
unitsJson = [ ...
    '{"id":"units","type":"units","name":"单位表","units":{' ...
    '"1/s":{"dim":"frequency","factor":1,"base":"1/s","symbol":"1/s","aliases":["s-1"]},' ...
    '"uM":{"dim":"concentration","factor":1e-6,"base":"M","symbol":"uM","aliases":["µM","umol/L"]},' ...
    '"%":{"dim":"dimensionless","factor":0.01,"base":"1","symbol":"%"}}}'];
bma.util.writeTextAtomic(fullfile(kbDir, 'units.json'), unitsJson);

enzyme = struct();
enzyme.id = 'enzyme_kinetics';
enzyme.type = 'archetype';
enzyme.name = '米氏酶动力学';
enzyme.name_en = 'Michaelis-Menten enzyme kinetics';
enzyme.domain = 'enzyme_kinetics';
enzyme.scale = 'molecule';
enzyme.model_class = 'ode';
enzyme.summary = 'Michaelis-Menten 底物饱和速率与竞争/非竞争抑制类型。';
enzyme.when_to_use = {'文献报告 Km、Vmax、kcat 数值', '初始速度法与 Lineweaver-Burk 作图'};
enzyme.tags = {'酶动力学', 'Michaelis-Menten', '抑制', '剂量-反应'};
enzyme.keywords = {'米氏方程', '米氏酶动力学', 'Km', 'Vmax', 'kcat', ...
    'enzyme kinetics', 'inhibition', 'competitive inhibition'};
eq = struct('name', '米氏速率', 'latex', 'v=\frac{V_{max}S}{K_m+S}', ...
    'plain', 'v = Vmax*S/(Km+S)', ...
    'terms', struct('Km', '半饱和常数（uM）', 'Vmax', '最大速率（uM/s）'));
enzyme.equations = eq;
enzyme.parameters = struct('id', 'Km', 'symbol', 'K_m', 'unit', 'uM', ...
    'typical_range', [1e-3, 1e3]);
enzyme.assumptions = {'充分混合', '恒温恒容'};
enzyme.fitting_notes = '非线性最小二乘全局拟合。';
enzyme.references = struct('citation', 'Michaelis L, Menten ML. 1913');
bma.util.writeJsonAtomic(fullfile(kbDir, 'archetypes', 'enzyme_kinetics.json'), enzyme);

gene = struct();
gene.id = 'gene_expression';
gene.type = 'archetype';
gene.name = '基因表达';
gene.name_en = 'Gene expression: transcription and translation';
gene.domain = 'gene_expression';
gene.scale = 'cell';
gene.model_class = 'ode';
gene.summary = 'mRNA 与蛋白的转录-翻译-降解两方程模型。';
gene.tags = {'基因表达', '转录', '翻译'};
gene.keywords = {'mRNA', '转录', '翻译', '降解', 'gene expression', 'transcription'};
gene.assumptions = {'充分混合'};
bma.util.writeJsonAtomic(fullfile(kbDir, 'archetypes', 'gene_expression.json'), gene);

massAction = struct();
massAction.id = 'mass_action';
massAction.type = 'principle';
massAction.name = '质量作用定律';
massAction.name_en = 'Law of mass action';
massAction.domain = 'chemical_kinetics';
massAction.summary = '反应速率与反应物浓度幂的乘积成正比。';
massAction.tags = {'基本原理', '化学动力学'};
massAction.keywords = {'质量作用', 'law of mass action', '反应速率', 'reaction rate'};
bma.util.writeJsonAtomic(fullfile(kbDir, 'principles', 'mass_action.json'), massAction);

conservation = struct();
conservation.id = 'conservation_law';
conservation.type = 'principle';
conservation.name = '守恒律';
conservation.name_en = 'Conservation laws';
conservation.domain = 'mathematical_modeling';
conservation.summary = '化学计量矩阵左零空间给出守恒量，用于降维与校验。';
conservation.tags = {'基本原理', '守恒'};
conservation.keywords = {'守恒律', '守恒量', 'stoichiometry', 'conservation', 'left null space'};
bma.util.writeJsonAtomic(fullfile(kbDir, 'principles', 'conservation_law.json'), conservation);

% ---- 2) index：扫描 / 计数 / 无警告 ----
idx = bma.kb.index('KbDir', kbDir, 'UseCache', false);
assertTrue(isstruct(idx), 'index 应返回 struct');
assertTrue(strcmp(idx.schema, 'bma.kb.index.v1'), 'index schema 错误');
assertTrue(strcmpi(idx.kb_dir, kbDir) || strcmp(idx.kb_dir, regexprep(kbDir, '[\\/]+$', '')), ...
    'index.kb_dir 应为 fixture 目录');
assertTrue(idx.counts.archetype == 2, sprintf('archetype 计数应为 2，实际 %d', idx.counts.archetype));
assertTrue(idx.counts.principle == 2, 'principle 计数应为 2');
assertTrue(idx.counts.unit == 3, sprintf('unit 计数应为 3，实际 %d', idx.counts.unit));
assertTrue(idx.counts.total >= 12, sprintf('总条目应 >= 12，实际 %d', idx.counts.total));
assertTrue(isempty(idx.warnings), 'fixture 索引不应有 warning');
assertTrue(isfield(idx, 'manifest') && ~isempty(idx.manifest), 'index.manifest 不应为空');

% ---- 3) list：默认不含 unit、可按 type/domain/关键字过滤 ----
[items, total] = bma.kb.list('', 50, 'KbDir', kbDir);
assertTrue(total == idx.counts.total - idx.counts.unit, ...
    sprintf('默认 list 总数应排除 unit：期望 %d，实际 %d', idx.counts.total - idx.counts.unit, total));
assertTrue(~isempty(items) && isstruct(items), 'list 应返回 struct 数组');
assertTrue(~any(strcmp({items.type}, 'unit')), '默认 list 不应包含 unit');
assertTrue(isfield(items, 'id') && isfield(items, 'tags') && isfield(items, 'summary'), ...
    'list 条目字段缺失');
[arch, archTotal] = bma.kb.list('archetype', 10, 'KbDir', kbDir);
assertTrue(archTotal == 2 && all(strcmp({arch.type}, 'archetype')), ...
    'list(archetype) 应返回 2 条 archetype');
[domainItems, domainTotal] = bma.kb.list('enzyme_kinetics', 10, 'KbDir', kbDir);
assertTrue(domainTotal >= 1 && any(strcmp({domainItems.id}, 'enzyme_kinetics')), ...
    'list(domain) 应命中 enzyme_kinetics');
[unitItems, unitTotal] = bma.kb.list('unit', 10, 'KbDir', kbDir);
assertTrue(unitTotal == 3 && numel(unitItems) == 3, 'list(unit) 应返回 3 条单位');
[limItems, limTotal] = bma.kb.list('', 2, 'KbDir', kbDir);
assertTrue(numel(limItems) == 2 && limTotal == total, 'list limit 应生效且 total 为过滤后总数');

% ---- 4) search：中英文混合查询命中 archetype ----
[hits, hitTotal] = bma.kb.search('米氏酶', {}, 10, 'KbDir', kbDir);
assertTrue(~isempty(hits), '中文查询"米氏酶"应有命中');
assertTrue(strcmp(hits(1).id, 'enzyme_kinetics'), ...
    sprintf('"米氏酶" 首位应命中 enzyme_kinetics，实际 %s', hits(1).id));
assertTrue(hits(1).score > 0 && ~isempty(hits(1).matched_terms), '命中应有 score/matched_terms');
assertTrue(isfield(hits, 'path') && ~isempty(hits(1).path), '命中应有 path');
[hits2] = bma.kb.search('Michaelis-Menten', {}, 10, 'KbDir', kbDir);
assertTrue(~isempty(hits2) && strcmp(hits2(1).id, 'enzyme_kinetics'), ...
    '英文查询 Michaelis-Menten 应命中 enzyme_kinetics');
[hitsMix] = bma.kb.search('酶动力学 Michaelis-Menten', {}, 5, 'KbDir', kbDir);
assertTrue(~isempty(hitsMix) && strcmp(hitsMix(1).id, 'enzyme_kinetics'), ...
    '中英混合查询应命中 enzyme_kinetics');
[hitsMass] = bma.kb.search('质量作用', {}, 5, 'KbDir', kbDir);
assertTrue(~isempty(hitsMass) && strcmp(hitsMass(1).id, 'mass_action'), ...
    '"质量作用" 应命中 mass_action');
[hitsCons, consTotal] = bma.kb.search('conservation', 'principle', 5, 'KbDir', kbDir);
assertTrue(~isempty(hitsCons) && strcmp(hitsCons(1).id, 'conservation_law'), ...
    'tags 过滤下 conservation 应命中 conservation_law');
assertTrue(all(strcmp({hitsCons.type}, 'principle')), 'tags=principle 过滤后应只含 principle');
[tagged] = bma.kb.search('kinetics', {'archetype'}, 5, 'KbDir', kbDir);
assertTrue(~isempty(tagged) && all(strcmp({tagged.type}, 'archetype')), ...
    'tags=archetype 过滤后应只含 archetype');
[oneHit, oneTotal] = bma.kb.search('kinetics', {}, 1, 'KbDir', kbDir);
assertTrue(numel(oneHit) == 1 && oneTotal >= 2, 'search limit 应生效且 total 为全部命中数');
assertTrue(isempty(bma.kb.search('zzzznotexist', {}, 5, 'KbDir', kbDir)), ...
    '无意义查询应返回空');

% ---- 5) get：完整字段 + 路径正确 ----
r = bma.kb.get('enzyme_kinetics', 'KbDir', kbDir);
assertTrue(isstruct(r) && isstruct(r.item), 'get 应返回 {item, path}');
assertTrue(isfield(r, 'path') && isfield(r, 'path_abs') && isfield(r, 'type'), 'get 返回字段缺失');
assertTrue(strcmp(r.type, 'archetype'), 'get type 应为 archetype');
assertTrue(isfile(r.path_abs), 'get path_abs 应存在');
it = r.item;
assertTrue(strcmp(it.name, '米氏酶动力学'), 'get item.name 错误');
assertTrue(strcmp(it.name_en, 'Michaelis-Menten enzyme kinetics'), 'get item.name_en 错误');
assertTrue(strcmp(it.domain, 'enzyme_kinetics'), 'get item.domain 错误');
assertTrue(strcmp(it.model_class, 'ode'), 'get item.model_class 错误');
assertTrue(~isempty(it.summary) && ~isempty(it.keywords), 'get item 缺少 summary/keywords');
assertTrue(isfield(it, 'equations') && isfield(it, 'parameters'), 'get item 缺少 equations/parameters');
assertTrue(isfield(it, 'assumptions') && isfield(it, 'references'), 'get item 缺少 assumptions/references');
% 单位 / ontology 条目
ru = bma.kb.get('unit.uM', 'KbDir', kbDir);
assertTrue(strcmp(ru.item.id, 'uM'), 'get unit.uM 错误');
assertTrue(strcmp(ru.item.dim, 'concentration'), 'uM dim 应为 concentration');
assertTrue(abs(ru.item.factor - 1e-6) < 1e-18, 'uM factor 应为 1e-6');
aliases = cellStr(ru.item.aliases);
assertTrue(any(strcmp(aliases, [char(181) 'M'])) || any(contains(aliases, 'umol/L')), ...
    'uM aliases 应包含 µM 或 umol/L');
ro = bma.kb.get('ontology.level.molecule', 'KbDir', kbDir);
assertTrue(strcmp(ro.item.id, 'molecule') && strcmp(ro.item.name, '分子层'), ...
    'get ontology.level.molecule 错误');
% 不存在条目
caught = false;
try
    bma.kb.get('no_such_item', 'KbDir', kbDir);
catch err
    caught = strcmp(err.identifier, 'bma:kb:notFound');
end
assertTrue(caught, '不存在的条目应报 bma:kb:notFound');

% ---- 6) units()：单位表读取（供 spec 校验复用） ----
[unitTable, unitMap] = bma.kb.units('KbDir', kbDir);
assertTrue(numel(unitTable) == 3, 'units() 应返回 3 个单位');
assertTrue(isa(unitMap, 'containers.Map'), 'units() 第二输出应为 containers.Map');
assertTrue(strcmp(unitMap('uM').dim, 'concentration'), 'units map 查询 uM 失败');
assertTrue(strcmp(unitMap('1/s').base, '1/s'), 'units map 查询 1/s 失败');

% ---- 7) mtime 失效：修改 KB 文件后自动重建索引 ----
pause(0.05);
gene2 = gene;
gene2.keywords = [gene.keywords, {'单细胞噪声', '表达噪声'}];
gene2.summary = 'mRNA 与蛋白的转录-翻译-降解两方程模型；含单细胞噪声讨论。';
bma.util.writeJsonAtomic(fullfile(kbDir, 'archetypes', 'gene_expression.json'), gene2);
[hitsNoise] = bma.kb.search('单细胞噪声', {}, 5, 'KbDir', kbDir);
assertTrue(~isempty(hitsNoise) && strcmp(hitsNoise(1).id, 'gene_expression'), ...
    'KB 文件变化后索引应按 mtime 失效重建并命中新关键词');
[hitsOld] = bma.kb.search('mRNA 转录', {}, 5, 'KbDir', kbDir);
assertTrue(~isempty(hitsOld), '重建后旧内容仍应可检索');

% ---- 8) 环境变量 BMA_KB_DIR 覆盖默认路径；默认指向项目 kb/ ----
oldEnv = getenv('BMA_KB_DIR');
restoreEnv = onCleanup(@() setenv('BMA_KB_DIR', oldEnv));
setenv('BMA_KB_DIR', kbDir);
idxEnv = bma.kb.index('UseCache', false);
assertTrue(strcmpi(idxEnv.kb_dir, idx.kb_dir), 'BMA_KB_DIR 环境变量应生效');
setenv('BMA_KB_DIR', '');
defaultKb = fullfile(bma.util.projectRoot(), 'kb');
assertEqualsPath(idxEnv.kb_dir, kbDir);
idxDefault = bma.kb.index('UseCache', false);
assertEqualsPath(idxDefault.kb_dir, defaultKb);

fprintf('  [test_kb_index_search] PASS (%d items; search/get/units/mtime OK)\n', idx.counts.total);

% ---------------------------------------------------------------------------
function assertTrue(cond, msg)
if ~cond
    error('test_kb_index_search:fail', '%s', msg);
end
end

function assertEqualsPath(actual, expected)
a = regexprep(strrep(char(actual), '\', '/'), '/+$', '');
e = regexprep(strrep(char(expected), '\', '/'), '/+$', '');
a = lower(a);
e = lower(e);
if ~strcmp(a, e)
    error('test_kb_index_search:fail', '路径不一致：%s != %s', actual, expected);
end
end

function out = cellStr(v)
if ischar(v)
    out = {v};
elseif isstring(v)
    out = cellstr(v);
elseif iscell(v)
    out = {};
    for k = 1:numel(v)
        if ischar(v{k})
            out{end + 1} = v{k}; %#ok<AGROW>
        elseif isstring(v{k})
            out{end + 1} = char(v{k}); %#ok<AGROW>
        end
    end
else
    out = {};
end
end

function safeRmdir(d)
try
    if isfolder(d)
        rmdir(d, 's');
    end
catch
end
end
