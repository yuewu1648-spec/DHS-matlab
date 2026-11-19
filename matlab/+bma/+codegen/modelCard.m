function card = modelCard(spec)
%MODELCARD 生成 JSON 安全的模型卡（model_card.json 的内容）。
%   card = bma.codegen.modelCard(spec)     % 接受模型规格或 bma.model.build 的模型结构
%
% 模型卡用于报告、归档与代码生成，包含：模型名/标题/描述、时间轴、物种表、
% 参数表（含单位/默认值/是否估计/bounds）、反应与速率公式、ODE 方程、守恒律概要、
% 假设与证据、如何运行生成代码的说明。整个结构体可直接 jsonencode。
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec)
    error('bma:spec:spec_invalid', 'bma.codegen.modelCard 需要模型规格或模型结构');
end
if isfield(spec, 'rhs')
    m = spec;
else
    m = bma.model.build(spec);
end
nS = m.n_species;
nP = m.n_params;
nR = m.n_reactions;
nO = m.n_outputs;

species = repmat(struct('index', 0, 'id', '', 'name', '', 'unit', '', ...
    'initial', 0, 'compartment', ''), 1, nS);
for i = 1:nS
    species(i) = struct('index', i, 'id', m.species{i}, ...
        'name', m.speciesNames{i}, 'unit', m.speciesUnits{i}, ...
        'initial', m.speciesInitial(i), 'compartment', m.speciesCompartment{i});
end
parameters = repmat(struct('index', 0, 'id', '', 'name', '', 'unit', '', ...
    'value', 0, 'estimate', false, 'bounds', [], 'evidence_types', {{}}), 1, nP);
for j = 1:nP
    est = false;
    if isfield(m, 'paramEstimate')
        est = logical(m.paramEstimate(j));
    end
    b = [];
    if isfield(m, 'paramBounds') && all(isfinite(m.paramBounds(j, :)))
        b = m.paramBounds(j, :);
    end
    evTypes = paramEvidenceTypes(m.spec, m.params{j});
    parameters(j) = struct('index', j, 'id', m.params{j}, ...
        'name', m.paramNames{j}, 'unit', m.paramUnits{j}, ...
        'value', m.paramValues(j), 'estimate', est, 'bounds', b, ...
        'evidence_types', {evTypes});
end
reactions = repmat(struct('index', 0, 'id', '', 'name', '', 'kind', '', ...
    'flux', '', 'stoichiometry', struct()), 1, nR);
for r = 1:nR
    reactions(r) = struct('index', r, 'id', m.reactions(r).id, ...
        'name', m.reactions(r).name, 'kind', m.reactions(r).kind, ...
        'flux', m.reactions(r).flux, ...
        'stoichiometry', m.reactions(r).stoichiometry);
end
% 守恒律概要（无需完整符号分析，用秩估计）
cons = struct('n_laws', 0, 'stoich_rank', 0, 'note', '');
try
    r = rank(m.S);
    cons.n_laws = max(0, nS - r);
    cons.stoich_rank = r;
    if cons.n_laws > 0
        cons.note = sprintf('检测到 %d 个线性守恒律（详细表达式见 bma.model.analyze）。', cons.n_laws);
    else
        cons.note = '未检测到线性守恒律。';
    end
catch
end
assumptions = {};
if isfield(m.spec, 'assumptions')
    assumptions = m.spec.assumptions;
end
evidence = {};
if isfield(m.spec, 'evidence')
    evidence = m.spec.evidence;
end
time = m.time;
card = struct();
card.schema_version = 'bma.model_card.v1';
card.generated_at = bma.util.nowIso();
card.generator = 'bma.codegen.model';
card.name = m.name;
card.title = m.title;
card.description = m.description;
card.kind = m.kind;
card.time = struct('unit', time.unit, 'start', time.start, 'end', time.end, 'n', time.n);
card.n_species = nS;
card.n_parameters = nP;
card.n_reactions = nR;
card.n_outputs = nO;
card.species = species;
card.parameters = parameters;
card.reactions = reactions;
card.outputs = repmat(struct('id', '', 'name', '', 'unit', '', 'expression', ''), 1, nO);
for o = 1:nO
    card.outputs(o) = struct('id', m.outputs(o).id, 'name', m.outputs(o).name, ...
        'unit', m.outputs(o).unit, 'expression', m.outputs(o).expression);
end
card.equations = m.odeText;
card.rate_laws = m.rateText;
card.conservation = cons;
card.assumptions = assumptions;
card.evidence = evidence;
card.parameter_order = m.params;
card.species_order = m.species;
card.metadata = struct();
if isfield(m.spec, 'metadata')
    card.metadata = m.spec.metadata;
end
if isfield(m, 'pde')
    card.pde = m.pde;
end
card.how_to_run = ['生成代码：<name>_ode.m 为 ODE 右端函数 dydt=f(t,y,p)；' ...
    '<name>_run.m 为仿真包装 [t,Y,out]=f(p,tspan,y0,opts)；p 顺序见 parameter_order，y 顺序见 species_order。'];
card.warnings = {};
end

% =========================================================================
function types = paramEvidenceTypes(spec, pid)
types = {};
if ~isstruct(spec) || ~isfield(spec, 'parameters')
    return
end
items = toItems(spec.parameters);
for k = 1:numel(items)
    e = items{k};
    if ~isstruct(e) || ~isfield(e, 'id') || ~strcmp(char(string(e.id)), pid)
        continue
    end
    if isfield(e, 'evidence')
        ev = toItems(e.evidence);
        for j = 1:numel(ev)
            if isstruct(ev{j}) && isfield(ev{j}, 'type')
                types{end+1} = char(string(ev{j}.type)); %#ok<AGROW>
            end
        end
    end
end
types = unique(types, 'stable');
end

function items = toItems(x)
% 将 struct 数组 / 元胞 / 单结构体统一为 1×N 元胞
items = {};
if isempty(x)
    return
end
if isstruct(x)
    n = numel(x);
    items = cell(1, n);
    for k = 1:n
        items{k} = x(k);
    end
elseif iscell(x)
    items = reshape(x, 1, numel(x));
else
    items = {x};
end
end
