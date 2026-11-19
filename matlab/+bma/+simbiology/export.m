function r = export(spec, runDir, opts)
%EXPORT 用 SimBiology 构建与规格等价的模型并保存 .sbproj（DESIGN §4.4 simbiology.export）。
%   r = bma.simbiology.export(spec, runDir)
%   r = bma.simbiology.export(spec, runDir, opts)
%
% 该导出是“可选项”，不参与主流程：任何失败都返回 r.ok=false + **非空 r.reason**，不抛异常。
% r.diag 记录每一步诊断信息（保存/回读/等价性），便于 full-access 环境排障。
%
% 流程：
%   1) bma.simbiology.buildModel 构建 SimBiology 模型；
%   2) sbiosaveproject 保存 .sbproj（R2024a 签名：filename + 调用者工作区变量名）；
%   3) sbioloadproject 回读校验物种/反应/隔室数量；
%   4) 等价性验证：sbiosimulate 与 bma.model.simulate 终值对比；
%      完整单位模型无法仿真时自动降级为无量纲克隆模型做数值等价验证。
%
% 失败时（任意阶段）都会尝试写出回退产物：
%   <modelDir>/<name>_simbio_model.mat   模型快照
%   <modelDir>/export_simbio.m           在桌面 MATLAB 中生成 .sbproj 的脚本
%   <modelDir>/simbio_export_diag.txt    诊断日志
%
% 返回 r（JSON 可编码）：
%   .ok .sbproj_path .model_name .n_species .n_parameters .n_reactions
%   .kinetics .readback .equivalence .warnings .reason .diag .elapsed_ms
%   保存失败时附 .fallback_mat_path / .fallback_script_path；给 opts.work_dir 附 .sbproj_rel
if nargin < 2
    runDir = '';
end
if nargin < 3 || isempty(opts)
    opts = struct();
end
t0 = tic;
r = emptyResult();
m = [];
sb = [];
modelDir = '';
sbprojPath = '';
try
    [r, m, sb, modelDir, sbprojPath] = doExport(r, spec, runDir, opts);
catch err
    % 兜底：任何未预期异常都转为结构化失败（reason 非空）
    r.ok = false;
    r.reason = buildFailReason(r, sprintf('导出过程异常：%s（%s）', err.message, err.identifier));
    r = addDiag(r, sprintf('UNEXPECTED_EXCEPTION %s :: %s', err.identifier, err.message));
    if isempty(r.sbproj_path)
        [r, ~] = writeFallbackArtifacts(r, m, sb, modelDir, sbprojPath);
    end
end
% ---- 失败时保证 reason 非空 + 回退产物 ----
if ~r.ok
    if isempty(strtrim(r.reason))
        r.reason = buildFailReason(r, '未知原因（见 diag）');
    end
    if ~isfield(r, 'fallback_mat_path') && ~isempty(sb) && ~isempty(modelDir)
        [r, ~] = writeFallbackArtifacts(r, m, sb, modelDir, sbprojPath);
    end
end
cleanupModel(sb);
r.elapsed_ms = round(toc(t0) * 1000);
end

% =========================================================================
function [r, m, sb, modelDir, sbprojPath] = doExport(r, spec, runDir, opts)
% 主流程；失败时设置 r.ok/r.reason，但不抛异常（除未预期异常由外层兜底）
modelDir = '';
sbprojPath = '';
r = addDiag(r, 'start');
% ---- 可用性检查 ----
if exist('sbiomodel', 'file') ~= 2
    r.reason = 'SimBiology 工具箱不可用（未安装或未授权），跳过导出。';
    return
end
try
    if isempty(ver('simbio'))
        r.reason = '未检测到 SimBiology 工具箱，跳过导出。';
        return
    end
catch
end
% ---- 构建 bma 模型（同时完成规格校验）----
try
    if ischar(spec) || isstring(spec)
        spec = bma.spec.load(char(spec));
    end
    if ~isstruct(spec)
        error('bma:spec:spec_invalid', 'simbiology.export 需要模型规格或模型结构');
    end
    if isfield(spec, 'rhs')
        m = spec;
    else
        m = bma.model.build(spec);
    end
catch err
    r.reason = ['模型构建失败，无法导出 SimBiology：' err.message];
    return
end
r.model_name = m.name;
r.n_species = m.n_species;
r.n_parameters = m.n_params;
r.n_reactions = m.n_reactions;
r = addDiag(r, sprintf('bma_model ok: name=%s species=%d params=%d reactions=%d', ...
    m.name, m.n_species, m.n_params, m.n_reactions));
% ---- 构建 SimBiology 模型 ----
try
    [sb, kinetics, buildWarnings, buildDiag] = bma.simbiology.buildModel(m, opts);
    r.kinetics = kinetics;
    r.warnings = [r.warnings, buildWarnings];
    r.diag = [r.diag, buildDiag];
    r = addDiag(r, sprintf('simbiology_model ok: species=%d reactions=%d kinetics=%d warnings=%d', ...
        numel(sb.Species), numel(sb.Reactions), numel(kinetics), numel(buildWarnings)));
catch err
    r.ok = false;
    r.reason = buildFailReason(r, ['SimBiology 模型构建失败：' err.message]);
    r = addDiag(r, sprintf('BUILD_MODEL_FAIL %s :: %s', err.identifier, err.message));
    return
end
% ---- 保存路径 ----
if isempty(runDir) || (ischar(runDir) && isempty(strtrim(runDir))) || ...
        (isstring(runDir) && strlength(runDir) == 0)
    runDir = fullfile(bma.util.projectRoot(), '.bma', 'simbiology', m.name);
end
modelDir = fullfile(char(runDir), 'models', m.name);
sbprojPath = fullfile(modelDir, [m.name '.sbproj']);
r = addDiag(r, sprintf('paths: runDir=%s modelDir=%s sbproj=%s', ...
    char(runDir), modelDir, sbprojPath));
% ---- 保存 .sbproj ----
saved = false;
try
    bma.util.ensureDir(modelDir);
    % R2024a：sbiosaveproject(filename, varname) 的 varname 是调用者工作区变量名
    modelVarName = 'bma_sb_model';
    bma_sb_model = sb; %#ok<NASGU>
    lastwarn('');
    sbiosaveproject(sbprojPath, modelVarName);
    [~, saveWarn] = lastwarn;
    fileExists = isfile(sbprojPath);
    fileBytes = 0;
    if fileExists
        info = dir(sbprojPath);
        fileBytes = info.bytes;
    end
    r = addDiag(r, sprintf('save: exists=%d bytes=%d lastwarn=[%s]', ...
        fileExists, fileBytes, saveWarn));
    if ~fileExists
        error('bma:simbiology:save', 'sbiosaveproject 未生成文件：%s', sbprojPath);
    end
    if ~isempty(saveWarn)
        r.warnings{end+1} = ['sbiosaveproject 警告：' saveWarn];
    end
    r.sbproj_path = sbprojPath;
    r.ok = true;
    saved = true;
catch err
    r.ok = false;
    r.reason = buildFailReason(r, sprintf(['保存 .sbproj 失败：%s。' ...
        'SimBiology 保存需要可写的 %%LOCALAPPDATA%%\\MathWorks\\SimBiology 目录；' ...
        '若运行环境限制了该路径，请把 LOCALAPPDATA 指向工作区内的可写目录并重启 MATLAB 服务。'], ...
        err.message));
    r = addDiag(r, sprintf('SAVE_FAIL %s :: %s', err.identifier, err.message));
end
% ---- 回读校验 .sbproj ----
if saved
    try
        [readback, loadedModels, readbackDiag] = readBackProject(sbprojPath, m, modelVarName);
        r.readback = readback;
        r = addDiag(r, readbackDiag);
        cleanupModels(loadedModels);
        if ~readback.ok
            r.ok = false;
            r.reason = buildFailReason(r, ['sbproj 回读校验失败：' readback.note]);
        end
    catch err
        r.ok = false;
        r.readback = struct('checked', true, 'ok', false, 'n_species', 0, ...
            'n_reactions', 0, 'n_compartments', 0, 'missing_species', {{}}, ...
            'note', ['回读异常：' err.message]);
        r.reason = buildFailReason(r, r.readback.note);
        r = addDiag(r, sprintf('READBACK_EXCEPTION %s :: %s', err.identifier, err.message));
    end
end
% ---- 等价性验证（可选）----
verify = true;
if isfield(opts, 'verify') && ~isempty(opts.verify)
    verify = logical(opts.verify);
end
if saved && isfield(r, 'readback') && r.readback.ok && verify
    try
        [r.equivalence, eqDiag] = verifyEquivalence(m, sb);
        r = addDiag(r, eqDiag);
        if ~r.equivalence.checked
            r.warnings{end+1} = ['等价性验证未完成：' r.equivalence.note];
        end
    catch err
        r.equivalence = struct('checked', false, 'max_rel_diff', NaN, ...
            'note', ['等价性验证异常：' err.message], 'method', '', 'n_points', 0);
        r.warnings{end+1} = r.equivalence.note;
        r = addDiag(r, sprintf('EQUIV_EXCEPTION %s :: %s', err.identifier, err.message));
    end
end
% ---- 最终判定：ok 与 reason 一致；任何未通过步骤都写 reason ----
readbackOk = saved && isfield(r, 'readback') && r.readback.checked && r.readback.ok;
if ~saved
    r.ok = false;
    if isempty(strtrim(r.reason))
        r.reason = buildFailReason(r, '保存 .sbproj 未完成');
    end
elseif ~readbackOk
    r.ok = false;
    rbNote = '未执行（原因未知）';
    try
        rbNote = r.readback.note;
    catch
    end
    r.reason = buildFailReason(r, ['sbproj 回读校验未通过：' rbNote]);
else
    r.ok = true;
    r.sbproj_path = sbprojPath;
    if verify
        eqChecked = false;
        eqNote = '未执行（原因未知）';
        eqDiff = NaN;
        try
            eqChecked = r.equivalence.checked;
            eqNote = r.equivalence.note;
            eqDiff = r.equivalence.max_rel_diff;
        catch
        end
        if ~eqChecked
            r.ok = false;
            r.reason = buildFailReason(r, ['等价性验证未执行/未完成：' eqNote]);
        elseif ~isfinite(eqDiff) || eqDiff > 1e-3
            r.ok = false;
            r.reason = buildFailReason(r, sprintf( ...
                '等价性验证未通过：max_rel_diff=%.3e（阈值 1e-3），%s', eqDiff, eqNote));
        end
    end
end
% ---- 相对路径 ----
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir) && ~isempty(r.sbproj_path)
    try
        r.sbproj_rel = bma.util.relPath(char(opts.work_dir), r.sbproj_path);
    catch
    end
end
r = addDiag(r, sprintf('done ok=%d reason=[%s]', r.ok, r.reason));
end

% =========================================================================
function r = emptyResult()
r = struct();
r.ok = false;
r.sbproj_path = '';
r.model_name = '';
r.n_species = 0;
r.n_parameters = 0;
r.n_reactions = 0;
r.kinetics = {};
r.readback = struct('checked', false, 'ok', false, 'n_species', 0, ...
    'n_reactions', 0, 'n_compartments', 0, 'missing_species', {{}}, 'note', '');
r.equivalence = struct('checked', false, 'max_rel_diff', NaN, ...
    'note', '', 'method', '', 'n_points', 0);
r.warnings = {};
r.reason = '';
r.diag = {};
r.elapsed_ms = 0;
end

function r = addDiag(r, msg)
try
    r.diag{end+1} = char(msg);
catch
end
end

function reason = buildFailReason(r, prefix)
% 汇总 reason：前缀 + diag 尾部，保证非空且信息充足
reason = prefix;
try
    if isfield(r, 'diag') && ~isempty(r.diag)
        tail = r.diag(max(1, end - 4):end);
        reason = [prefix ' 诊断：' strjoin(tail, ' | ')];
    end
catch
end
if isempty(strtrim(reason))
    reason = 'SimBiology 导出失败（未知原因，请查看 r.diag）。';
end
end

function cleanupModel(sb)
try
    if ~isempty(sb) && isvalid(sb)
        delete(sb);
    end
catch
end
end

function cleanupModels(models)
try
    for k = 1:numel(models)
        if isvalid(models(k))
            delete(models(k));
        end
    end
catch
end
end

% =========================================================================
function [readback, loadedModels, diagMsg] = readBackProject(sbprojPath, m, modelVarName)
% 回读 .sbproj：用 sbioloadproject 打开并核对物种/反应/隔室数量
readback = struct('checked', true, 'ok', false, 'n_species', 0, ...
    'n_reactions', 0, 'n_compartments', 0, 'missing_species', {{}}, 'note', '');
loadedModels = [];
diagMsg = '';
try
    info = dir(sbprojPath);
    diagMsg = sprintf('readback: file exists=%d bytes=%d', isfile(sbprojPath), info(1).bytes);
catch
end
proj = sbioloadproject(sbprojPath);
if ~isstruct(proj)
    readback.note = 'sbproj 回读结果不是结构体。';
    diagMsg = [diagMsg ' | 回读返回非结构体'];
    return
end
vars = fieldnames(proj);
readback.project_variables = vars;
diagMsg = [diagMsg ' | project_vars=' strjoin(vars, ',')];
modelBack = [];
for k = 1:numel(vars)
    try
        if isa(proj.(vars{k}), 'SimBiology.Model')
            modelBack = proj.(vars{k});
            break
        end
    catch
    end
end
if isempty(modelBack)
    readback.note = ['sbproj 回读结果中找不到 SimBiology 模型（变量：' strjoin(vars, ',') '）。'];
    diagMsg = [diagMsg ' | 找不到模型变量'];
    return
end
loadedModels = modelBack;
readback.n_species = numel(modelBack.Species);
readback.n_reactions = numel(modelBack.Reactions);
readback.n_compartments = numel(modelBack.Compartments);
diagMsg = [diagMsg sprintf(' | back: species=%d reactions=%d compartments=%d', ...
    readback.n_species, readback.n_reactions, readback.n_compartments)];
speciesNames = {};
try
    spList = modelBack.Species;
    speciesNames = arrayfun(@(s) char(s.Name), spList, 'UniformOutput', false);
catch
end
missing = {};
for i = 1:m.n_species
    if ~any(strcmp(speciesNames, m.species{i}))
        missing{end+1} = m.species{i}; %#ok<AGROW>
    end
end
readback.missing_species = missing;
readback.ok = (readback.n_species >= m.n_species) && ...
    (readback.n_reactions == m.n_reactions) && isempty(missing);
if readback.ok
    readback.note = sprintf('回读成功：%d 物种 / %d 反应 / %d 隔室（模型变量 %s）。', ...
        readback.n_species, readback.n_reactions, readback.n_compartments, vars{1});
else
    readback.note = sprintf(['回读不一致：物种 %d（期望 >=%d，缺失 %s），反应 %d（期望 %d）。'], ...
        readback.n_species, m.n_species, strjoin(missing, ','), ...
        readback.n_reactions, m.n_reactions);
end
diagMsg = [diagMsg ' | readback_ok=' num2str(readback.ok)];
end

% =========================================================================
function [eq, diagMsg] = verifyEquivalence(m, sb)
% sbiosimulate ↔ bma.model.simulate 终值对比；必要时降级为无量纲克隆模型。
eq = struct('checked', false, 'max_rel_diff', NaN, 'note', '', ...
    'method', '', 'n_points', 0);
diagMsg = '';
[tS1, X1, names1, ok1, err1] = trySimulate(sb, m);
diagMsg = sprintf('sim(full-units): ok=%d err=[%s]', ok1, err1);
if ok1
    [eq.max_rel_diff, eq.n_points, cmpNote, cmpDiag] = compareFinal(m, tS1, X1, names1);
    eq.checked = isfinite(eq.max_rel_diff);
    eq.method = 'full-units';
    eq.note = cmpNote;
    diagMsg = [diagMsg ' | ' cmpDiag];
    return
end
% 降级：无量纲克隆模型（只用于数值等价性验证）
try
    sbU = bma.simbiology.buildModel(m, struct('noUnits', true));
catch err
    eq.note = sprintf('完整单位模型仿真失败（%s）；无量纲克隆构建失败（%s）。', ...
        err1, err.message);
    diagMsg = [diagMsg ' | unitless build fail: ' err.message];
    return
end
try
    [tS2, X2, names2, ok2, err2] = trySimulate(sbU, m);
catch err
    [tS2, X2, names2, ok2, err2] = deal([], [], {}, false, err.message);
end
finallyDelete(sbU);
diagMsg = [diagMsg sprintf(' | sim(unitless): ok=%d err=[%s]', ok2, err2)];
if ~ok2
    eq.note = sprintf('完整单位模型与无量纲克隆模型仿真均失败：%s | %s', err1, err2);
    return
end
[eq.max_rel_diff, eq.n_points, cmpNote, cmpDiag] = compareFinal(m, tS2, X2, names2);
eq.checked = isfinite(eq.max_rel_diff);
eq.method = 'unitless-clone';
eq.note = sprintf(['完整单位模型在 SimBiology 中无法仿真（%s），' ...
    '已用无量纲克隆模型验证数值等价；保存的 .sbproj 仍保留完整单位。%s'], err1, cmpNote);
diagMsg = [diagMsg ' | ' cmpDiag];
end

function finallyDelete(obj)
try
    delete(obj);
catch
end
end

function [tS, X, names, ok, errMsg] = trySimulate(sb, m)
tS = [];
X = [];
names = {};
ok = false;
errMsg = '';
try
    cs = getconfigset(sb, 'active');
    try
        cs.StopTime = m.time.end;
    catch
    end
    try
        tu = mapTimeUnitLocal(m.timeUnit);
        if ~isempty(tu)
            cs.TimeUnits = tu;
        end
    catch
    end
    try
        [tS, X, names] = sbiosimulate(sb, cs);
    catch
        [tS, X, names] = sbiosimulate(sb);
    end
    ok = ~isempty(tS) && ~isempty(X);
    if ~ok
        errMsg = '仿真未返回数据';
    end
catch err
    ok = false;
    errMsg = err.message;
end
end

function [maxRel, nPoints, note, diagMsg] = compareFinal(m, tS, X, names)
maxRel = NaN;
nPoints = numel(tS);
note = '';
diagMsg = sprintf('compare: n_points=%d', nPoints);
try
    names = cellfun(@char, names, 'UniformOutput', false);
catch
end
try
    if numel(tS) >= 2
        res = bma.model.simulate(m, struct('tspan', tS(:), 'solver', 'ode15s', ...
            'write_csv', false, 'n', numel(tS)));
    else
        res = bma.model.simulate(m, struct('write_csv', false, 'n', 101));
    end
catch err
    note = ['bma.model.simulate 等价性对比仿真异常：' err.message];
    diagMsg = [diagMsg ' bma_sim_exception=' err.message];
    return
end
if ~res.success
    note = 'bma.model.simulate 等价性对比仿真失败。';
    return
end
finalB = res.Y(end, :);
finalS = nan(1, m.n_species);
for i = 1:m.n_species
    idx = find(strcmp(names, m.species{i}), 1);
    if ~isempty(idx) && idx <= size(X, 2)
        finalS(i) = X(end, idx);
    end
end
if any(~isfinite(finalS))
    note = 'SimBiology 输出缺少部分物种，无法比较。';
    diagMsg = [diagMsg ' missing_sim_species'];
    return
end
scale = max(1, max(abs(finalB)));
maxRel = max(abs(finalB - finalS)) / scale;
note = sprintf('终值比较：bma=[%s]，SimBiology=[%s]。', ...
    num2str(finalB, '%.4g '), num2str(finalS, '%.4g '));
diagMsg = [diagMsg sprintf(' max_rel_diff=%.3e', maxRel)];
end

% =========================================================================
function [r, modelDir] = writeFallbackArtifacts(r, m, sb, modelDir, sbprojPath)
% 失败时的回退产物：模型 MAT 快照 + 一键导出脚本 + 诊断日志
warnMsg = {};
try
    if isempty(modelDir)
        modelDir = fullfile(bma.util.projectRoot(), '.bma', 'simbiology', ...
            char(string(getfieldOrDefault(m, 'name', 'model'))));
    end
    bma.util.ensureDir(modelDir);
catch err
    r.reason = [r.reason '（回退产物目录创建失败：' err.message '）'];
    return
end
try
    matPath = fullfile(modelDir, [char(getfieldOrDefault(m, 'name', 'model')) '_simbio_model.mat']);
    sbSnapshot = sb; %#ok<NASGU>
    if ~isempty(sb)
        save(matPath, 'sbSnapshot');
        if isfile(matPath)
            r.fallback_mat_path = matPath;
        end
    end
    scriptPath = fullfile(modelDir, 'export_simbio.m');
    bma.util.writeTextAtomic(scriptPath, buildFallbackScript(m));
    if isfile(scriptPath)
        r.fallback_script_path = scriptPath;
    end
    diagPath = fullfile(modelDir, 'simbio_export_diag.txt');
    txt = strjoin(r.diag, sprintf('\n'));
    bma.util.writeTextAtomic(diagPath, [txt sprintf('\n')]);
    r.fallback_diag_path = diagPath;
catch err
    warnMsg{end+1} = ['回退产物写入失败：' err.message];
end
if ~isempty(warnMsg)
    try
        r.warnings = [r.warnings, warnMsg];
    catch
    end
end
end

function v = getfieldOrDefault(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end

function txt = buildFallbackScript(m)
name = char(getfieldOrDefault(m, 'name', 'model'));
matName = [name '_simbio_model.mat'];
lines = {};
lines{end+1} = 'function export_simbio()';
lines{end+1} = ['%EXPORT_SIMBIOLOGY 从 MAT 快照生成 SimBiology 工程文件（' name '）。'];
lines{end+1} = '%';
lines{end+1} = '% 背景：计算服务可能运行在文件沙箱中，SimBiology 固定写';
lines{end+1} = '% %LOCALAPPDATA%\MathWorks\SimBiology，导致 sbiosaveproject 失败。';
lines{end+1} = '% 在普通桌面 MATLAB 中运行本脚本即可生成等价 .sbproj。';
lines{end+1} = '';
lines{end+1} = 'here = fileparts(mfilename(''fullpath''));';
lines{end+1} = ['matFile = fullfile(here, ''' matName ''');'];
lines{end+1} = 'S = load(matFile);';
lines{end+1} = 'sb = S.sbSnapshot;';
lines{end+1} = ['outFile = fullfile(here, ''' name '.sbproj'');'];
lines{end+1} = 'sbiosaveproject(outFile, ''sb'');';
lines{end+1} = 'fprintf(''已生成 SimBiology 工程文件：%s\n'', outFile);';
lines{end+1} = 'end';
txt = [strjoin(lines, sprintf('\n')) sprintf('\n')];
end

function tu = mapTimeUnitLocal(unit)
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
