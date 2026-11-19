function start(workDir, token, opts)
%START Run the BioModel-MATLAB JSON-RPC server loop (blocking).
%   bma.server.start(workDir, token)
%   bma.server.start(workDir, token, struct('maxIdleSeconds', 0))
%
% The server communicates with the Node bridge through files:
%   <workDir>/.bma/server/{inbox,outbox,done}/<request-id>.json
% and maintains <workDir>/.bma/server/state.json with a heartbeat. It never
% opens a network port, which keeps it reliable under Windows sandboxes.
%
% This function blocks until a `server.stop` call, a stop flag file appears,
% or the optional idle timeout expires. It is normally launched with:
%   matlab -batch "addpath('<project>/matlab'); bma.server.start('<workDir>','<token>')"

if nargin < 2 || isempty(token)
    error('bma:server:start', 'A non-empty token string is required.');
end
if nargin < 3 || isempty(opts)
    opts = struct();
end
workDir = normalizeWorkDir(workDir);
token = char(token);
root = bma.util.projectRoot();

% A control server keeps the lightweight RPC loop responsive; heavy analysis/
% fit calls run in a second server process with its own IPC directory. The
% subdirectory must stay under <workDir>/.bma so a worker can never escape the
% session workspace.
serverSubdir = 'server';
if isfield(opts, 'serverSubdir') && ~isempty(opts.serverSubdir)
    serverSubdir = char(opts.serverSubdir);
end
serverSubdir = regexprep(strtrim(serverSubdir), '/', filesep);
if isempty(serverSubdir) || ~isempty(regexp(serverSubdir, '^([A-Za-z]:[\\/]|\\\\|/)', 'once')) ...
        || any(strcmp(regexp(serverSubdir, '[\\/]', 'split'), '..'))
    error('bma:server:badSubdir', 'serverSubdir 必须是 .bma 下的相对目录，实际为 "%s"。', serverSubdir);
end
srv = fullfile(workDir, '.bma', serverSubdir);
inbox = fullfile(srv, 'inbox');
outbox = fullfile(srv, 'outbox');
done = fullfile(srv, 'done');
claims = fullfile(srv, 'claims');
bma.util.ensureDir(inbox);
bma.util.ensureDir(outbox);
bma.util.ensureDir(done);
bma.util.ensureDir(claims);
% A new server process means any previous RPC exchange belongs to a dead
% session. Drop stale inbox/outbox/claims files and the cancel flag so a stale
% response or orphaned request can never stall the next call (ISS-02).
cleanStale(fullfile(srv, 'inbox'), '*.json');
cleanStale(fullfile(srv, 'outbox'), '*.json');
cleanStale(claims, '*.json');
cleanStale(done, '*.json');
if exist(fullfile(srv, 'cancel.flag'), 'file')
    delete(fullfile(srv, 'cancel.flag'));
end
stateFile = fullfile(srv, 'state.json');
stopFlag = fullfile(srv, 'stop.flag');
logFile = fullfile(srv, 'server.log');
if exist(stopFlag, 'file')
    delete(stopFlag);
end

% Refuse a second live server on the same work directory. mkdir is atomic on
% Windows, which a read-check-write on state.json is not.
lockDir = fullfile(srv, 'server.lock');
if isfolder(lockDir)
    ownerFile = fullfile(lockDir, 'owner.txt');
    ownerPid = 0;
    if isfile(ownerFile)
        try
            ownerPid = str2double(strtrim(bma.util.readText(ownerFile)));
        catch
        end
    end
    if ownerPid > 0 && isAlive(ownerPid)
        error('bma:server:duplicate', ...
            'Another server (pid %d) is already live for %s', ownerPid, workDir);
    end
    rmdir(lockDir, 's');
end
[lockOk, lockMsg] = mkdir(lockDir);
if ~lockOk
    error('bma:server:duplicate', ...
        'Cannot acquire server lock %s (%s)', lockDir, lockMsg);
end
bma.util.writeTextAtomic(fullfile(lockDir, 'owner.txt'), sprintf('%d', feature('getpid')));

state = struct();
state.schema = 'bma.rpc.v1';
state.pid = feature('getpid');
state.token = token;
state.work_dir = workDir;
state.project_root = root;
state.server_subdir = serverSubdir;
state.matlab_version = version;
if ~isempty(which('bma.version'))
    try
        av = bma.version();
        state.agent_version = av.agent_version;
        state.bundle_version = av.bundle_version;
        state.spec_schema = av.spec_schema;
    catch
    end
end
state.started_at = bma.util.nowIso();
state.heartbeat = state.started_at;
state.methods = dispatchableMethods();
bma.util.writeJsonAtomic(stateFile, state);
logFid = fopen(logFile, 'a', 'n', 'UTF-8');
if logFid < 0
    error('bma:server:start', 'Cannot open server log: %s', logFile);
end
cleaner = onCleanup(@() cleanupServer(stateFile, logFid, state, lockDir)); %#ok<NASGU>
% Any relative file a MATLAB function writes must land in the session
% workspace, never in the agent installation checkout.
try
    cd(workDir);
catch
end
logLine(logFid, sprintf('server start pid=%d workDir=%s matlab=%s', ...
    state.pid, workDir, version));

lastBeat = tic;
lastActivity = tic;
maxIdle = inf;
if isfield(opts, 'maxIdleSeconds') && ~isempty(opts.maxIdleSeconds)
    requestedIdle = double(opts.maxIdleSeconds);
    % 0 / negative means "no idle timeout" (the E2E launcher and long-lived
    % sessions pass 0); only a positive value enables the idle exit.
    if requestedIdle > 0
        maxIdle = requestedIdle;
    end
end
running = true;
while running
    if exist(stopFlag, 'file')
        delete(stopFlag);
        logLine(logFid, 'stop flag observed');
        break
    end
    if toc(lastBeat) >= 1.0
        state.heartbeat = bma.util.nowIso();
        bma.util.writeJsonAtomic(stateFile, state);
        lastBeat = tic;
    end
    if toc(lastActivity) > maxIdle
        logLine(logFid, 'idle timeout reached');
        break
    end
    reqs = dir(fullfile(inbox, '*.json'));
    if isempty(reqs)
        pause(0.04);
        continue
    end
    names = sort({reqs.name});
    for k = 1:numel(names)
        reqFile = fullfile(inbox, names{k});
        if ~isfile(reqFile)
            continue
        end
        lastActivity = tic;
        claimFile = fullfile(claims, names{k});
        [claimed, ~] = movefile(reqFile, claimFile);
        if ~claimed
            continue   % another server/worker already took this request
        end
        % Publish queue/current-call state before dispatch. A long symbolic
        % call blocks the heartbeat loop, so this file is the only externally
        % visible signal that the server is busy rather than dead (I1/U1.3).
        state.busy = true;
        state.busy_since = bma.util.nowIso();
        state.current_call = names{k};
        state.queue_depth = numel(names) - k;
        bma.util.writeJsonAtomic(stateFile, state);
        resp = processOne(claimFile, outbox, done, state, logFid);
        state.busy = false;
        state.current_call = '';
        state.queue_depth = 0;
        state.last_call = names{k};
        state.last_call_at = bma.util.nowIso();
        if isstruct(resp)
            if isfield(resp, 'method')
                state.last_method = resp.method;
            end
            if isfield(resp, 'elapsed_ms')
                state.last_elapsed_ms = resp.elapsed_ms;
            end
            if isfield(resp, 'ok') && ~resp.ok && isfield(resp, 'error')
                state.last_error = struct('code', resp.error.code, ...
                    'message', resp.error.message, 'at', bma.util.nowIso());
                if strcmp(resp.error.code, 'BMA_TIMEOUT')
                    state.last_timeout = struct('call', names{k}, ...
                        'at', bma.util.nowIso(), ...
                        'elapsed_ms', resp.elapsed_ms);
                end
            end
        end
        bma.util.writeJsonAtomic(stateFile, state);
    end
end
cleanupServer(stateFile, logFid, state);
end

% ---------------------------------------------------------------------------
function resp = processOne(reqFile, outbox, done, state, logFid)
reqId = '__unknown__';
methodName = '?';
t0 = tic;
try
    req = bma.util.readJson(reqFile);
    if isfield(req, 'id')
        reqId = char(req.id);
    end
    if isfield(req, 'method')
        methodName = char(req.method);
    end
    if ~isfield(req, 'method') || isempty(req.method)
        resp = makeError(reqId, 0, 'BMA_BAD_REQUEST', 'Missing method.', [], '');
    elseif ~isfield(req, 'token') || ~strcmp(char(req.token), state.token)
        resp = makeError(reqId, 0, 'BMA_AUTH', 'Bad or missing token.', [], '');
    else
        try
            result = bma.server.dispatch(char(req.method), getParams(req), req);
            resp = struct('schema', 'bma.rpc.v1', 'id', reqId, 'ok', true, ...
                'elapsed_ms', round(toc(t0) * 1000), ...
                'result', bma.server.jsonSafe(result));
        catch err
            resp = makeError(reqId, round(toc(t0) * 1000), errorCode(err), ...
                err.message, errorDetails(err), getStack(err));
        end
    end
catch err
    resp = makeError(reqId, round(toc(t0) * 1000), 'BMA_RPC_FAILURE', ...
        err.message, [], getStack(err));
end
try
    respFile = fullfile(outbox, [safeName(reqId) '.json']);
    if isstruct(resp)
        resp.method = methodName;
    end
    bma.util.writeJsonAtomic(respFile, resp);
catch err
    logLine(logFid, sprintf('ERROR writing response for %s: %s', reqId, err.message));
end
try
    logLine(logFid, sprintf('%s %s ok=%d %dms', reqId, methodName, ...
        double(resp.ok), resp.elapsed_ms));
catch
end
try
    [ok, msg] = movefile(reqFile, fullfile(done, [safeName(reqId) '-' char(datetime('now', 'Format', 'HHmmssSSS')) '.json']));
    if ~ok
        logLine(logFid, sprintf('WARN archiving request %s: %s', reqId, msg));
    end
catch
    % archiving is best-effort
end
end

function p = getParams(req)
p = struct();
if isfield(req, 'params') && ~isempty(req.params)
    p = req.params;
    if iscell(p) && numel(p) == 1 && isstruct(p{1})
        p = p{1};
    end
end
end

function code = errorCode(err)
code = 'BMA_INTERNAL';
id = '';
try
    if isa(err, 'MException')
        id = char(err.identifier);
    elseif isfield(err, 'identifier') && ~isempty(err.identifier)
        id = char(err.identifier);
    end
catch
    id = '';
end
if ~isempty(id)
    if startsWith(id, 'bma:')
        parts = strsplit(id, ':');
        code = upper(strjoin(parts(end), '_'));
        code = ['BMA_' regexprep(code, '[^A-Z0-9_]', '_')];
    elseif strcmp(id, 'MATLAB:undefinedVarOrClass') || startsWith(id, 'MATLAB:UndefinedFunction')
        code = 'BMA_NOT_IMPLEMENTED';
    else
        code = ['BMA_' regexprep(upper(id), '[^A-Z0-9_]', '_')];
    end
end
end

function d = errorDetails(err)
d = struct();
isMException = false;
try
    isMException = isa(err, 'MException');
catch
end
hasStack = false;
try
    hasStack = ~isempty(err.stack);
catch
end
if hasStack
    try
        d.stack = arrayfun(@(s) sprintf('%s:%d', s.name, s.line), err.stack(1:min(8, numel(err.stack))), 'UniformOutput', false);
    catch
        d.stack = {};
    end
end
try
    if ~isempty(err.cause)
        if iscell(err.cause)
            d.cause_message = err.cause{1}.message;
        else
            d.cause_message = err.cause.message;
        end
    end
catch
end
end

function s = getStack(err)
s = '';
try
    if ~isempty(err.stack)
        s = sprintf('%s (%s:%d)\n', err.stack(1).name, err.stack(1).file, err.stack(1).line);
    end
catch
end
end

function resp = makeError(reqId, elapsedMs, code, message, details, stack)
resp = struct('schema', 'bma.rpc.v1', 'id', reqId, 'ok', false, ...
    'elapsed_ms', elapsedMs, ...
    'error', struct('code', code, 'message', char(message), ...
    'details', details, 'stack', char(stack)));
end

function n = safeName(id)
n = regexprep(char(id), '[^A-Za-z0-9_.-]', '_');
if isempty(n)
    n = 'req';
end
if numel(n) > 120
    n = n(1:120);
end
end

function logLine(fid, msg)
try
    fprintf(fid, '%s | %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS')), msg);
catch
end
end

function cleanupServer(stateFile, logFid, state, lockDir)
try
    state.heartbeat = bma.util.nowIso();
    state.stopped_at = bma.util.nowIso();
    state.running = false;
    bma.util.writeJsonAtomic(stateFile, state);
catch
end
try
    logLine(logFid, 'server stop');
catch
end
try
    fclose(logFid);
catch
end
try
    if isfolder(lockDir)
        rmdir(lockDir, 's');
    end
catch
end
end

function cleanStale(dirPath, pattern)
%CLEANSTALE Delete request/response artifacts left by a previous server process.
try
    d = dir(fullfile(dirPath, pattern));
    for k = 1:numel(d)
        if ~d(k).isdir
            try
                delete(fullfile(dirPath, d(k).name));
            catch
            end
        end
    end
catch
end
end

function tf = isAlive(pid)
tf = false;
try
    pid = double(pid);
    if ispc
        [status, out] = system(sprintf('tasklist /FI "PID eq %d" /NH', pid));
        tf = status == 0 && contains(out, num2str(pid));
    else
        tf = system(sprintf('kill -0 %d', pid)) == 0;
    end
catch
end
end

function tf = isFresh(isoText, maxAgeSeconds)
tf = false;
try
    t = datetime(isoText, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ssXXX');
    tf = seconds(datetime('now') - t) < maxAgeSeconds;
catch
end
end

function wd = normalizeWorkDir(workDir)
if nargin < 1 || isempty(workDir)
    workDir = pwd;
end
wd = char(workDir);
if ~isfolder(wd)
    error('bma:server:start', 'Work directory does not exist: %s', wd);
end
co = onCleanup(@() []);
old = pwd;
cd(wd);
wd = pwd;
cd(old);
clear co;
end

function m = dispatchableMethods()
m = {'server.ping', 'server.info', 'server.stop', 'server.cancel', 'dev.eval', 'test.run', ...
    'run.init', 'run.list', 'run.info', 'run.import_artifact', 'run.waive_gate', ...
    'kb.list', 'kb.search', 'kb.get', ...
    'literature.ingest', 'spec.validate', 'model.build', 'model.analyze', ...
    'model.simulate', 'pde.simulate', 'advanced.solve', 'model.simulate_cases', 'fit.estimate', 'fit.profile', ...
    'fit.sensitivity', 'fit.identifiability', 'validate.model_selection', ...
    'validate.cross_validation', 'validate.residuals', 'report.build', ...
    'codegen.model', 'simbiology.export'};
end
