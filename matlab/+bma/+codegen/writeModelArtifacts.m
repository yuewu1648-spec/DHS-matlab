function info = writeModelArtifacts(m, runDir, report)
%WRITEMODELARTIFACTS 按 DESIGN §7 写出模型产物（规格/归一化/校验/独立代码/模型卡）。
%   info = bma.codegen.writeModelArtifacts(m, runDir)
%   info = bma.codegen.writeModelArtifacts(m, runDir, report)
%
% m       : bma.model.build 返回的模型结构
% runDir  : 运行目录（绝对路径）
% report  : 可选，bma.spec.validate 的返回，若给出则额外写 validation.json
%
% 写出：
%   <runDir>/models/<name>/spec.json
%   <runDir>/models/<name>/normalized.json
%   <runDir>/models/<name>/validation.json      （report 给出时）
%   <runDir>/models/<name>/code/<name>_ode.m
%   <runDir>/models/<name>/code/<name>_run.m
%   <runDir>/models/<name>/model_card.json
%
% info 返回上述文件的绝对路径（model_dir/code_dir/m_file/run_file/model_card_path 等），
% 以及 *_rel 相对 model_dir 的路径，供 RPC 返回。
if nargin < 2 || isempty(runDir)
    error('bma:model:model_invalid', 'bma.codegen.writeModelArtifacts 需要 runDir');
end
if ~isstruct(m) || ~isfield(m, 'rhs')
    error('bma:model:model_invalid', 'bma.codegen.writeModelArtifacts 需要 bma.model.build 返回的模型结构');
end
runDir = char(runDir);
modelDir = fullfile(runDir, 'models', m.name);
codeDir = fullfile(modelDir, 'code');
bma.util.ensureDir(codeDir);

% ---- 规格 ----
specPath = fullfile(modelDir, 'spec.json');
normPath = fullfile(modelDir, 'normalized.json');
bma.util.writeJsonAtomic(specPath, m.spec);
bma.util.writeJsonAtomic(normPath, m.spec);
validationPath = '';
if nargin >= 3 && isstruct(report) && ~isempty(report)
    validationPath = fullfile(modelDir, 'validation.json');
    bma.util.writeJsonAtomic(validationPath, report);
end

% ---- 独立可运行代码 ----
fname = m.name;
odeFile = fullfile(codeDir, [fname '_ode.m']);
runFile = fullfile(codeDir, [fname '_run.m']);
pdeFile = '';
pdeRel = '';
bma.util.writeTextAtomic(odeFile, buildOdeFileText(m));
bma.util.writeTextAtomic(runFile, buildRunFileText(m));
if isfield(m, 'pde')
    pdeFile = fullfile(codeDir, [fname '_pde.m']);
    pdeRel = ['code/' fname '_pde.m'];
    bma.util.writeTextAtomic(pdeFile, buildPdeFileText(m));
end

% ---- 模型卡 ----
card = bma.codegen.modelCard(m);
card.files = struct( ...
    'spec', 'spec.json', ...
    'normalized_spec', 'normalized.json', ...
    'ode_file', ['code/' fname '_ode.m'], ...
    'run_file', ['code/' fname '_run.m']);
if ~isempty(pdeFile)
    card.files.pde_file = pdeRel;
end
cardPath = fullfile(modelDir, 'model_card.json');
bma.util.writeJsonAtomic(cardPath, card);

info = struct();
info.model_dir = modelDir;
info.code_dir = codeDir;
info.spec_path = specPath;
info.normalized_spec_path = normPath;
info.validation_path = validationPath;
info.m_file = odeFile;
info.run_file = runFile;
info.pde_file = pdeFile;
info.model_card_path = cardPath;
info.function_name = [fname '_ode'];
info.run_function_name = [fname '_run'];
info.ode_file_rel = ['code/' fname '_ode.m'];
info.run_file_rel = ['code/' fname '_run.m'];
info.pde_file_rel = pdeRel;
info.model_card_rel = 'model_card.json';
end

% =========================================================================
% =========================================================================
function txt = buildPdeFileText(m)
fname = [m.name '_pde'];
p = m.pde;
lines = {};
lines{end+1} = ['function meta = ' fname '()'];
lines{end+1} = ['%' upper(fname) '  PDE/MOL 元数据（由 bma.codegen.model 生成）'];
lines{end+1} = '%';
lines{end+1} = '% 实际积分请使用同目录的 <name>_ode.m / <name>_run.m；';
lines{end+1} = '% 本文件只记录 PDE 几何、网格、边界与展开器版本，便于复现与引用。';
lines{end+1} = '%';
lines{end+1} = 'meta = struct();';
lines{end+1} = sprintf('meta.schema = %s;', q('bma.pde.meta.v1'));
lines{end+1} = sprintf('meta.geometry = %s;', q(char(getF(p, 'geometry', ''))));
lines{end+1} = sprintf('meta.dim = %d;', getF(p, 'dim', 1));
lines{end+1} = sprintf('meta.n = %d;', getF(p, 'n', 0));
lines{end+1} = sprintf('meta.dx = %.17g;', getF(p, 'dx', NaN));
lines{end+1} = sprintf('meta.time_unit = %s;', q(char(getF(p, 'time_unit', ''))));
lines{end+1} = sprintf('meta.approximation = %s;', q(char(getF(p, 'approximation', ''))));
lines{end+1} = sprintf('meta.expander_version = %s;', q(char(getF(p, 'expander_version', ''))));
lines{end+1} = sprintf('meta.expander_sha256 = %s;', q(char(getF(p, 'expander_sha256', ''))));
ext = getF(p, 'extent', struct());
lines{end+1} = sprintf('meta.extent = struct(''value'', %.17g, ''unit'', %s);', ...
    getF(ext, 'value', NaN), q(char(getF(ext, 'unit', ''))));
faces = getF(p, 'faces', struct());
for k = 1:2
    faceName = {'x0', 'x1'};
    f = getF(faces, faceName{k}, struct());
    lines{end+1} = sprintf('meta.faces.%s = struct(''face'', %s, ''type'', %s);', ...
        faceName{k}, q(faceName{k}), q(char(getF(f, 'type', '')))); %#ok<AGROW>
end
lines{end+1} = 'end';
txt = strjoin(lines, newline);
end

function s = q(txt)
s = ['''' strrep(char(txt), '''', '''''') ''''];
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end

function txt = buildOdeFileText(m)
fname = [m.name '_ode'];
nS = m.n_species;
lines = {};
lines{end+1} = ['function dydt = ' fname '(t, y, p)'];
lines{end+1} = ['%' upper(fname) '  ' m.title];
lines{end+1} = ['%' m.description];
lines{end+1} = '%';
lines{end+1} = '% 本文件由 BioModel-MATLAB（bma.codegen.model）自动生成，可独立运行，不依赖 +bma 包。';
lines{end+1} = '%';
lines{end+1} = '% 用法示例：';
lines{end+1} = '%   p  = [ ... ];     % 参数向量，顺序见下方“参数索引”';
lines{end+1} = '%   y0 = [ ... ];     % 初值向量，顺序见下方“状态变量索引”';
lines{end+1} = ['%   [t, Y] = ode15s(@(t,y) ' fname '(t, y, p), [0 60], y0);'];
lines{end+1} = ['%   或直接运行同目录的 ' m.name '_run.m 包装函数。'];
lines{end+1} = '%';
lines{end+1} = '% 状态变量索引（y）：';
for i = 1:nS
    lines{end+1} = sprintf('%%   y(%d) = %-8s %-10s [%s] 初值 = %s', ...
        i, m.species{i}, m.speciesNames{i}, m.speciesUnits{i}, ...
        fmt(m.speciesInitial(i))); %#ok<AGROW>
end
lines{end+1} = '%';
lines{end+1} = '% 参数向量索引（p）：';
for j = 1:m.n_params
    estTag = '固定';
    if m.paramEstimate(j)
        estTag = '估计';
    end
    lines{end+1} = sprintf('%%   p(%d) = %-8s %-10s [%s] 默认值 = %s（%s）', ...
        j, m.params{j}, m.paramNames{j}, m.paramUnits{j}, ...
        fmt(m.paramValues(j)), estTag); %#ok<AGROW>
end
lines{end+1} = '%';
lines{end+1} = '% 动态方程（d x_i/dt = Σ_r S_ir * v_r）：';
for i = 1:nS
    lines{end+1} = ['%   ' m.odeText{i}]; %#ok<AGROW>
end
lines{end+1} = '%';
lines{end+1} = '% 反应速率：';
for r = 1:m.n_reactions
    lines{end+1} = ['%   ' m.rateText{r}]; %#ok<AGROW>
end
if isfield(m, 'rate_functions') && ~isempty(m.rate_functions)
    lines{end+1} = '%';
    lines{end+1} = '% 外部速率函数（kind="matlab"）：运行前必须保持在 MATLAB 路径上';
    for k = 1:numel(m.rate_functions)
        rf = m.rate_functions{k};
        lines{end+1} = sprintf('%%   %s -> %s (unit=%s)', ...
            rf.reaction, getfield(rf, 'function'), rf.unit); %#ok<AGROW,SFLD>
    end
end
lines{end+1} = '%';
lines{end+1} = ['    dydt = zeros(' num2str(nS) ', 1);'];
for i = 1:nS
    terms = {};
    for r = 1:m.n_reactions
        c = m.S(i, r);
        if c == 0
            continue
        end
        flux = ['(' m.fluxCode{r} ')'];
        if abs(c) == 1
            coefStr = '';
        else
            coefStr = [fmt(abs(c)) '*'];
        end
        term = [coefStr flux];
        if isempty(terms)
            if c < 0
                terms{end+1} = ['-' term]; %#ok<AGROW>
            else
                terms{end+1} = term; %#ok<AGROW>
            end
        elseif c < 0
            terms{end+1} = [' - ' term]; %#ok<AGROW>
        else
            terms{end+1} = [' + ' term]; %#ok<AGROW>
        end
    end
    if isempty(terms)
        rhs = '0';
    else
        rhs = strjoin(terms, '');
    end
    lines{end+1} = ['    dydt(' num2str(i) ') = ' rhs ';']; %#ok<AGROW>
end
lines{end+1} = 'end';
txt = strjoin(lines, sprintf('\n'));
txt = [txt sprintf('\n')];
end

function txt = buildRunFileText(m)
fname = [m.name '_run'];
odeName = [m.name '_ode'];
nS = m.n_species;
lines = {};
lines{end+1} = ['function [t, Y, out] = ' fname '(p, tspan, y0, opts)'];
lines{end+1} = ['%' upper(fname) '  ' m.title '：仿真包装函数（自动生成）。'];
lines{end+1} = '%';
lines{end+1} = '% 输入：';
lines{end+1} = '%   p     : 参数向量（顺序见下方说明；缺省用默认值）';
lines{end+1} = '%   tspan : 时间范围 [t0 tEnd] 或时间向量（缺省用模型默认时间轴）';
lines{end+1} = '%   y0    : 初值向量（缺省用规格初值）';
lines{end+1} = '%   opts  : 结构体，支持 .solver/.rtol/.atol/.n';
lines{end+1} = '%';
lines{end+1} = '% 输出：';
lines{end+1} = '%   t     : 时间列向量';
lines{end+1} = '%   Y     : 时间 × 物种 的状态矩阵';
lines{end+1} = '%   out   : 观测量结构体（每个输出 id 一列）';
lines{end+1} = '%';
lines{end+1} = '% 示例：';
lines{end+1} = ['%   [t, Y, out] = ' fname '([], [], []);'];
lines{end+1} = '%';
lines{end+1} = '% 参数索引（p）：';
for j = 1:m.n_params
    lines{end+1} = sprintf('%%   p(%d) = %-8s %s [%s] 默认值 = %s', ...
        j, m.params{j}, m.paramNames{j}, m.paramUnits{j}, fmt(m.paramValues(j))); %#ok<AGROW>
end
lines{end+1} = '%';
lines{end+1} = '% 状态变量索引（y）：';
for i = 1:nS
    lines{end+1} = sprintf('%%   y(%d) = %-8s [%s] 初值 = %s', ...
        i, m.species{i}, m.speciesUnits{i}, fmt(m.speciesInitial(i))); %#ok<AGROW>
end
lines{end+1} = ['if nargin < 1 || isempty(p), p = [' vecText(m.paramValues) ']; end'];
lines{end+1} = ['if nargin < 2 || isempty(tspan), tspan = [' ...
    fmt(m.time.start) ' ' fmt(m.time.end) ']; end'];
lines{end+1} = ['if nargin < 3 || isempty(y0), y0 = [' vecText(m.speciesInitial) ']; end'];
lines{end+1} = 'if nargin < 4 || isempty(opts), opts = struct(); end';
lines{end+1} = 'solver = ''ode15s'';';
lines{end+1} = 'rtol = 1e-6;';
lines{end+1} = 'atol = 1e-9;';
lines{end+1} = ['n = ' num2str(m.time.n) ';'];
lines{end+1} = 'if isfield(opts, ''solver'') && ~isempty(opts.solver), solver = char(opts.solver); end';
lines{end+1} = 'if isfield(opts, ''rtol'') && ~isempty(opts.rtol), rtol = opts.rtol; end';
lines{end+1} = 'if isfield(opts, ''atol'') && ~isempty(opts.atol), atol = opts.atol; end';
lines{end+1} = 'if isfield(opts, ''n'') && ~isempty(opts.n), n = opts.n; end';
lines{end+1} = 'if numel(tspan) == 2';
lines{end+1} = '    tspan = linspace(tspan(1), tspan(2), n);';
lines{end+1} = 'end';
lines{end+1} = ['odefun = @(t, y) ' odeName '(t, y, p);'];
lines{end+1} = 'solOpts = odeset(''RelTol'', rtol, ''AbsTol'', atol);';
lines{end+1} = 'try';
lines{end+1} = '    [t, Y] = feval(solver, odefun, tspan, y0, solOpts);';
lines{end+1} = 'catch err';
lines{end+1} = '    if ~strcmp(solver, ''ode15s'')';
lines{end+1} = '        [t, Y] = ode15s(odefun, tspan, y0, solOpts);';
lines{end+1} = '    else';
lines{end+1} = '        rethrow(err);';
lines{end+1} = '    end';
lines{end+1} = 'end';
lines{end+1} = 'out = struct();';
lines{end+1} = 'out.time = t;';
for o = 1:m.n_outputs
    oid = m.outputs(o).id;
    code = m.outputs(o).code;
    lines{end+1} = ['out.' oid ' = zeros(numel(t), 1);']; %#ok<AGROW>
    lines{end+1} = 'for k = 1:numel(t)'; %#ok<AGROW>
    lines{end+1} = '    y = Y(k, :).'';'; %#ok<AGROW>
    lines{end+1} = ['    out.' oid '(k, 1) = ' code ';']; %#ok<AGROW>
    lines{end+1} = 'end'; %#ok<AGROW>
end
lines{end+1} = 'end';
txt = [strjoin(lines, sprintf('\n')) sprintf('\n')];
end

function s = fmt(v)
if ~isnumeric(v) || ~isscalar(v)
    s = '0';
    return
end
if v == 0
    s = '0';
elseif v == round(v) && abs(v) < 1e15
    s = sprintf('%.0f', v);
else
    s = sprintf('%.10g', v);
end
end

function s = vecText(v)
parts = cell(1, numel(v));
for k = 1:numel(v)
    parts{k} = fmt(v(k));
end
s = strjoin(parts, '; ');
end
