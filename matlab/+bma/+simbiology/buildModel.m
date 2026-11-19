function [sb, kinetics, warnings, diag] = buildModel(spec, opts)
%BUILDMODEL 用 SimBiology 构建与 bma 模型等价的 SimBiology 模型对象（不保存）。
%   [sb, kinetics, warnings] = bma.simbiology.buildModel(spec)
%   [sb, kinetics, warnings] = bma.simbiology.buildModel(spec, opts)
%
% 供 bma.simbiology.export 与调试脚本使用。返回的 sb 是 SimBiology.Model 句柄，
% 调用方负责 delete(sb)。
%
% 映射规则：
%   - 隔室/物种/参数：名称用英文 id（**不用中文名**，否则反应式与动力学律表达式中的
%     id 无法解析）；中文名写入物种的 Notes，便于阅读。
%   - 每个反应使用用户自定义动力学律（sbioabstractkineticlaw + sbioaddtolibrary +
%     addkineticlaw），速率表达式即规格 flux 公式（物种/参数用 id，隔室替换为数值）。
%   - 无反应物/产物的反应通过边界虚拟物种 BMA_SOURCE / BMA_SINK 表达。
%
% opts：
%   .noUnits   true 时所有隔室/物种/参数都不写单位（用于 SimBiology 单位系统
%              与规格单位不完全兼容时的数值等价性验证；保存的工程仍用完整单位）。
%
% 返回：
%   sb        SimBiology.Model
%   kinetics  1×nReactions cellstr，每个反应的动力学律说明
%   warnings  cellstr（单位无法映射、虚拟物种创建失败等）
if nargin < 2 || isempty(opts)
    opts = struct();
end
noUnits = false;
if isfield(opts, 'noUnits') && ~isempty(opts.noUnits)
    noUnits = logical(opts.noUnits);
end
warnings = {};
kinetics = {};
diag = {};
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec)
    error('bma:spec:spec_invalid', 'bma.simbiology.buildModel 需要模型规格或模型结构');
end
if ~isfield(spec, 'rhs')
    m = bma.model.build(spec);
else
    m = spec;
end
sb = sbiomodel(m.name);
% ---- 隔室 ----
compObjs = cell(1, numel(m.compartments));
for k = 1:numel(m.compartments)
    c = m.compartments(k);
    unitStr = '';
    if ~noUnits
        unitStr = mapUnit(c.unit);
    end
    compObj = [];
    if ~isempty(unitStr)
        try
            compObj = addcompartment(sb, c.id, c.volume, 'CapacityUnit', unitStr);
        catch
            compObj = [];
        end
    end
    if isempty(compObj)
        try
            compObj = addcompartment(sb, c.id, c.volume);
        catch err
            error('bma:simbiology:compartment', '添加隔室 "%s" 失败：%s', c.id, err.message);
        end
        if ~isempty(unitStr)
            warnings{end+1} = sprintf('隔室 "%s" 的单位 "%s" 无法映射为 SimBiology 单位，已按无量纲处理。', ...
                c.id, c.unit); %#ok<AGROW>
        end
    end
    compObjs{k} = compObj;
end
if isempty(compObjs) || isempty(compObjs{1})
    compObjs{1} = addcompartment(sb, 'cell', 1, 'CapacityUnit', 'liter');
end
% ---- 物种（Name 用英文 id；中文名写 Notes）----
speciesObj = cell(1, m.n_species);
for i = 1:m.n_species
    sid = m.species{i};
    unitStr = '';
    if ~noUnits
        unitStr = mapUnit(m.speciesUnits{i});
    end
    targetComp = compObjs{1};
    if isfield(m, 'speciesCompartment') && ~isempty(m.speciesCompartment{i})
        for k = 1:numel(m.compartments)
            if strcmp(m.compartments(k).id, m.speciesCompartment{i})
                targetComp = compObjs{k};
                break
            end
        end
    end
    [sp, w] = addSpeciesSafe(targetComp, sid, m.speciesInitial(i), unitStr);
    speciesObj{i} = sp;
    warnings = [warnings, w]; %#ok<AGROW>
    % 中文名写入 Notes（不要改 Name！否则反应式/动力学律表达式中的 id 会解析失败）
    try
        if ~isempty(m.speciesNames{i})
            sp.Notes = m.speciesNames{i};
        end
    catch
    end
end
% ---- 参数 ----
for j = 1:m.n_params
    unitStr = '';
    if ~noUnits
        unitStr = mapUnit(m.paramUnits{j});
    end
    w = addParameterSafe(sb, m.params{j}, m.paramValues(j), unitStr);
    warnings = [warnings, w]; %#ok<AGROW>
end
% ---- 汇总虚拟源/汇物种 ----
sinkName = 'BMA_SINK';
sourceName = 'BMA_SOURCE';
needSink = false;
needSource = false;
for rIdx = 1:m.n_reactions
    [react, prod] = splitStoich(m, rIdx);
    if isempty(prod)
        needSink = true;
    end
    if isempty(react)
        needSource = true;
    end
end
if needSink
    addBoundarySpecies(compObjs{1}, sinkName, warnings);
end
if needSource
    addBoundarySpecies(compObjs{1}, sourceName, warnings);
end
% ---- 反应 + 自定义动力学律 ----
for rIdx = 1:m.n_reactions
    [react, prod, rxnName] = splitStoich(m, rIdx);
    if isempty(react)
        react = {sourceName};
    end
    if isempty(prod)
        prod = {sinkName};
    end
    eqn = sprintf('%s -> %s', strjoin(react, ' + '), strjoin(prod, ' + '));
    try
        rxn = addreaction(sb, eqn);
    catch err
        error('bma:simbiology:reaction', '添加反应 "%s"（%s）失败：%s', rxnName, eqn, err.message);
    end
    lawName = kineticLawName(m, rIdx);
    expr = simBiologyExpression(m, rIdx);
    [lawInfo, w2] = applyCustomKineticLaw(rxn, lawName, expr, m.reactions(rIdx));
    warnings = [warnings, w2]; %#ok<AGROW>
    diag{end+1} = sprintf('kineticlaw %s: expr=%s param_vars=%d param_names=%d species_vars=%d species_names=%d reaction_law=%d', ...
        lawInfo.law_name, lawInfo.expression, lawInfo.n_parameter_vars, ...
        lawInfo.n_parameter_names, lawInfo.n_species_vars, ...
        lawInfo.n_species_names, lawInfo.reaction_law_attached); %#ok<AGROW>
    kinetics{rIdx} = sprintf('%s：%s（用户自定义动力学律 %s）', ...
        rxnName, m.fluxText{rIdx}, lawName); %#ok<AGROW>
end
end

% =========================================================================
function [sp, warnings] = addSpeciesSafe(comp, name, initial, unitStr)
warnings = {};
sp = [];
if ~isempty(unitStr)
    lastwarn('');
    try
        sp = addspecies(comp, name, 'InitialAmount', initial, 'InitialAmountUnits', unitStr);
        [~, w] = lastwarn;
        if ~isempty(w)
            try
                delete(sp);
            catch
            end
            sp = [];
        end
    catch
        sp = [];
    end
end
if isempty(sp)
    sp = addspecies(comp, name, 'InitialAmount', initial);
    if ~isempty(unitStr)
        warnings{end+1} = sprintf('物种 "%s" 的单位 "%s" 无法映射为 SimBiology 单位，已按无量纲处理。', ...
            name, unitStr); %#ok<AGROW>
    end
end
end

function w = addParameterSafe(sb, name, value, unitStr)
w = {};
if ~isempty(unitStr)
    lastwarn('');
    try
        addparameter(sb, name, value, 'ValueUnits', unitStr);
        [~, msg] = lastwarn;
        if isempty(msg)
            return
        end
        try
            p = sbioselect(sb, 'Type', 'parameter', 'Name', name);
            if ~isempty(p)
                delete(p);
            end
        catch
        end
    catch
    end
end
addparameter(sb, name, value);
if ~isempty(unitStr)
    w = {sprintf('参数 "%s" 的单位 "%s" 无法映射为 SimBiology 单位，已按无量纲处理。', ...
        name, unitStr)};
end
end

function addBoundarySpecies(comp, name, warnings)
try
    sp = addspecies(comp, name, 'InitialAmount', 0);
    sp.BoundaryCondition = true;
catch err
    warnings{end+1} = sprintf('添加边界虚拟物种 %s 失败：%s', name, err.message); %#ok<AGROW>
end
end

function [react, prod, name] = splitStoich(m, rIdx)
stoich = m.reactions(rIdx).stoichiometry;
fn = fieldnames(stoich);
react = {};
prod = {};
name = m.reactions(rIdx).id;
for k = 1:numel(fn)
    sid = fn{k};
    coef = stoich.(sid);
    if coef > 0
        n = round(coef);
        if abs(coef - n) > 1e-9
            error('bma:simbiology:stoich', ...
                '反应 "%s" 物种 "%s" 的化学计量系数 %g 不是整数，SimBiology 导出暂不支持。', ...
                name, sid, coef);
        end
        if n == 1
            prod{end+1} = sid; %#ok<AGROW>
        else
            prod{end+1} = sprintf('%d %s', n, sid); %#ok<AGROW>
        end
    elseif coef < 0
        n = round(-coef);
        if abs(-coef - n) > 1e-9
            error('bma:simbiology:stoich', ...
                '反应 "%s" 物种 "%s" 的化学计量系数 %g 不是整数，SimBiology 导出暂不支持。', ...
                name, sid, coef);
        end
        if n == 1
            react{end+1} = sid; %#ok<AGROW>
        else
            react{end+1} = sprintf('%d %s', n, sid); %#ok<AGROW>
        end
    end
end
end

function lawName = kineticLawName(m, rIdx)
base = ['bma_' m.name '_' m.reactions(rIdx).id];
lawName = regexprep(base, '[^A-Za-z0-9_]', '_');
if isempty(regexp(lawName, '^[A-Za-z]', 'once'))
    lawName = ['bma_' lawName];
end
if numel(lawName) > 60
    lawName = lawName(1:60);
end
end

function expr = simBiologyExpression(m, rIdx)
expr = m.fluxText{rIdx};
for k = numel(m.compartmentIds):-1:1
    cid = m.compartmentIds{k};
    pat = ['(?<![A-Za-z0-9_])' cid '(?![A-Za-z0-9_])'];
    expr = regexprep(expr, pat, sprintf('%.17g', m.compartmentVolumes(k)));
end
end

function tf = lawExistsInLibrary(lawName)
% 判断用户自定义动力学律库中是否存在同名律
tf = false;
try
    userLib = get(sbioroot, 'UserDefinedLibrary');
    laws = get(userLib, 'KineticLaws');
    if isempty(laws)
        return
    end
    names = cellfun(@char, {laws.Name}, 'UniformOutput', false);
    tf = any(strcmp(names, lawName));
catch
    tf = false;
end
end

function [info, warnings] = applyCustomKineticLaw(rxn, lawName, expr, rxnInfo)
% 创建用户自定义动力学律并挂到反应上，然后做“无需仿真”的可仿真性自检。
% 关键点：
%   - sbioabstractkineticlaw(Name, Expression) 定义律的 Expression/SpeciesVariables/ParameterVariables，
%     必须 sbioaddtolibrary 后才能从模型引用；
%   - 挂到反应上之后必须把 Expression 中的变量名映射到模型物种/参数：
%     kl.SpeciesVariableNames / kl.ParameterVariableNames；否则 sbiosimulate 校验会报
%     "Parameter variable name on kinetic law '' is empty"；
%   - 同名旧律可能来自历史会话/历史版本（定义不完整），先尝试 sbioremovefromlibrary 清掉。
warnings = {};
speciesNames = rxnInfo.species_ids;
parameterNames = rxnInfo.parameter_ids;
if ~iscell(speciesNames)
    speciesNames = {};
end
if ~iscell(parameterNames)
    parameterNames = {};
end
speciesNames = speciesNames(~cellfun(@isempty, speciesNames));
parameterNames = parameterNames(~cellfun(@isempty, parameterNames));
% 1) 清理同名旧律（仅当该律确实在用户库中，避免 "does not exist" 警告）
try
    if lawExistsInLibrary(lawName)
        sbioremovefromlibrary('kineticlaw', lawName);
    end
catch
end
% 2) 创建并配置抽象律，加入用户库；同名冲突时换唯一后缀重试
assignedName = lawName;
added = false;
lastErr = [];
for attempt = 1:3
    try
        akl = sbioabstractkineticlaw(assignedName, expr);
        if ~isempty(speciesNames)
            akl.SpeciesVariables = speciesNames;
        end
        if ~isempty(parameterNames)
            akl.ParameterVariables = parameterNames;
        end
        sbioaddtolibrary(akl);
        added = true;
        break
    catch err
        lastErr = err;
        assignedName = regexprep(sprintf('%s_%d', lawName, attempt + 1), '[^A-Za-z0-9_]', '_');
        if numel(assignedName) > 60
            assignedName = assignedName(1:60);
        end
    end
end
if ~added
    error('bma:simbiology:kinetic', '创建自定义动力学律 "%s" 失败：%s', ...
        lawName, lastErr.message);
end
% 3) 挂到反应
try
    kl = addkineticlaw(rxn, assignedName);
catch err
    error('bma:simbiology:kinetic', ...
        '为反应设置动力学律 "%s"（%s）失败：%s', assignedName, expr, err.message);
end
% 4) 把表达式变量名映射到模型里的物种/参数
if ~isempty(speciesNames)
    try
        kl.SpeciesVariableNames = speciesNames;
    catch err
        error('bma:simbiology:kinetic', ...
            '设置动力学律 %s 的 SpeciesVariableNames 失败：%s', assignedName, err.message);
    end
end
if ~isempty(parameterNames)
    try
        kl.ParameterVariableNames = parameterNames;
    catch err
        error('bma:simbiology:kinetic', ...
            '设置动力学律 %s 的 ParameterVariableNames 失败：%s', assignedName, err.message);
    end
end
% 5) 自检：Expression 非空、变量映射数量与定义一致、反应 KineticLaw 非空
info = struct();
info.law_name = assignedName;
info.expression = '';
info.n_parameter_vars = 0;
info.n_parameter_names = 0;
info.n_species_vars = 0;
info.n_species_names = 0;
info.reaction_law_attached = false;
info.ok = false;
try
    info.expression = char(kl.Expression);
catch
end
try
    info.n_parameter_vars = numel(kl.ParameterVariables);
    info.n_parameter_names = numel(kl.ParameterVariableNames);
catch
end
try
    info.n_species_vars = numel(kl.SpeciesVariables);
    info.n_species_names = numel(kl.SpeciesVariableNames);
catch
end
info.reaction_law_attached = ~isempty(rxn.KineticLaw);
if isempty(info.expression)
    error('bma:simbiology:kinetic', '动力学律 "%s" 的 Expression 为空，无法用于仿真。', assignedName);
end
if info.n_parameter_vars ~= info.n_parameter_names
    error('bma:simbiology:kinetic', ...
        '动力学律 "%s" 参数映射不完整（定义 %d 个，映射 %d 个）。', ...
        assignedName, info.n_parameter_vars, info.n_parameter_names);
end
if info.n_species_vars ~= info.n_species_names
    error('bma:simbiology:kinetic', ...
        '动力学律 "%s" 物种映射不完整（定义 %d 个，映射 %d 个）。', ...
        assignedName, info.n_species_vars, info.n_species_names);
end
if ~info.reaction_law_attached
    error('bma:simbiology:kinetic', '反应未成功挂载动力学律 "%s"。', assignedName);
end
info.ok = true;
end

% =========================================================================
function unitStr = mapUnit(unit)
% bma 单位 → SimBiology（SBML 风格）单位名；无法映射返回 ''（无量纲）。
if isempty(unit)
    unitStr = '';
    return
end
u = strtrim(char(unit));
if isempty(u) || strcmp(u, '1') || strcmp(u, '-')
    unitStr = '';
    return
end
persistent T
if isempty(T)
    T = containers.Map('KeyType', 'char', 'ValueType', 'char');
    T('s') = 'second';
    T('sec') = 'second';
    T('ms') = 'millisecond';
    T('min') = 'minute';
    T('h') = 'hour';
    T('hr') = 'hour';
    T('day') = 'day';
    T('L') = 'liter';
    T('l') = 'liter';
    T('mL') = 'milliliter';
    T('ml') = 'milliliter';
    T('uL') = 'microliter';
    T('nL') = 'nanoliter';
    T('pL') = 'picoliter';
    T('fL') = 'femtoliter';
    T('dL') = 'deciliter';
    T('M') = 'mole/liter';
    T('mM') = 'millimole/liter';
    T('uM') = 'micromole/liter';
    T('nM') = 'nanomole/liter';
    T('pM') = 'picomole/liter';
    T('fM') = 'femtomole/liter';
    T('mol') = 'mole';
    T('mmol') = 'millimole';
    T('umol') = 'micromole';
    T('nmol') = 'nanomole';
    T('pmol') = 'picomole';
    T('1/s') = '1/second';
    T('1/ms') = '1/millisecond';
    T('1/min') = '1/minute';
    T('1/h') = '1/hour';
    T('1/day') = '1/day';
    T('g') = 'gram';
    T('mg') = 'milligram';
    T('ug') = 'microgram';
    T('m') = 'meter';
    T('cm') = 'centimeter';
    T('mm') = 'millimeter';
    T('um') = 'micrometer';
    T('nm') = 'nanometer';
    T('person') = 'item';
    T('persons') = 'item';
    T('cell') = 'item';
    T('cells') = 'item';
    T('molecule') = 'item';
    T('molecules') = 'item';
    T('copy') = 'item';
    T('copies') = 'item';
    T('mV') = 'millivolt';
    T('V') = 'volt';
    T('A') = 'ampere';
    T('uA') = 'microampere';
    T('nA') = 'nanoampere';
    T('pA') = 'picoampere';
    T('mS') = 'millisiemens';
    T('S') = 'siemens';
    T('uF') = 'microfarad';
    T('F') = 'farad';
    T('nF') = 'nanofarad';
    T('pF') = 'picofarad';
end
if isKey(T, u)
    unitStr = T(u);
    return
end
unitStr = '';
tokens = regexp(u, '[A-Za-z]+', 'match');
if isempty(tokens) || ~isempty(regexp(u, '\s', 'once'))
    return
end
out = u;
for k = 1:numel(tokens)
    tok = tokens{k};
    if isKey(T, tok)
        rep = T(tok);
        pat = ['(?<![A-Za-z0-9_])' tok '(?![A-Za-z0-9_])'];
        out = regexprep(out, pat, rep);
    elseif any(strcmp(tok, {'mol', 'liter', 'mole', 'second', 'minute', 'hour', 'day', ...
            'meter', 'centimeter', 'millimeter', 'micrometer', 'nanometer', ...
            'gram', 'milligram', 'microgram', 'volt', 'millivolt', 'ampere', ...
            'microampere', 'nanoampere', 'picoampere', 'siemens', 'millisiemens', ...
            'farad', 'microfarad', 'nanofarad', 'picofarad', 'millimole', ...
            'micromole', 'nanomole', 'picomole'}))
        % 已是 SimBiology 单位名
    else
        return
    end
end
unitStr = out;
end

function tu = mapTimeUnit(unit)
switch strtrim(char(unit))
    case {'s', 'sec'}
        tu = 'second';
    case 'ms'
        tu = 'millisecond';
    case 'min'
        tu = 'minute';
    case {'h', 'hr'}
        tu = 'hour';
    case 'day'
        tu = 'day';
    otherwise
        tu = '';
end
end
