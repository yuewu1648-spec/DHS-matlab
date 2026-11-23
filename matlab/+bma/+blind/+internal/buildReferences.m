function [refs, warnings] = buildReferences(workDir, runDir, primaryAbs, primarySha, opts)
%BUILDREFERENCES Build the reference inventory for a blind-modeling run.
%   [refs, warnings] = bma.blind.internal.buildReferences(workDir, runDir, ...
%       primaryAbs, primarySha, opts)
%
%   Sources (any combination):
%     opts.references_dir   folder scanned recursively for supported files
%     opts.references_json  JSON array (or path to JSON) of strings or
%                           {citation, path?, url?, doi?} objects
%     opts.bib_citations    cellstr parsed from the primary bibliography
%
%   Every entry is a full struct so jsonencode produces a uniform array. The
%   primary paper is excluded by canonical path AND by SHA-256, so an accidental
%   copy of the primary cannot slip into the reference set.
if nargin < 5 || isempty(opts)
    opts = struct();
end
refs = {};
warnings = {};
maxRefs = 300;
if isfield(opts, 'max_references') && ~isempty(opts.max_references)
    maxRefs = double(opts.max_references);
end
seenKeys = {};
seenPaths = {};
primaryCanon = lower(bma.blind.internal.canonicalPath(primaryAbs));
if ~isempty(primarySha)
    seenKeys{end + 1} = ['sha:' lower(primarySha)]; %#ok<AGROW>
end
if ~isempty(primaryAbs)
    seenPaths{end + 1} = primaryCanon; %#ok<AGROW>
end

if isfield(opts, 'references_dir') && ~isempty(opts.references_dir)
    root = bma.util.absPath(workDir, char(opts.references_dir));
    if ~isfolder(root)
        error('bma:blind:references_dir_not_found', ...
            'references_dir 不存在：%s', root);
    end
    files = listSupportedFiles(root);
    if isempty(files)
        warnings{end + 1} = sprintf('references_dir 中没有受支持的文献文件：%s', root); %#ok<AGROW>
    end
    for k = 1:numel(files)
        addFile(files{k}, 'dir', '');
    end
end

if isfield(opts, 'references_json') && ~isempty(opts.references_json)
    items = loadReferenceItems(workDir, opts.references_json);
    for k = 1:numel(items)
        addItem(items{k});
    end
end

if isfield(opts, 'bib_citations') && ~isempty(opts.bib_citations)
    cites = opts.bib_citations;
    if ischar(cites)
        cites = {cites};
    end
    for k = 1:numel(cites)
        addCitation(char(cites{k}));
    end
end

if numel(refs) > maxRefs
    error('bma:blind:too_many_references', ...
        ['参考文献 %d 篇，超过上限 %d。全部参考文献都必须读，不能截断；' ...
         '请提高 max_references 或拆分任务。'], numel(refs), maxRefs);
end

% Stable ids after all sources are merged.
for k = 1:numel(refs)
    refs{k}.id = sprintf('R%d', k);
end

    % -----------------------------------------------------------------------
    function addFile(absPath, addedFrom, citationOverride)
        absPath = bma.blind.internal.canonicalPath(absPath);
        key = ['path:' lower(absPath)];
        if any(strcmp(seenPaths, lower(absPath))) || any(strcmp(seenKeys, key))
            warnings{end + 1} = sprintf('跳过重复/主文献文件：%s', absPath); %#ok<AGROW>
            return
        end
        sha = bma.util.sha256File(absPath);
        hkey = '';
        if ~isempty(sha)
            hkey = ['sha:' lower(sha)];
            if any(strcmp(seenKeys, hkey))
                warnings{end + 1} = sprintf('跳过内容重复的文献（SHA-256 相同）：%s', absPath); %#ok<AGROW>
                return
            end
        end
        d = dir(absPath);
        ref = makeRef();
        if isempty(citationOverride)
            [~, base, ext] = fileparts(absPath);
            ref.citation = [base ext];
        else
            ref.citation = char(citationOverride);
        end
        ref.path = bma.util.relPath(workDir, absPath);
        ref.abs_path = absPath;
        ref.bytes = d(1).bytes;
        ref.sha256 = sha;
        ref.access = 'file';
        ref.added_from = addedFrom;
        ref.source = 'file';
        refs{end + 1} = ref;
        seenKeys{end + 1} = key; %#ok<AGROW>
        seenPaths{end + 1} = lower(absPath); %#ok<AGROW>
        if ~isempty(hkey)
            seenKeys{end + 1} = hkey; %#ok<AGROW>
        end
    end

    function addItem(item)
        if ischar(item) || isstring(item)
            addCitation(char(item));
            return
        end
        if ~isstruct(item)
            warnings{end + 1} = sprintf('忽略无法识别的参考文献条目：%s', class(item)); %#ok<AGROW>
            return
        end
        citation = getStr(item, 'citation', '');
        p = getStr(item, 'path', '');
        if ~isempty(p)
            absPath = bma.util.absPath(workDir, p);
            if isfile(absPath)
                addFile(absPath, 'list', citation);
                return
            end
            warnings{end + 1} = sprintf('参考文献路径不存在，按题录登记：%s', absPath); %#ok<AGROW>
        end
        if isempty(citation)
            citation = getStr(item, 'title', '');
        end
        if isempty(citation)
            warnings{end + 1} = '忽略既无 citation/title 也无 path 的参考文献条目。'; %#ok<AGROW>
            return
        end
        key = ['cit:' lower(regexprep(citation, '\s+', ' '))];
        if any(strcmp(seenKeys, key))
            warnings{end + 1} = sprintf('跳过重复题录：%s', citation); %#ok<AGROW>
            return
        end
        ref = makeRef();
        ref.citation = citation;
        ref.url = getStr(item, 'url', '');
        ref.doi = getStr(item, 'doi', '');
        ref.access = 'citation_only';
        ref.added_from = 'list';
        ref.source = 'list';
        refs{end + 1} = ref;
        seenKeys{end + 1} = key; %#ok<AGROW>
    end

    function addCitation(citation)
        citation = strtrim(regexprep(char(citation), '\s+', ' '));
        if isempty(citation)
            return
        end
        key = ['cit:' lower(citation)];
        if any(strcmp(seenKeys, key))
            return
        end
        ref = makeRef();
        ref.citation = citation;
        ref.access = 'citation_only';
        ref.added_from = 'bibliography';
        ref.source = 'bibliography';
        refs{end + 1} = ref;
        seenKeys{end + 1} = key; %#ok<AGROW>
    end
end

% ---------------------------------------------------------------------------
function ref = makeRef()
ref = struct('id', '', 'citation', '', 'path', '', 'abs_path', '', ...
    'url', '', 'doi', '', 'bytes', 0, 'sha256', '', 'format', '', ...
    'access', '', 'status', 'pending', 'note_path', '', 'text_path', '', ...
    'text_chars', 0, 'depth', '', 'verified', false, 'read_at', '', ...
    'access_limited_reason', '', 'added_from', '', 'source', '', ...
    'no_modeling_content', false, 'claims_count', 0, ...
    'quotes_verified', 0, 'note_status', '');
end

function files = listSupportedFiles(root)
formats = bma.io.supportedFormats();
items = dir(fullfile(root, '**', '*'));
items = items(~[items.isdir]);
files = {};
for k = 1:numel(items)
    [~, ~, ext] = fileparts(items(k).name);
    if any(strcmpi(ext, formats))
        files{end + 1} = fullfile(items(k).folder, items(k).name); %#ok<AGROW>
    end
end
files = sort(files);
end

function items = loadReferenceItems(workDir, raw)
items = {};
if ischar(raw) || isstring(raw)
    p = bma.util.absPath(workDir, char(raw));
    if ~isfile(p)
        error('bma:blind:references_json_invalid', ...
            'references_json 既不是 JSON 数组/对象，也不是存在的 JSON 文件：%s', char(raw));
    end
    raw = bma.util.readJson(p);
end
if isempty(raw)
    return
end
if iscell(raw)
    items = raw(:)';
elseif isstruct(raw)
    items = num2cell(raw(:)');
elseif ischar(raw) || isstring(raw)
    items = {char(raw)};
else
    error('bma:blind:references_json_invalid', ...
        'references_json 必须是数组、对象或 JSON 文件路径。');
end
end

function s = getStr(s0, f, d)
if isstruct(s0) && isfield(s0, f) && ~isempty(s0.(f))
    s = char(string(s0.(f)));
else
    s = d;
end
end
