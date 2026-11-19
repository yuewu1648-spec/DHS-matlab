function m = build(spec, opts)
%BUILD 校验并构建 ODE 模型结构（DESIGN §5.3 契约入口）。
%   m = bma.model.build(spec)
%   m = bma.model.build(spec_path)
%   m = bma.model.build(spec, opts)
%
% 行为：
%   1) 先调用 bma.spec.validate(spec)；若规格无效，抛出
%      MException('bma:spec:spec_invalid')，message 汇总所有错误码/path/修复建议；
%   2) 通过后调用 bma.spec.compile 得到模型结构 m（字段见 help bma.spec.compile）；
%   3) m.warnings 中保存校验警告（cell of struct {code,path,message,hint,severity}）；
%   4) 若 opts.run_dir 给出，则按 DESIGN §7 写产物：
%        <run_dir>/models/<name>/spec.json
%        <run_dir>/models/<name>/normalized.json
%        <run_dir>/models/<name>/validation.json
%        <run_dir>/models/<name>/code/<name>_ode.m
%        <run_dir>/models/<name>/code/<name>_run.m
%        <run_dir>/models/<name>/model_card.json
%      并在 m.model_dir / m.rhs_function_path / m.model_card_path 等字段返回绝对路径。
%
% 说明：m 中含函数句柄（m.rhs/m.vfuns/m.outputs.fh），不可直接 jsonencode；
% RPC 返回请只挑选 DESIGN §4.4 要求的字段。
if nargin < 2 || isempty(opts)
    opts = struct();
end
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec) || isempty(spec) || numel(spec) > 1
    error('bma:spec:spec_invalid', 'bma.model.build 需要单个模型规格结构体或 JSON 路径');
end
report = bma.spec.validate(spec);
if ~report.valid
    error('bma:spec:spec_invalid', '%s', formatValidationErrors(report));
end
m = bma.spec.compile(report.normalized_spec);
m.warnings = report.warnings;
m.validation = struct('valid', true, ...
    'n_errors', report.n_errors, ...
    'n_warnings', report.n_warnings, ...
    'warning_codes', {report.warning_codes}, ...
    'n_conservation_laws', report.conservation.n_laws);
m.summary = report.summary;

% 可选：写入运行目录产物（代码 + 规格 + 模型卡）
if isfield(opts, 'run_dir') && ~isempty(opts.run_dir)
    if isfield(m, 'kind') && any(strcmpi(char(m.kind), {'dde', 'bvp', 'dae'}))
        m.codegen_skipped = true;
        m.codegen_warning = sprintf('%s 模型暂不生成 ODE 代码；使用 bma_model_simulate 的结果/报告。', char(m.kind));
    else
        runDir = char(opts.run_dir);
        info = bma.codegen.writeModelArtifacts(m, runDir, report);
        m.model_dir = info.model_dir;
        m.code_dir = info.code_dir;
        m.spec_path = info.spec_path;
        m.normalized_spec_path = info.normalized_spec_path;
        m.validation_path = info.validation_path;
        m.rhs_function_path = info.m_file;
        m.run_function_path = info.run_file;
        m.function_name = info.function_name;
        m.model_card_path = info.model_card_path;
    end
end
end

% =========================================================================
function msg = formatValidationErrors(report)
maxShow = 12;
lines = {sprintf('模型规格校验失败：%d 个错误，%d 个警告。', report.n_errors, report.n_warnings)};
nShow = min(numel(report.errors), maxShow);
for k = 1:nShow
    e = report.errors{k};
    lines{end+1} = sprintf('  [%s] %s：%s', e.code, e.path, e.message); %#ok<AGROW>
    if ~isempty(e.hint)
        lines{end+1} = sprintf('      修复建议：%s', e.hint); %#ok<AGROW>
    end
end
if numel(report.errors) > maxShow
    lines{end+1} = sprintf('  ……其余 %d 个错误请调用 bma.spec.validate 查看完整列表。', ...
        numel(report.errors) - maxShow);
end
msg = strjoin(lines, sprintf('\n'));
end
