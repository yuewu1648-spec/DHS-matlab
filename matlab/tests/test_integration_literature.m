% test_integration_literature.m
% =========================================================================
% Integration test: literature ingestion + knowledge base + run management.
%
% For every synthetic fixture in tests/fixtures/literature (three papers,
% five formats each: .md .txt .html .docx .pdf) this test:
%   * calls literature.ingest through bma.server.dispatch,
%   * asserts the persisted artifact set (text/sections/numbers/tables),
%   * checks that the section structure contains the expected journal
%     sections (Abstract/Introduction/Methods/Results/Discussion/References),
%   * cross-checks extracted numbers against expected_facts.json,
%   * verifies deterministic doc ids (same content -> same doc_id).
% It also smoke-tests the knowledge base (kb.list/search/get) and run
% management (run.init/list/info).
%
% Contract: docs/DESIGN.md sections 4.4, 5.8, 5.9, 5.10, 9, 10.4.
% Owner: qa-acceptance. Fixture ground truth: tests/fixtures/README.md.
% =========================================================================
qaRunLiterature();

% -------------------------------------------------------------------------
function qaRunLiterature()
projRoot = bma.util.projectRoot();
workDir = fullfile(projRoot, '.qa', 'test-artifacts', char(bma.util.newId('it-lit')));
bma.util.ensureDir(workDir);
fprintf('[literature] project root : %s\n', projRoot);
fprintf('[literature] work dir     : %s\n', workDir);
req = struct('schema', 'bma.rpc.v1', 'id', 'qa-literature', 'work_dir', workDir);

% ---- supported formats (module-level contract, DESIGN 5.8) --------------
fmts = bma.io.supportedFormats();
fmts = lower(qaCellstr(fmts));
for f = {'pdf', 'docx', 'txt', 'md', 'html'}
    qaAssert(any(contains(fmts, f{1})), ...
        sprintf('bma.io.supportedFormats() does not advertise %s (got: %s)', ...
        f{1}, strjoin(fmts, ',')));
end
fprintf('[literature] supported formats: %s\n', strjoin(fmts, ','));

fixtureIds = {'enzyme_kinetics', 'gene_oscillator', 'epidemic_sir'};
formatExts = {'md', 'txt', 'html', 'docx', 'pdf'};
run1 = qaDispatch(req, 'run.init', struct('name', ''));
runDir = char(run1.run_dir);
summary = struct('fixtures', {{}}, 'work_dir', workDir);

for fi = 1:numel(fixtureIds)
    fid = fixtureIds{fi};
    fixtureDir = fullfile(projRoot, 'tests', 'fixtures', 'literature', fid);
    qaAssert(isfolder(fixtureDir), sprintf('[%s] fixture directory missing: %s', fid, fixtureDir));
    expFile = fullfile(fixtureDir, 'expected_facts.json');
    qaAssert(isfile(expFile), sprintf('[%s] expected_facts.json missing', fid));
    expectations = bma.util.readJson(expFile);

    fprintf('\n[literature] ===== fixture: %s =====\n', fid);
    for k = 1:numel(formatExts)
        ext = formatExts{k};
        src = fullfile(fixtureDir, ['paper.' ext]);
        qaAssert(isfile(src), sprintf('[%s] fixture file missing: paper.%s', fid, ext));
        fprintf('[literature]   ingest paper.%s (%d bytes)\n', ext, qaFileSize(src));
        t0 = tic;
        doc = qaDispatch(req, 'literature.ingest', struct('path', src, 'run_dir', runDir));
        secs = toc(t0);

        % --- result contract (DESIGN 4.4 literature.ingest) -------------
        qaAssert(isfield(doc, 'doc_id') && ~isempty(char(doc.doc_id)), ...
            sprintf('[%s.%s] no doc_id', fid, ext));
        qaAssert(isfield(doc, 'char_count') && double(doc.char_count) > 2000, ...
            sprintf('[%s.%s] char_count too small (%g)', fid, ext, qaNum(doc, 'char_count', -1)));
        qaAssert(isfield(doc, 'sections') && numel(doc.sections) >= 5, ...
            sprintf('[%s.%s] only %d sections extracted', fid, ext, qaNumel(doc, 'sections')));
        qaAssert(isfield(doc, 'numbers') && numel(doc.numbers) >= 5, ...
            sprintf('[%s.%s] only %d numbers extracted', fid, ext, qaNumel(doc, 'numbers')));
        artFields = {'text_path', 'sections_path', 'numbers_path'};
        for ai = 1:numel(artFields)
            qaAssert(isfield(doc, artFields{ai}) && qaPathExists(workDir, doc.(artFields{ai})), ...
                sprintf('[%s.%s] missing artifact %s', fid, ext, artFields{ai}));
        end
        numPersisted = bma.util.readJson(bma.util.absPath(workDir, doc.numbers_path));
        qaAssert(numel(numPersisted) >= 5, ...
            sprintf('[%s.%s] persisted numbers.json has %d entries', fid, ext, numel(numPersisted)));

        % --- section structure ------------------------------------------
        sectionsList = qaItems(doc.sections);
        numbersList = qaItems(doc.numbers);
        headings = qaSectionHeadings(sectionsList);
        joined = lower(strjoin(headings, ' | '));
        sectionTokens = {'abstract', 'introduction', 'method', 'result', 'discussion', 'reference'};
        for si = 1:numel(sectionTokens)
            qaAssertContains(tokensFound(joined, sectionTokens{si}), ...
                sprintf('[%s.%s] expected journal section "%s" not found (headings: %s)', ...
                fid, ext, sectionTokens{si}, strjoin(headings, ' | ')));
        end
        qaAssert(isfield(doc, 'char_count') && numel(headings) >= 5, ...
            sprintf('[%s.%s] headings not usable', fid, ext));
        % every section must carry location metadata
        for si = 1:numel(sectionsList)
            s = sectionsList{si};
            qaAssert(isfield(s, 'id') && isfield(s, 'heading') && isfield(s, 'text'), ...
                sprintf('[%s.%s] section %d is missing id/heading/text', fid, ext, si));
            qaAssert(isfield(s, 'char_start') && double(s.char_start) >= 0, ...
                sprintf('[%s.%s] section %d has no char_start', fid, ext, si));
        end

        % --- extracted numbers vs expected facts -----------------------
        % NOTE: jsondecode returns a cell array when array elements carry
        % different fields (our facts have optional keys), so normalise.
        expFacts = qaItems(expectations.facts);
        nChecked = 0; nFound = 0; missing = {};
        for pj = 1:numel(expFacts)
            fact = expFacts{pj};
            if ~ismember(qaStr(fact, 'role', ''), ...
                    {'parameter', 'initial', 'observation', 'derived', 'derived_parameter'})
                continue
            end
            if ~isfield(fact, 'value'), continue; end
            tv = double(fact.value);
            if ~isfinite(tv), continue; end
            nChecked = nChecked + 1;
            tol = qaFactTol(fact, tv);
            if qaNumbersContain(numbersList, tv, tol)
                nFound = nFound + 1;
            else
                missing{end+1} = qaStr(fact, 'id', '?'); %#ok<AGROW>
            end
        end
        qaAssert(nChecked >= 6, ...
            sprintf('[%s.%s] expected facts JSON has too few numeric facts (%d)', fid, ext, nChecked));
        foundFrac = nFound / nChecked;
        if foundFrac < 0.80
            fprintf('[literature]     WARNING: %s.%s only %d/%d expected values found (missing: %s)\n', ...
                fid, ext, nFound, nChecked, strjoin(missing, ', '));
        end
        qaAssert(foundFrac >= 0.60, ...
            sprintf('[%s.%s] number extraction recovered only %d/%d expected values (missing: %s)', ...
            fid, ext, nFound, nChecked, strjoin(missing, ', ')));

        % units should be attached to a fair share of numbers
        nNum = numel(numbersList);
        nUnit = 0;
        for nj = 1:nNum
            nu = numbersList{nj};
            if isfield(nu, 'unit') && ~isempty(strtrim(char(nu.unit)))
                nUnit = nUnit + 1;
            end
        end
        qaAssert(nUnit >= 0.25 * nNum, ...
            sprintf('[%s.%s] only %d/%d extracted numbers carry a unit', fid, ext, nUnit, nNum));

        % tables: markdown/html/docx render the paper tables; pdf may not
        nTables = qaNumel(doc, 'tables');
        hasTables = isfield(doc, 'tables') && nTables > 0;
        if any(strcmp(ext, {'md', 'html', 'docx'}))
            qaAssert(hasTables, sprintf('[%s.%s] no tables extracted though the paper has tables', fid, ext));
        end

        % deterministic doc id (same content -> same id)
        if strcmp(ext, 'md')
            doc2 = qaDispatch(req, 'literature.ingest', struct('path', src, 'run_dir', runDir));
            qaAssert(strcmpi(char(doc.doc_id), char(doc2.doc_id)), ...
                sprintf('[%s] doc_id is not deterministic for identical content', fid));
            firstDocId = char(doc.doc_id);
            summary.fixtures{end+1} = struct('fixture', fid, 'format', ext, ...
                'doc_id', firstDocId, 'sections', numel(sectionsList), ...
                'numbers', nNum, 'tables', nTables, 'seconds', secs); %#ok<AGROW>
        else
            summary.fixtures{end+1} = struct('fixture', fid, 'format', ext, ...
                'doc_id', char(doc.doc_id), 'sections', numel(sectionsList), ...
                'numbers', nNum, 'tables', nTables, 'seconds', secs); %#ok<AGROW>
        end
    end
end

% ---- knowledge base ------------------------------------------------------
fprintf('\n[literature] ===== knowledge base =====\n');
kl = qaDispatch(req, 'kb.list', struct('limit', 200));
qaAssert(isfield(kl, 'items') && numel(kl.items) >= 10, ...
    sprintf('kb.list returned %d items; the KB requires >= 12 archetypes/principles in total', ...
    qaNumelOr(kl, 'items')));
qaAssert(isfield(kl, 'total') && double(kl.total) >= 10, 'kb.list total is too small');
items = qaItems(kl.items);
firstId = char(items{1}.id);
for ii = 1:numel(items)
    it = items{ii};
    qaAssert(isfield(it, 'id') && isfield(it, 'type') && isfield(it, 'name'), ...
        'kb.list item is missing id/type/name');
end

queries = {'enzyme kinetics', 'negative feedback oscillation', 'SIR epidemic'};
for qi = 1:numel(queries)
    q = queries{qi};
    hits = qaDispatch(req, 'kb.search', struct('query', q, 'limit', 10));
    qaAssert(isfield(hits, 'hits') && numel(hits.hits) > 0, ...
        sprintf('kb.search("%s") returned no hits', q));
    hitItems = qaItems(hits.hits);
    top = hitItems{1};
    qaAssert(isfield(top, 'id') && isfield(top, 'score'), ...
        sprintf('kb.search("%s") hit is missing id/score', q));
    qaAssert(isfield(top, 'matched_terms') && ~isempty(top.matched_terms), ...
        sprintf('kb.search("%s") hit has no matched_terms', q));
    qaAssert(isfield(top, 'path') && qaPathExists(projRoot, top.path), ...
        sprintf('kb.search("%s") hit path does not exist', q));
    fprintf('[literature]   kb.search "%s" -> %d hits, top=%s (score %.3f)\n', ...
        q, numel(hits.hits), char(top.id), double(top.score));
end
kget = qaDispatch(req, 'kb.get', struct('id', firstId));
qaAssert(isfield(kget, 'item') && isstruct(kget.item), 'kb.get returned no item');
qaAssert(isfield(kget, 'path') && qaPathExists(projRoot, kget.path), ...
    'kb.get returned no readable path');
qaAssert(isfield(kget.item, 'name'), 'kb.get item has no name');

% ---- run management (DESIGN 5.9 / 7) ------------------------------------
fprintf('\n[literature] ===== run management =====\n');
nav = qaDispatch(req, 'run.init', struct('name', 'qa-fixed-run'));
navDir = char(nav.run_dir);
qaAssert(~isempty(strfind(navDir, 'qa-fixed-run')), ...
    sprintf('run.init did not honour the requested name (%s)', navDir));
nav2 = qaDispatch(req, 'run.init', struct('name', 'qa-fixed-run'));
qaAssert(strcmp(char(nav2.run_dir), navDir), 'run.init is not idempotent for the same name');
rl = qaDispatch(req, 'run.list', struct());
qaAssert(isfield(rl, 'runs') && numel(rl.runs) >= 2, ...
    sprintf('run.list returned %d runs; expected >= 2', qaNumelOr(rl, 'runs')));
rInfo = qaDispatch(req, 'run.info', struct('run_dir', navDir));
qaAssert(isfield(rInfo, 'exists') && logical(rInfo.exists), 'run.info reports the run does not exist');

summary.work_dir = workDir;
bma.util.writeJsonAtomic(fullfile(workDir, 'qa_literature_summary.json'), summary);
fprintf('\n[literature] PASS: %d ingestions across %d fixtures; artifacts: %s\n', ...
    numel(summary.fixtures), numel(fixtureIds), workDir);
end

% =========================================================================
% helpers
% =========================================================================
function r = qaDispatch(req, method, params)
r = bma.server.dispatch(method, params, req);
end

function c = qaItems(v)
% Normalize a JSON-decoded array (struct array or cell array) to a cell row.
if iscell(v)
    c = v(:)';
elseif isstruct(v)
    c = num2cell(v);
    c = c(:)';
elseif isempty(v)
    c = {};
else
    c = {v};
end
end

function h = qaSectionHeadings(sections)
h = cell(1, numel(sections));
for k = 1:numel(sections)
    if isfield(sections{k}, 'heading')
        h{k} = qaStr(sections{k}, 'heading', '');
    else
        h{k} = '';
    end
end
end

function tf = tokensFound(joinedLower, token)
tf = contains(joinedLower, lower(token));
end

function tf = qaNumbersContain(numbers, value, tol)
tf = false;
for k = 1:numel(numbers)
    n = numbers{k};
    if ~isfield(n, 'value'), continue; end
    v = double(n.value);
    if ~isfinite(v), continue; end
    if abs(v - value) <= tol
        tf = true; return
    end
end
end

function tol = qaFactTol(fact, value)
tol = 1e-3;
if isfield(fact, 'tolerance')
    t = fact.tolerance;
    if isfield(t, 'relative'), tol = max(tol, double(t.relative) * abs(value)); end
    if isfield(t, 'absolute'), tol = max(tol, double(t.absolute)); end
end
tol = max(tol, 0.02 * max(abs(value), 1));
end

function s = qaStr(st, field, fallback)
s = fallback;
if isstruct(st) && isfield(st, field) && ~isempty(st.(field))
    v = st.(field);
    if ischar(v), s = v;
    elseif isstring(v), s = char(v);
    elseif iscell(v) && numel(v) == 1, s = qaStr(v{1}, field, fallback);
    else, s = char(string(v)); end
end
end

function n = qaNum(st, field, fallback)
n = fallback;
if isstruct(st) && isfield(st, field) && ~isempty(st.(field))
    n = double(st.(field));
end
end

function n = qaNumel(st, field)
n = qaNumelOr(st, field);
end

function n = qaNumelOr(st, field)
n = 0;
if isstruct(st) && isfield(st, field)
    v = st.(field);
    if iscell(v) || isnumeric(v) || isstruct(v)
        n = numel(v);
    end
end
end

function c = qaCellstr(v)
if ischar(v)
    c = {v};
elseif isstring(v)
    c = cellstr(v(:)');
elseif iscell(v)
    c = cellfun(@(x) char(string(x)), v(:)', 'UniformOutput', false);
else
    c = {num2str(v)};
end
c = c(:)';
end

function n = qaFileSize(p)
d = dir(p);
if isempty(d), n = 0; else, n = d(1).bytes; end
end

function tf = qaPathExists(base, rel)
p = bma.util.absPath(base, rel);
tf = isfile(p) || isfolder(p);
end

function qaAssert(cond, msg)
if ~logical(cond)
    error('qa:assert:failed', '%s', msg);
end
end

function qaAssertContains(cond, msg)
qaAssert(cond, msg);
end
