function dim = parseUnit(unitStr, T)
%PARSEUNIT 解析单位字符串为量纲向量。
%   dim = parseUnit(unitStr, T) 中 T 为 unitTable() 返回的映射表。
%   支持：单单位（'uM'、'nM'、'1'、'person'）、商/积（'nM/min'、'1/(uM*s)'、
%   'mol/L'）、幂（'s^-1'、'L^2'）、括号组合。
%   返回 1×7 量纲向量 [amount volume time temperature length mass count]。
%   空单位抛出 BMA_UNIT_SYNTAX；无法识别的单位名抛出 BMA_UNIT_UNKNOWN。
if nargin < 2 || isempty(T)
    T = unitTable();
end
if ~ischar(unitStr)
    error('bma:unit:syntax', '单位必须是字符向量');
end
if isempty(strtrim(unitStr))
    error('bma:unit:syntax', '单位为空');
end
toks = unitTokens(unitStr);
[dim, i] = uExpr(toks, 1, T);
if i <= numel(toks)
    error('bma:unit:syntax', '单位表达式在 "%s" 附近存在多余内容', toks(i).text);
end
end

% -------------------------------------------------------------------------
% 词法分析：数字、单位名（允许 µ/μ/°/%%）、* / ^ 与括号
% -------------------------------------------------------------------------
function toks = unitTokens(str)
toks = struct('type', {}, 'text', {}, 'pos', {});
n = numel(str);
i = 1;
while i <= n
    ch = str(i);
    if ch == ' ' || ch == char(9) || ch == char(10) || ch == char(13)
        i = i + 1;
        continue
    end
    tok = struct('type', '', 'text', '', 'pos', i);
    if isUDigit(ch) || ch == '.'
        j = i;
        while j <= n && (isUDigit(str(j)) || str(j) == '.')
            j = j + 1;
        end
        tok.type = 'number';
        tok.text = str(i:j-1);
        i = j;
    elseif isUIdentChar(ch)
        j = i;
        while j <= n && isUIdentChar(str(j))
            j = j + 1;
        end
        tok.type = 'ident';
        tok.text = str(i:j-1);
        i = j;
    elseif ch == '*' || ch == '/' || ch == '^' || ch == '+' || ch == '-'
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
    else
        error('bma:unit:syntax', '单位字符串包含不允许的字符 "%s"（位置 %d）', ch, i);
    end
    toks(end+1) = tok; %#ok<AGROW>
end
end

function tf = isUDigit(ch)
tf = ch >= '0' && ch <= '9';
end

function tf = isUIdentChar(ch)
tf = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ...
    ch == '_' || ch == char(181) || ch == char(956) || ch == char(176) || ch == '%';
end

% -------------------------------------------------------------------------
% 递归下降解析：expr := term (('*'|'/') term)*；term := factor ('^' sign int)?
% -------------------------------------------------------------------------
function [dim, i] = uExpr(toks, i, T)
[dim, i] = uTerm(toks, i, T);
n = numel(toks);
while i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '*' || toks(i).text == '/')
    op = toks(i).text;
    [d2, i] = uTerm(toks, i + 1, T);
    if op == '*'
        dim = dim + d2;
    else
        dim = dim - d2;
    end
end
end

function [dim, i] = uTerm(toks, i, T)
[dim, i] = uFactor(toks, i, T);
n = numel(toks);
if i <= n && strcmp(toks(i).type, 'op') && toks(i).text == '^'
    sign = 1;
    i = i + 1;
    if i <= n && strcmp(toks(i).type, 'op') && (toks(i).text == '+' || toks(i).text == '-')
        if toks(i).text == '-'
            sign = -1;
        end
        i = i + 1;
    end
    if i > n || ~strcmp(toks(i).type, 'number')
        error('bma:unit:syntax', '单位中的幂指数必须是数字');
    end
    expVal = str2double(toks(i).text);
    if isnan(expVal)
        error('bma:unit:syntax', '单位中的幂指数非法："%s"', toks(i).text);
    end
    dim = dim * (sign * expVal);
    i = i + 1;
end
end

function [dim, i] = uFactor(toks, i, T)
n = numel(toks);
if i > n
    error('bma:unit:syntax', '单位表达式意外结束');
end
tok = toks(i);
if strcmp(tok.type, 'number')
    % 纯数字因子（如 "1"）视为无量纲
    dim = zeros(1, 8);
    i = i + 1;
elseif strcmp(tok.type, 'ident')
    dim = lookupUnit(T, tok.text);
    i = i + 1;
elseif strcmp(tok.type, 'lparen')
    [dim, i] = uExpr(toks, i + 1, T);
    if i > n || ~strcmp(toks(i).type, 'rparen')
        error('bma:unit:syntax', '单位表达式缺少右括号 ")"');
    end
    i = i + 1;
else
    error('bma:unit:syntax', '单位表达式在 "%s" 处语法错误', tok.text);
end
end

function dim = lookupUnit(T, name)
% 单位名严格大小写敏感（mS 电导 ≠ ms 毫秒）；别名只来自 kb/units.json 的 aliases。
keys = T.keys;
idx = find(strcmp(keys, name), 1);
if isempty(idx)
    error('bma:unit:unknown', ...
        '未识别的单位 "%s"（单位名大小写敏感；可用单位见 kb/units.json，或使用 uM、nM/min、1/(uM*s)、1、person 等）', name);
end
dim = T(keys{idx});
end
