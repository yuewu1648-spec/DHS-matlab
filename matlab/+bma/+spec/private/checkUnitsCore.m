function uc = checkUnitsCore(spec)
%CHECKUNITSCORE 模型规格量纲检查核心实现（内部函数，spec 需已 normalize）。
%   uc = checkUnitsCore(spec) 返回：
%     uc.checked         : true
%     uc.ok              : 逻辑值（无错误；单位缺失/不可解析为错误）
%     uc.dimensional_ok  : 逻辑值（无任何错误与量纲不一致警告）
%     uc.n_units_checked : 成功解析的单位字符串数量
%     uc.issues          : cell，每项 {code,path,message,hint,severity}
%     uc.errors / uc.warnings : issues 的两个子集
%     uc.n_errors / uc.n_warnings
%
% 检查内容：
%   1. variables / parameters / compartments / outputs / time 的单位是否可解析；
%   2. 每个反应的通量量纲是否等于目标物种变化率量纲（物种单位/时间单位）；
%   3. 米氏动力学中底物/Km/抑制剂 Ki 的量纲一致性；
%   4. Hill 动力学中调控物种/k 的量纲一致性、Hill 指数无量纲；
%   5. 输出表达式与输出单位的量纲一致性；
%   6. 时间轴单位必须是时间量纲。
if nargin < 1 || isempty(spec) || ~isstruct(spec)
    error('bma:spec:spec_invalid', 'checkUnitsCore 需要模型规格结构体');
end
issues = {};
nChecked = 0;
T = unitTable();

vars = itemize(getField(spec, 'variables', []));
params = itemize(getField(spec, 'parameters', []));
comps = itemize(getField(spec, 'compartments', []));
outputs = itemize(getField(spec, 'outputs', []));
reacs = itemize(getField(spec, 'reactions', []));
nS = numel(vars);
nP = numel(params);

% ---- 变量单位 ----
varIds = cell(1, nS);
varDims = nan(nS, 8);
speciesIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for i = 1:nS
    e = vars{i};
    id = char(string(getField(e, 'id', '')));
    varIds{i} = id;
    unitStr = char(string(getField(e, 'unit', '')));
    [dim, nChecked, iss] = parseUnitAt(unitStr, sprintf('variables[%d].unit', i-1), T, nChecked);
    if ~isempty(iss)
        issues{end+1} = iss; %#ok<AGROW>
    end
    varDims(i, :) = dim;
    if ~isempty(id)
        speciesIndex(id) = i;
    end
end

% ---- 参数单位 ----
parIds = cell(1, nP);
parDims = nan(nP, 8);
paramIndex = containers.Map('KeyType', 'char', 'ValueType', 'double');
for j = 1:nP
    e = params{j};
    id = char(string(getField(e, 'id', '')));
    parIds{j} = id;
    unitStr = char(string(getField(e, 'unit', '')));
    [dim, nChecked, iss] = parseUnitAt(unitStr, sprintf('parameters[%d].unit', j-1), T, nChecked);
    if ~isempty(iss)
        issues{end+1} = iss; %#ok<AGROW>
    end
    parDims(j, :) = dim;
    if ~isempty(id)
        paramIndex(id) = j;
    end
end

% ---- 隔室单位 ----
nC = numel(comps);
compIds = cell(1, nC);
compDims = nan(nC, 8);
compVolumes = nan(1, nC);
for k = 1:nC
    e = comps{k};
    id = char(string(getField(e, 'id', '')));
    compIds{k} = id;
    vol = getField(e, 'volume', 1);
    if isnumeric(vol) && isscalar(vol)
        compVolumes(k) = vol;
    end
    unitStr = char(string(getField(e, 'unit', '')));
    [dim, nChecked, iss] = parseUnitAt(unitStr, sprintf('compartments[%d].unit', k-1), T, nChecked);
    if ~isempty(iss)
        issues{end+1} = iss; %#ok<AGROW>
    end
    compDims(k, :) = dim;
    if ~isempty(iss) || any(isnan(dim))
        % 隔室体积单位未知时，表达式引用隔室无法检查，保持 NaN
        compDims(k, :) = nan(1, 8);
    else
        volumeDim = [0 1 0 0 0 0 0 0];
        if ~dimsEqual(dim, volumeDim)
            issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', ...
                sprintf('compartments[%d].unit', k-1), ...
                sprintf('隔室 "%s" 的单位应为体积量纲（如 L/mL/uL），当前解析量纲为 %s', id, dimText(dim)), ...
                '体积单位缺失或错误会影响表达式量纲检查，请使用 L、mL、uL、nL 等。', 'warning'); %#ok<AGROW>
        end
    end
end

% ---- 时间轴单位 ----
timeUnit = char(string(getField(getField(spec, 'time', struct()), 'unit', '')));
dimensionlessTime = false;
[~, nChecked, iss] = parseUnitAt(timeUnit, 'time.unit', T, nChecked);
if ~isempty(iss)
    issues{end+1} = iss; %#ok<AGROW>
else
    tDim = parseUnitSafe(timeUnit, T);
    if ~isempty(tDim) && ~any(isnan(tDim)) && all(abs(tDim) < 1e-12)
        % "1"/dimensionless time: d/dt is dimensionless, so flux and state
        % rates have the same dimension (Rössler/Lorenz-style models).
        dimensionlessTime = true;
        timeDim = zeros(1, 8);
    elseif ~isempty(tDim) && ~any(isnan(tDim)) && ~dimsEqual(tDim, [0 0 1 0 0 0 0 0])
        issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', 'time.unit', ...
            sprintf('时间轴单位 "%s" 不是时间量纲', timeUnit), ...
            '请使用 s、min、h、day 或 "1"（无量纲时间）。', 'warning'); %#ok<AGROW>
    end
end

% ---- 供表达式使用的量纲表 ----
dimRefs = containers.Map('KeyType', 'char', 'ValueType', 'any');
for i = 1:nS
    if ~isempty(varIds{i})
        dimRefs(varIds{i}) = varDims(i, :);
    end
end
for j = 1:nP
    if ~isempty(parIds{j})
        dimRefs(parIds{j}) = parDims(j, :);
    end
end
for k = 1:nC
    if ~isempty(compIds{k}) && any(~isnan(compDims(k, :)))
        dimRefs(compIds{k}) = compDims(k, :);
    end
end
if dimensionlessTime
    timeDim = zeros(1, 8);
else
    timeDim = [0 0 1 0 0 0 0 0];
end

% ---- 反应通量量纲 ----
nR = numel(reacs);
for r = 1:nR
    e = reacs{r};
    rate = getField(e, 'rate', struct());
    if ~isstruct(rate)
        continue
    end
    kind = lower(strtrim(char(string(getField(rate, 'kind', '')))));
    path = sprintf('reactions[%d].rate', r-1);
    fluxDim = nan(1, 8);
    switch kind
        case 'mass_action'
            fluxDim = refDimById(getField(getField(rate, 'parameters', struct()), 'k', []), ...
                dimRefs, paramIndex, parDims, []);
            speciesDef = getField(rate, 'species', struct());
            if isstruct(speciesDef)
                fn = fieldnames(speciesDef);
                for k = 1:numel(fn)
                    order = speciesDef.(fn{k});
                    sd = refDimById(fn{k}, dimRefs, speciesIndex, varDims, []);
                    if isnumeric(order) && isscalar(order) && isfinite(order) && ~any(isnan(sd))
                        if any(isnan(fluxDim))
                            fluxDim = nan(1, 8);
                        else
                            fluxDim = fluxDim + order * sd;
                        end
                    end
                end
            end
        case 'constant'
            fluxDim = refDimById(getField(getField(rate, 'parameters', struct()), 'k', []), ...
                dimRefs, paramIndex, parDims, []);
        case 'michaelis_menten'
            pdef = getField(rate, 'parameters', struct());
            fluxDim = refDimById(getField(pdef, 'vmax', []), dimRefs, paramIndex, parDims, []);
            % 底物/Km/抑制剂量纲一致性
            sdef = getField(rate, 'species', struct());
            sid = singleSpeciesId(sdef, 'substrate');
            if ~isempty(sid)
                sDim = refDimById(sid, dimRefs, speciesIndex, varDims, []);
                kmDim = refDimById(getField(pdef, 'km', []), dimRefs, paramIndex, parDims, []);
                if ~any(isnan(sDim)) && ~any(isnan(kmDim)) && ~dimsEqual(sDim, kmDim)
                    issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', [path '.parameters.km'], ...
                        'Km 的量纲必须与底物浓度一致', ...
                        '请把 Km 与底物设置为相同单位（如都为 uM）。', 'warning'); %#ok<AGROW>
                end
                inh = getField(rate, 'inhibitor', []);
                if isstruct(inh)
                    iid = char(string(getField(inh, 'species', '')));
                    if ~isempty(iid)
                        iDim = refDimById(iid, dimRefs, speciesIndex, varDims, []);
                        if ~any(isnan(iDim)) && ~any(isnan(sDim)) && ~dimsEqual(iDim, sDim)
                            issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', [path '.inhibitor.species'], ...
                                '抑制剂浓度与底物浓度的量纲必须一致', ...
                                '请给抑制剂与底物设置相同单位（如都为 uM）。', 'warning'); %#ok<AGROW>
                        end
                    end
                    kiDim = refDimById(getField(inh, 'ki', []), dimRefs, paramIndex, parDims, []);
                    if ~any(isnan(kiDim)) && ~any(isnan(sDim)) && ~dimsEqual(kiDim, sDim)
                        issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', [path '.inhibitor.ki'], ...
                            'Ki 的量纲必须与底物浓度一致', ...
                            '请把 Ki 与底物设置为相同单位（如都为 uM）。', 'warning'); %#ok<AGROW>
                    end
                end
            end
        case 'hill'
            pdef = getField(rate, 'parameters', struct());
            fluxDim = refDimById(getField(pdef, 'vmax', []), dimRefs, paramIndex, parDims, []);
            sdef = getField(rate, 'species', struct());
            rid = singleSpeciesId(sdef, 'regulator');
            if ~isempty(rid)
                rDim = refDimById(rid, dimRefs, speciesIndex, varDims, []);
                kDim = refDimById(getField(pdef, 'k', []), dimRefs, paramIndex, parDims, []);
                if ~any(isnan(rDim)) && ~any(isnan(kDim)) && ~dimsEqual(rDim, kDim)
                    issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', [path '.parameters.k'], ...
                        'Hill 半效浓度 k 的量纲必须与调控物种浓度一致', ...
                        '请把 k 与调控物种设置为相同单位（如都为 nM）。', 'warning'); %#ok<AGROW>
                end
                nDim = refDimById(getField(pdef, 'n', []), dimRefs, paramIndex, parDims, []);
                if ~any(isnan(nDim)) && any(abs(nDim) > 1e-12)
                    issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', [path '.parameters.n'], ...
                        'Hill 指数 n 必须无量纲（建议单位填写 "1"）', ...
                        'Hill 指数是幂次，单位应为 "1" 或无量纲。', 'warning'); %#ok<AGROW>
                end
            end
        case 'matlab'
            % 函数体量纲无法静态推导：用规格里声明的 unit 作为通量量纲，
            % 再与化学计量要求的“物种量纲/时间”比较（这仍然是有信息的检查）。
            unitStr = char(string(getField(rate, 'unit', '')));
            if isempty(strtrim(unitStr))
                issues{end+1} = makeIssue('BMA_SPEC_MISSING_FIELD', [path '.unit'], ...
                    'kind=matlab 必须显式声明通量单位', ...
                    '函数体内部量纲无法静态推导，请补 "unit":"uM/s"。', 'error'); %#ok<AGROW>
            else
                fluxDim = parseUnitSafe(unitStr, T);
                if isempty(fluxDim)
                    issues{end+1} = makeIssue('BMA_UNIT_UNKNOWN', [path '.unit'], ...
                        sprintf('无法解析 matlab 速率声明的单位 "%s"', unitStr), ...
                        '可用示例：uM/s、nM/min、1/s、1。', 'error'); %#ok<AGROW>
                    fluxDim = nan(1, 8);
                else
                    issues{end+1} = makeIssue('BMA_RATE_DECLARED_UNIT', [path '.unit'], ...
                        sprintf('kind=matlab 的通量单位 "%s" 为声明值，未做函数体量纲推导', unitStr), ...
                        '请在模型卡/报告中标注该单位来源为 declared（声明），而非推导。', 'warning'); %#ok<AGROW>
                end
            end
        case 'expression'
            expr = char(string(getField(rate, 'expression', '')));
            if ~isempty(strtrim(expr))
                try
                    fluxDim = evalExprDims(expr, dimRefs);
                catch err
                    fluxDim = nan(1, 8);
                    if strcmp(err.identifier, 'bma:unit:mismatch')
                        issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', [path '.expression'], ...
                            ['速率表达式内部量纲不一致：' err.message], ...
                            '请检查表达式中的加减项与函数参数是否同量纲。', 'warning'); %#ok<AGROW>
                    elseif strcmp(err.identifier, 'bma:expr:unknown_id')
                        issues{end+1} = makeIssue('BMA_SPEC_UNKNOWN_ID', [path '.expression'], ...
                            err.message, ...
                            '速率表达式只能引用 variables / parameters / compartments 的 id。', 'error'); %#ok<AGROW>
                    else
                        issues{end+1} = makeIssue('BMA_RATE_INVALID', [path '.expression'], ...
                            err.message, ...
                            '请检查表达式语法。', 'error'); %#ok<AGROW>
                    end
                end
            end
        otherwise
            % 未知 kind 由 validate 的 rateParse 报错，这里跳过
    end
    if any(isnan(fluxDim))
        continue
    end
    % 与化学计量中每个物种的变化率量纲比较
    stoich = getField(e, 'stoichiometry', struct());
    if ~isstruct(stoich)
        continue
    end
    fn = fieldnames(stoich);
    for k = 1:numel(fn)
        sid = fn{k};
        coef = stoich.(sid);
        if ~isnumeric(coef) || ~isscalar(coef) || coef == 0
            continue
        end
        if ~isKey(speciesIndex, sid)
            continue
        end
        target = varDims(speciesIndex(sid), :) - timeDim;
        if any(isnan(target))
            continue
        end
        if ~dimsEqual(fluxDim, target)
            issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', path, ...
                sprintf('反应 "%s" 的通量量纲 (%s) 与物种 "%s" 的变化率量纲 (%s) 不一致', ...
                    char(string(getField(e, 'id', ''))), dimText(fluxDim), sid, dimText(target)), ...
                '请检查速率常数单位（如 kf 应为 1/(uM*s)）与物种浓度单位是否自洽。', 'warning'); %#ok<AGROW>
            break
        end
    end
end

% ---- 输出单位与表达式量纲 ----
nO = numel(outputs);
for o = 1:nO
    e = outputs{o};
    unitStr = char(string(getField(e, 'unit', '')));
    [outDim, nChecked, iss] = parseUnitAt(unitStr, sprintf('outputs[%d].unit', o-1), T, nChecked);
    if ~isempty(iss)
        issues{end+1} = iss; %#ok<AGROW>
    end
    expr = char(string(getField(e, 'expression', '')));
    if isempty(strtrim(expr)) || any(isnan(outDim))
        continue
    end
    try
        exprDim = evalExprDims(expr, dimRefs);
    catch err
        if strcmp(err.identifier, 'bma:unit:mismatch')
            issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', sprintf('outputs[%d].expression', o-1), ...
                ['输出表达式内部量纲不一致：' err.message], ...
                '请检查输出表达式的量纲。', 'warning'); %#ok<AGROW>
        end
        continue
    end
    if any(isnan(exprDim))
        continue
    end
    if ~dimsEqual(exprDim, outDim)
        issues{end+1} = makeIssue('BMA_UNIT_MISMATCH', sprintf('outputs[%d]', o-1), ...
            sprintf('输出 "%s" 的单位 (%s) 与表达式量纲 (%s) 不一致', ...
                char(string(getField(e, 'id', ''))), dimText(outDim), dimText(exprDim)), ...
            '请检查输出表达式与输出单位是否一致。', 'warning'); %#ok<AGROW>
    end
end

% ---- 汇总 ----
severity = cellfun(@(s) s.severity, issues, 'UniformOutput', false);
isErr = strcmp(severity, 'error');
uc = struct();
uc.checked = true;
uc.ok = ~any(isErr);
uc.dimensional_ok = isempty(issues);
uc.n_units_checked = nChecked;
uc.issues = issues;
uc.errors = issues(isErr);
uc.warnings = issues(~isErr);
uc.n_errors = sum(isErr);
uc.n_warnings = sum(~isErr);
uc.note = '量纲检查：单位可解析性为错误级；量纲不一致为警告级（dimension warnings 会使 dimensional_ok=false）。';
end

% =========================================================================
function [dim, nChecked, iss] = parseUnitAt(unitStr, path, T, nChecked)
iss = [];
dim = nan(1, 8);
if isempty(strtrim(unitStr))
    iss = makeIssue('BMA_SPEC_MISSING_FIELD', path, '缺少单位（unit）', ...
        '请补充单位：浓度如 "uM"/"nM"；速率常数如 "1/s"/"1/(uM*s)"；无量纲填 "1"；计数用 "person"/"cell"/"molecule"。', ...
        'error');
    return
end
try
    dim = parseUnit(unitStr, T);
    nChecked = nChecked + 1;
catch err
    if strcmp(err.identifier, 'bma:unit:unknown') || strcmp(err.identifier, 'bma:unit:syntax')
        iss = makeIssue('BMA_UNIT_UNKNOWN', path, err.message, ...
            '可用示例：uM、nM、mM、M、s、min、h、day、L、mL、nM/min、1/(uM*s)、1、person。', ...
            'error');
    else
        iss = makeIssue('BMA_UNIT_UNKNOWN', path, ['单位解析失败：' err.message], ...
            '请检查单位字符串写法。', 'error');
    end
end
end

function dim = parseUnitSafe(unitStr, T)
dim = [];
if isempty(strtrim(unitStr))
    return
end
try
    dim = parseUnit(unitStr, T);
catch
    dim = [];
end
end

function dim = refDimById(value, dimRefs, idIndex, dimMat, ~)
% 把速率参数/物种引用（id 字符串或数值常量）解析为量纲向量。
if ischar(value) && ~isempty(value)
    if isKey(dimRefs, value)
        dim = dimRefs(value);
    elseif isKey(idIndex, value)
        dim = dimMat(idIndex(value), :);
    else
        dim = nan(1, 8);
    end
elseif isnumeric(value) && isscalar(value) && isfinite(value)
    dim = zeros(1, 8);
else
    dim = nan(1, 8);
end
end

function sid = singleSpeciesId(speciesDef, preferredField)
sid = '';
if ischar(speciesDef) && ~isempty(strtrim(speciesDef))
    sid = strtrim(speciesDef);
    return
end
if ~isstruct(speciesDef)
    return
end
fn = fieldnames(speciesDef);
if isfield(speciesDef, preferredField)
    v = speciesDef.(preferredField);
    if ischar(v)
        sid = v;
    end
    return
end
if numel(fn) == 1
    v = speciesDef.(fn{1});
    if ischar(v)
        sid = v;
    end
end
end

function tf = dimsEqual(a, b)
tf = all(abs(a - b) < 1e-9);
end

function s = dimText(d)
if any(isnan(d))
    s = '未知量纲';
    return
end
base = {'amount', 'volume', 'time', 'temperature', 'length', 'mass', 'count', 'current'};
if all(abs(d) < 1e-12)
    s = '无量纲';
    return
end
parts = {};
for k = 1:numel(base)
    if abs(d(k)) > 1e-12
        if abs(d(k) - 1) < 1e-12
            parts{end+1} = base{k}; %#ok<AGROW>
        else
            parts{end+1} = sprintf('%s^%g', base{k}, d(k)); %#ok<AGROW>
        end
    end
end
s = strjoin(parts, '*');
end
