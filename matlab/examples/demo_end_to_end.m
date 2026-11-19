%DEMO_END_TO_END 无 DSH 的完整建模示例：validate → analyze → simulate → fit → validate → report → codegen
%
% 用法（在 MATLAB 中）：
%   cd('E:\matlab系统建模'); startup_bma; demo_end_to_end
%
% 产物写到 <project>/.bma/demo/ 下（不污染 spec/examples）。示例使用
% spec/examples/enzyme_mm.json 与 spec/examples/data/enzyme_progress.csv。

root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(root, 'matlab'));
workDir = fullfile(root, '.bma', 'demo');
if ~isfolder(workDir), mkdir(workDir); end

fprintf('== BioModel-MATLAB demo ==\n');
fprintf('project root: %s\n', root);

%% 1. 运行目录
run = bma.run.init(workDir, '');
if isAbsolutePath(run.run_dir)
    runDir = run.run_dir;
else
    runDir = fullfile(workDir, run.run_dir);
end
fprintf('[1/8] run dir: %s\n', runDir);

%% 2. 模型规格 + 校验
specPath = fullfile(root, 'spec', 'examples', 'enzyme_mm.json');
spec = bma.spec.load(specPath);
vr = bma.spec.validate(spec, workDir);
assert(vr.valid, 'spec 校验失败：%s', strjoin(arrayfun(@(e) e.message, vr.errors, 'UniformOutput', false), '; '));
fprintf('[2/8] spec valid: %s (%d species, %d params)\n', vr.summary.name, vr.summary.n_species, vr.summary.n_parameters);

%% 3. 构建 + 结构分析
m = bma.model.build(spec);
a = bma.model.analyze(m);
fprintf('[3/8] build ok; conservation laws: %d, steady states: %d\n', ...
    numel(a.conservation_laws), numel(a.steady_states));
if ~isempty(a.conservation_laws)
    fprintf('      laws: %s\n', strjoin(cellfun(@(x) char(x), a.conservation_laws, 'UniformOutput', false), ' | '));
end

%% 4. 仿真
res = bma.model.simulate(m, struct('time_end', 60, 'n', 301));
fprintf('[4/8] simulate ok: P(60)=%.4g uM, S(60)=%.4g uM\n', ...
    res.outputs(strcmp({res.outputs.id}, 'P_obs')).final, ...
    res.outputs(strcmp({res.outputs.id}, 'S_obs')).final);

%% 5. 拟合（合成数据来自 scripts/gen_example_data.py，真值见 truth.json）
dataPath = fullfile(root, 'spec', 'examples', 'data', 'enzyme_progress.csv');
T = readtable(dataPath, 'VariableNamingRule', 'preserve');
data = struct();
data.t = T{:, 1};
data.Y = T{:, 2:end};
data.output_map = struct('P_obs', 'P_obs', 'S_obs', 'S_obs');
data.weights = [];
fr = bma.fit.estimate(m, data, struct('multistart', 6, 'max_iter', 200));
fprintf('[5/8] fit: R2=%.4f RMSE=%.4g\n', fr.metrics.r2, fr.metrics.rmse);
for k = 1:numel(fr.params)
    p = fr.params(k);
    fprintf('      %-4s = %.4g  CI=[%.3g, %.3g] %s\n', p.id, p.value, ...
        p.ci_low, p.ci_high, ternary(p.fixed, '(fixed)', ''));
end

%% 6. 可辨识性 + 敏感性（若模块可用）
try
    idr = bma.fit.identifiability(m, data, struct());
    fprintf('[6/8] identifiability: rank=%d cond=%.3g\n', ...
        getfield_or(idr, 'rank', NaN), getfield_or(idr, 'condition_number', NaN));
catch err
    fprintf('[6/8] identifiability skipped: %s\n', err.message);
end
try
    sen = bma.fit.sensitivity(m, struct('method', 'local'));
    fprintf('      sensitivity ok: %d entries\n', numel(fieldnames(sen)));
catch err
    fprintf('      sensitivity skipped: %s\n', err.message);
end

%% 7. 报告
frFile = fullfile(runDir, 'fits', 'demo_fit.json');
try
    bma.util.writeJsonAtomic(frFile, bma.server.jsonSafe(fr));
catch
end
try
    rep = bma.report.build(runDir, spec, fr, a, struct('title', '米氏酶动力学：从示例数据到可验证模型'));
    fprintf('[7/8] report: %s\n', rep.report_html);
catch err
    fprintf('[7/8] report skipped: %s\n', err.message);
end

%% 8. 代码导出
try
    cg = bma.codegen.model(spec, runDir);
    fprintf('[8/8] codegen: %s (function %s)\n', cg.m_file, cg.function_name);
catch err
    fprintf('[8/8] codegen skipped: %s\n', err.message);
end

fprintf('== demo finished; artifacts under %s ==\n', workDir);

function tf = isAbsolutePath(p)
if ispc
    tf = ~isempty(regexp(char(p), '^([A-Za-z]:[\\/]|\\\\|/)', 'once'));
else
    tf = ~isempty(regexp(char(p), '^/', 'once'));
end
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end

function v = getfield_or(s, name, fallback)
if isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = fallback;
end
end
