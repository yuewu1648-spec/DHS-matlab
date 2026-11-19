% test_io_tables.m — 验证 bma.io.extractTables 的 Markdown/TSV/空格对齐表格解析。
% 由 matlab/tests/run_all_tests.m 或 RPC test.run 调用，失败即抛异常。

fprintf('  [test_io_tables] start\n');

% ---- 1) Markdown 表格（含 caption 与 Results 章节归属） ----
mdLines = { ...
    '# Kinetic Parameter Tables', ...
    '', ...
    'We measured steady-state kinetics for all variants.', ...
    '', ...
    '## Results', ...
    '', ...
    'Table 1. Kinetic parameters of the enzyme variants.', ...
    '', ...
    '| Variant | Km (uM) | kcat (1/s) | kcat/Km (1/(uM*s)) |', ...
    '|---|---|---|---|', ...
    '| WT | 12.5 | 3.4 | 0.27 |', ...
    '| Mutant A | 8.1 | 1.2 | 0.15 |', ...
    '', ...
    'The values are means of three independent experiments.'};
mdText = bma.io.internal.normalizeText(strjoin(mdLines, char(10)));
tables = bma.io.extractTables(mdText, bma.io.sectionize(mdText));
assertTrue(numel(tables) == 1, sprintf('Markdown 表格应识别 1 个，实际 %d 个', numel(tables)));
t = tables(1);
assertTrue(strcmp(t.format, 'markdown'), 'format 应为 markdown');
assertTrue(numel(t.header) == 4, '表头应有 4 列');
assertTrue(numel(t.rows) == 2, sprintf('应有 2 行数据，实际 %d', numel(t.rows)));
assertTrue(t.n_cols == 4 && t.n_rows == 2, 'n_rows/n_cols 应正确');
assertTrue(strcmp(t.header{1}, 'Variant'), '第 1 列表头应为 Variant');
assertTrue(contains(t.header{2}, 'Km'), '第 2 列表头应包含 Km');
assertTrue(strcmp(t.rows{1}{2}, '12.5'), 'WT 的 Km 单元格应为 12.5');
assertTrue(strcmp(t.rows{2}{1}, 'Mutant A'), '第 2 行第 1 列应为 Mutant A');
assertTrue(contains(t.caption, 'Table 1'), '应识别 Table 1 caption');
assertTrue(strcmp(t.section_heading, 'Results'), ...
    sprintf('表格应归属 Results 章节，实际 "%s"', t.section_heading));
assertTrue(~isempty(t.section_id), 'section_id 不应为空');
assertTrue(isfield(t, 'char_start') && t.char_start >= 1, 'char_start 应有效');

% ---- 2) 制表符表格 ----
tsvLines = { ...
    'Results', ...
    '', ...
    'time	rate	note', ...
    '0	1.5	baseline', ...
    '5	2.3	induced', ...
    '10	3.1	plateau'};
tsvText = bma.io.internal.normalizeText(strjoin(tsvLines, char(10)));
ttabs = bma.io.extractTables(tsvText, bma.io.sectionize(tsvText));
assertTrue(numel(ttabs) == 1, sprintf('TSV 表格应识别 1 个，实际 %d', numel(ttabs)));
tt = ttabs(1);
assertTrue(strcmp(tt.format, 'tsv'), 'format 应为 tsv');
assertTrue(tt.n_rows == 3 && tt.n_cols == 3, 'TSV 行列数应为 3x3');
assertTrue(strcmp(tt.header{2}, 'rate'), 'TSV 表头第 2 列应为 rate');
assertTrue(strcmp(tt.rows{1}{1}, '0'), 'TSV 首行首列应为 0');
assertTrue(strcmp(tt.rows{3}{3}, 'plateau'), 'TSV 末行末列应为 plateau');

% ---- 3) 空格对齐表格 ----
fixedLines = { ...
    'Variant    Km    kcat', ...
    'WT         12.5  3.4', ...
    'Mutant A   8.1   1.2'};
fixedText = bma.io.internal.normalizeText(strjoin(fixedLines, char(10)));
ftabs = bma.io.extractTables(fixedText, bma.io.sectionize(fixedText));
assertTrue(numel(ftabs) >= 1, '空格对齐表格应被识别');
ft = ftabs(1);
assertTrue(strcmp(ft.format, 'fixed'), 'format 应为 fixed');
assertTrue(ft.n_cols == 3, '固定宽度表格应有 3 列');
assertTrue(strcmp(ft.header{1}, 'Variant'), '固定宽度表头第 1 列应为 Variant');
assertTrue(strcmp(ft.rows{2}{1}, 'Mutant A'), '固定宽度第 2 行第 1 列应为 Mutant A');

% ---- 4) 普通段落不应误判为表格 ----
proseLines = { ...
    'This is a paragraph with  double spaces in it.', ...
    'The values increase over time  and then plateau at saturation.'};
proseText = bma.io.internal.normalizeText(strjoin(proseLines, char(10)));
ptabs = bma.io.extractTables(proseText, bma.io.sectionize(proseText));
assertTrue(isempty(ptabs), sprintf('普通段落不应识别为表格，实际 %d 个', numel(ptabs)));

% ---- 5) 空文本 -> 空 struct 数组 ----
etabs = bma.io.extractTables('');
assertTrue(isstruct(etabs) && isempty(etabs), '空文本应返回空表格数组');

fprintf('  [test_io_tables] PASS (markdown/tsv/fixed)\n');

% ---------------------------------------------------------------------------
function assertTrue(cond, msg)
if ~cond
    error('test_io_tables:fail', '%s', msg);
end
end
