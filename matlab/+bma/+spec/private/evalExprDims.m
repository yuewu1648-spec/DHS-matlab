function [dim, numval] = evalExprDims(expr, dimRefs)
%EVALEXPRDIMS 对速率/输出表达式做量纲检查。
%   [dim, numval] = evalExprDims(expr, dimRefs)
%
%   dimRefs : containers.Map，键为标识符，值为 1×7 量纲向量
%             （[amount volume time temperature length mass count]）。
%   返回 dim 为表达式的量纲向量；若某个参与量的量纲未知（NaN）则返回 NaN 向量。
%   numval 为表达式在“数值常量”意义下的值（仅当表达式全部由数字常量组成时有效，
%   用于判断 Hill 指数等是否为无量纲常数），否则为 NaN。
%
%   量纲不一致（+、min、max 两侧量纲不同，exp/log 参数非无量纲等）会抛出
%   BMA_UNIT_MISMATCH 异常；语法错误抛出 BMA_EXPR_* 异常。
%   未知标识符抛出 BMA_EXPR_UNKNOWN_ID。
if ~ischar(expr) || isempty(strtrim(expr))
    error('bma:expr:syntax', '表达式必须是非空字符串');
end
toks = tokenizeExpression(expr);
[dim, numval, idx] = sumLocal(toks, 1, dimRefs);
if idx <= numel(toks)
    error('bma:expr:syntax', '表达式在 "%s" 处存在多余的语法成分', toks(idx).text);
end
end

function [dim, numval, i] = sumLocal(toks, i, dimRefs)
[dim, numval, i] = termLocal(toks, i, dimRefs);
n = numel(toks);
while i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '+' || toks(i).text == '-')
    op = toks(i).text;
    [d2, v2, i] = termLocal(toks, i + 1, dimRefs);
    dim = addDims(dim, d2, op);
    if isnan(numval) || isnan(v2)
        numval = NaN;
    elseif op == '+'
        numval = numval + v2;
    else
        numval = numval - v2;
    end
end
end

function [dim, numval, i] = termLocal(toks, i, dimRefs)
[dim, numval, i] = unaryLocal(toks, i, dimRefs);
n = numel(toks);
while i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '*' || toks(i).text == '/')
    op = toks(i).text;
    [d2, v2, i] = unaryLocal(toks, i + 1, dimRefs);
    if op == '*'
        dim = dim + d2;
        if isnan(numval) || isnan(v2)
            numval = NaN;
        else
            numval = numval * v2;
        end
    else
        dim = dim - d2;
        if isnan(numval) || isnan(v2)
            numval = NaN;
        elseif v2 == 0
            numval = NaN;
        else
            numval = numval / v2;
        end
    end
end
end

function [dim, numval, i] = unaryLocal(toks, i, dimRefs)
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '+' || toks(i).text == '-')
    sign = toks(i).text;
    [dim, numval, i] = unaryLocal(toks, i + 1, dimRefs);
    if sign == '-'
        numval = -numval;
    end
    return
end
[dim, numval, i] = powerLocal(toks, i, dimRefs);
end

function [dim, numval, i] = powerLocal(toks, i, dimRefs)
[baseDim, baseVal, i] = primaryLocal(toks, i, dimRefs);
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'op') && toks(i).text == '^'
    [expDim, expVal, i] = unaryLocal(toks, i + 1, dimRefs);
    if any(abs(expDim) > 1e-12)
        throw(MException('bma:unit:mismatch', '幂指数的量纲必须无量纲'));
    end
    if isnan(expVal) || any(isnan(baseDim))
        dim = nan(1, 8);
        numval = NaN;
    else
        dim = baseDim * expVal;
        numval = baseVal ^ expVal;
    end
else
    dim = baseDim;
    numval = baseVal;
end
end

function [dim, numval, i] = primaryLocal(toks, i, dimRefs)
n = numel(toks);
if i > n
    error('bma:expr:syntax', '表达式意外结束');
end
tok = toks(i);
if strcmp(tok.type, 'number')
    dim = zeros(1, 8);
    numval = str2double(tok.text);
    if isnan(numval)
        error('bma:expr:syntax', '非法数字 "%s"', tok.text);
    end
    i = i + 1;
elseif strcmp(tok.type, 'ident')
    name = tok.text;
    if i + 1 <= n && strcmp(toks(i + 1).type, 'lparen')
        allowed = {'exp', 'log', 'sqrt', 'sin', 'cos', 'tan', 'min', 'max'};
        if ~any(strcmp(name, allowed))
            error('bma:expr:forbidden', '表达式不允许调用函数 "%s"', name);
        end
        [argsDim, argsVal, i] = argsLocal(toks, i + 2, dimRefs, name);
        if numel(argsDim) ~= 1 && any(strcmp(name, {'exp', 'log', 'sqrt', 'sin', 'cos', 'tan'}))
            error('bma:expr:syntax', '函数 %s 需要 1 个参数', name);
        end
        switch name
            case 'exp'
                requireDimensionless(argsDim{1}, 'exp');
                dim = zeros(1, 8);
                numval = exp(argsVal{1});
            case 'log'
                requireDimensionless(argsDim{1}, 'log');
                dim = zeros(1, 8);
                if isnan(argsVal{1})
                    numval = NaN;
                else
                    numval = log(argsVal{1});
                end
            case 'sqrt'
                dim = argsDim{1} / 2;
                if isnan(argsVal{1})
                    numval = NaN;
                else
                    numval = sqrt(argsVal{1});
                end
            case {'sin', 'cos', 'tan'}
                requireDimensionless(argsDim{1}, name);
                dim = zeros(1, 8);
                numval = feval(name, argsVal{1});
            case 'abs'
                dim = argsDim{1};
                numval = abs(argsVal{1});
            otherwise  % min / max
                dim = argsDim{1};
                for k = 2:numel(argsDim)
                    if ~dimsEqual(dim, argsDim{k})
                        throw(MException('bma:unit:mismatch', ...
                            '函数 %s 各参数的量纲必须一致', name));
                    end
                end
                vals = [argsVal{:}];
                if any(isnan(vals))
                    numval = NaN;
                elseif strcmp(name, 'min')
                    numval = min(vals);
                else
                    numval = max(vals);
                end
        end
    else
        if ~isKey(dimRefs, name)
            error('bma:expr:unknown_id', '表达式引用了未定义的标识符 "%s"', name);
        end
        dim = dimRefs(name);
        numval = NaN;
        i = i + 1;
    end
elseif strcmp(tok.type, 'lparen')
    [dim, numval, i] = sumLocal(toks, i + 1, dimRefs);
    if i > n || ~strcmp(toks(i).type, 'rparen')
        error('bma:expr:syntax', '缺少右括号 ")"');
    end
    i = i + 1;
else
    error('bma:expr:syntax', '表达式在 "%s" 处语法错误', tok.text);
end
end

function [argsDim, argsVal, i] = argsLocal(toks, i, dimRefs, fname)
argsDim = {};
argsVal = {};
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'rparen')
    i = i + 1;
    return
end
while true
    [d, v, i] = sumLocal(toks, i, dimRefs);
    argsDim{end+1} = d; %#ok<AGROW>
    argsVal{end+1} = v; %#ok<AGROW>
    if i <= n && strcmp(toks(i).type, 'comma')
        i = i + 1;
        continue
    end
    if i <= n && strcmp(toks(i).type, 'rparen')
        i = i + 1;
        break
    end
    error('bma:expr:syntax', '函数 %s 的参数列表缺少 ")"', fname);
end
end

function dim = addDims(a, b, op)
if any(isnan(a)) || any(isnan(b))
    dim = nan(1, 8);
    return
end
if ~dimsEqual(a, b)
    error('bma:unit:mismatch', '运算符 "%s" 两侧量纲不一致（%s 与 %s）', ...
        op, dimText(a), dimText(b));
end
dim = a;
end

function tf = dimsEqual(a, b)
tf = all(abs(a - b) < 1e-9);
end

function requireDimensionless(d, fname)
if any(isnan(d))
    return
end
if any(abs(d) > 1e-12)
    throw(MException('bma:unit:mismatch', '函数 %s 的参数必须无量纲', fname));
end
end

function s = dimText(d)
if any(isnan(d))
    s = '未知量纲';
    return
end
base = {'amount', 'volume', 'time', 'temperature', 'length', 'mass', 'count', 'current'};
if all(abs(d) < 1e-12)
    s = '无量纲';
    return
end
parts = {};
for k = 1:numel(base)
    if abs(d(k)) > 1e-12
        if abs(d(k) - 1) < 1e-12
            parts{end+1} = base{k}; %#ok<AGROW>
        else
            parts{end+1} = sprintf('%s^%g', base{k}, d(k)); %#ok<AGROW>
        end
    end
end
s = strjoin(parts, '*');
end
