function r = waiveGate(workDir, runDir, gate, reason, substitute, evidence)
%WAIVEGATE 显式记录一个质量门的豁免（issue 0.5.0 / I7）。
%   r = bma.run.waiveGate(workDir, runDir, gate, reason)
%   r = bma.run.waiveGate(workDir, runDir, gate, reason, substitute, evidence)
%
% 质量门（G0…G9）在计算上不可行时，不能静默跳过，也不能无限等待：
% 调用本函数把 gate/reason/substitute/evidence 写入 <run_dir>/gates.json，
% 报告与 model card 会渲染“质量门与豁免”一节。替代结果应同时由
% bma_model_analyze 的 numeric_fallback 等字段提供。
%
% 返回 {waived, gate, reason, substitute, count, gates_path, run_dir,
%       duplicate, recorded_at}；路径相对 workDir。
if nargin < 6 || isempty(evidence)
    evidence = struct();
end
workDir = char(workDir);
runDir = char(runDir);
if ~isfolder(runDir)
    error('bma:run:notFound', '运行目录不存在：%s', runDir);
end
gate = strtrim(char(gate));
reason = strtrim(char(reason));
if isempty(gate)
    error('bma:run:gateMissing', '质量门豁免必须给出 gate（如 G6）。');
end
if isempty(reason)
    error('bma:run:gateReasonMissing', '质量门豁免必须给出 reason（为什么不可行、替代证据是什么）。');
end
if isempty(substitute)
    substitute = '';
else
    substitute = char(substitute);
end

gatesPath = fullfile(runDir, 'gates.json');
if isfile(gatesPath)
    try
        doc = bma.util.readJson(gatesPath);
    catch
        doc = struct();
    end
else
    doc = struct();
end
if ~isstruct(doc)
    doc = struct();
end
if ~isfield(doc, 'schema') || isempty(doc.schema)
    doc.schema = 'bma.gates.v1';
end
if ~isfield(doc, 'run_id') || isempty(doc.run_id)
    doc.run_id = basename(runDir);
end
if ~isfield(doc, 'waivers') || isempty(doc.waivers)
    doc.waivers = {};
elseif isstruct(doc.waivers) && ~iscell(doc.waivers)
    doc.waivers = num2cell(doc.waivers);
end
if ~iscell(doc.waivers)
    doc.waivers = {};
end
duplicate = false;
for k = 1:numel(doc.waivers)
    if isstruct(doc.waivers{k}) && isfield(doc.waivers{k}, 'gate') && ...
            strcmpi(char(doc.waivers{k}.gate), gate)
        duplicate = true;
        break
    end
end
entry = struct();
entry.gate = gate;
entry.reason = reason;
entry.substitute = substitute;
entry.evidence = evidence;
entry.recorded_at = bma.util.nowIso();
try
    v = bma.version();
    entry.agent_version = v.agent_version;
catch
    entry.agent_version = '';
end
doc.waivers{end+1} = entry;
doc.updated_at = bma.util.nowIso();
bma.util.writeJsonAtomic(gatesPath, doc);

r = struct();
r.waived = true;
r.gate = gate;
r.reason = reason;
r.substitute = substitute;
r.count = numel(doc.waivers);
r.gates_path = bma.util.relPath(workDir, gatesPath);
r.run_dir = bma.util.relPath(workDir, runDir);
r.duplicate = duplicate;
r.recorded_at = entry.recorded_at;
end

function b = basename(p)
[~, b] = fileparts(char(p));
end
