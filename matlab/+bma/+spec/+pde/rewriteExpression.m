function [expr, info] = rewriteExpression(expr, speciesId, n, opts)
%REWRITEEXPRESSION Rewrite PDE node references and field statistics to ODE ids.
%   [expr, info] = bma.spec.pde.rewriteExpression(expr, 'C', 16, opts)
%
% Supported syntax (v1):
%   C[i]              -> C_i (1-based node index, i=1..n)
%   max(C) / min(C)   -> nested max/min over all nodes
%   mean(C)           -> arithmetic mean over nodes
%   mean_over_domain(C) -> volume-weighted mean over nodes
%   integral(C)       -> sum(V_i*C_i); caller supplies the matching output unit
%   argmax(C)         -> not supported in v1 (scalar time-series expression cannot
%                        return an index); throws BMA_PDE_OUTPUT_UNSUPPORTED.
%
% opts.cell_volume / opts.dx / opts.dim provide physical weights; defaults are
% uniform (slab-like) weights. Unknown species ids are left for the ordinary
% expression parser to report.
if nargin < 4 || isempty(opts)
    opts = struct();
end
expr = char(expr);
speciesId = char(speciesId);
n = double(n);
info = struct('node_refs', 0, 'stats', {{}});
if n < 2 || n ~= round(n)
    error('bma:pde:badGrid', 'n 必须是 >=2 的整数');
end
% ---- field statistics (must run before node substitution) ----
patStats = '(max|min|mean|mean_over_domain|integral|argmax)\s*\(\s*([A-Za-z][A-Za-z0-9_]*)\s*\)';
while true
    [tok, startPos, endPos] = regexp(expr, patStats, 'tokens', 'start', 'end', 'once');
    if isempty(tok)
        break
    end
    fname = lower(tok{1});
    sid = tok{2};
    replacement = '';
    if strcmp(sid, speciesId)
        replacement = statExpression(fname, speciesId, n, opts);
        info.stats{end+1} = fname;
    end
    if isempty(replacement)
        break
    end
    expr = [expr(1:startPos-1) replacement expr(endPos+1:end)];
end
% ---- node references species[i] ----
patNode = '([A-Za-z][A-Za-z0-9_]*)\s*\[\s*(\d+)\s*\]';
while true
    [tok, startPos, endPos] = regexp(expr, patNode, 'tokens', 'start', 'end', 'once');
    if isempty(tok)
        break
    end
    sid = tok{1};
    idx = str2double(tok{2});
    replacement = '';
    if strcmp(sid, speciesId)
        if idx < 1 || idx > n || idx ~= round(idx)
            error('bma:pde:nodeOutOfRange', ...
                '输出表达式中的 %s[%d] 越界（有效 1..%d）', sid, idx, n);
        end
        replacement = sprintf('%s_%d', sid, idx);
        info.node_refs = info.node_refs + 1;
    end
    if isempty(replacement)
        break
    end
    expr = [expr(1:startPos-1) replacement expr(endPos+1:end)];
end
end

% ---------------------------------------------------------------------------
function s = statExpression(fname, sid, n, opts)
ids = arrayfun(@(k) sprintf('%s_%d', sid, k), 1:n, 'UniformOutput', false);
switch fname
    case 'max'
        s = ids{1};
        for k = 2:n
            s = sprintf('max(%s, %s)', s, ids{k});
        end
    case 'min'
        s = ids{1};
        for k = 2:n
            s = sprintf('min(%s, %s)', s, ids{k});
        end
    case {'mean', 'mean_over_domain'}
        w = weights(opts, n);
        if strcmp(fname, 'mean')
            w = ones(1, n);
        end
        s = weightedSum(ids, w);
        s = sprintf('(%s)/%.17g', s, sum(w));
    case 'integral'
        w = weights(opts, n);
        dx = getOpt(opts, 'dx', 1);
        dim = getOpt(opts, 'dim', 1);
        s = weightedSum(ids, w * dx^dim);
    case 'argmax'
        error('bma:pde:unsupportedOutput', ...
            ['v1 不支持 argmax(C) 作为标量输出（索引随时间的 argmax 无法用受限表达式表示）。' ...
             '请改用 max(C)/C[i]，或把 argmax 作为后处理产物。']);
    otherwise
        error('bma:pde:unsupportedOutput', '不支持的场统计量 "%s"', fname);
end
end

function s = weightedSum(ids, w)
parts = cell(1, numel(ids));
for k = 1:numel(ids)
    parts{k} = sprintf('%.17g*%s', w(k), ids{k});
end
s = parts{1};
for k = 2:numel(parts)
    s = sprintf('%s + %s', s, parts{k});
end
end

function w = weights(opts, n)
w = getOpt(opts, 'cell_volume', ones(1, n));
if numel(w) ~= n
    w = ones(1, n);
end
end

function v = getOpt(opts, name, default)
v = default;
if isfield(opts, name) && ~isempty(opts.(name))
    v = opts.(name);
end
end
