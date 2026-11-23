function spec = normalize(spec)
%NORMALIZE 为 bma.modelSpec.v1 模型规格补齐默认字段并统一数据类型。
%   spec = bma.spec.normalize(spec)
%
% 只做“补默认 + 类型规范化”，不判断合法性（合法性由 bma.spec.validate 负责）。
% 补全内容（依据 DESIGN §5.2）：
%   - compartments：缺省单室 cell（体积 1 L）
%   - variables.initial：缺省 0；variable.compartment：缺省第一个隔室
%   - parameters.bounds：estimate 为 true 且缺省时给默认范围（数值的 1e-3~1e3 倍）
%   - outputs：缺省时等于 variables（观测量 = 状态变量）
%   - datasets / evidence / assumptions / metadata：缺省空
% 同时把 jsondecode 的 struct 数组 / 元胞 / 标量统一为字段齐全的结构体数组，
% 保证 jsonencode(spec) 可稳定回写为合法 JSON。
%
% 注意：本函数对缺失的顶层必填字段（schema_version/name/kind/time/variables/
% parameters/reactions）只做最小填充，是否合法由 validate 判断。
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec) || isempty(spec)
    error('bma:spec:spec_invalid', 'normalize 需要非空的模型规格结构体');
end
if numel(spec) > 1
    spec = spec(1);
end
out = spec;  % 保留顶层未知字段（metadata 等自由字段）

% ---- 顶层文本/结构字段 ----
if ~isfield(out, 'schema_version') || ~ischar(out.schema_version) || isempty(out.schema_version)
    out.schema_version = 'bma.modelSpec.v1';
end
if ~isfield(out, 'name') || ~ischar(out.name)
    out.name = '';
end
if ~isfield(out, 'title') || ~ischar(out.title)
    out.title = '';
end
if ~isfield(out, 'description') || ~ischar(out.description)
    out.description = '';
end
if ~isfield(out, 'kind') || ~ischar(out.kind)
    out.kind = '';
end
out.time = normalizeTime(getField(out, 'time', struct()));
out.compartments = normalizeCompartments(getField(out, 'compartments', []));
compIds = compartmentIds(out.compartments);
if isempty(compIds)
    out.compartments = defaultCompartment();
    compIds = compartmentIds(out.compartments);
end

% ---- variables ----
rawVars = itemize(getField(out, 'variables', []));
varItems = cell(1, numel(rawVars));
for i = 1:numel(rawVars)
    e = rawVars{i};
    s = struct();
    s.id = charIf(getField(e, 'id', ''), '');
    s.name = charIf(getField(e, 'name', ''), '');
    s.unit = charIf(getField(e, 'unit', ''), '');
    s.compartment = charIf(getField(e, 'compartment', ''), '');
    if isempty(s.compartment) && ~isempty(compIds)
        s.compartment = compIds{1};
    end
    s.initial = normalizeValueField(getField(e, 'initial', []), 0);
    % kind: "state" (ODE state, default) or "algebraic" (helper expression)
    kind = '';
    try
        kind = charIf(getField(e, 'kind', ''), '');
    catch
    end
    alg = false;
    try
        if isfield(e, 'algebraic') && ~isempty(e.algebraic)
            alg = logical(e.algebraic);
        end
    catch
    end
    if strcmpi(kind, 'algebraic') || alg
        s.kind = 'algebraic';
        s.algebraic = true;
    else
        s.kind = 'state';
        s.algebraic = false;
    end
    s.expression = charIf(getField(e, 'expression', ''), '');
    signed = false;
    try
        if isfield(e, 'signed') && ~isempty(e.signed)
            signed = logical(e.signed);
        end
    catch
    end
    s.signed = signed;
    varItems{i} = s;
end
out.variables = structArray(varItems);

% ---- parameters ----
rawParams = itemize(getField(out, 'parameters', []));
parItems = cell(1, numel(rawParams));
for i = 1:numel(rawParams)
    e = rawParams{i};
    s = struct();
    s.id = charIf(getField(e, 'id', ''), '');
    s.name = charIf(getField(e, 'name', ''), '');
    s.unit = charIf(getField(e, 'unit', ''), '');
    s.value = normalizeValueField(getField(e, 'value', []), []);
    s.estimate = normalizeLogical(getField(e, 'estimate', false), false);
    s.bounds = normalizeBounds(getField(e, 'bounds', []));
    s.evidence = normalizeEvidence(getField(e, 'evidence', []));
    % estimate 为 true 且没有 bounds 时给默认范围（validate 会给出提示）
    if islogical(s.estimate) && isscalar(s.estimate) && s.estimate && isempty(s.bounds)
        v = s.value.value;
        if isnumeric(v) && isscalar(v) && isfinite(v)
            if v > 0
                s.bounds = [v * 1e-3, v * 1e3];
            elseif v < 0
                s.bounds = [v - abs(v), v + abs(v)];
            else
                s.bounds = [-1, 1];
            end
        end
    end
    parItems{i} = s;
end
out.parameters = structArray(parItems);

% ---- reactions ----
rawReacts = itemize(getField(out, 'reactions', []));
reacItems = cell(1, numel(rawReacts));
for i = 1:numel(rawReacts)
    e = rawReacts{i};
    s = struct();
    s.id = charIf(getField(e, 'id', ''), '');
    s.name = charIf(getField(e, 'name', ''), '');
    stoich = getField(e, 'stoichiometry', struct());
    if ~isstruct(stoich)
        stoich = struct();
    end
    s.stoichiometry = stoich;
    s.rate = normalizeRate(getField(e, 'rate', []));
    reacItems{i} = s;
end
out.reactions = structArray(reacItems);

% ---- outputs（缺省 = variables）----
rawOutputs = itemize(getField(out, 'outputs', []));
if isempty(rawOutputs)
    % outputs 缺省时用变量本身作为观测量
    rawOutputs = cell(1, numel(rawVars));
    for i = 1:numel(rawVars)
        rawOutputs{i} = struct('id', getField(rawVars{i}, 'id', ''), ...
            'name', getField(rawVars{i}, 'name', ''), ...
            'unit', getField(rawVars{i}, 'unit', ''), ...
            'expression', getField(rawVars{i}, 'id', ''));
    end
end
outItems = cell(1, numel(rawOutputs));
for i = 1:numel(rawOutputs)
    e = rawOutputs{i};
    s = struct();
    s.id = charIf(getField(e, 'id', ''), '');
    s.name = charIf(getField(e, 'name', ''), '');
    s.unit = charIf(getField(e, 'unit', ''), '');
    s.expression = charIf(getField(e, 'expression', ''), '');
    s.note = charIf(getField(e, 'note', ''), '');
    outItems{i} = s;
end
out.outputs = structArray(outItems);

% ---- datasets ----
rawData = itemize(getField(out, 'datasets', []));
dsItems = cell(1, numel(rawData));
for i = 1:numel(rawData)
    e = rawData{i};
    s = struct();
    s.id = charIf(getField(e, 'id', ''), '');
    s.name = charIf(getField(e, 'name', ''), '');
    s.time_unit = charIf(getField(e, 'time_unit', ''), '');
    s.time = columnVector(getField(e, 'time', []));
    cols = getField(e, 'columns', struct());
    if ~isstruct(cols)
        cols = struct();
    end
    s.columns = cols;
    s.source = charIf(getField(e, 'source', ''), '');
    dsItems{i} = s;
end
out.datasets = structArray(dsItems);

% ---- assumptions / evidence / metadata ----
out.assumptions = toCellstr(getField(out, 'assumptions', []));
out.evidence = normalizeEvidence(getField(out, 'evidence', []));
md = getField(out, 'metadata', struct());
if ~isstruct(md)
    md = struct();
end
out.metadata = md;

spec = out;
end

% =========================================================================
function t = normalizeTime(raw)
t = struct();
t.unit = charIf(getField(raw, 'unit', 's'), 's');
t.start = getField(raw, 'start', 0);
t.end = getField(raw, 'end', 100);
t.n = getField(raw, 'n', 101);
end

function comps = normalizeCompartments(raw)
items = itemize(raw);
if isempty(items)
    comps = {};
    return
end
c = cell(1, numel(items));
for i = 1:numel(items)
    e = items{i};
    s = struct();
    s.id = charIf(getField(e, 'id', ''), '');
    s.volume = getField(e, 'volume', 1);
    s.unit = charIf(getField(e, 'unit', ''), '');
    c{i} = s;
end
comps = structArray(c);
end

function comps = defaultCompartment()
comps = struct('id', 'cell', 'volume', 1, 'unit', 'L');
end

function ids = compartmentIds(comps)
items = itemize(comps);
ids = cell(1, numel(items));
for i = 1:numel(items)
    ids{i} = charIf(getField(items{i}, 'id', ''), '');
end
end

function v = normalizeValueField(raw, defaultValue)
% 统一 {value, note, param?, expression?} 形式；JSON 里允许直接给数值。
% initial 支持 {"param":"p0"} / {"expression":"p0*2"}（Gap A），这里必须保留
% 这两个字段，否则编译期会静默回退到 0。
if isstruct(raw)
    v = struct();
    v.value = getField(raw, 'value', defaultValue);
    v.note = charIf(getField(raw, 'note', ''), '');
    if isfield(raw, 'param') && ~isempty(raw.param)
        v.param = charIf(raw.param, '');
    end
    if isfield(raw, 'expression') && ~isempty(raw.expression)
        v.expression = charIf(raw.expression, '');
    end
elseif isnumeric(raw) && isscalar(raw)
    v = struct('value', raw, 'note', '');
elseif isempty(raw)
    v = struct('value', defaultValue, 'note', '');
else
    v = struct('value', raw, 'note', '');
end
end

function b = normalizeBounds(raw)
if isnumeric(raw) && ~isempty(raw)
    b = reshape(raw, 1, numel(raw));
elseif isempty(raw)
    b = [];
else
    b = raw;  % 非法类型原样保留，交给 validate 报错
end
end

function flag = normalizeLogical(raw, defaultValue)
if islogical(raw) && isscalar(raw)
    flag = raw;
elseif isnumeric(raw) && isscalar(raw)
    flag = (raw ~= 0);
elseif isempty(raw)
    flag = defaultValue;
else
    flag = raw;  % 非法类型原样保留，交给 validate 报错
end
end

function ev = normalizeEvidence(raw)
items = itemize(raw);
if isempty(items)
    ev = {};
    return
end
c = cell(1, numel(items));
for i = 1:numel(items)
    e = items{i};
    if ~isstruct(e)
        c{i} = struct('type', '', 'quote', '', 'section_id', '', 'source', '', 'note', '');
        continue
    end
    s = e;  % 保留证据条目里的其他字段
    s.type = charIf(getField(e, 'type', ''), '');
    s.quote = charIf(getField(e, 'quote', ''), '');
    s.section_id = charIf(getField(e, 'section_id', ''), '');
    s.source = charIf(getField(e, 'source', ''), '');
    s.note = charIf(getField(e, 'note', ''), '');
    c{i} = s;
end
ev = c;
end

function r = normalizeRate(raw)
if ~isstruct(raw)
    r = raw;
    return
end
r = struct();
r.kind = charIf(getField(raw, 'kind', ''), '');
params = getField(raw, 'parameters', struct());
if ~isstruct(params)
    params = struct();
end
r.parameters = params;
species = getField(raw, 'species', struct());
if ~isstruct(species)
    species = struct();
end
r.species = species;
r.mode = charIf(getField(raw, 'mode', ''), '');
r.expression = charIf(getField(raw, 'expression', ''), '');
% kind="matlab"：自定义函数速率（function/file/arguments/unit/display）
r.unit = charIf(getField(raw, 'unit', ''), '');
r.display = charIf(getField(raw, 'display', ''), '');
fn = getField(raw, 'function', '');
if ischar(fn) || (isstring(fn) && isscalar(fn))
    r.('function') = char(fn);
end
r.file = charIf(getField(raw, 'file', ''), '');
args = getField(raw, 'arguments', {});
if ischar(args) || (isstring(args) && all(isscalar(args)))
    args = cellstr(args);
elseif isnumeric(args)
    args = num2cell(args(:).');
end
if iscell(args)
    r.arguments = reshape(args, 1, []);
else
    r.arguments = {};
end
inh = getField(raw, 'inhibitor', []);
if isstruct(inh)
    i2 = struct();
    i2.species = charIf(getField(inh, 'species', ''), '');
    i2.ki = getField(inh, 'ki', []);
    i2.type = charIf(getField(inh, 'type', 'competitive'), 'competitive');
    inh = i2;
end
r.inhibitor = inh;
end

function c = charIf(v, default)
if ischar(v)
    c = v;
elseif isstring(v) && isscalar(v)
    c = char(v);
elseif isempty(v)
    c = default;
else
    c = default;
end
end

function arr = structArray(items)
if isempty(items)
    arr = {};
    return
end
arr = [items{:}];
end

function v = columnVector(x)
if isnumeric(x) && ~isempty(x)
    v = x(:);
else
    v = x;
end
end
