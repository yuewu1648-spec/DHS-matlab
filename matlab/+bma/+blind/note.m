function r = note(workDir, runDir, refId, note, opts)
%NOTE Record a verified reading note for one reference.
%   r = bma.blind.note(workDir, runDir, refId, note, opts)
%
%   Every reference in the inventory needs a note. Claims must carry a verbatim
%   quote; the quote is checked against the reference's extracted text, so a
%   paraphrased or fabricated citation fails loudly instead of becoming
%   "evidence". citation-only entries (no readable file) are recorded as
%   `limited` and must be covered by an impossible/over_budget self-check issue
%   before the protocol can stop.
%
%   note fields: depth ("full_text"|"abstract_only"|"citation_only"),
%   claims[{kind, claim, quote, location}], relevance{question_link,
%   modeling_use}, parameters?, title?, year?, venue?, sections_read?,
%   no_modeling_content?, no_modeling_content_reason?, access_limited_reason?.
if nargin < 5
    opts = struct();
end
workDir = char(workDir);
runDir = char(runDir);
refId = strtrim(char(refId));
p = bma.blind.internal.loadProtocol(runDir, true);
idx = -1;
for k = 1:numel(p.references)
    if strcmpi(char(getStr(p.references{k}, 'id', '')), refId)
        idx = k;
        break
    end
end
if idx < 0
    error('bma:blind:reference_unknown', ...
        '参考文献 id "%s" 不在清单中（共 %d 篇）。先 bma_blind_check(action:"status") 查看 id。', ...
        refId, numel(p.references));
end
ref = p.references{idx};

if ischar(note) || isstring(note)
    try
        note = jsondecode(char(note));
    catch
        error('bma:blind:note_invalid', 'note 不是合法 JSON。');
    end
end
if ~isstruct(note)
    error('bma:blind:note_invalid', 'note 必须是 JSON 对象。');
end

depth = lower(strtrim(char(getStr(note, 'depth', ''))));
if ~any(strcmp(depth, {'full_text', 'abstract_only', 'citation_only'}))
    error('bma:blind:note_invalid', ...
        'note.depth 必须是 full_text / abstract_only / citation_only 之一。');
end
claims = bma.blind.internal.asStructList(getField(note, 'claims', {}));
noModeling = getBool(note, 'no_modeling_content', false);
access = lower(strtrim(char(getStr(ref, 'access', ''))));
if strcmp(access, 'citation_only') && ~strcmp(depth, 'citation_only')
    error('bma:blind:note_invalid', ...
        ['参考文献 %s 只有题录（无可读文件），depth 必须是 citation_only。' ...
         '若你找到了全文文件，请用 bma_blind_check(action:"references") 追加。'], refId);
end
if strcmp(access, 'file') && strcmp(depth, 'citation_only')
    % Allowed only if the file is unreadable (scanned/no text); checked below.
end
if isempty(claims) && ~noModeling
    error('bma:blind:note_invalid', ...
        ['参考文献 %s 的笔记至少要有 1 条 claim（带逐字 quote），' ...
         '或显式声明 no_modeling_content=true 并给原因。'], refId);
end

claimKinds = {'mechanism', 'parameter', 'condition', 'method', 'negative', 'review', 'background'};
for k = 1:numel(claims)
    c = claims{k};
    if ~isstruct(c)
        error('bma:blind:note_invalid', 'claims(%d) 必须是对象。', k);
    end
    kind = lower(strtrim(char(getStr(c, 'kind', ''))));
    if ~any(strcmp(kind, claimKinds))
        error('bma:blind:note_invalid', ...
            'claims(%d).kind 必须是 %s。', k, strjoin(claimKinds, '/'));
    end
    if numel(strtrim(char(getStr(c, 'claim', '')))) < 15
        error('bma:blind:note_invalid', 'claims(%d).claim 太短（<15 字符）。', k);
    end
    if numel(strtrim(char(getStr(c, 'quote', '')))) < 6
        error('bma:blind:note_invalid', ...
            'claims(%d).quote 必须 ≥6 字符的逐字原文；不得转述。', k);
    end
end
if noModeling
    reason = strtrim(char(getStr(note, 'no_modeling_content_reason', '')));
    if numel(reason) < 80
        error('bma:blind:note_invalid', ...
            ['no_modeling_content=true 时必须给 no_modeling_content_reason（≥80 字符），' ...
             '说明为什么这篇文献对问题/目标没有建模价值。']);
    end
end
relevance = getField(note, 'relevance', struct());
if ~isstruct(relevance)
    error('bma:blind:note_invalid', 'note.relevance 必须是对象。');
end
questionLink = strtrim(char(getStr(relevance, 'question_link', '')));
if numel(questionLink) < 30
    error('bma:blind:note_invalid', ...
        'relevance.question_link 必须 ≥30 字符，说明该文献与主文献问题/目标的联系。');
end
modelingUse = lower(strtrim(char(getStr(relevance, 'modeling_use', ''))));
useKinds = {'mechanism', 'parameter', 'constraint', 'comparison', 'background', 'none'};
if ~any(strcmp(modelingUse, useKinds))
    error('bma:blind:note_invalid', ...
        'relevance.modeling_use 必须是 %s。', strjoin(useKinds, '/'));
end
if strcmp(modelingUse, 'none') && ~noModeling
    error('bma:blind:note_invalid', ...
        'modeling_use="none" 时必须同时 no_modeling_content=true 并给原因。');
end

% ---- verify quotes against the actual reference text ---------------------
textOut = bma.blind.internal.extractReferenceText(workDir, runDir, ref);
verification = struct('status', 'no_claims', 'quotes_checked', 0, ...
    'quotes_found', 0, 'text_path', textOut.text_path, ...
    'text_chars', textOut.text_chars, 'warnings', {textOut.warnings});
if ~isempty(claims)
    if textOut.available
        chk = bma.blind.internal.checkQuotes(textOut.text, claims);
        verification.quotes_checked = chk.checked;
        verification.quotes_found = chk.found;
        if chk.found < chk.checked
            verification.status = 'unverified';
            bad = {};
            for k = 1:numel(chk.results)
                if ~chk.results{k}.found
                    bad{end + 1} = clipQuote(chk.results{k}.quote); %#ok<AGROW>
                end
            end
            error('bma:blind:quote_not_found', ...
                ['参考文献 %s 有 %d/%d 条 quote 在原文中找不到：%s\n' ...
                 '请打开 %s 逐字复制原文（不要转述、不要跨列拼接），或把无法核实的说法写成 assumed 并在 note 中说明。' ...
                 '这不是形式检查：quote 必须能在原文定位。'], ...
                refId, chk.checked - chk.found, chk.checked, ...
                strjoin(bad, ' || '), textOut.text_path);
        end
        verification.status = 'verified';
    else
        if ~isempty(claims)
            % Without extractable full text, only text that literally appears in
            % the citation can be quoted; anything else would be unverifiable.
            chkCit = bma.blind.internal.checkQuotes( ...
                char(getStr(ref, 'citation', '')), claims);
            verification.quotes_checked = chkCit.checked;
            verification.quotes_found = chkCit.found;
            if chkCit.found < chkCit.checked
                bad = {};
                for k = 1:numel(chkCit.results)
                    if ~chkCit.results{k}.found
                        bad{end + 1} = clipQuote(chkCit.results{k}.quote); %#ok<AGROW>
                    end
                end
                error('bma:blind:quote_not_found', ...
                    ['参考文献 %s 没有可抽取的全文本，只能核对题录；以下 quote 不在题录中：%s\n' ...
                     '请改为 no_modeling_content=true（并说明原因），或只引用题录中逐字出现的文字。'], ...
                    refId, strjoin(bad, ' || '));
            end
            verification.status = 'verified_citation_only';
        elseif strcmp(depth, 'citation_only') || strcmp(access, 'citation_only')
            verification.status = 'not_applicable';
        end
    end
end

status = 'read';
limitedReason = strtrim(char(getStr(note, 'access_limited_reason', '')));
limitByText = strcmp(access, 'file') && ~textOut.available;
if strcmp(depth, 'citation_only') || strcmp(access, 'citation_only') || ...
        limitByText || strcmp(verification.status, 'not_applicable')
    status = 'limited';
end
if strcmp(status, 'limited')
    if numel(limitedReason) < 60
        error('bma:blind:note_invalid', ...
            ['参考文献 %s 只能记为 limited（题录/无全文）；必须给 access_limited_reason（≥60 字符），' ...
             '说明缺什么、对模型证据链的影响。'], refId);
    end
end

% ---- persist note + update protocol -------------------------------------
noteFile = fullfile(runDir, 'blind', 'notes', [char(getStr(ref, 'id', refId)) '.json']);
bma.util.ensureDir(fileparts(noteFile));
record = struct('schema', 'bma.blindRefNote.v1', 'reference', ref, ...
    'note', note, 'verification', verification, 'status', status, ...
    'read_at', bma.util.nowIso(), 'agent_version', agentVersion());
bma.util.writeJsonAtomic(noteFile, record);

ref.status = status;
ref.depth = depth;
ref.verified = logical(strcmp(verification.status, 'verified'));
ref.note_path = bma.util.relPath(workDir, noteFile);
ref.text_path = textOut.text_path;
ref.text_chars = textOut.text_chars;
ref.read_at = record.read_at;
ref.access_limited_reason = limitedReason;
ref.no_modeling_content = logical(noModeling);
ref.claims_count = numel(claims);
ref.quotes_verified = double(verification.quotes_found);
ref.note_status = verification.status;
p.references{idx} = ref;
p.coverage = bma.blind.internal.computeCoverage(p.references);
p.warnings{end + 1} = sprintf('参考文献 %s 记录完成（%s/%s）。', refId, ...
    status, verification.status);
bma.blind.internal.saveProtocol(runDir, p);

r = struct();
r.ok = true;
r.reference_id = char(getStr(ref, 'id', refId));
r.status = status;
r.depth = depth;
r.verification = verification;
r.coverage = p.coverage;
r.note_path = ref.note_path;
r.text_path = textOut.text_path;
r.remaining_ids = remainingIds(p.references);
r.warnings = textOut.warnings;
r.next_hint = nextHint(p.coverage);
end

% ---------------------------------------------------------------------------
function ids = remainingIds(refs)
ids = {};
for k = 1:numel(refs)
    st = lower(strtrim(char(getStr(refs{k}, 'status', 'pending'))));
    if ~strcmp(st, 'read') && ~strcmp(st, 'limited')
        ids{end + 1} = char(getStr(refs{k}, 'id', sprintf('R%d', k))); %#ok<AGROW>
    end
end
end

function h = nextHint(cov)
if cov.total == 0
    h = '还没有参考文献：先 bma_blind_check(action:"references") 追加全部参考文献。';
elseif cov.read < cov.total
    h = sprintf('还需处理 %d 篇参考文献（read %d/%d）。', cov.total - cov.read, cov.read, cov.total);
else
    h = '全部参考文献已登记；进入建模与自检（bma_blind_check action:"round"）。';
end
end

function q = clipQuote(q)
q = regexprep(char(q), '\s+', ' ');
if numel(q) > 120
    q = [q(1:117) '...'];
end
end

function v = agentVersion()
v = '';
try
    ver = bma.version();
    v = ver.agent_version;
catch
end
end

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

function v = getField(s, f, d)
if isstruct(s) && isfield(s, f)
    v = s.(f);
else
    v = d;
end
end
