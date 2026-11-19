function o = resolveOpts(opts, defaultName)
%RESOLVEOPTS 统一绘图选项：工作目录、输出目录、文件名、可见性。
%   o = bma.plot.internal.resolveOpts(opts, defaultName)
%
% 识别字段（兼容 camelCase 与 snake_case）：
%   work_dir / workDir    工作目录（相对路径基准），默认项目根
%   out_dir  / outDir     输出目录（绝对或相对 work_dir），默认 <workDir>/figures
%   name / filename       文件名（默认 defaultName）
%   dpi                   导出分辨率（默认 150）
%   relative              返回相对路径（默认 true）
if nargin < 2 || isempty(defaultName)
    defaultName = 'figure.png';
end
if nargin < 1 || isempty(opts)
    opts = struct();
end
o = struct();
o.workDir = getAny(opts, {'work_dir', 'workDir'}, '');
if isempty(o.workDir)
    o.workDir = bma.util.projectRoot();
end
o.workDir = char(o.workDir);

outDir = getAny(opts, {'out_dir', 'outDir'}, '');
if isempty(outDir)
    o.outDir = fullfile(o.workDir, 'figures');
else
    o.outDir = bma.util.absPath(o.workDir, char(outDir));
end
o.outDir = char(o.outDir);
bma.util.ensureDir(o.outDir);

name = getAny(opts, {'name', 'filename'}, defaultName);
name = char(name);
if isempty(regexp(name, '\.png$', 'once'))
    name = [name '.png'];
end
o.name = name;
o.absPath = fullfile(o.outDir, o.name);
o.dpi = 200;
if isfield(opts, 'dpi') && ~isempty(opts.dpi)
    o.dpi = double(opts.dpi);
end
o.relative = true;
if isfield(opts, 'relative') && ~isempty(opts.relative)
    o.relative = logical(opts.relative);
end
end

% ======================================================================
function v = getAny(s, names, default)
v = default;
for k = 1:numel(names)
    if isfield(s, names{k}) && ~isempty(s.(names{k}))
        v = s.(names{k});
        return
    end
end
end
