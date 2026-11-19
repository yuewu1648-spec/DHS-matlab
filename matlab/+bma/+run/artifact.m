function [p, rel] = artifact(runDir, kind, name)
%ARTIFACT 返回并创建运行目录下的规范产物路径。
%   p = bma.run.artifact(runDir, kind)
%   p = bma.run.artifact(runDir, kind, name)
%   [p, rel] = bma.run.artifact(...)   % rel 为相对 work_dir 的路径
%
%   kind 取值（不区分大小写）：
%     literature | models(model/spec/specs) | data(dataset) | fits(fit) |
%     figures(figure/plot) | report(reports) | logs | root
%   name 省略时返回该类别根目录；给出 name 时：带扩展名视为文件路径（只建父目录，
%   不创建文件本身），否则视为子目录（创建之）。所有路径基于 runDir，避免依赖 pwd。
if nargin < 1 || isempty(runDir)
    error('bma:run:missingRunDir', 'bma.run.artifact 需要 run_dir。');
end
if nargin < 2 || isempty(kind)
    error('bma:run:missingKind', ...
        'bma.run.artifact 需要 kind（literature/models/data/fits/figures/report/logs/root）。');
end
if isstring(kind)
    kind = char(kind);
end
runDir = bma.run.internal.resolveRunDir(runDir);
if ~isfolder(runDir)
    error('bma:run:notFound', '运行目录不存在：%s', runDir);
end
[subdir, kindName] = kindToSubdir(kind);
if isempty(subdir)
    p = runDir;
else
    p = fullfile(runDir, subdir);
    bma.util.ensureDir(p);
end
if nargin >= 3 && ~isempty(name)
    if isstring(name)
        name = char(name);
    end
    name = char(name);
    validateName(name);
    target = fullfile(p, name);
    if hasFileExtension(name)
        bma.util.ensureDir(fileparts(target));
    else
        bma.util.ensureDir(target);
    end
    p = target;
else
    kindName = kindName; %#ok<ASGSL>
end
workDir = bma.run.internal.inferWorkDir(runDir);
rel = bma.util.relPath(workDir, p);
end

% ---------------------------------------------------------------------------
function [subdir, kindName] = kindToSubdir(kind)
kindName = lower(strtrim(char(kind)));
switch kindName
    case {'literature', 'docs', 'doc'}
        subdir = 'literature';
        kindName = 'literature';
    case {'models', 'model', 'spec', 'specs', 'code', 'codegen'}
        subdir = 'models';
        kindName = 'models';
    case {'data', 'dataset', 'datasets'}
        subdir = 'data';
        kindName = 'data';
    case {'fits', 'fit'}
        subdir = 'fits';
        kindName = 'fits';
    case {'figures', 'figure', 'plots', 'plot', 'fig'}
        subdir = 'figures';
        kindName = 'figures';
    case {'report', 'reports'}
        subdir = 'report';
        kindName = 'report';
    case {'logs', 'log'}
        subdir = 'logs';
        kindName = 'logs';
    case {'artifacts', 'artifact', 'imports', 'import'}
        subdir = 'artifacts';
        kindName = 'artifacts';
    case 'root'
        subdir = '';
        kindName = 'root';
    otherwise
        error('bma:run:unknownKind', ...
            ['未知产物类别 "%s"。可用：literature / models / data / fits / ' ...
            'figures / report / logs / root。'], kindName);
end
end

function validateName(name)
if isempty(strtrim(name))
    error('bma:run:badName', '产物 name 不能为空。');
end
if ~isempty(regexp(name, '^([A-Za-z]:[\\/]|\\\\|/)', 'once'))
    error('bma:run:badName', '产物 name 不能是绝对路径：%s', name);
end
parts = regexp(name, '[\\/]', 'split');
for k = 1:numel(parts)
    if any(strcmp(parts{k}, {'..', '.'}))
        error('bma:run:badName', '产物 name 不能包含 "." 或 ".." 路径段：%s', name);
    end
end
end

function tf = hasFileExtension(name)
tf = ~isempty(regexp(name, '\.[A-Za-z0-9]{1,8}$', 'once'));
end
