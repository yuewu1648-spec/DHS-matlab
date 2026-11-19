function a = analyze(m, opts)
%ANALYZE 模型稳态/守恒律/稳定性/量纲分析（DESIGN §5.3 / §4.4 model.analyze）。
%   a = bma.model.analyze(m)
%   a = bma.model.analyze(spec)
%   a = bma.model.analyze(m, opts)     % opts.run_dir / opts.work_dir / opts.multistart
%
% 返回 a（保证 jsonencode(a) 成功，可安全回传 RPC）：
%   .conservation_laws   cellstr，每条守恒律的人类可读表达式（如 "E + ES = 1"）
%   .conservation_law_details  cell of struct {index, expression, relation, constant,
%                         coefficients(struct id→系数), basis(1×nS), kind, verified}
%   .conservation_basis  nSpecies×k 数值基（Z'*S=0）
%   .n_conservation_laws
%   .steady_states       struct array {values(struct id→浓度), y(nS×1), stability,
%                         max_real_eig, eigenvalues_re, eigenvalues_im,
%                         eigenvalue_text(cellstr), method, residual}
%   .steady_state_count
%   .jacobian            在第一个稳态（无稳态时在初值）处的数值 Jacobian
%   .jacobian_at         'steady_state' | 'initial'
%   .dimensional_ok     量纲检查是否通过
%   .units               量纲检查摘要 {ok,dimensional_ok,n_errors,n_warnings,issues}
%   .equations           ODE 文本（cellstr）
%   .symbolic            符号求解状态 {mode,attempted,skipped,reason,complexity,
%                        max_states,max_score,elapsed_ms}
%   .symbolic_skipped    true 表示已跳过符号稳态、改用数值多起点/数值 Jacobian
%   .analysis_mode       'symbolic+numeric' | 'numeric_fallback'
%   .numeric             数值多起点预算 {budget_seconds,stopped_early}
%   .warnings/.notes     中文警告/说明（cellstr）
%   .analysis_path       给出 opts.run_dir 时写入 models/<name>/analysis.json
%
% 稳态求解策略：默认只在状态数 ≤ symbolic_max_states（默认 6）且静态符号
% 复杂度 ≤ symbolic_max_score（默认 12）时尝试 solve/vpasolve；否则跳过符号
% 求解，直接用多起点 fsolve/lsqnonlin（受 numeric_budget_seconds 限制）与
% 数值 Jacobian。可用 opts.symbolic = 'auto'|'on'|'off' 显式控制。
if nargin < 2 || isempty(opts)
    opts = struct();
end
t0 = tic;
if ischar(m) || isstring(m)
    m = bma.model.build(char(m));
end
if isstruct(m) && isfield(m, 'kind') && strcmpi(char(m.kind), 'dde')
    error('bma:dde:analysisUnsupported', ...
        'DDE 模型暂不支持 bma.model.analyze（守恒律/稳态/Jacobian 需要无延迟状态方程）；请用 bma_model_simulate 做前向仿真。');
end
if isstruct(m) && isfield(m, 'kind') && strcmpi(char(m.kind), 'bvp')
    error('bma:bvp:analysisUnsupported', ...
        'BVP 模型暂不支持 bma.model.analyze（边值问题不是 IVP 稳态分析）；请用 bma_model_simulate 得到空间剖面。');
end
if isstruct(m) && isfield(m, 'kind') && strcmpi(char(m.kind), 'dae')
    error('bma:dae:analysisUnsupported', ...
        'DAE 模型暂不支持 bma.model.analyze（需一致初值与隐式状态方程）；请用 bma_model_simulate 做前向仿真。');
end
if ~isstruct(m) || ~isfield(m, 'rhs')
    if isstruct(m) && isfield(m, 'schema_version') && isfield(m, 'variables')
        m = bma.model.build(m);
    else
        error('bma:model:model_invalid', 'bma.model.analyze 需要模型结构或模型规格');
    end
end
if isfield(m, 'kind') && strcmpi(char(m.kind), 'dde')
    error('bma:dde:analysisUnsupported', ...
        'DDE 模型暂不支持 bma.model.analyze（守恒律/稳态/Jacobian 需要无延迟状态方程）；请用 bma_model_simulate 做前向仿真。');
end
if isfield(m, 'kind') && strcmpi(char(m.kind), 'bvp')
    error('bma:bvp:analysisUnsupported', ...
        'BVP 模型暂不支持 bma.model.analyze（边值问题不是 IVP 稳态分析）；请用 bma_model_simulate 得到空间剖面。');
end
if ~isfield(opts, 'multistart') || isempty(opts.multistart)
    opts.multistart = 12;
end
warnings = {};
notes = {};
nS = m.n_species;
nR = m.n_reactions;
y0 = m.initial;
p = m.paramValues;

% =========================================================================
% 1. 守恒律（S 左零空间，有理基）
% =========================================================================
Z = zeros(nS, 0);
Zsym = [];
consMethod = 'numeric';
try
    [Z, consMethod, Zsym] = bma.model.leftNullspace(m.S);
catch err
    warnings{end+1} = ['守恒律计算失败：' err.message];
    Z = zeros(nS, 0);
end
nLaws = size(Z, 2);
lawDetails = cell(1, nLaws);
lawTexts = cell(1, nLaws);
for k = 1:nLaws
    lawDetails{k} = formatConservationLaw(Z(:, k), k, m.species, y0, m.S); %#ok<AGROW>
    lawTexts{k} = lawDetails{k}.relation; %#ok<AGROW>
end

% =========================================================================
% 2. 稳态
% =========================================================================
[solMat, solMethods, solResiduals, ssStats, ssWarnings, ssNotes] = ...
    steadyStates(m, opts);
warnings = [warnings, ssWarnings]; %#ok<AGROW>
notes = [notes, ssNotes]; %#ok<AGROW>
nSS = size(solMat, 2);

% =========================================================================
% 3. Jacobian 特征值与稳定性
% =========================================================================
% 用 cell 数组保存稳态（保证 Windows/RPC 序列化后始终是 JSON 数组，即使只有 1 个）
states = {};
stabilityLines = {};
oscillation = false;
jacobian = [];
jacobianAt = 'initial';
for k = 1:nSS
    y = solMat(:, k);
    s = struct('values', struct(), 'y', y, 'stability', '', ...
        'max_real_eig', NaN, 'eigenvalues_re', [], 'eigenvalues_im', [], ...
        'eigenvalue_text', {{}}, 'method', '', 'residual', NaN);
    s.values = vectorToStruct(y, m.species);
    s.method = solMethods{k};
    s.residual = solResiduals(k);
    try
        J = numericJacobian(@(yy) m.rhs(0, yy, p), y);
        lam = eig(J);
        lam = lam(isfinite(lam));
        s.max_real_eig = max(real(lam));
        s.eigenvalues_re = real(lam).';
        s.eigenvalues_im = imag(lam).';
        s.eigenvalue_text = formatEigenText(lam);
        tol = 1e-8 * (1 + norm(J, 1));
        if s.max_real_eig < -tol
            s.stability = 'stable';
        elseif s.max_real_eig > tol
            s.stability = 'unstable';
        else
            s.stability = 'marginal';
        end
        if any(abs(imag(lam)) > 1e-8)
            oscillation = true;
        end
        if k == 1
            jacobian = J;
            jacobianAt = 'steady_state';
        end
    catch err
        s.max_real_eig = NaN;
        s.eigenvalues_re = [];
        s.eigenvalues_im = [];
        s.eigenvalue_text = {};
        s.stability = 'unknown';
        s.residual = NaN;
        warnings{end+1} = sprintf('第 %d 个稳态的 Jacobian/特征值计算失败：%s', k, err.message); %#ok<AGROW>
    end
    states{k} = s; %#ok<AGROW>
    stabilityLines{end+1} = stableLineText(k, s, m); %#ok<AGROW>
end
if nSS == 0
    % 没有稳态时在初值处给 Jacobian，便于判断局部趋势
    try
        jacobian = numericJacobian(@(yy) m.rhs(0, yy, p), y0);
        jacobianAt = 'initial';
    catch
        jacobian = [];
    end
end
if ~isempty(jacobian)
    jacobian = sanitizeMatrix(jacobian);
end

% =========================================================================
% 4. 量纲检查
% =========================================================================
unitsInfo = struct('ok', false, 'dimensional_ok', false, 'n_errors', 0, ...
    'n_warnings', 0, 'issues', {{}});
dimensionalOk = false;
try
    uc = bma.spec.checkUnits(m.spec);
    unitsInfo = struct('ok', uc.ok, 'dimensional_ok', uc.dimensional_ok, ...
        'n_errors', uc.n_errors, 'n_warnings', uc.n_warnings, 'issues', {uc.issues});
    dimensionalOk = uc.dimensional_ok;
    if ~dimensionalOk
        notes{end+1} = sprintf('量纲检查发现 %d 个错误、%d 个警告，详见 a.units.issues。', ...
            uc.n_errors, uc.n_warnings);
    else
        notes{end+1} = '量纲检查通过：所有单位可解析，反应通量与状态变化率量纲一致。';
    end
catch err
    warnings{end+1} = ['量纲检查执行失败：' err.message];
end

% =========================================================================
% 5. 说明文字
% =========================================================================
if nLaws > 0
    notes{end+1} = sprintf('检测到 %d 个独立守恒律：%s', nLaws, strjoin(lawTexts, '；'));
    notes{end+1} = '存在守恒律时稳态可能是连续族（非孤立点），数值方法给出的是其中的代表点。';
else
    notes{end+1} = '未检测到线性守恒律（化学计量矩阵列满秩于物种空间）。';
end
if nSS > 0
    notes{end+1} = sprintf('稳态搜索找到 %d 个非负物理稳态（方法：%s）。', ...
        nSS, strjoin(unique(solMethods), ' / '));
    if oscillation
        notes{end+1} = '稳态附近存在复特征值，系统具有振荡模态。';
    end
    unstable = false;
    marginal = false;
    for k = 1:nSS
        if strcmp(states{k}.stability, 'unstable')
            unstable = true;
        end
        if strcmp(states{k}.stability, 'marginal')
            marginal = true;
        end
    end
    if marginal && nLaws > 0
        notes{end+1} = ['部分稳态为临界稳定（Jacobian 存在零特征值），这是守恒系统' ...
            '（守恒律导致中性方向）的正常现象。'];
    end
    if unstable && oscillation
        notes{end+1} = '存在正实部复特征值对，可能发生 Hopf 分岔/持续振荡。';
    end
else
    notes{end+1} = '未找到非负物理稳态：模型可能无稳态、稳态为非实数，或数值搜索未收敛。';
end
if isempty(jacobian)
    notes{end+1} = '未能计算 Jacobian（模型函数在考察点不可微或计算失败）。';
end

% =========================================================================
% 6. 组装（保证 JSON 可编码）
% =========================================================================
a = struct();
a.schema_version = 'bma.analysis.v1';
a.model_name = m.name;
a.title = m.title;
a.n_species = nS;
a.n_reactions = nR;
a.species = m.species;
a.params = m.params;
a.equations = m.odeText;
a.conservation_laws = lawTexts;
a.conservation_law_details = lawDetails;
a.conservation_basis = sanitizeMatrix(Z);
a.n_conservation_laws = nLaws;
a.conservation_method = consMethod;
a.steady_states = states;
if isfield(ssStats, 'guard_substitution')
    a.guard_substitution = ssStats.guard_substitution;
else
    a.guard_substitution = struct('requested', false, 'attempted', false, 'stripped', {{}});
end
a.steady_state_count = nSS;
a.steady_state_physical_count = nSS;
if isstruct(ssStats) && isfield(ssStats, 'total_found')
    a.steady_state_total_found = ssStats.total_found;
else
    a.steady_state_total_found = nSS;
end
a.steady_state_methods = ssStats.methods;
if isfield(ssStats, 'symbolic')
    a.symbolic = ssStats.symbolic;
else
    a.symbolic = struct('mode', 'auto', 'attempted', false, 'skipped', false, ...
        'reason', '', 'complexity', struct(), 'max_states', 6, ...
        'max_score', 12, 'elapsed_ms', 0);
end
a.symbolic_skipped = logical(a.symbolic.skipped);
a.symbolic_reason = a.symbolic.reason;
if isfield(ssStats, 'numeric')
    a.numeric = ssStats.numeric;
end
a.analysis_mode = 'symbolic+numeric';
if a.symbolic_skipped
    a.analysis_mode = 'numeric_fallback';
end
a.stability_summary = stabilityLines;
a.jacobian = jacobian;
a.jacobian_at = jacobianAt;
a.dimensional_ok = dimensionalOk;
a.units = unitsInfo;
a.warnings = reshape(warnings, 1, []);
a.notes = reshape(notes, 1, []);
a.analyzed_at = bma.util.nowIso();
a.elapsed_ms = round(toc(t0) * 1000);

% =========================================================================
% 7. 可选：写 analysis.json
% =========================================================================
if isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    try
        modelDir = fullfile(char(opts.run_dir), 'models', m.name);
        bma.util.ensureDir(modelDir);
        outPath = fullfile(modelDir, 'analysis.json');
        a.analysis_path = outPath;
        bma.util.writeJsonAtomic(outPath, a);
        if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
            a.analysis_rel = bma.util.relPath(char(opts.work_dir), outPath);
        end
    catch err
        a.warnings{end+1} = ['写 analysis.json 失败：' err.message];
    end
end
end

% =========================================================================
function law = formatConservationLaw(z, index, species, y0, S)
% 将（已归一化为最简整数的）左零空间基向量格式化为守恒量表达式。
% 例：z=[1;0;1] → "E + ES = 1"；z=[0;1;1;1] → "S + ES + P = 10"。
z = z(:);
nS = numel(z);
expr = '';
for i = 1:nS
    if z(i) == 0
        continue
    end
    a = abs(z(i));
    if a == 1
        term = species{i};
    else
        term = sprintf('%d*%s', a, species{i});
    end
    if isempty(expr)
        if z(i) < 0
            expr = ['-' term];
        else
            expr = term;
        end
    elseif z(i) < 0
        expr = [expr ' - ' term]; %#ok<AGROW>
    else
        expr = [expr ' + ' term]; %#ok<AGROW>
    end
end
if isempty(expr)
    expr = '0';
end
constant = z.' * y0(:);
law = struct();
law.index = index;
law.expression = expr;
law.relation = sprintf('%s = %s', expr, formatNumberLocal(constant));
law.constant = constant;
coefStruct = struct();
for i = 1:nS
    if z(i) ~= 0
        coefStruct.(species{i}) = z(i);
    end
end
law.coefficients = coefStruct;
law.basis = z.';
law.kind = 'linear_invariant';
if all(z >= 0)
    law.kind = 'conserved_pool';
end
law.verified = norm(z.' * S) <= 1e-9 * max(1, norm(S, 'fro'));
end

function txt = formatEigenText(lam)
n = numel(lam);
txt = cell(1, n);
for k = 1:n
    re = real(lam(k));
    im = imag(lam(k));
    if abs(im) < 1e-10 * max(1, abs(re))
        txt{k} = sprintf('%.4g', re);
    else
        txt{k} = sprintf('%.4g%+.4gi', re, im);
    end
end
end

function line = stableLineText(k, s, m)
% 稳态的简要中文描述
switch s.stability
    case 'stable'
        st = '稳定';
    case 'unstable'
        st = '不稳定';
    case 'marginal'
        st = '临界稳定';
    otherwise
        st = '未知';
end
vals = {};
ids = m.species;
for i = 1:numel(ids)
    if isfield(s.values, ids{i})
        vals{end+1} = sprintf('%s=%s', ids{i}, formatNumberLocal(s.values.(ids{i}))); %#ok<AGROW>
    end
end
if isfield(s, 'max_real_eig') && isfinite(s.max_real_eig)
    line = sprintf('稳态 %d：%s（%s，λmax=%.4g）', k, strjoin(vals, ', '), st, s.max_real_eig);
else
    line = sprintf('稳态 %d：%s（%s）', k, strjoin(vals, ', '), st);
end
end

function M = sanitizeMatrix(M)
if isnumeric(M)
    M(~isfinite(M)) = 0;
end
end

function s = vectorToStruct(v, ids)
s = struct();
for k = 1:numel(ids)
    if ~isempty(ids{k})
        s.(ids{k}) = v(k);
    end
end
end

function J = numericJacobian(fun, x)
n = numel(x);
J = zeros(n, n);
h = 1e-6 * max(1, abs(x(:)));
for j = 1:n
    xp = x; xp(j) = xp(j) + h(j);
    xm = x; xm(j) = xm(j) - h(j);
    J(:, j) = (fun(xp) - fun(xm)) / (2 * h(j));
end
end

function s = formatNumberLocal(v)
if ~isnumeric(v) || ~isscalar(v) || ~isfinite(v)
    s = 'NaN';
    return
end
if v == 0
    s = '0';
elseif v == round(v) && abs(v) < 1e15
    s = sprintf('%.0f', v);
else
    s = sprintf('%.6g', v);
end
end
