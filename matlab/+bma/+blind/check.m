function r = check(workDir, runDir, params)
%CHECK Blind-protocol self-check ledger, goal, references, freeze and stop.
%   r = bma.blind.check(workDir, runDir, params)
%
%   params.action:
%     status      -> coverage / rounds / issues / can_stop (no mutation)
%     goal        -> record the modeling question, objective, success criteria
%     references  -> append references (dir / JSON list / from_primary)
%     round       -> append a self-check round: checks + issues + model snapshot
%     freeze      -> freeze the current model specs (required before stop)
%     stop        -> enforce the stop criteria and write blind_summary.md
%
%   Stop is allowed only when remaining issues are closed as `fixed`,
%   `impossible` (with a general-impossibility argument) or `over_budget`
%   (spent >= 2x the declared budget), the reference set is read/covered, the
%   minimum number of rounds ran, and the model is frozen.
if nargin < 3 || isempty(params)
    params = struct();
end
workDir = char(workDir);
runDir = char(runDir);
p = bma.blind.internal.loadProtocol(runDir, true);
action = lower(strtrim(char(getStr(params, 'action', 'status'))));
roundInfo = struct();
freezeInfo = struct();
goalInfo = struct();
refsInfo = struct();

switch action
    case 'status'
        % read-only
    case 'goal'
        [p, goalInfo] = applyGoal(p, params);
    case 'references'
        [p, refsInfo] = applyReferences(workDir, runDir, p, params);
    case 'round'
        [p, roundInfo] = applyRound(workDir, p, params);
    case 'freeze'
        [p, freezeInfo] = applyFreeze(workDir, p, params);
    case 'stop'
        [p, roundInfo] = applyStop(workDir, runDir, p, params);
    otherwise
        error('bma:blind:unknown_action', ...
            ['未知 action "%s"。可用：status / goal / references / round / freeze / stop。'], action);
end

p.coverage = bma.blind.internal.computeCoverage(p.references);
if ~strcmp(action, 'status')
    bma.blind.internal.saveProtocol(runDir, p);
end
st = bma.blind.internal.evaluateStop(p);
r = buildResult(workDir, runDir, p, st, action, roundInfo, freezeInfo, goalInfo, refsInfo);
end

% ===========================================================================
function [p, info] = applyGoal(p, params)
g = getField(params, 'goal', struct());
if ~isstruct(g)
    error('bma:blind:goal_invalid', 'goal 必须是 JSON 对象。');
end
question = strtrim(char(getStr(g, 'question', '')));
objective = strtrim(char(getStr(g, 'objective', '')));
success = asCellstr(getField(g, 'success_criteria', {}));
outOfScope = asCellstr(getField(g, 'out_of_scope', {}));
if numel(question) < 40
    error('bma:blind:goal_invalid', ...
        'goal.question 必须 ≥40 字符：写清主文献摘要要研究/回答的问题。');
end
if numel(success) < 2
    error('bma:blind:goal_invalid', ...
        'goal.success_criteria 至少 2 条：模型做到什么算成功（可判定）。');
end
for k = 1:numel(success)
    if numel(strtrim(success{k})) < 10
        error('bma:blind:goal_invalid', 'success_criteria(%d) 太短（<10 字符）。', k);
    end
end
if ~isempty(objective) && numel(objective) < 20
    error('bma:blind:goal_invalid', 'goal.objective 若给出必须 ≥20 字符。');
end
p.question = struct('question', question, 'objective', objective, ...
    'success_criteria', {success}, 'out_of_scope', {outOfScope}, ...
    'recorded_at', bma.util.nowIso());
info = struct('recorded', true, 'question', question, ...
    'success_criteria', {success});
end

% ===========================================================================
function [p, info] = applyReferences(workDir, runDir, p, params)
refOpts = struct();
refOpts.max_references = p.options.max_references;
if isfield(params, 'references_dir') && ~isempty(params.references_dir)
    refOpts.references_dir = params.references_dir;
end
if isfield(params, 'references') && ~isempty(params.references)
    refOpts.references_json = params.references;
end
fromPrimary = getBool(params, 'from_primary', false);
warnings = {};
if fromPrimary
    src = char(p.primary.source_path);
    if ~isfile(src)
        error('bma:blind:primary_not_found', '主文献文件不存在：%s', src);
    end
    fmt = bma.io.internal.detectFormat(src);
    [raw, ~, w, ~] = bma.io.internal.readSourceText(src, fmt, 2 * 1024 * 1024);
    txt = bma.io.internal.normalizeText(raw);
    secs = bma.io.sectionize(txt);
    bib = bma.blind.internal.parseBibliography(txt, secs);
    refOpts.bib_citations = bib.citations;
    warnings = [warnings, w, bib.warnings];
end
[newRefs, w2] = bma.blind.internal.buildReferences(workDir, runDir, ...
    char(p.primary.source_path), char(p.primary.sha256), refOpts);
warnings = [warnings, w2];

% Merge against existing entries and keep existing ids stable.
existingKeys = {};
for k = 1:numel(p.references)
    ref = p.references{k};
    existingKeys = [existingKeys, refKeys(ref)]; %#ok<AGROW>
end
nextId = nextReferenceNumber(p.references);
added = {};
for k = 1:numel(newRefs)
    ref = newRefs{k};
    keys = refKeys(ref);
    duplicate = false;
    for j = 1:numel(keys)
        if any(strcmp(existingKeys, keys{j}))
            duplicate = true;
            break
        end
    end
    if duplicate
        continue
    end
    ref.id = sprintf('R%d', nextId);
    nextId = nextId + 1;
    p.references{end + 1} = ref;
    existingKeys = [existingKeys, keys]; %#ok<AGROW>
    added{end + 1} = ref.id; %#ok<AGROW>
end
p.warnings = [p.warnings, warnings];
if ~isempty(added)
    p.warnings{end + 1} = sprintf('追加 %d 篇参考文献：%s', ...
        numel(added), strjoin(added, ', '));
end
info = struct('added', {added}, 'total', numel(p.references), ...
    'added_count', numel(added));
end

% ===========================================================================
function [p, info] = applyRound(workDir, p, params)
rd = getField(params, 'round', struct());
if ~isstruct(rd)
    error('bma:blind:round_invalid', 'round 必须是 JSON 对象。');
end
summary = strtrim(char(getStr(rd, 'summary', '')));
if numel(summary) < 80
    error('bma:blind:round_invalid', ...
        'round.summary 必须 ≥80 字符：说明本轮检查了什么、发现了什么、怎么修补。');
end
checks = bma.blind.internal.asStructList(getField(rd, 'checks', {}));
if numel(checks) < 3
    error('bma:blind:round_invalid', ...
        'round.checks 至少 3 项（例如 spec / structure / numerics / evidence / coverage）。');
end
checkResults = {'pass', 'fail', 'skipped'};
for k = 1:numel(checks)
    c = checks{k};
    if ~isstruct(c)
        error('bma:blind:round_invalid', 'checks(%d) 必须是对象。', k);
    end
    name = strtrim(char(getStr(c, 'name', '')));
    result = lower(strtrim(char(getStr(c, 'result', ''))));
    evidence = strtrim(char(getStr(c, 'evidence', '')));
    if isempty(name)
        error('bma:blind:round_invalid', 'checks(%d).name 不能为空。', k);
    end
    if ~any(strcmp(result, checkResults))
        error('bma:blind:round_invalid', ...
            'checks(%d).result 必须是 pass/fail/skipped。', k);
    end
    if isempty(evidence)
        error('bma:blind:round_invalid', ...
            'checks(%d) (%s) 必须给 evidence（工具返回/数值/文件路径）。', k, name);
    end
end
issueInputs = bma.blind.internal.asStructList(getField(rd, 'issues', {}));
hasFail = false;
for k = 1:numel(checks)
    if strcmpi(char(getStr(checks{k}, 'result', '')), 'fail')
        hasFail = true;
        break
    end
end
if hasFail && isempty(issueInputs)
    error('bma:blind:round_invalid', ...
        '本轮有 fail 检查项，但 issues 为空：失败必须落成可追踪的问题。');
end
modelInputs = bma.blind.internal.asStructList(getField(rd, 'model_specs', {}));
modelSpecs = hashModels(workDir, modelInputs);

% ---- merge issues --------------------------------------------------------
issues = p.selfcheck.issues;
nextIssue = nextIssueNumber(issues);
added = {};
closedNow = {};
modelFix = false;
for k = 1:numel(issueInputs)
    in = issueInputs{k};
    if ~isstruct(in)
        error('bma:blind:issue_invalid', 'issues(%d) 必须是对象。', k);
    end
    id = strtrim(char(getStr(in, 'id', '')));
    if ~isempty(id)
        idx = findIssue(issues, id);
        if idx < 0
            error('bma:blind:issue_unknown', ...
                'issue id "%s" 不存在；新问题请省略 id 让工具分配。', id);
        end
        issue = fillIssueDefaults(issues{idx});
        before = lower(strtrim(char(getStr(issue, 'status', 'open'))));
        issue = mergeIssue(issue, in);
        issue = validateIssue(issue, false);
        after = lower(strtrim(char(getStr(issue, 'status', 'open'))));
        if strcmp(after, 'fixed') && strcmpi(char(getStr(issue, 'fix_kind', '')), 'model')
            modelFix = true;
        end
        if ~strcmp(before, after) && isTerminal(after)
            issue.closed_round = numel(p.selfcheck.rounds) + 1;
            closedNow{end + 1} = id; %#ok<AGROW>
        end
        issue.updated_at = bma.util.nowIso();
        issues{idx} = issue;
    else
        issue = fillIssueDefaults(struct());
        issue.id = sprintf('I%d', nextIssue);
        nextIssue = nextIssue + 1;
        issue = mergeIssue(issue, in);
        if isempty(strtrim(char(getStr(issue, 'status', ''))))
            issue.status = 'open';
        end
        issue = validateIssue(issue, true);
        issue.found_round = numel(p.selfcheck.rounds) + 1;
        issue.created_at = bma.util.nowIso();
        issue.updated_at = issue.created_at;
        if isTerminal(issue.status)
            issue.closed_round = numel(p.selfcheck.rounds) + 1;
            closedNow{end + 1} = issue.id; %#ok<AGROW>
        end
        if strcmp(issue.status, 'fixed') && strcmpi(issue.fix_kind, 'model')
            modelFix = true;
        end
        issues{end + 1} = issue;
        added{end + 1} = issue.id; %#ok<AGROW>
    end
end

% ---- model-change evidence ----------------------------------------------
if modelFix
    if isempty(modelSpecs)
        error('bma:blind:model_unchanged', ...
            ['本轮有 fix_kind="model" 的修复，但 round.model_specs 为空。' ...
             '重新建模后必须提交新的 spec 快照（name + spec_path），否则无法证明修补过。']);
    end
    prevHashes = previousModelHashes(p);
    newHashes = modelHashes(modelSpecs);
    if ~isempty(prevHashes) && sameHashSet(prevHashes, newHashes)
        error('bma:blind:model_unchanged', ...
            ['fix_kind="model" 声明修复了模型，但 spec 的 SHA-256 与上一轮完全相同。' ...
             '请真正修改/重建模型后再记录，或在 fix_kind 中如实写成 evidence/method。']);
    end
end

roundNo = numel(p.selfcheck.rounds) + 1;
elapsed = getNum(rd, 'elapsed_seconds', 0);
openNow = {};
for k = 1:numel(issues)
    if strcmpi(char(getStr(issues{k}, 'status', 'open')), 'open')
        openNow{end + 1} = char(getStr(issues{k}, 'id', '')); %#ok<AGROW>
    end
end
p.selfcheck.issues = issues;
p.selfcheck.rounds{end + 1} = struct( ...
    'round', roundNo, 'at', bma.util.nowIso(), 'summary', summary, ...
    'checks', {checks}, 'issues_added', {added}, 'issues_closed', {closedNow}, ...
    'issues_open', {openNow}, 'model_specs', {modelSpecs}, ...
    'elapsed_seconds', elapsed);
p.selfcheck.rounds_completed = roundNo;
p.selfcheck.elapsed_seconds = p.selfcheck.elapsed_seconds + max(0, elapsed);
p.selfcheck.stop = struct('met', false, 'verdict', '', 'note', '', ...
    'evaluated_at', '', 'reasons', {{'新的自检轮次已记录：需重新执行 stop 判定'}});
if ~isempty(modelSpecs)
    p.model.latest = struct('round', roundNo, ...
        'models', {modelSpecs}, 'at', bma.util.nowIso());
end
info = struct('number', roundNo, 'issues_added', {added}, ...
    'issues_closed', {closedNow}, 'issues_open', {openNow}, ...
    'model_specs', {modelSpecs});
end

% ===========================================================================
function [p, info] = applyFreeze(workDir, p, params)
modelsIn = bma.blind.internal.asStructList(getField(params, 'models', {}));
if isempty(modelsIn)
    error('bma:blind:freeze_invalid', ...
        'freeze 需要 models 数组：[{name, spec_path, role:"primary"|"alternative"}]。');
end
models = hashModels(workDir, modelsIn);
primaryCount = 0;
primary = struct();
for k = 1:numel(models)
    if strcmpi(char(getStr(models{k}, 'role', 'primary')), 'primary')
        primaryCount = primaryCount + 1;
        if isempty(fieldnames(primary))
            primary = models{k};
        end
    end
end
if primaryCount < 1
    error('bma:blind:freeze_invalid', ...
        '至少一个模型必须 role="primary"（主模型）。');
end
version = numel(p.model.versions) + 1;
entry = struct('version', version, 'frozen_at', bma.util.nowIso(), ...
    'models', {models}, 'primary_spec', char(getStr(primary, 'spec_path', '')), ...
    'primary_sha256', char(getStr(primary, 'sha256', '')), ...
    'agent_version', agentVersion());
p.model.versions{end + 1} = entry;
p.model.frozen = true;
p.model.current = version;
p.model.primary_spec = entry.primary_spec;
p.model.primary_sha256 = entry.primary_sha256;
p.selfcheck.stop = struct('met', false, 'verdict', '', 'note', '', ...
    'evaluated_at', '', 'reasons', {{'模型已冻结/更新：需重新执行 stop 判定'}});
info = struct('version', version, 'models', {models}, ...
    'primary_spec', entry.primary_spec, 'primary_sha256', entry.primary_sha256);
end

% ===========================================================================
function [p, info] = applyStop(workDir, runDir, p, params)
st = bma.blind.internal.evaluateStop(p);
if ~st.can_stop
    error('bma:blind:stop_blocked', ...
        '停止判据未满足：%s', strjoin(st.reasons, '；'));
end
verdict = lower(strtrim(char(getStr(params, 'verdict', 'passed'))));
if ~any(strcmp(verdict, {'passed', 'stopped_with_limits'}))
    error('bma:blind:stop_invalid', ...
        'verdict 必须是 passed 或 stopped_with_limits。');
end
note = strtrim(char(getStr(params, 'note', '')));
if strcmp(verdict, 'stopped_with_limits') && numel(note) < 60
    error('bma:blind:stop_invalid', ...
        'verdict=stopped_with_limits 时必须给 note（≥60 字符），说明哪些问题无法在一般情况下解决或超预算。');
end
p.selfcheck.stop = struct('met', true, 'verdict', verdict, 'note', note, ...
    'evaluated_at', bma.util.nowIso(), 'reasons', {{}});
summaryPath = bma.blind.internal.writeSummary(workDir, runDir, p, st);
p.selfcheck.summary_path = bma.util.relPath(workDir, summaryPath);
p.selfcheck.summary_written_at = bma.util.nowIso();
info = struct('verdict', verdict, 'note', note, ...
    'summary_path', p.selfcheck.summary_path);
end

% ===========================================================================
function issue = mergeIssue(issue, in)
fields = {'category', 'severity', 'title', 'detail', 'status', ...
    'fix', 'fix_kind', 'reason', 'why_general', 'evidence', ...
    'covers_references'};
for k = 1:numel(fields)
    f = fields{k};
    if isfield(in, f)
        issue.(f) = in.(f);
    end
end
if isfield(in, 'budget') && isstruct(in.budget)
    issue.budget = in.budget;
end
end

% ---------------------------------------------------------------------------
function issue = validateIssue(issue, isNew)
cats = {'evidence', 'coverage', 'units', 'structure', 'parameters', ...
    'identifiability', 'numerics', 'reproduction', 'reporting', 'other'};
sevs = {'P0', 'P1', 'P2', 'P3'};
statuses = {'open', 'fixed', 'impossible', 'over_budget'};
category = lower(strtrim(char(getStr(issue, 'category', ''))));
severity = upper(strtrim(char(getStr(issue, 'severity', ''))));
status = lower(strtrim(char(getStr(issue, 'status', 'open'))));
if isNew || ~isempty(category)
    if ~any(strcmp(category, cats))
        error('bma:blind:issue_invalid', ...
            'issue.category 必须是 %s。', strjoin(cats, '/'));
    end
    issue.category = category;
end
if isNew || ~isempty(severity)
    if ~any(strcmp(severity, sevs))
        error('bma:blind:issue_invalid', 'issue.severity 必须是 P0/P1/P2/P3。');
    end
    issue.severity = severity;
end
if ~any(strcmp(status, statuses))
    error('bma:blind:issue_invalid', ...
        'issue.status 必须是 open/fixed/impossible/over_budget。');
end
issue.status = status;
if isNew
    if numel(strtrim(char(getStr(issue, 'title', '')))) < 10
        error('bma:blind:issue_invalid', '新 issue.title 必须 ≥10 字符。');
    end
    if numel(strtrim(char(getStr(issue, 'detail', '')))) < 20
        error('bma:blind:issue_invalid', '新 issue.detail 必须 ≥20 字符。');
    end
end
issue.evidence = strtrim(char(getStr(issue, 'evidence', '')));
issue.reason = strtrim(char(getStr(issue, 'reason', '')));
issue.why_general = strtrim(char(getStr(issue, 'why_general', '')));
issue.fix = strtrim(char(getStr(issue, 'fix', '')));
issue.fix_kind = lower(strtrim(char(getStr(issue, 'fix_kind', ''))));
if strcmp(status, 'fixed')
    if numel(issue.fix) < 20
        error('bma:blind:issue_invalid', ...
            'status=fixed 的 issue 必须给 fix（≥20 字符，说明怎么改的）。');
    end
    if ~any(strcmp(issue.fix_kind, {'model', 'parameter', 'evidence', 'report', 'method'}))
        error('bma:blind:issue_invalid', ...
            'status=fixed 的 fix_kind 必须是 model/parameter/evidence/report/method。');
    end
    if numel(issue.evidence) < 10
        error('bma:blind:issue_invalid', ...
            'status=fixed 的 issue 必须给 evidence（≥10 字符：修复后的验证结果）。');
    end
elseif strcmp(status, 'impossible')
    if numel(issue.reason) < 80
        error('bma:blind:issue_invalid', ...
            'status=impossible 的 reason 必须 ≥80 字符：为什么在一般情况下不可能解决。');
    end
    if numel(issue.why_general) < 60
        error('bma:blind:issue_invalid', ...
            ['status=impossible 必须给 why_general（≥60 字符）：为什么这不是"预算不够/懒得做"，' ...
             '而是原理上不可解（数据不可辨识、文献矛盾、模型类缺少必要物理等）。']);
    end
    if numel(issue.evidence) < 20
        error('bma:blind:issue_invalid', ...
            'status=impossible 必须给 evidence（≥20 字符：尝试过什么、为什么失败）。');
    end
elseif strcmp(status, 'over_budget')
    if numel(issue.reason) < 80
        error('bma:blind:issue_invalid', ...
            'status=over_budget 的 reason 必须 ≥80 字符：说明继续做要花多少、为什么已过分超预算。');
    end
    if numel(issue.evidence) < 20
        error('bma:blind:issue_invalid', ...
            'status=over_budget 必须给 evidence（≥20 字符：已投入与剩余估算）。');
    end
    okBudget = validBudget(getField(issue, 'budget', struct()));
    if ~okBudget
        error('bma:blind:issue_invalid', ...
            ['status=over_budget 必须给 budget {spent_s, limit_s}，且 spent_s >= 2*limit_s、limit_s>0；' ...
             '"非常过分地超出预算"按 2 倍计。']);
    end
end
issue.covers_references = asCellstr(getField(issue, 'covers_references', {}));
end

% ---------------------------------------------------------------------------
function models = hashModels(workDir, modelInputs)
models = {};
for k = 1:numel(modelInputs)
    m = modelInputs{k};
    if ~isstruct(m)
        error('bma:blind:model_invalid', 'model_specs(%d) 必须是对象。', k);
    end
    name = strtrim(char(getStr(m, 'name', '')));
    spec = strtrim(char(getStr(m, 'spec_path', '')));
    if isempty(name) || isempty(spec)
        error('bma:blind:model_invalid', ...
            'model_specs(%d) 需要 name 与 spec_path。', k);
    end
    absPath = bma.util.absPath(workDir, spec);
    if ~isfile(absPath)
        error('bma:blind:model_invalid', 'spec 文件不存在：%s', absPath);
    end
    % A frozen "model" must be a valid bma.modelSpec.v1, not an arbitrary JSON
    % file whose hash merely changed.
    try
        specObj = bma.util.readJson(absPath);
        rep = bma.spec.validate(specObj, workDir);
    catch err
        error('bma:blind:model_invalid', '无法校验 spec %s：%s', absPath, err.message);
    end
    if ~isfield(rep, 'valid') || ~rep.valid
        detail = 'unknown';
        if isfield(rep, 'errors') && ~isempty(rep.errors)
            detail = [char(rep.errors{1}.code) ': ' char(string(rep.errors{1}.message))];
        end
        error('bma:blind:model_invalid', ...
            '模型 %s 的 spec 校验失败（valid=false）：%s', name, char(detail));
    end
    sha = bma.util.sha256File(absPath);
    if isempty(sha)
        error('bma:blind:model_invalid', '无法计算 spec 的 SHA-256：%s', absPath);
    end
    d = dir(absPath);
    models{end + 1} = struct('name', name, ...
        'spec_path', bma.util.relPath(workDir, absPath), ...
        'sha256', sha, 'bytes', d(1).bytes, ...
        'role', lower(strtrim(char(getStr(m, 'role', 'primary'))))); %#ok<AGROW>
end
end

% ---------------------------------------------------------------------------
function prev = previousModelHashes(p)
prev = {};
if isfield(p.model, 'latest') && isstruct(p.model.latest) && ...
        isfield(p.model.latest, 'models')
    prev = modelHashes(bma.blind.internal.asStructList(p.model.latest.models));
    return
end
for k = numel(p.selfcheck.rounds):-1:1
    r = p.selfcheck.rounds{k};
    ms = bma.blind.internal.asStructList(getField(r, 'model_specs', {}));
    if ~isempty(ms)
        prev = modelHashes(ms);
        return
    end
end
if ~isempty(p.model.versions)
    v = p.model.versions{end};
    ms = bma.blind.internal.asStructList(getField(v, 'models', {}));
    prev = modelHashes(ms);
end
end

function h = modelHashes(models)
h = {};
for k = 1:numel(models)
    h{end + 1} = char(getStr(models{k}, 'sha256', '')); %#ok<AGROW>
end
h = sort(h);
end

function tf = sameHashSet(a, b)
a = sort(a);
b = sort(b);
tf = numel(a) == numel(b) && all(strcmp(a, b));
end

% ---------------------------------------------------------------------------
function issue = fillIssueDefaults(issue)
defaults = struct('id', '', 'category', '', 'severity', '', 'title', '', ...
    'detail', '', 'status', 'open', 'fix', '', 'fix_kind', '', ...
    'reason', '', 'why_general', '', 'evidence', '', ...
    'budget', struct('spent_s', 0, 'limit_s', 0), ...
    'covers_references', {{}}, 'found_round', 0, 'closed_round', 0, ...
    'created_at', '', 'updated_at', '');
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(issue, names{k})
        issue.(names{k}) = defaults.(names{k});
    end
end
issue.covers_references = asCellstr(getField(issue, 'covers_references', {}));
end

function idx = findIssue(issues, id)
idx = -1;
for k = 1:numel(issues)
    if strcmpi(char(getStr(issues{k}, 'id', '')), id)
        idx = k;
        return
    end
end
end

function n = nextIssueNumber(issues)
n = 1;
for k = 1:numel(issues)
    id = char(getStr(issues{k}, 'id', ''));
    tok = regexp(id, '^I(\d+)$', 'tokens', 'once');
    if ~isempty(tok)
        n = max(n, str2double(tok{1}) + 1);
    end
end
end

function n = nextReferenceNumber(refs)
n = 1;
for k = 1:numel(refs)
    id = char(getStr(refs{k}, 'id', ''));
    tok = regexp(id, '^R(\d+)$', 'tokens', 'once');
    if ~isempty(tok)
        n = max(n, str2double(tok{1}) + 1);
    end
end
end

function tf = isTerminal(status)
tf = any(strcmpi(status, {'fixed', 'impossible', 'over_budget'}));
end

function [ok, reason] = validBudget(b)
ok = false;
reason = '';
if ~isstruct(b) || ~isfield(b, 'spent_s') || ~isfield(b, 'limit_s')
    reason = 'missing_budget';
    return
end
spent = double(b.spent_s);
limit = double(b.limit_s);
if ~isfinite(spent) || ~isfinite(limit) || limit <= 0 || spent < 2 * limit
    reason = 'invalid_budget';
    return
end
ok = true;
end

function keys = refKeys(ref)
keys = {};
if isstruct(ref)
    sha = char(getStr(ref, 'sha256', ''));
    if ~isempty(sha)
        keys{end + 1} = ['sha:' lower(sha)];
    end
    p = char(getStr(ref, 'abs_path', ''));
    if ~isempty(p)
        keys{end + 1} = ['path:' lower(bma.blind.internal.canonicalPath(p))];
    end
    c = char(getStr(ref, 'citation', ''));
    if ~isempty(c)
        keys{end + 1} = ['cit:' lower(regexprep(c, '\s+', ' '))];
    end
end
end

% ===========================================================================
function r = buildResult(workDir, runDir, p, st, action, roundInfo, freezeInfo, goalInfo, refsInfo)
cov = bma.blind.internal.computeCoverage(p.references);
question = '';
objective = '';
success = {};
if isfield(p, 'question') && isstruct(p.question)
    question = strtrim(char(getStr(p.question, 'question', '')));
    objective = strtrim(char(getStr(p.question, 'objective', '')));
    success = asCellstr(getField(p.question, 'success_criteria', {}));
end
r = struct();
r.action = action;
r.run_dir = bma.util.relPath(workDir, runDir);
r.protocol_path = bma.util.relPath(workDir, ...
    bma.blind.internal.protocolFile(runDir));
r.status = p.status;
r.sealed = logical(p.guard.sealed);
r.primary = struct('title', char(p.primary.title), ...
    'abstract_source', char(p.primary.abstract.source), ...
    'abstract_confidence', char(p.primary.abstract.confidence), ...
    'abstract_chars', double(p.primary.abstract.chars), ...
    'sha256', char(p.primary.sha256));
r.question = struct('recorded', ~isempty(question), 'question', question, ...
    'objective', objective, 'success_criteria', {success});
r.coverage = cov;
r.rounds_completed = st.rounds;
r.min_rounds = st.min_rounds;
r.issues = st.issues;
r.model = st.model;
r.can_stop = logical(st.can_stop);
r.stop_reasons = st.reasons;
r.stop = struct('met', logical(getBool(p.selfcheck.stop, 'met', false)), ...
    'verdict', char(getStr(p.selfcheck.stop, 'verdict', '')), ...
    'summary_path', char(getStr(p.selfcheck, 'summary_path', '')));
r.warnings = p.warnings;
r.next_steps = nextSteps(p, st);
switch action
    case 'round'
        r.round = roundInfo;
    case 'freeze'
        r.freeze = freezeInfo;
    case 'goal'
        r.goal = goalInfo;
    case 'references'
        r.references_added = refsInfo;
    case 'stop'
        r.stop_result = roundInfo;
end
end

function steps = nextSteps(p, st)
steps = {};
if isempty(strtrim(char(getStr(p.question, 'question', ''))))
    steps{end + 1} = 'bma_blind_check action:"goal" 记录问题/目标与成功判据';
    return
end
if st.coverage.total == 0
    steps{end + 1} = 'bma_blind_check action:"references" 追加全部参考文献';
    return
end
if st.coverage.read < st.coverage.total
    steps{end + 1} = '用 bma_blind_note 逐篇登记剩余参考文献（quote 会被逐字校验）';
    return
end
if st.rounds < st.min_rounds
    steps{end + 1} = sprintf('继续自检：bma_blind_check action:"round"（%d/%d）', ...
        st.rounds, st.min_rounds);
    return
end
if st.issues.open > 0
    steps{end + 1} = sprintf('修补未封闭问题 %s，再用 action:"round" 记录', ...
        strjoin(st.issues.open_ids, ', '));
    return
end
if ~st.model.frozen
    steps{end + 1} = 'bma_blind_check action:"freeze" 冻结模型（提交 spec 快照）';
    return
end
if ~st.can_stop
    steps{end + 1} = 'bma_blind_check action:"stop" 前先处理后述原因：';
    steps = [steps, st.reasons];
    return
end
if strcmpi(char(p.status), 'sealed')
    steps{end + 1} = '可选：bma_blind_reveal action:"reveal" 解封主文献并对照';
    steps{end + 1} = '交付：bma_report_build 时把 blind/blind_summary.md 作为 extra_sections 嵌入';
    return
end
steps{end + 1} = 'bma_blind_reveal action:"compare" 记录模型对照并生成 blind/model_comparison.md';
end

function v = agentVersion()
v = '';
try
    ver = bma.version();
    v = ver.agent_version;
catch
end
end

% ---------------------------------------------------------------------------
function v = getStr(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = char(string(s.(f)));
else
    v = d;
end
end

function v = getBool(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = logical(s.(f));
else
    v = d;
end
end

function v = getNum(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f))
    v = double(s.(f));
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

function c = asCellstr(v)
if isempty(v)
    c = {};
elseif iscell(v)
    c = cellfun(@char, v(:)', 'UniformOutput', false);
elseif ischar(v)
    c = {char(v)};
else
    c = {char(string(v))};
end
end
