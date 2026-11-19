function [code, info] = parseExpression(expr, refs)
%PARSEEXPRESSION 将受限数学表达式编译为安全的 MATLAB 代码字符串。
%   [code, info] = parseExpression(expr, refs)
%
%   expr : 字符向量，例如 'beta*S*I/N'
%   refs : containers.Map，键为合法标识符，值为替换用的 MATLAB 代码片段，
%          例如 'y(3)'、'p(1)'、'0.5'。表达式中的每个标识符必须在此表中。
%
%   code : 替换后的 MATLAB 表达式字符串（可直接 str2func 成 @(y,p) ...）；
%          只包含数字、y(i)/p(j) 索引、+ - * / ^、括号与白名单函数。
%   info : struct('ids',{用到的标识符}, 'functions',{用到的函数名})
%
% 白名单函数：exp / log / sqrt / min / max。禁止任何其他函数调用，
% 因此不会执行任意代码。语法、未知标识符、禁用函数分别抛出
% BMA_EXPR_SYNTAX / BMA_EXPR_UNKNOWN_ID / BMA_EXPR_FORBIDDEN 异常。
if ~ischar(expr) || isempty(strtrim(expr))
    error('bma:expr:syntax', '表达式必须是非空字符串');
end
toks = tokenizeExpression(expr);
[code, idx, ids, funcs] = parseSumLocal(toks, 1, refs);
if idx <= numel(toks)
    tok = toks(idx);
    error('bma:expr:syntax', '表达式在 "%s" 处存在多余的语法成分（位置 %d）', tok.text, tok.pos);
end
if isempty(ids)
    ids = {};
else
    ids = unique(ids, 'stable');
end
if isempty(funcs)
    funcs = {};
else
    funcs = unique(funcs, 'stable');
end
info = struct('ids', {ids}, 'functions', {funcs});
end

% -------------------------------------------------------------------------
% 递归下降解析：expr := term (('+'|'-') term)*
%              term := unary (('*'|'/') unary)*
%              unary := ('+'|'-') unary | power
%              power := primary ('^' unary)?
%              primary := number | ident | ident '(' args ')' | '(' expr ')'
% -------------------------------------------------------------------------
function [code, i, ids, funcs] = parseSumLocal(toks, i, refs)
[code, i, ids, funcs] = parseTermLocal(toks, i, refs);
n = numel(toks);
while i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '+' || toks(i).text == '-')
    op = toks(i).text;
    [rhs, i, ids2, funcs2] = parseTermLocal(toks, i + 1, refs);
    code = sprintf('(%s %s %s)', code, op, rhs);
    ids = [ids, ids2]; %#ok<AGROW>
    funcs = [funcs, funcs2]; %#ok<AGROW>
end
end

function [code, i, ids, funcs] = parseTermLocal(toks, i, refs)
[code, i, ids, funcs] = parseUnaryLocal(toks, i, refs);
n = numel(toks);
while i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '*' || toks(i).text == '/')
    op = toks(i).text;
    [rhs, i, ids2, funcs2] = parseUnaryLocal(toks, i + 1, refs);
    code = sprintf('(%s %s %s)', code, op, rhs);
    ids = [ids, ids2]; %#ok<AGROW>
    funcs = [funcs, funcs2]; %#ok<AGROW>
end
end

function [code, i, ids, funcs] = parseUnaryLocal(toks, i, refs)
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '+' || toks(i).text == '-')
    sign = toks(i).text;
    [operand, i, ids, funcs] = parseUnaryLocal(toks, i + 1, refs);
    if sign == '-'
        code = ['(-' operand ')'];
    else
        code = operand;
    end
    return
end
[code, i, ids, funcs] = parsePowerLocal(toks, i, refs);
end

function [code, i, ids, funcs] = parsePowerLocal(toks, i, refs)
[base, i, ids, funcs] = parsePrimaryLocal(toks, i, refs);
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'op') && toks(i).text == '^'
    [exponent, i, ids2, funcs2] = parseUnaryLocal(toks, i + 1, refs);
    code = sprintf('(%s^%s)', base, exponent);
    ids = [ids, ids2]; %#ok<AGROW>
    funcs = [funcs, funcs2]; %#ok<AGROW>
else
    code = base;
end
end

function [code, i, ids, funcs] = parsePrimaryLocal(toks, i, refs)
n = numel(toks);
if i > n
    error('bma:expr:syntax', '表达式意外结束（期望一个数字、标识符或 "("）');
end
tok = toks(i);
ids = {};
funcs = {};
if strcmp(tok.type, 'number')
    if isempty(regexp(tok.text, '^(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$', 'once'))
        error('bma:expr:syntax', '非法的数字字面量 "%s"（位置 %d）', tok.text, tok.pos);
    end
    code = tok.text;
    i = i + 1;
elseif strcmp(tok.type, 'ident')
    name = tok.text;
    if i + 1 <= n && strcmp(toks(i + 1).type, 'lparen')
        allowed = {'exp', 'log', 'sqrt', 'sin', 'cos', 'tan', 'min', 'max'};
        if ~any(strcmp(name, allowed))
            error('bma:expr:forbidden', ...
                '表达式中不允许调用函数 "%s"（仅允许 exp/log/sqrt/sin/cos/tan/min/max）', name);
        end
        [args, i, ids, funcs] = parseArgsLocal(toks, i + 2, refs, name);
        if any(strcmp(name, {'exp', 'log', 'sqrt', 'sin', 'cos', 'tan'})) && numel(args) ~= 1
            error('bma:expr:syntax', '函数 %s 需要恰好 1 个参数', name);
        end
        if numel(args) < 1
            error('bma:expr:syntax', '函数 %s 缺少参数', name);
        end
        code = sprintf('%s(%s)', name, strjoin(args, ', '));
        funcs = [funcs, {name}];
    else
        if ~isKey(refs, name)
            error('bma:expr:unknown_id', ...
                '表达式引用了未定义的标识符 "%s"（只能引用 variables/parameters/compartments 的 id）', name);
        end
        code = refs(name);
        ids = {name};
        i = i + 1;
    end
elseif strcmp(tok.type, 'lparen')
    [code, i, ids, funcs] = parseSumLocal(toks, i + 1, refs);
    if i > n || ~strcmp(toks(i).type, 'rparen')
        error('bma:expr:syntax', '缺少右括号 ")"（位置 %d 附近）', tok.pos);
    end
    i = i + 1;
    code = ['(' code ')'];
else
    error('bma:expr:syntax', '表达式在 "%s" 处语法错误（位置 %d）', tok.text, tok.pos);
end
end

function [args, i, ids, funcs] = parseArgsLocal(toks, i, refs, fname)
% 解析函数调用的参数列表（起始位置在 "(" 之后）
args = {};
ids = {};
funcs = {};
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'rparen')
    i = i + 1;
    return
end
while true
    [arg, i, ids2, funcs2] = parseSumLocal(toks, i, refs);
    args{end+1} = arg; %#ok<AGROW>
    ids = [ids, ids2]; %#ok<AGROW>
    funcs = [funcs, funcs2]; %#ok<AGROW>
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
