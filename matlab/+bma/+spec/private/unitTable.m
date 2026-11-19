function T = unitTable(kbUnits)
%UNITTABLE 单位字符串 → 量纲向量 的映射表（规范见 kb/units.json v2）。
%   T = unitTable()          使用内置单位表 + kb/units.json（若存在，权威覆盖）
%   T = unitTable(kbUnits)   使用传入的知识库单位结构体
%
%   量纲向量顺序（8 个 base）：
%       [amount volume time temperature length mass count current]
%   例如：uM（微摩尔/升）→ [1 -1 0 0 0 0 0 0]；1/s → [0 0 -1 0 0 0 0 0]；
%         mV → 电压量纲 = mass*length^2/(time^3*current)。
%   只关心量纲（用于一致性检查），不关心换算因子；复合单位由 parseUnit 按
%   * / ^ 组合解析。单位名严格大小写敏感（mS 电导 ≠ ms 毫秒）。
if nargin < 1
    kbUnits = loadKbUnits();
end
T = containers.Map('KeyType', 'char', 'ValueType', 'any');

Z = zeros(1, 8);
amount = [1 0 0 0 0 0 0 0];
volume = [0 1 0 0 0 0 0 0];
time = [0 0 1 0 0 0 0 0];
temperature = [0 0 0 1 0 0 0 0];
length_ = [0 0 0 0 1 0 0 0];
mass = [0 0 0 0 0 1 0 0];
count = [0 0 0 0 0 0 1 0];
current = [0 0 0 0 0 0 0 1];
concentration = amount - volume;
frequency = -time;
voltage = mass + 2 * length_ - 3 * time - current;
charge_ = current + time;
capacitance = charge_ - voltage;
conductance = current - voltage;
resistance = voltage - current;

% ---- 无量纲与信号强度 ----
T = addMany(T, {'1', 'dimensionless', 'unitless', 'ratio', '-', '%'}, Z);
T = addMany(T, {'AU', 'RFU', 'OD', 'au', 'arbitrary_unit', 'arbitrary_units'}, Z);

% ---- 物质的量 ----
T = addMany(T, {'mol', 'mole', 'moles', 'mmol', 'umol', 'µmol', 'μmol', ...
    'nmol', 'pmol', 'fmol', 'kmol'}, amount);

% ---- 浓度 ----
T = addMany(T, {'M', 'mM', 'uM', 'µM', 'μM', 'nM', 'pM', 'fM', 'aM'}, concentration);
T = addMany(T, {'mol/L', 'mol/l'}, concentration);

% ---- 时间 ----
T = addMany(T, {'s', 'sec', 'secs', 'second', 'seconds'}, time);
T = addMany(T, {'ms', 'min', 'mins', 'minute', 'minutes'}, time);
T = addMany(T, {'h', 'hr', 'hrs', 'hour', 'hours'}, time);
T = addMany(T, {'day', 'days', 'd', 'wk', 'week', 'weeks', ...
    'month', 'months', 'year', 'years', 'yr'}, time);

% ---- 体积 ----
T = addMany(T, {'L', 'l', 'liter', 'liters', 'litre', 'litres', 'dm^3'}, volume);
T = addMany(T, {'mL', 'ml', 'uL', 'µL', 'μL', 'nL', 'pL', 'fL', 'dL'}, volume);

% ---- 计数（细胞/个体/分子数等） ----
T = addMany(T, {'molecule', 'molecules', 'copy', 'copies', 'cell', 'cells', ...
    'person', 'persons', 'people', 'individual', 'individuals', 'count', 'counts', ...
    'CFU', 'cfu', 'virion', 'virions', 'particle', 'particles', ...
    'event', 'events', 'item', 'items', 'nucleus', 'nuclei'}, count);

% ---- 长度 ----
T = addMany(T, {'m', 'meter', 'meters', 'metre', 'metres', 'cm', ...
    'mm', 'um', 'µm', 'μm', 'nm', 'km', 'dm'}, length_);

% ---- 质量 / 质量浓度 ----
T = addMany(T, {'g', 'gram', 'grams', 'kg', 'mg', 'ug', 'µg', 'μg', 'ng', ...
    'Da', 'kDa', 'dalton'}, mass);
T = addMany(T, {'g/L', 'mg/L', 'ng/L', 'g/mL', 'mg/mL', 'ug/mL', 'µg/mL'}, mass - volume);

% ---- 温度 ----
T = addMany(T, {'K', 'kelvin', 'C', 'celsius', 'degC', '°C'}, temperature);

% ---- 频率 / 速率常数 ----
T = addMany(T, {'Hz', 'kHz', 'MHz', '1/s', '1/ms', '1/min', '1/h', '1/day', '1/year', ...
    'per_s', 'per_min', 'per_h', 'per_day', 's^-1', 'min^-1', 'h^-1', 'day^-1', 'ms^-1'}, frequency);

% ---- 电生理（HH 等） ----
T = addMany(T, {'A', 'mA', 'uA', 'µA', 'μA', 'nA', 'pA', 'fA'}, current);
T = addMany(T, {'V', 'mV', 'uV', 'µV', 'μV', 'kV'}, voltage);
T = addMany(T, {'C', 'mC', 'uC', 'nC', 'pC'}, charge_);
T = addMany(T, {'F', 'mF', 'uF', 'µF', 'μF', 'nF', 'pF'}, capacitance);
T = addMany(T, {'S', 'mS', 'uS', 'nS', 'pS'}, conductance);
T = addMany(T, {'ohm', 'Ohm', 'kohm', 'kOhm', 'Mohm', 'Gohm'}, resistance);
T = addMany(T, {'Hz'}, frequency);

% ---- 热力学 / 功率 / 压强 / 质量摩尔浓度（ISS-08） ----
energy = mass + 2 * length_ - 2 * time;
power = energy - time;
pressure = mass - length_ - 2 * time;
T = addMany(T, {'J', 'joule', 'joules', 'kJ', 'mJ', 'MJ'}, energy);
T = addMany(T, {'W', 'watt', 'watts', 'kW', 'mW', 'uW', 'µW', 'μW'}, power);
T = addMany(T, {'Pa', 'pascal', 'kPa', 'MPa', 'mmHg', 'bar', 'mbar', 'atm'}, pressure);
T = addMany(T, {'J/mol', 'kJ/mol', 'J/mol/K', 'kJ/mol/K'}, energy - amount);
T = addMany(T, {'W/kg', 'mW/kg'}, power - mass);
T = addMany(T, {'mol/kg', 'mmol/kg', 'umol/kg'}, amount - mass);
T = addMany(T, {'kcal', 'kcal/mol'}, energy);

% ---- 合并知识库定义（kb/units.json v2：units 为对象数组） ----
if isstruct(kbUnits) && isfield(kbUnits, 'units')
    items = kbItems(kbUnits.units);
    for k = 1:numel(items)
        item = items{k};
        if ~isstruct(item)
            continue
        end
        id = char(string(getFieldLocal(item, 'id', '')));
        dimName = char(string(getFieldLocal(item, 'dim', '')));
        dim = dimFromName(dimName);
        if isempty(dim) && ~isempty(id)
            % 复合单位 id（如 mm^2、mS/cm^2）先用当前表试解析
            try
                dim = parseUnit(id, T);
            catch
                dim = [];
            end
        end
        if isempty(dim)
            continue
        end
        if ~isempty(id) && isUnitTokenLike(id)
            T(id) = dim;
        end
        aliasList = toCellstrLocal(getFieldLocal(item, 'aliases', {}));
        for a = 1:numel(aliasList)
            alias = aliasList{a};
            if ~isempty(alias) && isUnitTokenLike(alias)
                T(alias) = dim;
            end
        end
        symbol = char(string(getFieldLocal(item, 'symbol', '')));
        if ~isempty(symbol) && isUnitTokenLike(symbol)
            T(symbol) = dim;
        end
    end
end
end

% =========================================================================
function T = addMany(T, names, dim)
for k = 1:numel(names)
    T(names{k}) = dim;
end
end

function tf = isUnitTokenLike(s)
% 可作为单个词法单位名注册（不含 * / ^ ( ) 空格等复合语法）
tf = ~isempty(regexp(s, '^[A-Za-z0-9_µμ°%]+$', 'once'));
end

function items = kbItems(u)
if iscell(u)
    items = reshape(u, 1, numel(u));
elseif isstruct(u)
    n = numel(u);
    items = cell(1, n);
    for k = 1:n
        items{k} = u(k);
    end
else
    items = {};
end
end

function dim = dimFromName(name)
% 知识库 dim 名称 → 量纲向量（kb/units.json v2 的 dimensions 词表 + 常见别名）
Z = zeros(1, 8);
amount = [1 0 0 0 0 0 0 0];
volume = [0 1 0 0 0 0 0 0];
time = [0 0 1 0 0 0 0 0];
temperature = [0 0 0 1 0 0 0 0];
length_ = [0 0 0 0 1 0 0 0];
mass = [0 0 0 0 0 1 0 0];
count = [0 0 0 0 0 0 1 0];
current = [0 0 0 0 0 0 0 1];
voltage = mass + 2 * length_ - 3 * time - current;
charge_ = current + time;
capacitance = charge_ - voltage;
conductance = current - voltage;
resistance = voltage - current;
name = lower(strtrim(char(string(name))));
switch name
    case {'', 'dimensionless', 'none', 'unitless', 'ratio'}
        dim = Z;
    case {'amount', 'mole', 'substance'}
        dim = amount;
    case {'volume'}
        dim = volume;
    case {'time', 'duration'}
        dim = time;
    case {'temperature'}
        dim = temperature;
    case {'length', 'distance'}
        dim = length_;
    case {'mass'}
        dim = mass;
    case {'count', 'number', 'population'}
        dim = count;
    case {'concentration', 'molarity'}
        dim = amount - volume;
    case {'mass_concentration'}
        dim = mass - volume;
    case {'rate', 'frequency', 'per_time', 'rate_constant'}
        dim = -time;
    case {'concentration_rate', 'concentration_per_time'}
        dim = amount - volume - time;
    case {'amount_rate', 'amount_per_time', 'flux', 'molar_flux'}
        dim = amount - volume - time;
    case {'rate_per_concentration'}
        dim = volume - amount - time;
    case {'count_rate', 'count_per_time'}
        dim = count - time;
    case {'volume_rate', 'volumetric_rate', 'flow'}
        dim = volume - time;
    case {'velocity', 'speed'}
        dim = length_ - time;
    case {'area'}
        dim = 2 * length_;
    case {'diffusion_coefficient'}
        dim = 2 * length_ - time;
    case {'energy', 'heat', 'work', 'enthalpy'}
        dim = mass + 2 * length_ - 2 * time;
    case {'power', 'heat_rate'}
        dim = mass + 2 * length_ - 3 * time;
    case {'pressure', 'stress'}
        dim = mass - length_ - 2 * time;
    case {'molar_energy', 'molar_enthalpy', 'energy_per_amount', 'chemical_potential'}
        dim = mass + 2 * length_ - 2 * time - amount;
    case {'specific_power', 'power_per_mass'}
        dim = 2 * length_ - 3 * time;
    case {'molality', 'amount_per_mass', 'mass_molality'}
        dim = amount - mass;
    case {'density'}
        dim = mass - volume;
    case {'mass_rate'}
        dim = mass - time;
    case {'voltage', 'electric_potential', 'potential', 'electric_potential_difference'}
        dim = voltage;
    case {'current', 'electric_current'}
        dim = current;
    case {'charge', 'electric_charge'}
        dim = charge_;
    case {'capacitance', 'electric_capacitance'}
        dim = capacitance;
    case {'conductance', 'electric_conductance'}
        dim = conductance;
    case {'resistance', 'electric_resistance'}
        dim = resistance;
    case {'current_density', 'electric_current_density'}
        dim = current - 2 * length_;
    case {'conductance_per_area', 'conductance_density', 'conductance_per_area_density'}
        dim = conductance - 2 * length_;
    case {'capacitance_per_area', 'capacitance_density'}
        dim = capacitance - 2 * length_;
    case {'voltage_rate', 'voltage_per_time', 'potential_rate'}
        dim = voltage - time;
    otherwise
        dim = [];
end
end

function v = getFieldLocal(s, name, default)
if isstruct(s) && isfield(s, name)
    v = s.(name);
else
    v = default;
end
end

function c = toCellstrLocal(x)
c = {};
if isempty(x)
    return
end
if ischar(x)
    c = {x};
elseif iscell(x)
    c = cell(1, numel(x));
    for k = 1:numel(x)
        if ischar(x{k})
            c{k} = x{k};
        elseif isstring(x{k}) && isscalar(x{k})
            c{k} = char(x{k});
        else
            c{k} = '';
        end
    end
elseif isstring(x)
    c = reshape(cellstr(x), 1, []);
end
end

function kb = loadKbUnits()
% 读取 kb/units.json（若存在）；失败时不阻断，仅回退到内置表。
kb = [];
try
    root = bma.util.projectRoot();
    p = fullfile(root, 'kb', 'units.json');
    if isfile(p)
        kb = bma.util.readJson(p);
    end
catch
    kb = [];
end
end
