function unit = normalizeUnit(raw)
%NORMALIZEUNIT 校验并规范化单位字符串；无法识别时返回空串 ''。
%   unit = bma.io.internal.normalizeUnit(raw)
%
%   规范化规则（任务书要求）：
%     µM / μM / umol/L -> uM，s−1 / s^-1 / s-1 -> 1/s，min−1 -> 1/min，
%     M^-1 s^-1 -> 1/(M*s)，µM/min -> uM/min，% / fold / °C 保持原义。
%   同时作为**单位合法性校验**：只有词表中的基本单位、经组合/指数/前缀
%   变换后的结果才会返回；普通英文单词（of/and/...）一律返回 ''，从而
%   保证 extractNumbers 不把正文单词误当单位（precision-first）。
unit = '';
if nargin < 1 || isempty(raw)
    return
end
if isstring(raw)
    raw = char(raw);
end
if ~ischar(raw)
    return
end
u = unicodeUnits(raw);
u = strtrim(u);
if isempty(u)
    return
end
u = regexprep(u, '\s+', ' ');
% 去掉末尾句读（PDF 抽取常把句号粘在单位后）
u = regexprep(u, '[.,;:]+$', '');
u = strtrim(u);
if isempty(u)
    return
end
% 倍数/比例类
low = lower(u);
if any(strcmp(low, {'-fold', 'fold', 'folds', 'fold-change', 'foldchange'}))
    unit = 'fold';
    return
end
if any(strcmp(low, {'ratio', 'unitless', 'dimensionless'}))
    unit = '1';
    return
end
% 按 / 拆分子分母（最多三段，如 nmol/min/mg）
parts = regexp(u, '/', 'split');
parts = parts(~cellfun(@isempty, parts));
if isempty(parts) || numel(parts) > 3
    return
end
num = {};
den = {};
for k = 1:numel(parts)
    [pn, pd, ok] = parseGroup(parts{k});
    if ~ok
        return
    end
    if k == 1
        num = [num, pn]; %#ok<AGROW>
        den = [den, pd]; %#ok<AGROW>
    else
        den = [den, pn, pd]; %#ok<AGROW>
    end
end
unit = buildUnit(num, den);
if isempty(unit)
    return
end
unit = aliasCompound(unit);
if isempty(unit)
    return
end
if numel(unit) > 40
    unit = '';
end
end

% ---------------------------------------------------------------------------
function u = unicodeUnits(u)
% 统一微符号、乘号、上标、破折号
repl = {char(181), 'u'; ...   % micro sign
    char(956), 'u'; ...       % greek mu
    char(183), '*'; ...       % middle dot
    char(8901), '*'; ...      % dot operator
    char(8727), '*'; ...      % asterisk operator
    char(215), 'x'; ...       % multiplication sign
    char(178), '^2'; ...      % superscript 2
    char(179), '^3'; ...      % superscript 3
    char(185), '^1'; ...      % superscript 1
    char(8315), '-'};         % superscript minus
for k = 1:size(repl, 1)
    u = strrep(u, repl{k, 1}, repl{k, 2});
end
u = strrep(u, '**', '^');
% 中缀空格乘号：'M^-1 s^-1' 保持空格（parseGroup 会拆分）
end

function [num, den, ok] = parseGroup(s)
% 解析一个乘除段，如 'M^-1 s^-1' / 'nmol' / '1'
num = {};
den = {};
ok = false;
s = strtrim(s);
if isempty(s)
    ok = true;
    return
end
if strcmp(s, '1')
    ok = true;
    return
end
% unicodeUnits 已把 · / ⋅ 归一化为 '*'
tokens = regexp(s, '[\s*]+', 'split');
tokens = tokens(~cellfun(@isempty, tokens));
for k = 1:numel(tokens)
    [base, expn] = parseToken(tokens{k});
    if isempty(base)
        return
    end
    if expn == 1
        num{end + 1} = base; %#ok<AGROW>
    elseif expn == -1
        den{end + 1} = base; %#ok<AGROW>
    else
        num{end + 1} = [base '^' num2str(expn)]; %#ok<AGROW>
    end
end
ok = true;
end

function [base, expn] = parseToken(tok)
base = '';
expn = 1;
tok = strtrim(tok);
if isempty(tok)
    return
end
% 带 ^ 的指数：s^-1 / cm^2
m = regexp(tok, '^(?<b>.+?)\^(?<e>[-+]?\d+)$', 'names', 'once');
if ~isempty(m)
    b = aliasBase(m.b);
    if ~isempty(b)
        base = b;
        expn = str2double(m.e);
        return
    end
end
% 无 ^ 的负指数：s-1 / min-1 / cm-2
m = regexp(tok, '^(?<b>.+?)(?<e>-[123])$', 'names', 'once');
if ~isempty(m)
    b = aliasBase(m.b);
    if ~isempty(b)
        base = b;
        expn = str2double(m.e);
        return
    end
end
% 无 ^ 的正指数：cm2 / m3（仅对已知基本单位生效）
m = regexp(tok, '^(?<b>[A-Za-z]+)(?<e>[23])$', 'names', 'once');
if ~isempty(m)
    b = aliasBase(m.b);
    if ~isempty(b)
        base = b;
        expn = str2double(m.e);
        return
    end
end
b = aliasBase(tok);
if ~isempty(b)
    base = b;
    expn = 1;
end
end

function base = aliasBase(tok)
% 基本单位词表（大小写敏感；已做微符号归一化）
persistent M
if isempty(M)
    keys = { ...
        'M', 'mM', 'uM', 'nM', 'pM', 'fM', 'aM', ...
        'mol', 'mmol', 'umol', 'nmol', 'pmol', 'fmol', ...
        's', 'sec', 'secs', 'second', 'seconds', ...
        'ms', 'us', 'ns', 'ps', ...
        'min', 'mins', 'minute', 'minutes', ...
        'h', 'hr', 'hrs', 'hour', 'hours', ...
        'd', 'day', 'days', ...
        'L', 'l', 'liter', 'litre', 'liters', 'litres', ...
        'mL', 'ml', 'uL', 'ul', 'nL', 'nl', 'pL', 'pl', 'fL', 'fl', 'dL', 'dl', 'cL', 'cl', ...
        'milliliter', 'millilitre', 'microliter', 'microlitre', ...
        'g', 'mg', 'ug', 'ng', 'pg', 'fg', 'kg', ...
        'Da', 'kDa', 'MDa', ...
        'm', 'cm', 'mm', 'um', 'nm', 'pm', 'km', ...
        'cell', 'cells', 'molecule', 'molecules', 'copy', 'copies', ...
        'virion', 'virions', 'CFU', 'cfu', 'particle', 'particles', ...
        'count', 'counts', 'event', 'events', ...
        'case', 'cases', 'individual', 'individuals', 'person', 'persons', ...
        'people', 'inhabitant', 'inhabitants', 'patient', 'patients', ...
        'infection', 'infections', 'organism', 'organisms', ...
        'A', 'mA', 'uA', 'nA', 'pA', 'fA', ...
        'V', 'mV', 'uV', 'nV', ...
        'S', 'mS', 'uS', 'nS', 'pS', ...
        'Hz', 'kHz', 'MHz', 'GHz', ...
        'ohm', 'kohm', 'Mohm', ...
        'K', 'J', 'kJ', 'cal', 'kcal', 'Pa', 'kPa', 'MPa', ...
        'bar', 'mbar', 'atm', 'torr', 'N', 'mN', ...
        'bp', 'kb', 'nt', 'aa', 'U', 'mU', 'kat', ...
        '%', [char(176) 'C'], char(8240), 'au', 'AU', 'OD', 'OD600', 'OD260', 'OD280', ...
        'rpm', 'arb', 'arbitrary'};
    vals = { ...
        'M', 'mM', 'uM', 'nM', 'pM', 'fM', 'aM', ...
        'mol', 'mmol', 'umol', 'nmol', 'pmol', 'fmol', ...
        's', 's', 's', 's', 's', ...
        'ms', 'us', 'ns', 'ps', ...
        'min', 'min', 'min', 'min', ...
        'h', 'h', 'h', 'h', 'h', ...
        'd', 'd', 'd', ...
        'L', 'L', 'L', 'L', 'L', 'L', ...
        'mL', 'mL', 'uL', 'uL', 'nL', 'nL', 'pL', 'pL', 'fL', 'fL', 'dL', 'dL', 'cL', 'cL', ...
        'mL', 'mL', 'uL', 'uL', ...
        'g', 'mg', 'ug', 'ng', 'pg', 'fg', 'kg', ...
        'Da', 'kDa', 'MDa', ...
        'm', 'cm', 'mm', 'um', 'nm', 'pm', 'km', ...
        'cell', 'cell', 'molecule', 'molecule', 'copy', 'copy', ...
        'virion', 'virion', 'CFU', 'CFU', 'particle', 'particle', ...
        'count', 'count', 'event', 'event', ...
        'count', 'count', 'count', 'count', ...
        'count', 'count', 'count', 'count', ...
        'count', 'count', 'count', 'count', ...
        'count', 'count', 'count', ...
        'A', 'mA', 'uA', 'nA', 'pA', 'fA', ...
        'V', 'mV', 'uV', 'nV', ...
        'S', 'mS', 'uS', 'nS', 'pS', ...
        'Hz', 'kHz', 'MHz', 'GHz', ...
        'ohm', 'kohm', 'Mohm', ...
        'K', 'J', 'kJ', 'cal', 'kcal', 'Pa', 'kPa', 'MPa', ...
        'bar', 'mbar', 'atm', 'torr', 'N', 'mN', ...
        'bp', 'kb', 'nt', 'aa', 'U', 'mU', 'kat', ...
        '%', [char(176) 'C'], char(8240), 'au', 'AU', 'OD', 'OD600', 'OD260', 'OD280', ...
        'rpm', 'arb', 'arbitrary'};
    % 摄氏度常见写法
    degC = [char(176) 'C'];
    extraKeys = {degC, 'degC', 'degc', 'celsius', 'degreeC'};
    extraVals = {degC, degC, degC, degC, degC};
    keys = [keys, extraKeys];
    vals = [vals, extraVals];
    M = containers.Map(keys, vals);
end
if isKey(M, tok)
    base = M(tok);
else
    base = '';
end
end

function unit = buildUnit(num, den)
unit = '';
if isempty(num) && isempty(den)
    return
end
if isempty(num)
    numStr = '1';
else
    numStr = strjoin(num, '*');
end
if isempty(den)
    unit = numStr;
    return
end
if numel(den) > 1
    denStr = ['(' strjoin(den, '*') ')'];
else
    denStr = den{1};
end
unit = [numStr '/' denStr];
end

function unit = aliasCompound(unit)
% 常见复合写法归一化（mol/L 系列 -> M 系列；umol/L -> uM ...）
persistent M
if isempty(M)
    keys = {'mol/L', 'mmol/L', 'umol/L', 'nmol/L', 'pmol/L', 'fmol/L', ...
        'mol/l', 'mmol/l', 'umol/l', 'nmol/l', 'pmol/l', 'fmol/l', ...
        'uM/s', 'mol/(s*L)'};
    vals = {'M', 'mM', 'uM', 'nM', 'pM', 'fM', ...
        'M', 'mM', 'uM', 'nM', 'pM', 'fM', ...
        'uM/s', 'M/s'};
    M = containers.Map(keys, vals);
end
if isKey(M, unit)
    unit = M(unit);
end
end
