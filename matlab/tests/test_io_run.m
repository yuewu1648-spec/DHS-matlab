% test_io_run.m — 验证 bma.run.init/info/list/artifact 的目录规范与幂等。
% 由 matlab/tests/run_all_tests.m 或 RPC test.run 调用，失败即抛异常。

fprintf('  [test_io_run] start\n');
workDir = tempname;
mkdir(workDir);
cleaner = onCleanup(@() safeRmdir(workDir));

% ---- 1) init：标准目录 + run.json + run_id 格式 ----
r1 = bma.run.init(workDir, 'first-run');
assertTrue(r1.created, '首次 init 的 created 应为 true');
assertTrue(isfolder(r1.run_dir_abs), 'run_dir_abs 应存在');
assertTrue(~isempty(regexp(r1.run_dir_abs, '^([A-Za-z]:[\\/]|/)', 'once')), 'run_dir_abs 应为绝对路径');
assertTrue(strcmp(r1.run_dir, '.bma/runs/first-run') || strcmpi(r1.run_dir, fullfile('.bma','runs','first-run')), 'DESIGN 约定 run_dir 应相对 work_dir');
expectedDirs = {'literature', 'models', 'data', 'fits', 'figures', 'report', 'logs'};
for k = 1:numel(expectedDirs)
    assertTrue(isfolder(fullfile(r1.run_dir_abs, expectedDirs{k})), ...
        sprintf('缺少标准子目录 %s', expectedDirs{k}));
end
runJson = r1.run_json_abs;
assertTrue(isfile(runJson), 'run.json 应存在');
meta = bma.util.readJson(runJson);
assertTrue(strcmp(meta.schema, 'bma.run.v1'), 'run.json schema 错误');
assertTrue(strcmp(meta.run_id, 'first-run'), 'run.json run_id 应与 name 一致');
assertTrue(isfield(meta, 'created_at') && ~isempty(meta.created_at), 'run.json 缺少 created_at');
assertTrue(isfield(meta, 'work_dir'), 'run.json 缺少 work_dir');
assertTrue(strcmpi(r1.run_dir_rel, fullfile('.bma', 'runs', 'first-run')) || ...
    strcmpi(r1.run_dir_rel, '.bma/runs/first-run'), 'run_dir_rel 应为 .bma/runs/first-run');

% ---- 2) 幂等：同名 init 复用同一 run_dir ----
r1b = bma.run.init(workDir, 'first-run');
assertTrue(~r1b.created, '同名再次 init 的 created 应为 false（复用）');
assertTrue(strcmp(r1b.run_dir, r1.run_dir), '同名 init 应返回同一 run_dir');
assertTrue(strcmp(r1b.run_id, r1.run_id), '同名 init 应返回同一 run_id');

% ---- 3) 不指定 name：生成 DESIGN §7 格式 run_id，且复用 current run ----
rAuto = bma.run.init(workDir, '', 'New', true);
assertTrue(rAuto.created, '首次无 name init 应创建 run');
assertTrue(~isempty(regexp(rAuto.run_id, '^r\d{8}-\d{6}-[0-9a-f]{4}$', 'once')), ...
    sprintf('自动 run_id 格式不符：%s', rAuto.run_id));
rAuto2 = bma.run.init(workDir);
assertTrue(strcmp(rAuto2.run_id, rAuto.run_id), '无 name 的重复 init 应复用 current run');
assertTrue(~rAuto2.created, '复用时 created 应为 false');
rAuto3 = bma.run.init(workDir, '', 'New', true);
assertTrue(~strcmp(rAuto3.run_id, rAuto.run_id), 'New=true 应强制新建 run');

% ---- 4) artifact：规范路径 + 创建目录 + 防路径穿越 ----
p = bma.run.artifact(rAuto.run_dir_abs, 'figures');
assertTrue(isfolder(p) && strcmp(p, fullfile(rAuto.run_dir_abs, 'figures')), ...
    'artifact(figures) 应返回 figures 根目录');
p = bma.run.artifact(rAuto.run_dir_abs, 'figures', 'demo.png');
assertTrue(strcmp(p, fullfile(rAuto.run_dir_abs, 'figures', 'demo.png')), ...
    'artifact(figures, 文件) 应返回文件路径');
assertTrue(isfolder(fileparts(p)), 'artifact 应创建文件父目录');
p = bma.run.artifact(rAuto.run_dir_abs, 'models', 'enzyme_mm');
assertTrue(isfolder(p) && strcmp(p, fullfile(rAuto.run_dir_abs, 'models', 'enzyme_mm')), ...
    'artifact(models, 目录) 应创建子目录');
p = bma.run.artifact(rAuto.run_dir_abs, 'literature', 'doc1');
assertTrue(isfolder(p), 'artifact(literature, 目录) 应创建子目录');
p = bma.run.artifact(rAuto.run_dir_abs, 'root');
assertTrue(strcmp(p, rAuto.run_dir_abs), 'artifact(root) 应返回 run 根目录');
caught = false;
try
    bma.run.artifact(rAuto.run_dir_abs, 'nonsense');
catch err
    caught = strcmp(err.identifier, 'bma:run:unknownKind');
end
assertTrue(caught, '未知 kind 应报 bma:run:unknownKind');
caught = false;
try
    bma.run.artifact(rAuto.run_dir_abs, 'figures', '../escape.png');
catch err
    caught = strcmp(err.identifier, 'bma:run:badName');
end
assertTrue(caught, '含 .. 的 name 应报 bma:run:badName');

% ---- 5) info：元数据 + 产物计数 ----
bma.util.writeTextAtomic(fullfile(rAuto.run_dir_abs, 'figures', 'demo.png'), 'fake-png');
bma.util.ensureDir(fullfile(rAuto.run_dir_abs, 'models', 'enzyme_mm'));
bma.util.ensureDir(fullfile(rAuto.run_dir_abs, 'fits', 'fit-001'));
bma.util.ensureDir(fullfile(rAuto.run_dir_abs, 'literature', 'doc-001'));
bma.util.writeTextAtomic(fullfile(rAuto.run_dir_abs, 'report', 'report.html'), '<html></html>');
info = bma.run.info(rAuto.run_dir_abs);
assertTrue(strcmp(info.run_id, rAuto.run_id), 'info run_id 错误');
assertTrue(strcmp(info.name, ''), 'info name 应为空（无 name run）');
assertTrue(info.model_count == 1, sprintf('model_count 应为 1，实际 %d', info.model_count));
assertTrue(info.fit_count == 1, 'fit_count 应为 1');
assertTrue(info.literature_count == 2, ...
    sprintf('literature_count 应为 2（artifact doc1 + doc-001），实际 %d', info.literature_count));
assertTrue(info.figure_count == 1, 'figure_count 应为 1');
assertTrue(info.report_count == 1, 'report_count 应为 1');
assertTrue(any(strcmp(info.models, 'enzyme_mm')), 'info.models 应包含 enzyme_mm');
assertTrue(any(strcmp(info.fits, 'fit-001')), 'info.fits 应包含 fit-001');
assertTrue(isfield(info, 'dirs') && isfield(info.dirs, 'models'), 'info.dirs 字段缺失');
% 纯 run_id 也能解析
info2 = bma.run.info(rAuto.run_id, 'WorkDir', workDir);
assertTrue(strcmp(info2.run_dir, rAuto.run_dir_abs), '按 run_id 查询应得到同一 run_dir');

% ---- 6) list：列出全部 run，字段齐全、按时间倒序 ----
[runs, total] = bma.run.list(workDir);
assertTrue(total >= 3, sprintf('至少应有 3 个 run，实际 %d', total));
assertTrue(numel(runs) == total, 'list 返回数量与 total 应一致');
needed = {'run_dir', 'run_dir_rel', 'run_id', 'created_at', 'models', ...
    'model_count', 'reports', 'report_count'};
for f = 1:numel(needed)
    assertTrue(isfield(runs, needed{f}), sprintf('list 条目缺少字段 %s', needed{f}));
end
ids = {runs.run_id};
assertTrue(any(strcmp(ids, 'first-run')), 'list 应包含 first-run');
assertTrue(any(strcmp(ids, rAuto.run_id)), 'list 应包含自动 run');
for k = 1:numel(runs)
    assertTrue(isfolder(runs(k).run_dir), 'list 中 run_dir 应存在');
end
emptyWork = tempname;
mkdir(emptyWork);
cleaner2 = onCleanup(@() safeRmdir(emptyWork));
[noRuns, noTotal] = bma.run.list(emptyWork);
assertTrue(noTotal == 0, '空 workDir 的 list total 应为 0');

% ---- 7) 不存在的 run -> 明确错误 ----
caught = false;
try
    bma.run.info(fullfile(workDir, '.bma', 'runs', 'no-such-run'));
catch err
    caught = strcmp(err.identifier, 'bma:run:notFound');
end
assertTrue(caught, '不存在的 run 应报 bma:run:notFound');

fprintf('  [test_io_run] PASS (%d runs, idempotent, artifacts OK)\n', total);

% ---------------------------------------------------------------------------
function assertTrue(cond, msg)
if ~cond
    error('test_io_run:fail', '%s', msg);
end
end

function safeRmdir(d)
try
    if isfolder(d)
        rmdir(d, 's');
    end
catch
end
end
