function r = codegen(m, runDir)
%CODEGEN Generate standalone MATLAB code for a constant/state-dependent/neutral DDE.
%   r = bma.dde.codegen(m, runDir)
%
% Outputs:
%   <runDir>/models/<name>/code/<name>_dde.m       dydt = f(t,y,Z,p)
%   <runDir>/models/<name>/code/<name>_dde_run.m   dde23/ddesd/ddensd wrapper
%   <runDir>/models/<name>/model_card.json
if nargin < 2 || isempty(runDir)
    runDir = fullfile(bma.util.projectRoot(), '.bma', 'codegen', m.name);
end
name = safeName(m.name);
modelDir = fullfile(runDir, 'models', name);
codeDir = fullfile(modelDir, 'code');
bma.util.ensureDir(codeDir);
ddeFile = fullfile(codeDir, [name '_dde.m']);
runFile = fullfile(codeDir, [name '_dde_run.m']);
% Rate right-hand side. Z carries delayed states (dde23/ddesd) or delayed
% derivatives (ddensd); compile already mapped refs accordingly.
lines = {};
lines{end+1} = sprintf('function dydt = %s_dde(t, y, Z, p)', name);
lines{end+1} = sprintf('%% Auto-generated DDE right-hand side (%s, mode=%s).', name, m.mode);
lines{end+1} = sprintf('rates = zeros(%d, 1);', m.n_reactions);
for rk = 1:numel(m.rate_codes)
    lines{end+1} = sprintf('rates(%d) = %s;', rk, m.rate_codes{rk}); %#ok<AGROW>
end
lines{end+1} = sprintf('S = %s;', mat2str(m.S));
lines{end+1} = 'dydt = S * rates;';
lines{end+1} = 'end';
writeText(ddeFile, lines);
% Delay functions for state-dependent/neutral modes.
delayFile = fullfile(codeDir, [name '_dde_delay.m']);
hasDelayExpr = ~isempty(m.delay_codes) && any(~cellfun(@isempty, m.delay_codes));
if hasDelayExpr
    dl = {};
    dl{end+1} = sprintf('function d = %s_dde_delay(t, y, p)', name);
    dl{end+1} = sprintf('d = zeros(%d, 1);', numel(m.delay_codes));
    for dj = 1:numel(m.delay_codes)
        dl{end+1} = sprintf('d(%d) = %s;', dj, m.delay_codes{dj}); %#ok<AGROW>
    end
    dl{end+1} = 'end';
    writeText(delayFile, dl);
elseif isfile(delayFile)
    delete(delayFile);
end
% Standalone run wrapper.
rl = {};
rl{end+1} = sprintf('function [t, Y, out] = %s_dde_run(p, tspan, y0)', name);
rl{end+1} = sprintf('%% Auto-generated DDE run wrapper (%s, mode=%s).', name, m.mode);
rl{end+1} = sprintf('if nargin < 1 || isempty(p), p = %s; end', mat2str(m.paramValues));
rl{end+1} = sprintf('if nargin < 2 || isempty(tspan), tspan = [%g %g]; end', ...
    m.time.start, m.time.end);
rl{end+1} = sprintf('if nargin < 3 || isempty(y0), y0 = %s; end', mat2str(m.history(:).'));
rl{end+1} = 'history = @(tt) y0(:);';
if strcmp(m.mode, 'constant')
    rl{end+1} = sprintf('lags = %s;', mat2str(m.delays(:).'));
    rl{end+1} = sprintf('sol = dde23(@(tt,yy,ZZ) %s_dde(tt,yy,ZZ,p), lags, history, tspan);', name);
elseif strcmp(m.mode, 'state_dependent')
    rl{end+1} = sprintf('dely = @(tt,yy) tt - %s_dde_delay(tt,yy,p);', name);
    rl{end+1} = sprintf('sol = ddesd(@(tt,yy,ZZ) %s_dde(tt,yy,ZZ,p), dely, history, tspan);', name);
else
    if ~hasDelayExpr
        rl{end+1} = sprintf('delyp = @(tt,yy) tt - %s;', mat2str(m.delays(:).'));
    else
        rl{end+1} = sprintf('delyp = @(tt,yy) tt - %s_dde_delay(tt,yy,p);', name);
    end
    rl{end+1} = sprintf('sol = ddensd(@(tt,yy,ZZ,YYp) %s_dde(tt,yy,YYp,p), [], delyp, history, tspan);', name);
end
rl{end+1} = 't = sol.x(:); Y = sol.y.'';';
rl{end+1} = sprintf('out = zeros(numel(t), %d);', numel(m.output_codes));
for oj = 1:numel(m.output_codes)
    rl{end+1} = sprintf('for kk = 1:numel(t), y = Y(kk,:).''; out(kk,%d) = %s; end', ...
        oj, m.output_codes{oj}); %#ok<AGROW>
end
rl{end+1} = 'end';
writeText(runFile, rl);
% Minimal model card.
card = struct('schema_version', 'bma.modelCard.v1', 'name', name, ...
    'kind', 'dde', 'mode', m.mode, 'species', {m.species}, ...
    'parameters', {m.params}, 'delays', m.delays, ...
    'delay_ids', {m.delay_ids}, 'generated_by', 'bma.dde.codegen');
cardPath = fullfile(modelDir, 'model_card.json');
writeText(cardPath, {jsonencode(card)});
r = struct();
r.schema_version = 'bma.codegen.v1';
r.ok = true;
r.name = name;
r.function_name = [name '_dde'];
r.run_function_name = [name '_dde_run'];
r.m_file = ddeFile;
r.run_file = runFile;
r.pde_file = '';
r.model_card_path = cardPath;
r.code_dir = codeDir;
r.model_dir = modelDir;
r.parameter_order = m.params;
r.species_order = m.species;
r.ode_preview = ['DDE ' m.mode];
r.parameter_index = m.paramValues;
r.species_index = m.species;
r.warnings = m.warnings;
r.editable_note = '生成代码使用 dde23/ddesd/ddensd，可直接在 MATLAB 中运行；DDE 模式见文件头。';
r.elapsed_ms = 0;
end

function writeText(path, lines)
fid = fopen(path, 'w');
if fid < 0, error('bma:dde:codegenWrite', '无法写入 %s', path); end
cleaner = onCleanup(@() fclose(fid));
for k = 1:numel(lines)
    fprintf(fid, '%s\n', lines{k});
end
end

function n = safeName(s)
n = regexprep(char(s), '[^A-Za-z0-9_]', '_');
if isempty(n) || ~isletter(n(1)), n = ['m_' n]; end
end
