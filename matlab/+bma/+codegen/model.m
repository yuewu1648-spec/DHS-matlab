function r = model(spec, runDir, opts)
%MODEL 生成可独立运行的 MATLAB ODE 代码与 model_card.json（DESIGN §4.4 codegen.model）。
%   r = bma.codegen.model(spec, runDir)
%   r = bma.codegen.model(spec, runDir, opts)
%   r = bma.codegen.model(m, runDir)          % 也接受 bma.model.build 的模型结构
%
% 输出文件（DESIGN §7）：
%   <runDir>/models/<name>/code/<name>_ode.m    ODE 右端函数 dydt = f(t,y,p)
%   <runDir>/models/<name>/code/<name>_run.m    仿真包装 [t,Y,out] = f(p,tspan,y0,opts)
%   <runDir>/models/<name>/model_card.json      模型卡（物种/参数/反应/方程/假设/证据）
%   <runDir>/models/<name>/spec.json|normalized.json
%
% 返回 r（JSON 可编码，含绝对路径；给 opts.work_dir 时附带 *_rel 相对路径）：
%   .ok .function_name .run_function_name .m_file .run_file .model_card_path
%   .code_dir .model_dir .parameter_order .species_order .ode_preview
%   .warnings .editable_note .elapsed_ms
if nargin < 2
    runDir = '';
end
if nargin < 3 || isempty(opts)
    opts = struct();
end
t0 = tic;
if ~isstruct(spec)
    spec = bma.spec.load(char(spec));
end
if isfield(spec, 'rhs')
    m = spec;
else
    m = bma.model.build(spec);
end
if isfield(m, 'kind') && any(strcmpi(char(m.kind), {'bvp', 'dae'}))
    error('bma:codegen:unsupportedKind', ...
        '%s 模型暂不支持 ODE 代码生成；请用 bma_model_simulate 的结果/报告。', char(m.kind));
end
if isempty(runDir) || (ischar(runDir) && isempty(strtrim(runDir))) || (isstring(runDir) && strlength(runDir) == 0)
    runDir = fullfile(bma.util.projectRoot(), '.bma', 'codegen', m.name);
end
if isfield(m, 'kind') && strcmpi(char(m.kind), 'dde')
    r = bma.dde.codegen(m, char(runDir));
    if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
        try
            workDir = char(opts.work_dir);
            r.m_file_rel = bma.util.relPath(workDir, r.m_file);
            r.run_file_rel = bma.util.relPath(workDir, r.run_file);
            r.model_card_rel = bma.util.relPath(workDir, r.model_card_path);
        catch
        end
    end
    return
end
info = bma.codegen.writeModelArtifacts(m, char(runDir), []);
r = struct();
r.schema_version = 'bma.codegen.v1';
r.ok = true;
r.name = m.name;
r.function_name = info.function_name;
r.run_function_name = info.run_function_name;
r.m_file = info.m_file;
r.run_file = info.run_file;
r.pde_file = '';
if isfield(info, 'pde_file')
    r.pde_file = info.pde_file;
end
r.model_card_path = info.model_card_path;
r.code_dir = info.code_dir;
r.model_dir = info.model_dir;
r.parameter_order = m.params;
r.species_order = m.species;
r.ode_preview = m.ode_rhs_preview;
r.parameter_index = m.paramInfo;
r.species_index = m.speciesInfo;
r.warnings = m.warnings;
r.editable_note = ['生成代码不依赖 +bma 包，可直接用 ode15s/ode45 调用；' ...
    'p 顺序见 parameter_order，y 顺序见 species_order。'];
r.elapsed_ms = round(toc(t0) * 1000);
if isfield(opts, 'work_dir') && ~isempty(opts.work_dir)
    try
        workDir = char(opts.work_dir);
        r.m_file_rel = bma.util.relPath(workDir, info.m_file);
        r.run_file_rel = bma.util.relPath(workDir, info.run_file);
        r.model_card_rel = bma.util.relPath(workDir, info.model_card_path);
    catch
    end
end
end
