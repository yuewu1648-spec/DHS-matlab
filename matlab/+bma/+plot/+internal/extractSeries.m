function [t, series, ids] = extractSeries(m, res)
%EXTRACTSERIES 从仿真结果中提取各 output 的时间序列。
%   [t, series, ids] = bma.plot.internal.extractSeries(m, res)
%
% 兼容三种形状：
%   1) bma.fit.simulatePredictions 归一化结果：res.t + res.series(struct)
%   2) core bma.model.simulate 结果：res.t + res.Y + res.outputs 或 m.outputs.fh
%   3) 任何含 t + Y 的结果（用模型 output 定义求值）
t = [];
series = struct();
ids = {};
if ~isstruct(res)
    error('bma.plot:resType', '仿真结果必须是 struct。');
end
% 形状 1
if isfield(res, 'series') && isstruct(res.series) && ~isempty(fieldnames(res.series))
    series = res.series;
    t = res.t(:);
    ids = fieldnames(series).';
    return
end
% 形状 2a：core res.outputs struct array {id,...,t,y}
if isfield(res, 'outputs') && ~isempty(res.outputs)
    O = res.outputs;
    if isstruct(O) && isfield(O, 'id')
        ok = true;
        for j = 1:numel(O)
            id = char(O(j).id);
            v = [];
            if isfield(O(j), 'y') && ~isempty(O(j).y)
                v = double(O(j).y(:));
            elseif isfield(O(j), 'values') && ~isempty(O(j).values)
                v = double(O(j).values(:));
            elseif isfield(O(j), 'data') && ~isempty(O(j).data)
                v = double(O(j).data(:));
            end
            if isempty(v)
                ok = false;
                break
            end
            series.(id) = v;
            ids{end+1} = id; %#ok<AGROW>
            if isempty(t) && isfield(O(j), 't') && ~isempty(O(j).t)
                t = double(O(j).t(:));
            end
        end
        if ok && ~isempty(ids)
            if isempty(t)
                if isfield(res, 't') && ~isempty(res.t)
                    t = double(res.t(:));
                else
                    t = (1:numel(series.(ids{1}))).';
                end
            end
            return
        end
        series = struct();
        ids = {};
        t = [];
    elseif iscell(O) && ~isempty(O) && isstruct(O{1}) && isfield(O{1}, 'id')
        for j = 1:numel(O)
            id = char(O{j}.id);
            v = [];
            if isfield(O{j}, 'y') && ~isempty(O{j}.y), v = double(O{j}.y(:)); end
            if isempty(v) && isfield(O{j}, 'values'), v = double(O{j}.values(:)); end
            if ~isempty(v)
                series.(id) = v;
                ids{end+1} = id; %#ok<AGROW>
            end
        end
        if ~isempty(ids)
            if isfield(res, 't') && ~isempty(res.t)
                t = double(res.t(:));
            else
                t = (1:numel(series.(ids{1}))).';
            end
            return
        end
    end
end
% 形状 2b/3：t + Y
if ~isfield(res, 't') || isempty(res.t) || ~isfield(res, 'Y') || isempty(res.Y)
    error('bma.plot:resShape', '仿真结果缺少 t/Y 或 outputs/series，无法绘图。');
end
t = double(res.t(:));
Y = double(res.Y);
if size(Y, 1) ~= numel(t) && size(Y, 2) == numel(t)
    Y = Y.';
end
pVec = paramsOf(m, res);
if isfield(m, 'outputs') && ~isempty(m.outputs)
    O = m.outputs;
    for j = 1:numel(O)
        id = char(O(j).id);
        fh = [];
        if isfield(O(j), 'fh') && ~isempty(O(j).fh)
            fh = O(j).fh;
        elseif isfield(O(j), 'fun') && ~isempty(O(j).fun)
            fh = O(j).fun;
        end
        if ~isempty(fh)
            series.(id) = applyFcn(fh, Y, pVec);
            ids{end+1} = id; %#ok<AGROW>
        end
    end
end
if isempty(ids)
    % 状态变量直接作为序列
    if isfield(m, 'species') && ~isempty(m.species)
        sp = cellstr(m.species);
    else
        sp = arrayfun(@(k) sprintf('y%d', k), 1:size(Y, 2), 'UniformOutput', false);
    end
    for k = 1:min(numel(sp), size(Y, 2))
        series.(sp{k}) = Y(:, k);
        ids{end+1} = sp{k}; %#ok<AGROW>
    end
end
end

% ======================================================================
function pVec = paramsOf(m, res)
pVec = [];
if isfield(res, 'params') && isstruct(res.params)
    names = cellstr(m.params);
    pVec = zeros(numel(names), 1);
    for k = 1:numel(names)
        if isfield(res.params, names{k})
            pVec(k) = double(res.params.(names{k}));
        elseif isfield(m, 'paramValues')
            pVec(k) = double(m.paramValues(k));
        end
    end
elseif isfield(m, 'paramValues') && ~isempty(m.paramValues)
    pVec = double(m.paramValues(:));
end
end

function vals = applyFcn(fh, Y, pVec)
n = size(Y, 1);
try
    v = fh(Y.', pVec);
    if isnumeric(v) && numel(v) == n
        vals = double(v(:));
        return
    end
catch
end
vals = zeros(n, 1);
for k = 1:n
    yCol = Y(k, :).';
    try
        v = fh(yCol, pVec);
    catch
        try
            v = fh(yCol);
        catch
            v = NaN;
        end
    end
    if isempty(v)
        vals(k) = NaN;
    else
        vals(k) = double(v(1));
    end
end
end
