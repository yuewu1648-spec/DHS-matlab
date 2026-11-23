function r = reveal(workDir, runDir, params)
%REVEAL Unseal the primary paper after a passed stop, then compare models.
%   r = bma.blind.reveal(workDir, runDir, params)
%
%   action:"reveal"  -> refuses unless the stop criteria passed and the model is
%                       frozen; then lifts the seal and ingests the full primary
%                       paper into <run_dir>/literature/.
%   action:"compare" -> validates a structured agent-vs-paper comparison and
%                       writes blind/model_comparison.{json,md}.
if nargin < 3 || isempty(params)
    params = struct();
end
workDir = char(workDir);
runDir = char(runDir);
p = bma.blind.internal.loadProtocol(runDir, true);
action = lower(strtrim(char(getStr(params, 'action', 'reveal'))));
switch action
    case 'reveal'
        r = doReveal(workDir, runDir, p, params);
    case 'compare'
        r = doCompare(workDir, runDir, p, params);
    otherwise
        error('bma:blind:unknown_action', ...
            '未知 action "%s"。可用：reveal / compare。', action);
end
end

% ===========================================================================
function r = doReveal(workDir, runDir, p, params)
if strcmpi(char(p.status), 'revealed')
    % A previous reveal may have timed out after lifting the seal but before
    % ingesting the full text. Only refuse when the ingest artifact is present.
    done = false;
    if isstruct(p.reveal) && isfield(p.reveal, 'text_path') && ~isempty(p.reveal.text_path)
        done = isfile(bma.util.absPath(workDir, char(p.reveal.text_path)));
    end
    if done
        error('bma:blind:already_revealed', ...
            '主文献已经解封（%s）。直接 action:"compare" 记录对照。', ...
            char(getStr(p.reveal, 'revealed_at', '')));
    end
end
st = bma.blind.internal.evaluateStop(p);
if ~st.can_stop
    error('bma:blind:stop_blocked', ...
        ['解封前必须先通过停止判据（自检轮次、参考文献覆盖、问题封闭、模型冻结）。' ...
         '当前未满足：%s'], strjoin(st.reasons, '；'));
end
if ~p.model.frozen
    error('bma:blind:not_frozen', '模型尚未冻结，禁止解封；先 bma_blind_check action:"freeze"。');
end
src = char(p.primary.source_path);
if ~isfile(src)
    error('bma:blind:primary_not_found', '主文献文件不存在：%s', src);
end
% Lift the seal BEFORE ingest, then restore it if ingest fails.
p.guard.sealed = false;
p.guard.ingest_blocked = false;
p.guard.full_text_exposed = true;
p.status = 'revealed';
p.reveal = struct('revealed_at', bma.util.nowIso(), ...
    'reason', strtrim(char(getStr(params, 'reason', ''))), ...
    'model_version', double(p.model.current), ...
    'stop_verdict', char(getStr(p.selfcheck.stop, 'verdict', '')), ...
    'primary_sha256', char(p.primary.sha256));
bma.blind.internal.saveProtocol(runDir, p);
bma.blind.internal.updateSealRegistry(bma.blind.internal.workspaceOf(runDir), struct( ...
    'run_id', char(p.run_id), 'primary_path', char(p.primary.source_path), ...
    'primary_sha256', char(p.primary.sha256), ...
    'protocol_path', bma.blind.internal.protocolFile(runDir), 'sealed', false, ...
    'revealed_at', p.reveal.revealed_at));
try
    doc = bma.io.ingest(src, runDir, 'WorkDir', workDir);
catch err
    p.guard.sealed = true;
    p.guard.ingest_blocked = true;
    p.guard.full_text_exposed = false;
    p.status = 'sealed';
    p.reveal = [];
    bma.blind.internal.saveProtocol(runDir, p);
    bma.blind.internal.updateSealRegistry(bma.blind.internal.workspaceOf(runDir), struct( ...
        'run_id', char(p.run_id), 'primary_path', char(p.primary.source_path), ...
        'primary_sha256', char(p.primary.sha256), ...
        'protocol_path', bma.blind.internal.protocolFile(runDir), 'sealed', true, ...
        'sealed_at', p.created_at));
    rethrow(err);
end
p.reveal.doc_id = doc.doc_id;
p.reveal.text_path = doc.text_path;
p.reveal.sections_path = doc.sections_path;
p.reveal.numbers_path = doc.numbers_path;
p.reveal.tables_path = doc.tables_path;
if isfield(doc, 'figures_path')
    p.reveal.figures_path = doc.figures_path;
end
p.reveal.title = doc.title;
p.reveal.char_count = doc.char_count;
p.reveal.figures = numel(doc.figures);
p.selfcheck.stop.met = true;  % stop verdict remains valid
bma.blind.internal.saveProtocol(runDir, p);

r = struct();
r.action = 'reveal';
r.run_dir = bma.util.relPath(workDir, runDir);
r.revealed = true;
r.revealed_at = p.reveal.revealed_at;
r.primary = struct('title', doc.title, 'sha256', char(p.primary.sha256), ...
    'doc_id', doc.doc_id, 'char_count', doc.char_count, ...
    'text_path', doc.text_path, 'sections_path', doc.sections_path, ...
    'figures_path', getFieldStr(doc, 'figures_path', ''), ...
    'figure_count', numel(doc.figures));
r.full_text_allowed = true;
r.model_version = double(p.model.current);
r.message = ['已解封：现在可以 read 主文献全文并对照。' ...
    '用 action:"compare" 提交 8 个维度的对照（question/model_class/state_variables/' ...
    'mechanisms/parameters/assumptions/behavior/evidence_use）。'];
r.warnings = doc.warnings;
end

% ===========================================================================
function r = doCompare(workDir, runDir, p, params)
if ~strcmpi(char(p.status), 'revealed')
    error('bma:blind:not_revealed', ...
        '模型对照必须在解封之后（先 action:"reveal"）。');
end
comp = getField(params, 'comparison', struct());
if ~isstruct(comp)
    error('bma:blind:compare_invalid', 'comparison 必须是 JSON 对象。');
end
required = {'question', 'model_class', 'state_variables', 'mechanisms', ...
    'parameters', 'assumptions', 'behavior', 'evidence_use'};
dims = bma.blind.internal.asStructList(getField(comp, 'dimensions', {}));
if isempty(dims)
    error('bma:blind:compare_invalid', ...
        'comparison.dimensions 必须是非空数组（每项 {key, agent, paper, agreement, evidence, gap, follow_up}）。');
end
seen = {};
for k = 1:numel(dims)
    d = dims{k};
    if ~isstruct(d)
        error('bma:blind:compare_invalid', 'dimensions(%d) 必须是对象。', k);
    end
    key = lower(strtrim(char(getStr(d, 'key', ''))));
    if ~any(strcmp(key, required))
        error('bma:blind:compare_invalid', ...
            'dimensions(%d).key="%s" 不在必需维度中：%s。', k, key, strjoin(required, '/'));
    end
    if any(strcmp(seen, key))
        error('bma:blind:compare_invalid', '维度 %s 重复。', key);
    end
    seen{end + 1} = key; %#ok<AGROW>
    agent = strtrim(char(getStr(d, 'agent', '')));
    paper = strtrim(char(getStr(d, 'paper', '')));
    agreement = lower(strtrim(char(getStr(d, 'agreement', ''))));
    evidence = strtrim(char(getStr(d, 'evidence', '')));
    follow = strtrim(char(getStr(d, 'follow_up', '')));
    if numel(agent) < 8 || numel(paper) < 8
        error('bma:blind:compare_invalid', ...
            '维度 %s 的 agent/paper 都必须 ≥8 字符（没有就写“文中未给出……”）。', key);
    end
    if ~any(strcmp(agreement, {'match', 'partial', 'diverge', 'not_comparable'}))
        error('bma:blind:compare_invalid', ...
            '维度 %s 的 agreement 必须是 match/partial/diverge/not_comparable。', key);
    end
    if numel(evidence) < 10
        error('bma:blind:compare_invalid', ...
            '维度 %s 必须给 evidence（≥10 字符：原文位置/数值/图形证据）。', key);
    end
    if any(strcmp(agreement, {'partial', 'diverge'})) && numel(follow) < 10
        error('bma:blind:compare_invalid', ...
            '维度 %s 是 %s，必须给 follow_up（≥10 字符：差距/下一步）。', key, agreement);
    end
end
missing = setdiff(required, seen);
if ~isempty(missing)
    error('bma:blind:compare_invalid', ...
        '缺少必需维度：%s（必须 8 个维度全给）。', strjoin(missing, ', '));
end
verdict = lower(strtrim(char(getStr(comp, 'verdict', ''))));
if ~any(strcmp(verdict, {'close', 'partial', 'diverge', 'not_comparable'}))
    error('bma:blind:compare_invalid', ...
        'comparison.verdict 必须是 close/partial/diverge/not_comparable。');
end
summary = strtrim(char(getStr(comp, 'summary', '')));
if numel(summary) < 100
    error('bma:blind:compare_invalid', ...
        'comparison.summary 必须 ≥100 字符：总结模型与原文献的异同及其原因。');
end
limitations = strtrim(char(getStr(comp, 'limitations', '')));

jsonFile = fullfile(runDir, 'blind', 'model_comparison.json');
mdFile = fullfile(runDir, 'blind', 'model_comparison.md');
record = struct('schema', 'bma.blindComparison.v1', ...
    'created_at', bma.util.nowIso(), 'verdict', verdict, ...
    'summary', summary, 'limitations', limitations, ...
    'dimensions', {dims}, ...
    'blind_protocol', struct('primary_title', char(p.primary.title), ...
        'primary_sha256', char(p.primary.sha256), ...
        'revealed_at', char(getStr(p.reveal, 'revealed_at', '')), ...
        'model_version', double(p.model.current), ...
        'coverage', bma.blind.internal.computeCoverage(p.references), ...
        'rounds_completed', numel(p.selfcheck.rounds), ...
        'issues', bma.blind.internal.issueStats(p.selfcheck.issues)));
bma.util.writeJsonAtomic(jsonFile, record);
bma.util.writeTextAtomic(mdFile, renderComparison(record));

p.reveal.comparison_path = bma.util.relPath(workDir, mdFile);
p.reveal.comparison_json_path = bma.util.relPath(workDir, jsonFile);
p.reveal.comparison_verdict = verdict;
p.reveal.compared_at = record.created_at;
bma.blind.internal.saveProtocol(runDir, p);

r = struct();
r.action = 'compare';
r.run_dir = bma.util.relPath(workDir, runDir);
r.verdict = verdict;
r.summary = summary;
r.dimensions = numel(dims);
r.missing_dimensions = {};
r.comparison_path = p.reveal.comparison_path;
r.comparison_json_path = p.reveal.comparison_json_path;
r.warnings = {};
r.next_steps = {'把 blind/blind_summary.md 与 blind/model_comparison.md 作为 bma_report_build 的 extra_sections 嵌入报告，' ...
    '并在报告中如实说明“盲建模期间未读全文、解封后对照发现的差异”。'};
end

% ===========================================================================
function md = renderComparison(rec)
lines = {
    '# 解封后模型对照（盲建模 vs 原文献）'
    ''
    ['- 主文献：' char(rec.blind_protocol.primary_title)]
    ['- 主文献 SHA-256：`' char(rec.blind_protocol.primary_sha256) '`']
    ['- 解封时间：' char(rec.blind_protocol.revealed_at)]
    ['- 冻结模型版本：v' sprintf('%d', double(rec.blind_protocol.model_version))]
    ['- 自检轮次：' sprintf('%d', double(rec.blind_protocol.rounds_completed))]
    ['- 总体判定：' char(rec.verdict)]
    ''
    '## 维度对照'
    ''
    '| 维度 | 我方模型（仅摘要+参考文献） | 原文献模型 | 一致性 | 证据 | 差距/后续 |'
    '|---|---|---|---|---|---|'
    };
for k = 1:numel(rec.dimensions)
    d = rec.dimensions{k};
    lines{end + 1} = sprintf('| %s | %s | %s | %s | %s | %s |', ...
        tableCell(getStr(d, 'key', '')), tableCell(getStr(d, 'agent', '')), ...
        tableCell(getStr(d, 'paper', '')), tableCell(getStr(d, 'agreement', '')), ...
        tableCell(getStr(d, 'evidence', '')), tableCell(getStr(d, 'follow_up', ''))); %#ok<AGROW>
end
lines{end + 1} = '';
lines{end + 1} = '## 结论';
lines{end + 1} = '';
lines{end + 1} = char(rec.summary);
if ~isempty(rec.limitations)
    lines{end + 1} = '';
    lines{end + 1} = '## 局限';
    lines{end + 1} = '';
    lines{end + 1} = char(rec.limitations);
end
lines{end + 1} = '';
lines{end + 1} = '> 对照是在模型冻结后进行的：解封前的模型只使用了摘要与参考文献，未读取主文献全文/图/表。';
md = strjoin(lines, char(10));
end

% ---------------------------------------------------------------------------
function s = tableCell(v)
s = regexprep(char(string(v)), '\s+', ' ');
s = strrep(s, '|', '\|');
if numel(s) > 300
    s = [s(1:297) '...'];
end
end

function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end

function v = getField(s, f, d)
if isstruct(s) && isfield(s, f)
    v = s.(f);
else
    v = d;
end
end

function v = getFieldStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end
