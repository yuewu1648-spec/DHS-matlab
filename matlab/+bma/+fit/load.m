function fr = load(path)
%LOAD 读取拟合结果（fit.json / fit.mat / 拟合目录）。
%   fr = bma.fit.load(path)
%
% 兼容 JSON 解码后的数值形状（列向量退化为行、null→[]），并补齐派生字段，
% 使 bma.validate.residuals / bma.plot.fit / bma.report.build 可直接消费。
if nargin < 1 || isempty(path)
    error('bma:fit:loadPath', 'bma.fit.load 需要路径。');
end
path = char(path);
if isfolder(path)
    if isfile(fullfile(path, 'fit.json'))
        path = fullfile(path, 'fit.json');
    elseif isfile(fullfile(path, 'fit.mat'))
        path = fullfile(path, 'fit.mat');
    else
        error('bma:fit:loadNotFound', '目录中没有 fit.json/fit.mat：%s', path);
    end
end
if ~isfile(path)
    error('bma:fit:loadNotFound', '拟合结果文件不存在：%s', path);
end
[~, ~, ext] = fileparts(path);
if strcmpi(ext, '.mat')
    S = load(path);
    if isfield(S, 'fr')
        fr = S.fr;
    else
        fr = S;
    end
    return
end
fr = bma.util.readJson(path);
fr = postprocess(fr);
end

% ======================================================================
function fr = postprocess(fr)
%POSTPROCESS 规整 JSON 解码后的结构，便于下游使用。
if isfield(fr, 'params') && ~isempty(fr.params)
    if isstruct(fr.params) && ~isfield(fr.params, 'id') && numel(fr.params) > 1
        % 某些 JSON 解码路径可能返回 cell；保持原样
    end
    fr.params = normalizeStructArray(fr.params);
end
if isfield(fr, 'solver_info')
    fr.solver_info = normalizeStructArray(fr.solver_info);
end
if isfield(fr, 'fittedSpec') && isstruct(fr.fittedSpec) ...
        && isfield(fr.fittedSpec, 'parameters')
    fr.fittedSpec.parameters = normalizeStructArray(fr.fittedSpec.parameters);
end
colFields = {'p', 'p0', 'p_all'};
for k = 1:numel(colFields)
    f = colFields{k};
    if isfield(fr, f) && isnumeric(fr.(f)) && isempty(fr.(f)) == false
        fr.(f) = fr.(f)(:);
    end
end
if isfield(fr, 'pnames')
    fr.pnames = normalizeCellstr(fr.pnames);
end
if isfield(fr, 'fitted')
    fr.fitted = normalizeCellstr(fr.fitted);
end
if isfield(fr, 'param_ids')
    fr.param_ids = normalizeCellstr(fr.param_ids);
end
if isfield(fr, 'warnings')
    fr.warnings = normalizeCellstr(fr.warnings);
end
if isfield(fr, 'figures')
    fr.figures = normalizeCellstr(fr.figures);
end
if ~isfield(fr, 'n_observations') && isfield(fr, 'metrics') ...
        && isfield(fr.metrics, 'n_observations')
    fr.n_observations = fr.metrics.n_observations;
end
if ~isfield(fr, 'n_parameters') && isfield(fr, 'metrics') ...
        && isfield(fr.metrics, 'n_parameters')
    fr.n_parameters = fr.metrics.n_parameters;
end
if isfield(fr, 'residuals') && isfield(fr.residuals, 'values')
    v = fr.residuals.values;
    if isnumeric(v)
        fr.residuals.values = v(:);
    end
end
% 空值（JSON null 解码为 []）在常用数值字段中视为 NaN
numFields = {'r2', 'rmse', 'aicc', 'bic', 'loglik'};
for k = 1:numel(numFields)
    f = numFields{k};
    if isfield(fr, f) && isempty(fr.(f))
        fr.(f) = NaN;
    end
end
end

function out = normalizeStructArray(x)
%NORMALIZESTRUCTARRAY 把 JSON 解码结果规整为 1×n struct array。
if isempty(x)
    out = x;
    return
end
if isstruct(x)
    out = x;
elseif iscell(x)
    try
        out = [x{:}];
    catch
        out = x;
    end
else
    out = x;
end
end

function c = normalizeCellstr(x)
%NORMALIZECELLSTR 规整字符串容器为行 cellstr。
if isempty(x)
    c = {};
elseif iscell(x)
    c = cellfun(@(s) char(s), x(:).', 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    c = {x};
else
    c = {};
end
end
