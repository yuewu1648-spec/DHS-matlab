function d = normalizeData(dataIn, m, opts)
%NORMALIZEDATA 把多种数据输入统一成拟合所需的规范结构。
%   d = bma.fit.normalizeData(data, m, opts)
%
% 支持的输入形式：
%   1) CSV 文件路径（char/string）：首行表头，时间列建议命名为 time 或位于首列；
%   2) dispatch 的 loadDataset 结果：struct 含 table / time / output_map / path；
%   3) 通用 struct：{t|time, Y|y|data|columns}，可带 outputs / outputMap / weights。
%
% 输出 d 的字段（列顺序与 output_map / m.outputs 顺序一致）：
%   t          n×1 double，按时间升序
%   Y          n×p 观测矩阵（缺失值为 NaN）
%   colIds     1×p cellstr，spec 中的 output id（拟合目标）
%   colNames   1×p cellstr，数据列名（CSV 表头）
%   weights    [] 或 n×p 权重（非负、有限）
%   source     数据来源描述
%   warnings   cellstr
%
% 说明：拟合只需 output id → 数据列的映射；若调用方未提供 output_map，
% 则按 m.outputs 中与数据列同名的 output 自动匹配；仍匹配不到时，若列数
% 与 output 数相同则按位置映射（并记录 warning）。

if nargin < 3 || isempty(opts)
    opts = struct();
end

d = struct('t', [], 'Y', [], 'colIds', {{}}, 'colNames', {{}}, ...
    'weights', [], 'source', 'struct', 'warnings', {{}});
if isempty(dataIn)
    error('bma:fit:noData', '拟合数据为空：请提供数据 struct、CSV 路径或 data.table。');
end

outMap = [];
inOutputs = {};
inWeights = [];
t = [];
Y = [];
colNames = {};
source = 'struct';

% ------------------------------------------------------------------
% 1) 取出 t / Y / colNames / 映射 / 权重
% ------------------------------------------------------------------
if ischar(dataIn) || isstring(dataIn)
    csvPath = char(dataIn);
    [t, Y, colNames] = readCsv(csvPath);
    source = csvPath;
    if isfield(opts, 'output_map') && ~isempty(opts.output_map)
        outMap = opts.output_map;
    end
    if isfield(opts, 'weights') && ~isempty(opts.weights)
        inWeights = opts.weights;
    end
elseif isstruct(dataIn)
    % --- 兼容 dispatch loadDataset：table + time + output_map ---
    if isfield(dataIn, 'outputMap') && ~isempty(dataIn.outputMap)
        outMap = dataIn.outputMap;
    elseif isfield(dataIn, 'output_map') && ~isempty(dataIn.output_map)
        outMap = dataIn.output_map;
    end
    if isfield(dataIn, 'outputs') && ~isempty(dataIn.outputs)
        inOutputs = toCellstr(dataIn.outputs);
    end
    if isfield(dataIn, 'weights') && ~isempty(dataIn.weights)
        inWeights = dataIn.weights;
    end
    if isfield(dataIn, 'csv') && ~isempty(dataIn.csv)
        source = char(dataIn.csv);
    elseif isfield(dataIn, 'path') && ~isempty(dataIn.path)
        source = char(dataIn.path);
    end

    if isfield(dataIn, 'table') && istable(dataIn.table) && ~isempty(dataIn.table)
        [t, Y, colNames] = tableToData(dataIn);
    elseif isfield(dataIn, 'csv') && ~isempty(dataIn.csv)
        [t, Y, colNames] = readCsv(char(dataIn.csv));
    else
        % --- 通用 struct：时间向量 + 观测矩阵/单元格 ---
        if isfield(dataIn, 't') && ~isempty(dataIn.t)
            t = double(dataIn.t(:));
        elseif isfield(dataIn, 'time') && ~isempty(dataIn.time)
            t = double(dataIn.time(:));
        end
        if isfield(dataIn, 'Y') && ~isempty(dataIn.Y)
            Y = dataIn.Y;
        elseif isfield(dataIn, 'y') && ~isempty(dataIn.y)
            Y = dataIn.y;
        elseif isfield(dataIn, 'data') && ~isempty(dataIn.data)
            Y = dataIn.data;
        end
        if isempty(t)
            error('bma:fit:dataNoTime', '数据 struct 缺少时间字段（t 或 time）。');
        end
        if isempty(Y)
            error('bma:fit:dataNoY', '数据 struct 缺少观测字段（Y 或 data）。');
        end
        Y = double(Y);
        if size(Y, 1) ~= numel(t) && size(Y, 2) == numel(t)
            Y = Y.';  % 兼容 观测×时间 的转置输入
        end
        if size(Y, 1) ~= numel(t)
            error('bma:fit:dataShape', ...
                '数据维度不一致：时间点 %d 个，但观测矩阵为 %d×%d。', ...
                numel(t), size(Y, 1), size(Y, 2));
        end
        if isempty(inOutputs) && isfield(dataIn, 'columns') && ~isempty(dataIn.columns)
            inOutputs = toCellstr(dataIn.columns);
        end
        colNames = inOutputs;
    end
else
    error('bma:fit:dataType', '无法识别的数据输入类型：%s', class(dataIn));
end

if ~isempty(inWeights)
    d.weights = inWeights;
elseif isfield(opts, 'weights') && ~isempty(opts.weights)
    d.weights = opts.weights;
end

% ------------------------------------------------------------------
% 2) 解析 output 映射：colIds <-> colNames
% ------------------------------------------------------------------
mOutIds = modelOutputIds(m);
if isempty(colNames)
    colNames = mOutIds;   % 无列名时退化为按 output 顺序
end
if numel(colNames) ~= size(Y, 2)
    % 列名数量不匹配：若列名比列少，用占位名补齐；否则截断
    if numel(colNames) > size(Y, 2)
        colNames = colNames(1:size(Y, 2));
    else
        for k = numel(colNames) + 1:size(Y, 2)
            colNames{k} = sprintf('col%d', k);
        end
    end
end
colNames = regexprep(colNames, '^"(.*)"$', '$1');

[colIds, pick, mapWarn] = resolveOutputMap(outMap, inOutputs, mOutIds, colNames);
d.warnings = [d.warnings, mapWarn];

if isempty(colIds)
    error('bma:fit:noOutputMatch', ...
        ['无法把数据列映射到模型 output。数据列：%s；模型 output：%s。' ...
         '请通过 output_map 指定映射（例如 {"P_obs":"P_obs"}）。'], ...
        strjoin(colNames, ', '), strjoin(mOutIds, ', '));
end
Y = Y(:, pick);
colNames = colNames(pick);

% ------------------------------------------------------------------
% 3) 排序 / 权重规范化 / 基本校验
% ------------------------------------------------------------------
d.t = t;
d.Y = Y;
d.colIds = colIds;
d.colNames = colNames;
d.source = source;

if numel(d.t) > 1
    [ts, order] = sort(d.t);
    if any(order ~= (1:numel(order))')
        d.t = ts;
        d.Y = d.Y(order, :);
        if ~isempty(d.weights) && isequal(size(d.weights), size(d.Y))
            d.weights = d.weights(order, :);
        end
    end
end
d.t = d.t(:);

keep = isfinite(d.t);
if any(~keep)
    bad = sum(~keep);
    d.t = d.t(keep);
    d.Y = d.Y(keep, :);
    if ~isempty(d.weights) && isequal(size(d.weights), [numel(keep), numel(d.colIds)])
        d.weights = d.weights(keep, :);
    end
    d.warnings{end+1} = sprintf('删除了 %d 个时间非有限的数据点。', bad);
end

nObs = numel(d.t);
p = numel(d.colIds);
if nObs < 2
    error('bma:fit:tooFewData', '有效数据点不足（%d 个），无法拟合。', nObs);
end
% 每个输出至少需要一个有效观测
for j = 1:p
    if ~any(isfinite(d.Y(:, j)))
        error('bma:fit:outputNoData', 'output "%s" 没有任何有效观测值。', d.colIds{j});
    end
end

d.weights = normalizeWeights(d.weights, nObs, p, d);
if any(~isfinite(d.Y(:)))
    d.warnings{end+1} = sprintf('数据含 %d 个缺失值（NaN），拟合时将按缺失处理。', sum(~isfinite(d.Y(:))));
end
end

% ======================================================================
% 局部函数
% ======================================================================
function [t, Y, names] = readCsv(path)
%READCSV 读取首列（或名为 time 的列）为时间、其余列为观测的 CSV。
if ~isfile(path)
    error('bma:fit:csvNotFound', '数据 CSV 不存在：%s', path);
end
fid = fopen(path, 'r', 'n', 'UTF-8');
if fid < 0
    error('bma:fit:csvOpen', '无法打开数据 CSV：%s', path);
end
cleaner = onCleanup(@() fclose(fid));
header = fgetl(fid);
if ~ischar(header) || isempty(strtrim(header))
    error('bma:fit:csvHeader', '数据 CSV 为空或缺表头：%s', path);
end
header = regexprep(header, '^\xEF\xBB\xBF', '');   % 去 UTF-8 BOM
names = strtrim(strsplit(header, ','));
names = regexprep(names, '^"(.*)"$', '$1');
nCol = numel(names);
if nCol < 2
    error('bma:fit:csvFormat', '数据 CSV 至少需要时间列 + 1 个观测列：%s', path);
end
fmt = repmat('%f', 1, nCol);
C = textscan(fid, fmt, 'Delimiter', ',', 'CollectOutput', true, ...
    'TreatAsEmpty', {'NA', 'NaN', '', 'null'}, 'EmptyValue', NaN);
M = C{1};
if isempty(M)
    error('bma:fit:csvEmpty', '数据 CSV 没有可解析的数值行：%s', path);
end
timeIdx = 1;
for k = 1:nCol
    if strcmpi(names{k}, 'time') || strcmpi(names{k}, 't')
        timeIdx = k;
        break
    end
end
cols = setdiff(1:nCol, timeIdx);
t = double(M(:, timeIdx));
Y = double(M(:, cols));
names = names(cols);
end

function [t, Y, names] = tableToData(dataIn)
%TABLETODATA 把 dispatch loadDataset 生成的 table 转成时间 + 观测矩阵。
T = dataIn.table;
tblNames = T.Properties.VariableNames;
n = height(T);
if isfield(dataIn, 'time') && ~isempty(dataIn.time) && numel(dataIn.time) == n
    t = double(dataIn.time(:));
    timeIdx = 1;
else
    timeIdx = 1;
    for k = 1:numel(tblNames)
        if strcmpi(tblNames{k}, 'time') || strcmpi(tblNames{k}, 't')
            timeIdx = k;
            break
        end
    end
    t = double(T{:, timeIdx});
end
cols = setdiff(1:numel(tblNames), timeIdx);
V = T{:, cols};
if iscell(V) || isstring(V)
    V = str2double(string(V));
end
Y = double(V);
names = tblNames(cols);
end

function ids = modelOutputIds(m)
%MODELOUTPUTIDS 从 build 后的模型结构或 spec 中取 output id 列表。
ids = {};
if isstruct(m) && isfield(m, 'outputs') && ~isempty(m.outputs)
    O = m.outputs;
    if isstruct(O)
        if isfield(O, 'id')
            ids = arrayfun(@(s) char(s.id), O, 'UniformOutput', false);
        else
            ids = fieldnames(O).';
        end
    elseif iscell(O)
        ids = cellfun(@(s) char(s.id), O, 'UniformOutput', false);
    end
end
if isempty(ids) && isstruct(m) && isfield(m, 'spec') && isfield(m.spec, 'outputs') ...
        && ~isempty(m.spec.outputs)
    ids = arrayfun(@(s) char(s.id), m.spec.outputs, 'UniformOutput', false);
end
ids = ids(:).';
end

function [colIds, pick, warnings] = resolveOutputMap(outMap, inOutputs, mOutIds, colNames)
%RESOLVEOUTPUTMAP 决定数据列与 spec output id 的对应关系。
warnings = {};
colIds = {};
pick = [];
nCols = numel(colNames);

% --- A) 显式 output_map：specId -> 数据列名 ---
if ~isempty(outMap)
    specIds = {};
    dataCols = {};
    if isstruct(outMap)
        f = fieldnames(outMap);
        specIds = f(:).';
        dataCols = cellfun(@(x) charIfy(outMap.(x)), f, 'UniformOutput', false);
    elseif isa(outMap, 'containers.Map')
        specIds = keys(outMap);
        specIds = specIds(:).';
        dataCols = values(outMap);
        dataCols = cellfun(@charIfy, dataCols, 'UniformOutput', false);
    elseif iscell(outMap) && size(outMap, 2) == 2
        specIds = cellfun(@charIfy, outMap(:, 1), 'UniformOutput', false).';
        dataCols = cellfun(@charIfy, outMap(:, 2), 'UniformOutput', false).';
    elseif ischar(outMap) || isstring(outMap)
        try
            parsed = jsondecode(char(outMap));
            [colIds, pick, warnings] = resolveOutputMap(parsed, inOutputs, mOutIds, colNames);
            return
        catch
            error('bma:fit:badOutputMap', '无法解析 output_map：%s', char(outMap));
        end
    end
    for k = 1:numel(specIds)
        cName = dataCols{k};
        idx = find(strcmp(colNames, cName), 1);
        if isempty(idx)
            idx = find(strcmp(colNames, specIds{k}), 1);
        end
        if isempty(idx)
            warnings{end+1} = sprintf('output_map 中的列 "%s" 不在数据中，已跳过。', cName); %#ok<AGROW>
            continue
        end
        if any(pick == idx)
            warnings{end+1} = sprintf('output_map 中重复映射到列 "%s"，已跳过。', cName); %#ok<AGROW>
            continue
        end
        colIds{end+1} = specIds{k}; %#ok<AGROW>
        pick(end+1) = idx; %#ok<AGROW>
    end
    return
end

% --- B) 调用方给出 outputs 列表 ---
if ~isempty(inOutputs)
    for k = 1:numel(inOutputs)
        name = charIfy(inOutputs{k});
        idx = find(strcmp(colNames, name), 1);
        specId = name;
        if isempty(idx)
            % 若 name 是 spec output id，尝试同名数据列
            if ismember(name, mOutIds)
                idx = find(strcmp(colNames, name), 1);
            end
        end
        if isempty(idx) && ismember(name, mOutIds) && numel(mOutIds) == nCols
            idx = find(strcmp(mOutIds, name), 1);   % 位置映射
        end
        if isempty(idx)
            warnings{end+1} = sprintf('数据列 "%s" 未找到，已跳过。', name); %#ok<AGROW>
            continue
        end
        if any(pick == idx)
            continue
        end
        colIds{end+1} = specId; %#ok<AGROW>
        pick(end+1) = idx; %#ok<AGROW>
    end
    return
end

% --- C) 自动匹配：按模型 output 顺序找同名数据列 ---
for k = 1:numel(mOutIds)
    idx = find(strcmp(colNames, mOutIds{k}), 1);
    if ~isempty(idx) && ~any(pick == idx)
        colIds{end+1} = mOutIds{k}; %#ok<AGROW>
        pick(end+1) = idx; %#ok<AGROW>
    end
end
if ~isempty(colIds)
    if numel(colIds) < nCols
        warnings{end+1} = sprintf( ...
            '数据中 %d 列未匹配到模型 output，已忽略：%s。', ...
            nCols - numel(colIds), strjoin(colNames(setdiff(1:nCols, pick)), ', ')); %#ok<AGROW>
    end
    return
end

% --- D) 位置映射兜底 ---
if nCols == numel(mOutIds) && nCols > 0
    colIds = mOutIds;
    pick = 1:nCols;
    warnings{end+1} = '未找到 output 名称匹配，已按列顺序映射到模型 output（请确认 output_map）。';
else
    warnings{end+1} = '无法自动匹配数据列与模型 output。';
end
end

function w = normalizeWeights(w, n, p, d)
%NORMALIZEWEIGHTS 把标量/向量/矩阵权重规范成 n×p。
if isempty(w)
    w = ones(n, p);
    return
end
if ischar(w) || isstring(w)
    if strcmpi(char(w), 'none')
        w = ones(n, p);
        return
    end
    error('bma:fit:weights', '无法识别的权重设置：%s', char(w));
end
w = double(w);
if isscalar(w)
    w = w * ones(n, p);
elseif isvector(w) && numel(w) == p
    w = repmat(w(:).', n, 1);
elseif isvector(w) && numel(w) == n
    w = repmat(w(:), 1, p);
elseif isequal(size(w), [n, p])
    % 原样
elseif isequal(size(w), [p, n])
    w = w.';
else
    d.warnings{end+1} = sprintf( ...
        '权重维度 %s 与数据 %d×%d 不匹配，已退化为等权。', mat2str(size(w)), n, p);
    w = ones(n, p);
    return
end
if any(~isfinite(w(:))) || any(w(:) < 0) || all(w(:) == 0)
    d.warnings{end+1} = '权重包含非有限/负值或全零，非法元素已修正为 1。';
    w(~isfinite(w) | w < 0) = 1;
    if all(w(:) == 0)
        w = ones(n, p);
    end
end
end

function c = toCellstr(x)
%TOCELLSTR 任意字符串容器 → 行 cellstr。
if iscell(x)
    c = cellfun(@charIfy, x(:).', 'UniformOutput', false);
elseif isstring(x)
    c = cellstr(x(:).');
elseif ischar(x)
    c = {x};
else
    c = {};
end
end

function s = charIfy(x)
%CHARIFY 把字符串/数值单元格内容转成 char。
if ischar(x)
    s = x;
elseif isstring(x)
    s = char(x);
elseif isnumeric(x) && isscalar(x)
    s = sprintf('%g', x);
else
    s = sprintf('%s', class(x));
end
end
