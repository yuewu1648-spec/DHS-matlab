function r = rateParse(rate, ctx)
%RATEPARSE 校验并编译一条速率定律（bma.modelSpec.v1 §3.2）。
%
%   r = rateParse(rate, ctx)
%
% 输入：
%   rate : 规格中的 reactions[k].rate 结构体 {kind, parameters, species, ...}
%   ctx  : 结构体，字段
%          speciesIds / paramIds / compartmentIds : cellstr
%          speciesIndex / paramIndex : containers.Map（id → 1 基索引）
%          compartmentVolumes : 数值向量
% 输出 r（结构体）：
%   ok             : 逻辑值，是否通过校验
%   kind / mode / inhibitor_type
%   code           : 通量表达式的 MATLAB 代码字符串（物种→y(i)，参数→p(j)，常量直接数值）
%   display        : 人类可读公式（保留 id）
%   params_used / species_used : 用到的参数/物种 id（cellstr）
%   issues         : 错误列表，每项 {code,message,hint,subpath}
%   warnings       : 警告列表（结构同上）
%
% 速率定律公式（v1）：
%   mass_action       v = k * prod_i x_i^order_i
%   michaelis_menten  v = Vmax*S/(Km+S)
%                     竞争性抑制   v = Vmax*S/(Km*(1+I/Ki)+S)
%                     非竞争性抑制 v = Vmax*S/((Km+S)*(1+I/Ki))
%                     反竞争性抑制 v = Vmax*S/(Km+S*(1+I/Ki))
%   hill  激活模式   v = Vmax*R^n/(k^n+R^n)
%         抑制模式   v = Vmax*k^n/(k^n+R^n)
%   constant          v = k
%   expression        v = 受限表达式（白名单函数与 + - * / ^）
%
% 本函数从不抛异常；所有问题返回在 issues/warnings 中，由 bma.spec.validate 汇总。
if ~isstruct(rate)
    r = emptyResult();
    r.issues{end+1} = mkIssue('BMA_RATE_INVALID', '反应缺少 rate 对象', ...
        '请补充 rate，例如 {"kind":"mass_action","parameters":{"k":"kf"},"species":{"E":1,"S":1}}。', '');
    return
end
r = emptyResult();
ctx = fillContext(ctx);
kind = lower(strtrim(char(string(getField(rate, 'kind', '')))));
r.kind = kind;
paramsDef = getField(rate, 'parameters', struct());
speciesDef = getField(rate, 'species', struct());

switch kind
    case 'mass_action'
        r = parseMassAction(r, paramsDef, speciesDef, ctx);
    case 'michaelis_menten'
        r = parseMichaelisMenten(r, rate, paramsDef, speciesDef, ctx);
    case 'hill'
        r = parseHill(r, rate, paramsDef, speciesDef, ctx);
    case 'constant'
        r = parseConstant(r, paramsDef, ctx);
    case 'expression'
        r = parseExpressionRate(r, rate, ctx);
    otherwise
        if isempty(kind)
            r.issues{end+1} = mkIssue('BMA_RATE_INVALID', '缺少速率定律 kind 字段', ...
                'v1 支持的 kind：mass_action / michaelis_menten / hill / constant / expression。', 'kind');
        else
            r.issues{end+1} = mkIssue('BMA_RATE_INVALID', ...
                sprintf('不支持的速率定律 kind="%s"', kind), ...
                'v1 支持的 kind：mass_action / michaelis_menten / hill / constant / expression。', 'kind');
        end
end
r.params_used = uniqueNonEmpty(r.params_used);
r.species_used = uniqueNonEmpty(r.species_used);
r.ok = isempty(r.issues);
end

% =========================================================================
% 各类速率定律
% =========================================================================
function r = parseMassAction(r, paramsDef, speciesDef, ctx)
[kRef, iss] = makeRef(getField(paramsDef, 'k', []), ctx, 'param', 'parameters.k');
if ~isempty(iss)
    r.issues{end+1} = iss;
end
if isempty(getField(paramsDef, 'k', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'mass_action 缺少参数 parameters.k', ...
        '请写成 {"parameters":{"k":"<已有参数 id>"}}，例如结合反应 {"k":"kf"}。', 'parameters.k');
end
if ~isstruct(speciesDef) || isempty(fieldnames(speciesDef))
    r.issues{end+1} = mkIssue('BMA_RATE_INVALID', 'mass_action 缺少 species 定义', ...
        '请写出参与该反应的物种及反应级数，例如 {"E":1,"S":1}。', 'species');
    return
end
fn = fieldnames(speciesDef);
termsCode = {};
termsDisp = {};
for k = 1:numel(fn)
    sid = fn{k};
    order = speciesDef.(sid);
    [sRef, sIss] = makeRef(sid, ctx, 'species', ['species.' sid]);
    if ~isempty(sIss)
        r.issues{end+1} = sIss;
        continue
    end
    if ~isnumeric(order) || ~isscalar(order) || ~isfinite(order) || order < 0
        r.issues{end+1} = mkIssue('BMA_RATE_INVALID', ...
            sprintf('mass_action 中物种 "%s" 的反应级数必须是非负有限数值', sid), ...
            '反应级数一般取整数（0、1、2…），例如 {"S":1,"E":1}。', ['species.' sid]);
        continue
    end
    if order == 0
        r.warnings{end+1} = mkIssue('BMA_RATE_WARN_ZERO_ORDER', ...
            sprintf('物种 "%s" 的反应级数为 0，该物种不影响反应速率', sid), ...
            '若非有意，请把级数改为 1 或从 species 中删除该物种。', ['species.' sid]);
        continue
    end
    r.species_used{end+1} = sid;
    if order == 1
        termsCode{end+1} = sRef.code; %#ok<AGROW>
        termsDisp{end+1} = sRef.display; %#ok<AGROW>
    else
        termsCode{end+1} = sprintf('%s^%s', sRef.code, numToCode(order)); %#ok<AGROW>
        termsDisp{end+1} = sprintf('%s^%s', sRef.display, formatNumber(order)); %#ok<AGROW>
    end
end
if isempty(termsCode) || ~kRef.ok
    return
end
r.params_used{end+1} = kRef.id;
code = kRef.code;
disp = kRef.display;
for k = 1:numel(termsCode)
    code = [code '*' termsCode{k}]; %#ok<AGROW>
    disp = [disp '*' termsDisp{k}]; %#ok<AGROW>
end
r.code = code;
r.display = disp;
end

function r = parseMichaelisMenten(r, rate, paramsDef, speciesDef, ctx)
r.mode = '';
bad = false;
[vRef, iss] = makeRef(getField(paramsDef, 'vmax', []), ctx, 'param', 'parameters.vmax');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
[kRef, iss] = makeRef(getField(paramsDef, 'km', []), ctx, 'param', 'parameters.km');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
if isempty(getField(paramsDef, 'vmax', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'michaelis_menten 缺少参数 parameters.vmax', ...
        '请写成 {"vmax":"<参数 id>","km":"<参数 id>"}。', 'parameters.vmax');
    bad = true;
end
if isempty(getField(paramsDef, 'km', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'michaelis_menten 缺少参数 parameters.km', ...
        'Km 与底物必须同单位（如 uM）。', 'parameters.km');
    bad = true;
end
[sid, iss] = singleSpeciesValue(speciesDef, 'substrate');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
sRef = struct('ok', false, 'id', '', 'code', '', 'display', '');
if ~isempty(sid)
    [sRef, iss] = makeRef(sid, ctx, 'species', 'species.substrate');
    if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
end
if sRef.ok, r.species_used{end+1} = sRef.id; end
if vRef.ok, r.params_used{end+1} = vRef.id; end
if kRef.ok, r.params_used{end+1} = kRef.id; end

% 可选抑制剂
inh = getField(rate, 'inhibitor', []);
itype = '';
if ~isempty(inh)
    if ~isstruct(inh)
        r.issues{end+1} = mkIssue('BMA_RATE_INVALID', 'inhibitor 必须是对象 {species, ki, type}', ...
            '例如 {"species":"I","ki":"Ki","type":"competitive"}。', 'inhibitor');
        bad = true;
    else
        itype = lower(strtrim(char(string(getField(inh, 'type', 'competitive')))));
        if ~any(strcmp(itype, {'competitive', 'noncompetitive', 'uncompetitive'}))
            r.issues{end+1} = mkIssue('BMA_RATE_INVALID', ...
                sprintf('非法的抑制类型 inhibitor.type="%s"', itype), ...
                'type 只能是 "competitive"（竞争性）、"noncompetitive"（非竞争性）或 "uncompetitive"（反竞争性）。', 'inhibitor.type');
            bad = true;
        end
        [iid, iss] = singleSpeciesValue(inh, 'species');
        if ~isempty(iss)
            r.issues{end+1} = iss;
            bad = true;
        end
        iRef = struct('ok', false, 'id', '', 'code', '', 'display', '');
        if ~isempty(iid)
            [iRef, iss] = makeRef(iid, ctx, 'species', 'inhibitor.species');
            if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
        end
        [kiRef, iss] = makeRef(getField(inh, 'ki', []), ctx, 'param', 'inhibitor.ki');
        if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
        if isempty(getField(inh, 'ki', []))
            r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', '抑制项缺少 inhibitor.ki', ...
                'Ki 必须与底物同单位（如 uM）。', 'inhibitor.ki');
            bad = true;
        end
        if iRef.ok, r.species_used{end+1} = iRef.id; end
        if kiRef.ok, r.params_used{end+1} = kiRef.id; end
    end
end
r.inhibitor_type = itype;
if bad
    return
end
S = sRef;
V = vRef;
Km = kRef;
switch itype
    case ''
        r.code = sprintf('%s*%s/(%s+%s)', V.code, S.code, Km.code, S.code);
        r.display = sprintf('%s*%s/(%s+%s)', V.display, S.display, Km.display, S.display);
    case 'competitive'
        I = inhSpeciesRef(inh, ctx);
        Ki = inhParamRef(inh, ctx);
        r.code = sprintf('%s*%s/(%s*(1+%s/%s)+%s)', ...
            V.code, S.code, Km.code, I.code, Ki.code, S.code);
        r.display = sprintf('%s*%s/(%s*(1+%s/%s)+%s)', ...
            V.display, S.display, Km.display, I.display, Ki.display, S.display);
    case 'noncompetitive'
        I = inhSpeciesRef(inh, ctx);
        Ki = inhParamRef(inh, ctx);
        r.code = sprintf('%s*%s/((%s+%s)*(1+%s/%s))', ...
            V.code, S.code, Km.code, S.code, I.code, Ki.code);
        r.display = sprintf('%s*%s/((%s+%s)*(1+%s/%s))', ...
            V.display, S.display, Km.display, S.display, I.display, Ki.display);
    otherwise  % uncompetitive
        I = inhSpeciesRef(inh, ctx);
        Ki = inhParamRef(inh, ctx);
        r.code = sprintf('%s*%s/(%s+%s*(1+%s/%s))', ...
            V.code, S.code, Km.code, S.code, I.code, Ki.code);
        r.display = sprintf('%s*%s/(%s+%s*(1+%s/%s))', ...
            V.display, S.display, Km.display, S.display, I.display, Ki.display);
end
end

function r = parseHill(r, rate, paramsDef, speciesDef, ctx)
bad = false;
mode = lower(strtrim(char(string(getField(rate, 'mode', '')))));
r.mode = mode;
if isempty(mode)
    r.issues{end+1} = mkIssue('BMA_RATE_INVALID', 'hill 速率缺少 mode 字段', ...
        'mode 必须是 "activation"（激活）或 "repression"（抑制）。', 'mode');
    bad = true;
elseif ~any(strcmp(mode, {'activation', 'repression'}))
    r.issues{end+1} = mkIssue('BMA_RATE_INVALID', ...
        sprintf('非法的 Hill 模式 mode="%s"', mode), ...
        'mode 只能是 "activation"（激活，v=Vmax*R^n/(k^n+R^n)）或 "repression"（抑制，v=Vmax*k^n/(k^n+R^n)）。', 'mode');
    bad = true;
end
[vRef, iss] = makeRef(getField(paramsDef, 'vmax', []), ctx, 'param', 'parameters.vmax');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
[kRef, iss] = makeRef(getField(paramsDef, 'k', []), ctx, 'param', 'parameters.k');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
[nRef, iss] = makeRef(getField(paramsDef, 'n', []), ctx, 'param', 'parameters.n');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
if isempty(getField(paramsDef, 'vmax', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'hill 速率缺少 parameters.vmax', ...
        'vmax 是最大速率，单位应为 浓度/时间。', 'parameters.vmax');
    bad = true;
end
if isempty(getField(paramsDef, 'k', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'hill 速率缺少 parameters.k', ...
        'k 是半效浓度，必须与调控物种同单位。', 'parameters.k');
    bad = true;
end
if isempty(getField(paramsDef, 'n', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'hill 速率缺少 parameters.n', ...
        'n 是 Hill 指数（无量纲，常用 1~4）。', 'parameters.n');
    bad = true;
end
[rid, iss] = singleSpeciesValue(speciesDef, 'regulator');
if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
rRef = struct('ok', false, 'id', '', 'code', '', 'display', '');
if ~isempty(rid)
    [rRef, iss] = makeRef(rid, ctx, 'species', 'species.regulator');
    if ~isempty(iss), r.issues{end+1} = iss; bad = true; end
end
if vRef.ok, r.params_used{end+1} = vRef.id; end
if kRef.ok, r.params_used{end+1} = kRef.id; end
if nRef.ok && ~isempty(nRef.id), r.params_used{end+1} = nRef.id; end
if rRef.ok, r.species_used{end+1} = rRef.id; end
if bad
    return
end
R = rRef;
V = vRef;
K = kRef;
N = nRef;
if strcmp(mode, 'activation')
    r.code = sprintf('%s*%s^%s/(%s^%s+%s^%s)', ...
        V.code, R.code, N.code, K.code, N.code, R.code, N.code);
    r.display = sprintf('%s*%s^%s/(%s^%s+%s^%s)', ...
        V.display, R.display, N.display, K.display, N.display, R.display, N.display);
else
    r.code = sprintf('%s*%s^%s/(%s^%s+%s^%s)', ...
        V.code, K.code, N.code, K.code, N.code, R.code, N.code);
    r.display = sprintf('%s*%s^%s/(%s^%s+%s^%s)', ...
        V.display, K.display, N.display, K.display, N.display, R.display, N.display);
end
end

function r = parseConstant(r, paramsDef, ctx)
[kRef, iss] = makeRef(getField(paramsDef, 'k', []), ctx, 'param', 'parameters.k');
if ~isempty(iss)
    r.issues{end+1} = iss;
end
if isempty(getField(paramsDef, 'k', []))
    r.issues{end+1} = mkIssue('BMA_SPEC_MISSING_FIELD', 'constant 速率缺少 parameters.k', ...
        'k 的维度应为 浓度/时间（或 count/时间）。', 'parameters.k');
    return
end
if ~kRef.ok
    return
end
r.params_used{end+1} = kRef.id;
r.code = kRef.code;
r.display = kRef.display;
end

function r = parseExpressionRate(r, rate, ctx)
expr = getField(rate, 'expression', '');
if ~ischar(expr) || isempty(strtrim(expr))
    r.issues{end+1} = mkIssue('BMA_RATE_INVALID', 'expression 速率缺少 expression 字段', ...
        '例如 {"kind":"expression","expression":"beta*S*I/N"}。', 'expression');
    return
end
refsMap = makeExpressionRefs(ctx);
try
    [code, info] = parseExpression(expr, refsMap);
    r.code = code;
    r.display = expr;
    for k = 1:numel(info.ids)
        id = info.ids{k};
        if isKey(ctx.paramIndex, id)
            r.params_used{end+1} = id;
        elseif isKey(ctx.speciesIndex, id)
            r.species_used{end+1} = id;
        end
    end
catch err
    [codeId, msg, hint] = mapExprError(err);
    r.issues{end+1} = mkIssue(codeId, msg, hint, 'expression');
end
end

% =========================================================================
% 工具函数
% =========================================================================
function r = emptyResult()
r = struct( ...
    'ok', false, ...
    'kind', '', ...
    'mode', '', ...
    'inhibitor_type', '', ...
    'code', '', ...
    'display', '', ...
    'params_used', {{}}, ...
    'species_used', {{}}, ...
    'issues', {{}}, ...
    'warnings', {{}});
end

function ctx = fillContext(ctx)
if ~isstruct(ctx)
    ctx = struct();
end
defaults = struct( ...
    'speciesIds', {{}}, 'paramIds', {{}}, 'compartmentIds', {{}}, ...
    'speciesIndex', containers.Map(), 'paramIndex', containers.Map(), ...
    'compartmentVolumes', []);
fn = fieldnames(defaults);
for k = 1:numel(fn)
    if ~isfield(ctx, fn{k})
        ctx.(fn{k}) = defaults.(fn{k});
    end
end
end

function s = mkIssue(code, message, hint, subpath)
if nargin < 4
    subpath = '';
end
s = struct('code', char(code), 'message', char(message), ...
    'hint', char(hint), 'subpath', char(subpath));
end

function [ref, iss] = makeRef(value, ctx, expectation, subpath)
% 将速率参数/物种引用（参数 id 字符串或数值常量）编译为代码片段。
ref = struct('ok', false, 'id', '', 'code', '', 'display', '');
iss = [];
if ischar(value) && ~isempty(strtrim(value))
    id = strtrim(value);
    if any(strcmp(expectation, {'param', 'any'})) && isKey(ctx.paramIndex, id)
        ref.ok = true;
        ref.id = id;
        ref.code = sprintf('p(%d)', ctx.paramIndex(id));
        ref.display = id;
        return
    end
    if any(strcmp(expectation, {'species', 'any'})) && isKey(ctx.speciesIndex, id)
        ref.ok = true;
        ref.id = id;
        ref.code = sprintf('y(%d)', ctx.speciesIndex(id));
        ref.display = id;
        return
    end
    if strcmp(expectation, 'param')
        label = '参数';
        known = ctx.paramIds;
        example = '{"k":"kf"}';
    else
        label = '物种';
        known = ctx.speciesIds;
        example = '{"substrate":"S"}';
    end
    iss = mkIssue('BMA_SPEC_UNKNOWN_ID', ...
        sprintf('速率定律引用了不存在的%s "%s"', label, id), ...
        sprintf('请检查 id 拼写，或在规格中补充该%s；当前可用 id：%s。示例：%s', ...
            label, shortList(known), example), subpath);
elseif isnumeric(value) && isscalar(value) && isfinite(value)
    ref.ok = true;
    ref.code = numToCode(value);
    ref.display = formatNumber(value);
else
    iss = mkIssue('BMA_RATE_INVALID', ...
        '速率定律参数必须是已有参数 id（字符串）或有限数值常量', ...
        '例如 {"k":"kf"} 或 {"k":0.5}；物种引用必须是已有变量的 id。', subpath);
end
end

function [val, iss] = singleSpeciesValue(speciesDef, preferredField)
% 从 species 定义中取出唯一物种 id（兼容 {"substrate":"S"}、{"regulator":"R"} 或直接 "S"）。
val = '';
iss = [];
if ischar(speciesDef) && ~isempty(strtrim(speciesDef))
    val = strtrim(speciesDef);
    return
end
if ~isstruct(speciesDef)
    iss = mkIssue('BMA_RATE_INVALID', 'species 必须是对象或物种 id 字符串', ...
        '例如 {"substrate":"S"}（米氏）或 {"regulator":"R"}（Hill）。', 'species');
    return
end
fn = fieldnames(speciesDef);
if isempty(fn)
    iss = mkIssue('BMA_RATE_INVALID', '缺少 species 定义', ...
        '例如 {"substrate":"S"}（米氏）或 {"regulator":"R"}（Hill）。', 'species');
    return
end
if isfield(speciesDef, preferredField)
    v = speciesDef.(preferredField);
    if ischar(v) && ~isempty(strtrim(v))
        val = strtrim(v);
        return
    end
    iss = mkIssue('BMA_RATE_INVALID', ...
        sprintf('species.%s 必须是物种 id 字符串', preferredField), ...
        '例如 {"substrate":"S"}。', ['species.' preferredField]);
    return
end
if numel(fn) == 1
    v = speciesDef.(fn{1});
    if ischar(v) && ~isempty(strtrim(v))
        val = strtrim(v);
        return
    end
end
iss = mkIssue('BMA_RATE_INVALID', ...
    sprintf('species 必须恰好指定一个物种（%s 或单字段形式）', preferredField), ...
    '例如 {"substrate":"S"}（米氏）或 {"regulator":"R"}（Hill）。', 'species');
end

function ref = inhSpeciesRef(inh, ctx)
ref = struct('ok', false, 'id', '', 'code', '', 'display', '');
if isstruct(inh)
    sid = getField(inh, 'species', '');
    if ischar(sid) && isKey(ctx.speciesIndex, sid)
        ref.ok = true;
        ref.id = sid;
        ref.code = sprintf('y(%d)', ctx.speciesIndex(sid));
        ref.display = sid;
    end
end
end

function ref = inhParamRef(inh, ctx)
ref = struct('ok', false, 'id', '', 'code', '', 'display', '');
if isstruct(inh)
    kid = getField(inh, 'ki', '');
    if ischar(kid) && isKey(ctx.paramIndex, kid)
        ref.ok = true;
        ref.id = kid;
        ref.code = sprintf('p(%d)', ctx.paramIndex(kid));
        ref.display = kid;
    end
end
end

function refsMap = makeExpressionRefs(ctx)
refsMap = containers.Map('KeyType', 'char', 'ValueType', 'char');
for i = 1:numel(ctx.speciesIds)
    refsMap(ctx.speciesIds{i}) = sprintf('y(%d)', i);
end
for j = 1:numel(ctx.paramIds)
    refsMap(ctx.paramIds{j}) = sprintf('p(%d)', j);
end
for k = 1:numel(ctx.compartmentIds)
    refsMap(ctx.compartmentIds{k}) = numToCode(ctx.compartmentVolumes(k));
end
end

function [codeId, msg, hint] = mapExprError(err)
if strcmp(err.identifier, 'bma:expr:unknown_id')
    codeId = 'BMA_SPEC_UNKNOWN_ID';
    msg = err.message;
    hint = '请检查表达式引用的 id 是否存在于 variables / parameters / compartments 中。';
elseif strcmp(err.identifier, 'bma:expr:forbidden')
    codeId = 'BMA_RATE_INVALID';
    msg = err.message;
    hint = '只允许 + - * / ^ 与 exp/log/sqrt/min/max；其他函数请改用组合速率定律或拆分反应。';
else
    codeId = 'BMA_RATE_INVALID';
    msg = ['速率表达式语法错误：' err.message];
    hint = '请检查括号是否配对、运算符位置与数字格式，例如 "beta*S*I/N"。';
end
end

function c = uniqueNonEmpty(c)
if isempty(c)
    c = {};
    return
end
c = unique(c, 'stable');
c = c(~cellfun(@isempty, c));
end

function s = shortList(ids)
if isempty(ids)
    s = '（无）';
elseif numel(ids) <= 12
    s = strjoin(ids, ', ');
else
    s = [strjoin(ids(1:12), ', ') ', ...'];
end
end

function s = numToCode(v)
% 数值 → 高精度 MATLAB 字面量（避免 0.1 之类的二进制误差影响仿真/代码生成）
s = sprintf('%.17g', v);
end
