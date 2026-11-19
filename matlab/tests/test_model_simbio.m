% test_model_simbio.m — bma.simbiology.export 导出等价 SimBiology 模型（DESIGN §4.4）
% 若 SimBiology 未安装/未授权，或运行环境（文件沙箱）禁止 SimBiology 写
% %LOCALAPPDATA%\MathWorks\SimBiology 而导致 .sbproj 保存失败，则明确打印限制并跳过
% 保存/等价性断言（不算失败）；模型构建阶段（动力学律）仍会被断言。
here = fileparts(mfilename('fullpath'));
if isempty(here)
    root = pwd;
else
    root = fileparts(fileparts(here));
end
assert(isfolder(fullfile(root, 'spec', 'examples')), '无法定位项目根目录');
addpath(fullfile(root, 'matlab'));
tmp = fullfile(root, '.bma', 'test_tmp', 'model_simbio');
if isfolder(tmp)
    rmdir(tmp, 's');
end

if exist('sbiomodel', 'file') ~= 2 || isempty(ver('simbio'))
    fprintf('[test_model_simbio] 跳过：SimBiology 工具箱不可用\n');
    return
end

% =====================================================================
% 1. enzyme_mm：导出成功、.sbproj 存在、等价性验证通过
% =====================================================================
specE = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
rE = bma.simbiology.export(specE, tmp, struct('verify', true));
assert(isstruct(rE) && isfield(rE, 'ok'), 'export 必须返回结构体');
% 模型构建阶段（不依赖 .sbproj 保存）应成功：每个反应都有动力学律说明
assert(numel(rE.kinetics) == rE.n_reactions, ...
    sprintf('SimBiology 模型构建阶段应完成（kinetics 数量 %d/%d）：%s', ...
    numel(rE.kinetics), rE.n_reactions, rE.reason));
for k = 1:numel(rE.kinetics)
    assert(ischar(rE.kinetics{k}) && ~isempty(rE.kinetics{k}), 'kinetics 条目应为非空字符串');
end
envBlocked = ~rE.ok && (contains(rE.reason, 'LOCALAPPDATA') || ...
    contains(rE.reason, '拒绝访问') || contains(rE.reason, 'MKDIR'));
if envBlocked
    fprintf(['[test_model_simbio] 环境限制：SimBiology 的 .sbproj 保存被文件沙箱拒绝\n' ...
        '  （SimBiology 固定写 %%LOCALAPPDATA%%\\MathWorks\\SimBiology）。\n' ...
        '  已确认：模型构建（隔室/物种/参数/自定义动力学律）全部成功。\n' ...
        '  跳过保存与等价性断言；在正常桌面 MATLAB 环境下应可生成 .sbproj。\n']);
    fprintf('[test_model_simbio] 限制详情：%s\n', rE.reason);
    % 受限环境下的回退产物：MAT 模型快照 + 一键导出脚本
    assert(isfield(rE, 'fallback_mat_path') && isfile(rE.fallback_mat_path), ...
        '保存失败时应生成模型 MAT 快照回退产物');
    assert(isfield(rE, 'fallback_script_path') && isfile(rE.fallback_script_path), ...
        '保存失败时应生成 export_simbio.m 一键导出脚本');
    scriptTxt = bma.util.readText(rE.fallback_script_path);
    assert(contains(scriptTxt, 'sbiosaveproject'), '回退脚本应调用 sbiosaveproject');
    return
end
assert(rE.ok, sprintf('enzyme_mm SimBiology 导出失败：%s | warnings=%s', ...
    rE.reason, strjoin(rE.warnings, ' | ')));
assert(isfile(rE.sbproj_path), sprintf('.sbproj 未生成：%s', rE.sbproj_path));
info = dir(rE.sbproj_path);
assert(info.bytes > 0, '.sbproj 文件为空');
assert(~isempty(rE.model_name), 'model_name 不应为空');
% sbproj 回读校验：物种/反应数量与规格一致
assert(isfield(rE, 'readback') && rE.readback.checked, '应执行 .sbproj 回读校验');
assert(rE.readback.ok, sprintf('sbproj 回读校验失败：%s', rE.readback.note));
assert(rE.readback.n_reactions == rE.n_reactions, '回读反应数量不一致');
assert(rE.readback.n_species >= rE.n_species, '回读物种数量不一致');
% 等价性验证
assert(isfield(rE, 'equivalence') && rE.equivalence.checked, ...
    sprintf('等价性验证应执行：%s', rE.equivalence.note));
assert(isfinite(rE.equivalence.max_rel_diff), '等价性相对偏差应有限');
assert(rE.equivalence.max_rel_diff < 1e-3, ...
    sprintf('SimBiology 与 bma 仿真终值偏差过大：%.2e', rE.equivalence.max_rel_diff));
assert(~isempty(rE.equivalence.method), '等价性验证应记录 method（full-units / unitless-clone）');
assert(~isempty(jsonencode(rE)), 'export 结果必须可 jsonencode');

% =====================================================================
% 2. goodwin / sir：都能导出（Hill 律与表达式速率走自定义动力学律）
% =====================================================================
for modelName = {'goodwin', 'sir'}
    specX = bma.spec.load(fullfile(root, 'spec', 'examples', [modelName{1} '.json']));
    rX = bma.simbiology.export(specX, tmp, struct('verify', false));
    assert(rX.ok, sprintf('%s SimBiology 导出失败：%s | warnings=%s', ...
        modelName{1}, rX.reason, strjoin(rX.warnings, ' | ')));
    assert(isfile(rX.sbproj_path), sprintf('%s 的 .sbproj 未生成', modelName{1}));
    assert(~isempty(jsonencode(rX)), 'export 结果必须可 jsonencode');
end

% =====================================================================
% 3. 覆盖已有 .sbproj（第二次导出不应报错）
% =====================================================================
rE2 = bma.simbiology.export(specE, tmp, struct('verify', false));
assert(rE2.ok, '重复导出应成功（覆盖）');

% =====================================================================
% 4. 无效规格：返回 ok=false + reason，绝不抛异常
% =====================================================================
bad = specE;
bad.parameters(1).unit = '';
threw = false;
rBad = [];
try
    rBad = bma.simbiology.export(bad, tmp, struct('verify', false));
catch err
    threw = true;
    reason = err.message; %#ok<NASGU>
end
assert(~threw, 'simbiology.export 对无效规格不应抛异常');
assert(isstruct(rBad) && ~rBad.ok, '无效规格应返回 ok=false');
assert(~isempty(rBad.reason), 'ok=false 时应给出 reason');

fprintf('[test_model_simbio] 全部通过（3 个示例导出 + 等价性 + 容错）\n');
