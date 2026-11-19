% test_cases_summary.m — ISSUE-009 full case summary CSV
root = bma.util.projectRoot();
work = fullfile(root, '.bma', 'test_tmp', bma.util.newId('cases_summary'));
bma.util.ensureDir(work);
spec = bma.spec.load(fullfile(root, 'spec', 'examples', 'enzyme_mm.json'));
cases = cell(1, 15);
for k = 1:15
    cases{k} = struct('name', sprintf('c%02d', k), ...
        'param_overrides', struct('kcat', 1 + 0.1 * k), ...
        'time_overrides', struct('end', 2, 'n', 21));
end
out = bma.server.dispatch('model.simulate_cases', ...
    struct('spec', spec, 'cases', {cases}), struct('work_dir', work));
assert(out.n_cases == 15 && numel(out.cases) == 15, 'cases 结果被截断：%d', numel(out.cases));
assert(isfield(out, 'cases_summary_path') && ~isempty(out.cases_summary_path), ...
    '缺少 cases_summary_path');
csvPath = fullfile(work, out.cases_summary_path);
assert(isfile(csvPath), 'cases_summary.csv 不存在：%s', csvPath);
txt = fileread(csvPath);
nLines = numel(strsplit(strtrim(txt), newline));
assert(nLines >= 16, 'summary CSV 行数不足：%d', nLines);
fprintf('[PASS] cases summary: %d cases, %d CSV lines\n', out.n_cases, nLines);
fprintf('[test_cases_summary] 全部通过\n');
