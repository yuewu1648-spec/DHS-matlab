function toks = tokenizeExpression(expr)
%TOKENIZEEXPRESSION 将受限数学表达式拆分为词法单元。
%   toks = tokenizeExpression(expr) 返回 1×N 结构体数组，字段：
%       type : 'number' | 'ident' | 'op' | 'lparen' | 'rparen' | 'comma'
%       text : 该词法单元的原始文本
%       pos  : 在表达式中的起始位置（1 基，用于错误提示）
%
% 允许的字符：数字（含小数点与科学计数法）、ASCII 标识符、+ - * / ^、括号、逗号、空白。
% 其他字符直接抛出 BMA_EXPR_CHAR 异常，由上层转换为结构化错误。
if ~ischar(expr)
    error('bma:expr:type', '表达式必须是字符向量');
end
toks = struct('type', {}, 'text', {}, 'pos', {});
n = numel(expr);
i = 1;
while i <= n
    ch = expr(i);
    if ch == ' ' || ch == char(9) || ch == char(10) || ch == char(13)
        i = i + 1;
        continue
    end
    tok = struct('type', '', 'text', '', 'pos', i);
    if isDigit(ch) || ch == '.'
        j = i;
        while j <= n && (isDigit(expr(j)) || expr(j) == '.')
            j = j + 1;
        end
        % 科学计数法：e/E 后必须跟（可带符号的）数字
        if j <= n && (expr(j) == 'e' || expr(j) == 'E')
            k = j + 1;
            if k <= n && (expr(k) == '+' || expr(k) == '-')
                k = k + 1;
            end
            if k <= n && isDigit(expr(k))
                j = k;
                while j <= n && isDigit(expr(j))
                    j = j + 1;
                end
            end
        end
        tok.type = 'number';
        tok.text = expr(i:j-1);
        i = j;
    elseif isIdentStart(ch)
        j = i;
        while j <= n && isIdentPart(expr(j))
            j = j + 1;
        end
        tok.type = 'ident';
        tok.text = expr(i:j-1);
        i = j;
    elseif ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '^'
        tok.type = 'op';
        tok.text = ch;
        i = i + 1;
    elseif ch == '('
        tok.type = 'lparen';
        tok.text = '(';
        i = i + 1;
    elseif ch == ')'
        tok.type = 'rparen';
        tok.text = ')';
        i = i + 1;
    elseif ch == ','
        tok.type = 'comma';
        tok.text = ',';
        i = i + 1;
    else
        error('bma:expr:char', '表达式中包含不允许的字符 "%s"（位置 %d）', ch, i);
    end
    toks(end+1) = tok; %#ok<AGROW>
end
end

function tf = isDigit(ch)
tf = ch >= '0' && ch <= '9';
end

function tf = isIdentStart(ch)
tf = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_';
end

function tf = isIdentPart(ch)
tf = isIdentStart(ch) || (ch >= '0' && ch <= '9');
end
