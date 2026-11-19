% test_io_numbers.m — 验证 bma.io.extractNumbers 的数值/单位/符号/上下文/位置抽取。
% 由 matlab/tests/run_all_tests.m 或 RPC test.run 调用，失败即抛异常。

fprintf('  [test_io_numbers] start\n');

% ---- 1) 自造小而真实的文献片段（含 5+ 带单位数字） ----
raw = [ ...
    'We characterized the enzyme using steady-state kinetics. ' ...
    'The Michaelis constant Km = 12.5 µM and the turnover number kcat of 3.4 s−1 were obtained. ' ...
    'Inhibition was potent with EC50 ≈ 0.8 nM for the lead compound. ' ...
    'The basic reproduction number R0 ~ 2.5 was estimated from the outbreak data. ' ...
    'The maximal flux reached 0.5 µM/min under standard assay conditions. ' ...
    'A rate constant of 10^-3 s^-1 was observed in the low-salt buffer. ' ...
    'Cells were grown at 37 °C and 5% CO2 for 24 h before lysis. ' ...
    'As reported previously [12], this agrees with Fig. 3 and Eq. (2) from a study in 2019. ' ...
    'Reference: Smith J. et al. (2018). J Biol Chem 293(4): 1234-1250. p. 42.'];
text = bma.io.internal.normalizeText(raw);
secs = bma.io.sectionize(text);
nums = bma.io.extractNumbers(text, secs);

assertTrue(isstruct(nums), 'extractNumbers 应返回 struct 数组');
assertTrue(~isempty(nums), '样例应至少抽取到 1 个数字');
fields = {'value', 'unit', 'unit_raw', 'symbol', 'context', 'section_id', ...
    'section_heading', 'char_start', 'quote', 'is_range', 'range'};
for f = 1:numel(fields)
    assertTrue(isfield(nums, fields{f}), sprintf('缺少字段 %s', fields{f}));
end

% ---- 2) 5/5 目标命中（值 + 单位 + 符号） ----
[ok, idx] = findNum(nums, 'Km', 12.5, 'uM');
assertTrue(ok, '未命中 Km = 12.5 µM');
assertTrue(contains(nums(idx).context, 'Km'), 'Km 记录的 context 应包含符号 Km');
assertTrue(contains(nums(idx).quote, '12.5'), 'Km 记录的 quote 应包含数值');

[ok, idx] = findNum(nums, 'kcat', 3.4, '1/s');
assertTrue(ok, '未命中 kcat of 3.4 s−1 -> 3.4 1/s');

[ok, idx] = findNum(nums, 'EC50', 0.8, 'nM');
assertTrue(ok, '未命中 EC50 ≈ 0.8 nM');

[ok, idx] = findNum(nums, 'R0', 2.5, '');
assertTrue(ok, '未命中 R0 ~ 2.5（无单位靠符号保留）');

[ok, idx] = findNum(nums, '', 0.5, 'uM/min');
assertTrue(ok, '未命中 0.5 µM/min');

[ok, idx] = findNum(nums, '', 1e-3, '1/s');
assertTrue(ok, '未命中 10^-3 s^-1 -> 1e-3 1/s');

% ---- 3) 其它带单位数值（温度/百分比/时间） ----
[okT] = findNum(nums, '', 37, '°C');
assertTrue(okT, '未命中 37 °C');
[okPct] = findNum(nums, '', 5, '%');
assertTrue(okPct, '未命中 5%');
[okH] = findNum(nums, '', 24, 'h');
assertTrue(okH, '未命中 24 h');

% ---- 4) 误报过滤：年份/引文/图表编号/页码/统计量 ----
assertTrue(~any(abs([nums.value] - 2019) < 1e-9), '2019 年份不应被抽取');
assertTrue(~any(abs([nums.value] - 2018) < 1e-9), '2018 年份不应被抽取');
assertTrue(~any(abs([nums.value] - 42) < 1e-9), '页码 42 不应被抽取');
assertTrue(~any(abs([nums.value] - 1234) < 1e-9), '文献页码 1234 不应被抽取');
assertTrue(~any(abs([nums.value] - 1250) < 1e-9), '文献页码 1250 不应被抽取');
for k = 1:numel(nums)
    assertTrue(~(isempty(nums(k).unit) && isempty(nums(k).symbol)), ...
        sprintf('第 %d 条记录 unit 与 symbol 同时为空（应被过滤）', k));
    assertTrue(nums(k).char_start >= 1 && nums(k).char_start <= numel(text), ...
        'char_start 越界');
    assertTrue(~isempty(nums(k).context), 'context 不应为空');
    assertTrue(~isempty(nums(k).section_id), 'section_id 不应为空');
end
% 期望数量：9 个合法数值（6 个目标 + 37 °C + 5% + 24 h）
assertTrue(numel(nums) == 9, sprintf('期望抽取 9 个数值，实际 %d 个', numel(nums)));

% ---- 5) 单位规范化：不残留 µ / 上标减号 ----
microCodes = [181, 956];
for k = 1:numel(nums)
    assertTrue(~any(ismember(double(nums(k).unit), microCodes)), ...
        'unit 不应残留 micro 符号');
    assertTrue(~contains(nums(k).unit, '−'), 'unit 不应残留 Unicode 减号');
end

% ---- 6) 区间数值：5–10 µM 两端各一条，is_range=true ----
rtext = bma.io.internal.normalizeText('Substrate was 5–10 µM across the tested conditions.');
rnums = bma.io.extractNumbers(rtext, bma.io.sectionize(rtext));
assertTrue(numel(rnums) == 2, sprintf('区间应产出 2 条记录，实际 %d 条', numel(rnums)));
assertTrue(all([rnums.is_range]), '区间记录的 is_range 应为 true');
assertTrue(all(strcmp({rnums.unit}, 'uM')), '区间单位应为 uM');
vals = sort([rnums.value]);
assertTrue(abs(vals(1) - 5) < 1e-9 && abs(vals(2) - 10) < 1e-9, '区间端点应为 5 与 10');
assertTrue(isequal(rnums(1).range, [5, 10]), 'range 字段应为 [5 10]');

% ---- 7) 失去 caret 的科学计数 10-3 s-1 -> 1e-3 1/s ----
stext = bma.io.internal.normalizeText('The fitted rate constant was 10-3 s-1 in buffer A.');
snums = bma.io.extractNumbers(stext, bma.io.sectionize(stext));
[okSci] = findNum(snums, '', 1e-3, '1/s');
assertTrue(okSci, '10-3 s-1 应解析为 1e-3 1/s');

% ---- 8) 负例：全是误报源 -> 0 条 ----
neg = bma.io.internal.normalizeText([ ...
    'As shown in Fig. 3 and Table 2 [12,13], the study from 2019 (see p. 42). ' ...
    'The p = 0.03 was not significant and 3 experiments were performed.']);
nnums = bma.io.extractNumbers(neg, bma.io.sectionize(neg));
assertTrue(isempty(nnums), sprintf('负例应抽出 0 条，实际 %d 条', numel(nnums)));

fprintf('  [test_io_numbers] PASS (%d numbers)\n', numel(nums));

% ---------------------------------------------------------------------------
function assertTrue(cond, msg)
if ~cond
    error('test_io_numbers:fail', '%s', msg);
end
end

function [ok, idx] = findNum(nums, symbol, value, unit)
ok = false;
idx = 0;
for k = 1:numel(nums)
    if abs(nums(k).value - value) > 1e-9
        continue
    end
    if ~strcmp(nums(k).unit, unit)
        continue
    end
    if ~isempty(symbol) && ~strcmpi(nums(k).symbol, symbol)
        continue
    end
    ok = true;
    idx = k;
    return
end
end
