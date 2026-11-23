function p = fillProtocolDefaults(p)
%FILLPROTOCOLDEFAULTS Normalize a decoded protocol document.
%   Guarantees the fields consumed by check/note/reveal exist and that every
%   JSON array is a cell array (appendable) even when jsondecode produced a
%   struct array or [].
if ~isstruct(p)
    p = struct();
end
if ~isfield(p, 'schema') || isempty(p.schema)
    p.schema = 'bma.blindProtocol.v1';
end
if ~isfield(p, 'status') || isempty(p.status)
    p.status = 'sealed';
end
if ~isfield(p, 'created_at') || isempty(p.created_at)
    p.created_at = bma.util.nowIso();
end
if ~isfield(p, 'warnings')
    p.warnings = {};
end
p.warnings = asCellstr(p.warnings);

if ~isfield(p, 'primary') || ~isstruct(p.primary)
    p.primary = struct();
end
if ~isfield(p.primary, 'abstract') || ~isstruct(p.primary.abstract)
    p.primary.abstract = struct('text', '', 'source', '', 'section_id', '', ...
        'confidence', '', 'chars', 0);
end
if ~isfield(p.primary, 'sha256')
    p.primary.sha256 = '';
end
if ~isfield(p.primary, 'source_path')
    p.primary.source_path = '';
end

if ~isfield(p, 'guard') || ~isstruct(p.guard)
    p.guard = struct();
end
if ~isfield(p.guard, 'sealed')
    p.guard.sealed = strcmpi(char(p.status), 'sealed');
end
if ~isfield(p.guard, 'ingest_blocked')
    p.guard.ingest_blocked = logical(p.guard.sealed);
end

if ~isfield(p, 'options') || ~isstruct(p.options)
    p.options = struct();
end
if ~isfield(p.options, 'min_rounds') || isempty(p.options.min_rounds)
    p.options.min_rounds = 3;
end
if ~isfield(p.options, 'budget_seconds') || isempty(p.options.budget_seconds)
    p.options.budget_seconds = 0;
end

if ~isfield(p, 'question') || ~isstruct(p.question)
    p.question = struct('question', '', 'objective', '', ...
        'success_criteria', {{}}, 'out_of_scope', {{}}, 'recorded_at', '');
end
if ~isfield(p.question, 'success_criteria')
    p.question.success_criteria = {};
end
p.question.success_criteria = asCellstr(p.question.success_criteria);
if ~isfield(p.question, 'out_of_scope')
    p.question.out_of_scope = {};
end
p.question.out_of_scope = asCellstr(p.question.out_of_scope);

if ~isfield(p, 'references')
    p.references = {};
end
p.references = bma.blind.internal.asStructList(p.references);

if ~isfield(p, 'coverage') || ~isstruct(p.coverage)
    p.coverage = struct();
end

if ~isfield(p, 'model') || ~isstruct(p.model)
    p.model = struct();
end
if ~isfield(p.model, 'frozen')
    p.model.frozen = false;
end
if ~isfield(p.model, 'versions')
    p.model.versions = {};
end
p.model.versions = bma.blind.internal.asStructList(p.model.versions);
if ~isfield(p.model, 'current') || isempty(p.model.current)
    p.model.current = 0;
end

if ~isfield(p, 'selfcheck') || ~isstruct(p.selfcheck)
    p.selfcheck = struct();
end
if ~isfield(p.selfcheck, 'rounds')
    p.selfcheck.rounds = {};
end
p.selfcheck.rounds = bma.blind.internal.asStructList(p.selfcheck.rounds);
if ~isfield(p.selfcheck, 'issues')
    p.selfcheck.issues = {};
end
p.selfcheck.issues = bma.blind.internal.asStructList(p.selfcheck.issues);
if ~isfield(p.selfcheck, 'stop') || ~isstruct(p.selfcheck.stop)
    p.selfcheck.stop = struct();
end
if ~isfield(p.selfcheck.stop, 'met')
    p.selfcheck.stop.met = false;
end
if ~isfield(p.selfcheck.stop, 'reasons')
    p.selfcheck.stop.reasons = {};
end
p.selfcheck.stop.reasons = asCellstr(p.selfcheck.stop.reasons);
if ~isfield(p.selfcheck, 'started_at') || isempty(p.selfcheck.started_at)
    p.selfcheck.started_at = bma.util.nowIso();
end
if ~isfield(p.selfcheck, 'rounds_completed')
    p.selfcheck.rounds_completed = numel(p.selfcheck.rounds);
end

if ~isfield(p, 'reveal')
    p.reveal = [];
end
end

% ---------------------------------------------------------------------------
function c = asCellstr(v)
if isempty(v)
    c = {};
elseif iscell(v)
    c = cellfun(@char, v(:)', 'UniformOutput', false);
elseif isstring(v)
    c = cellstr(v(:)');
elseif ischar(v)
    c = {char(v)};
else
    c = {char(string(v))};
end
end
