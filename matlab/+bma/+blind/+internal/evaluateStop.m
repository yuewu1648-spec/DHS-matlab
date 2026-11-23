function st = evaluateStop(p)
%EVALUATESTOP Decide whether the blind protocol may stop modeling.
%   st = bma.blind.internal.evaluateStop(p)
%
%   Stop is allowed only when: the question/goal is recorded; every reference is
%   read or covered by a closed impossible/over_budget issue; the minimum number
%   of self-check rounds ran; no issue is open; every impossible/over_budget
%   closure carries the required justification; and the model is frozen.
refs = p.references;
cov = bma.blind.internal.computeCoverage(refs);
issues = bma.blind.internal.asStructList(p.selfcheck.issues);
rounds = numel(p.selfcheck.rounds);
minR = double(p.options.min_rounds);
reasons = {};

q = '';
if isfield(p, 'question') && isstruct(p.question)
    q = strtrim(char(getStr(p.question, 'question', '')));
end
if isempty(q)
    reasons{end + 1} = '建模问题/目标尚未记录（bma_blind_check action:"goal"）'; %#ok<AGROW>
end

if cov.total == 0
    reasons{end + 1} = '参考文献清单为空：全部参考文献必须逐篇登记并核验'; %#ok<AGROW>
elseif cov.read < cov.total
    covered = {};
    for k = 1:numel(issues)
        s = lower(strtrim(char(getStr(issues{k}, 'status', ''))));
        if any(strcmp(s, {'impossible', 'over_budget'}))
            covered = [covered, refsOf(issues{k})]; %#ok<AGROW>
        end
    end
    covered = unique(covered);
    blocking = setdiff(cov.blocking_ids, covered);
    if ~isempty(blocking)
        reasons{end + 1} = sprintf( ...
            '有 %d 篇参考文献未完成核验，且未被 impossible/over_budget 问题覆盖：%s', ...
            numel(blocking), strjoin(blocking, ', ')); %#ok<AGROW>
    end
end
% Anti-formalism: marking a large share of the references as irrelevant is
% usually "read a part and call it done". Allow at most 30% (or 2 entries).
if cov.total >= 4
    allowed = max(2, ceil(0.3 * cov.total));
    if cov.no_modeling > allowed
        reasons{end + 1} = sprintf( ...
            ['有 %d/%d 篇参考文献被标为 no_modeling_content（上限 %d）。' ...
             '这通常意味着只形式主义地翻了部分文献；请补读/补证据，或把它们作为证据缺口写成问题。'], ...
            cov.no_modeling, cov.total, allowed); %#ok<AGROW>
    end
elseif cov.total > 0 && cov.no_modeling == cov.total
    reasons{end + 1} = '全部参考文献都被标为无建模价值：不满足“每篇都要看并提取可用信息”的要求。'; %#ok<AGROW>
end

if rounds < minR
    reasons{end + 1} = sprintf('自检轮次不足：%d/%d（每轮都要记录检查项与问题）', ...
        rounds, minR); %#ok<AGROW>
end

openIds = {};
badClosed = {};
for k = 1:numel(issues)
    s = lower(strtrim(char(getStr(issues{k}, 'status', 'open'))));
    id = char(getStr(issues{k}, 'id', sprintf('I%d', k)));
    if strcmp(s, 'open')
        openIds{end + 1} = id; %#ok<AGROW>
        continue
    end
    if strcmp(s, 'impossible')
        if numel(strtrim(char(getStr(issues{k}, 'reason', '')))) < 80 || ...
                numel(strtrim(char(getStr(issues{k}, 'why_general', '')))) < 60 || ...
                numel(strtrim(char(getStr(issues{k}, 'evidence', '')))) < 20
            badClosed{end + 1} = id; %#ok<AGROW>
        end
    elseif strcmp(s, 'over_budget')
        [okBudget, ~] = validBudget(getField(issues{k}, 'budget', struct()));
        if ~okBudget || numel(strtrim(char(getStr(issues{k}, 'reason', '')))) < 80 || ...
                numel(strtrim(char(getStr(issues{k}, 'evidence', '')))) < 20
            badClosed{end + 1} = id; %#ok<AGROW>
        end
    end
end
if ~isempty(openIds)
    reasons{end + 1} = sprintf('仍有 %d 个未封闭问题：%s', ...
        numel(openIds), strjoin(openIds, ', ')); %#ok<AGROW>
end
if ~isempty(badClosed)
    reasons{end + 1} = sprintf( ...
        ['以下问题以 impossible/over_budget 关闭但论证不足（impossible 需 reason≥80、' ...
         'why_general≥60、evidence≥20；over_budget 需预算 ≥2× 且 reason/evidence 齐全）：%s'], ...
        strjoin(badClosed, ', ')); %#ok<AGROW>
end

if ~p.model.frozen || numel(p.model.versions) == 0
    reasons{end + 1} = '模型尚未冻结（bma_blind_check action:"freeze"）'; %#ok<AGROW>
end

st = struct();
st.can_stop = isempty(reasons);
st.reasons = reasons;
st.coverage = cov;
st.rounds = rounds;
st.min_rounds = minR;
st.issues = bma.blind.internal.issueStats(issues);
st.model = struct('frozen', logical(p.model.frozen), ...
    'current', double(p.model.current), 'versions', numel(p.model.versions));
end

% ---------------------------------------------------------------------------
function ids = refsOf(issue)
ids = {};
v = getField(issue, 'covers_references', {});
if isempty(v)
    return
end
if ischar(v) || isstring(v)
    ids = {char(v)};
elseif iscell(v)
    for k = 1:numel(v)
        ids{end + 1} = char(string(v{k})); %#ok<AGROW>
    end
end
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
if ~isfinite(spent) || ~isfinite(limit) || limit <= 0
    reason = 'invalid_budget';
    return
end
if spent < 2 * limit
    reason = 'not_grossly_over_budget';
    return
end
ok = true;
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
