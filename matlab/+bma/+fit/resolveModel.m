function [m, spec] = resolveModel(mOrSpec)
%RESOLVEMODEL 接受 build 后的模型结构或模型规格，返回 (m, spec)。
%   [m, spec] = bma.fit.resolveModel(m)
%   [m, spec] = bma.fit.resolveModel(spec)
%
% - 若输入是 bma.modelSpec.v1 规格（含 schema_version），调用
%   bma.model.build（core）构建模型；
% - 若输入已是 build 结果（含 rhs），直接返回并取其 m.spec。
spec = [];
m = mOrSpec;
if ~isstruct(mOrSpec)
    error('bma:fit:modelType', '模型输入必须是 struct（build 结果或模型规格）。');
end
if isfield(mOrSpec, 'schema_version') && isempty(mOrSpec.schema_version) == false ...
        && strcmp(char(mOrSpec.schema_version), 'bma.modelSpec.v1')
    spec = mOrSpec;
    if exist('bma.model.build', 'file') ~= 2
        error('bma:fit:coreMissing', ...
            '收到模型规格但 core 模块 bma.model.build 尚不可用；请先实现 core 或直接传入 build 结果。');
    end
    m = bma.model.build(spec);
    return
end
if isfield(mOrSpec, 'rhs') && ~isempty(mOrSpec.rhs)
    if isfield(mOrSpec, 'spec') && ~isempty(mOrSpec.spec)
        spec = mOrSpec.spec;
    else
        error('bma:fit:noSpec', '模型结构缺少 m.spec；无法读取参数默认值与边界。');
    end
    return
end
% DDE/BVP compiled structures have no m.rhs (dde23/bvp4c callbacks instead),
% but bma.fit.simulatePredictions uses bma.model.simulate, so they are valid
% fit models for simulation-based calibration.
if isfield(mOrSpec, 'kind') && any(strcmpi(char(mOrSpec.kind), {'dde', 'bvp', 'dae'})) ...
        && isfield(mOrSpec, 'spec') && ~isempty(mOrSpec.spec)
    spec = mOrSpec.spec;
    return
end
if isfield(mOrSpec, 'spec') && isfield(mOrSpec.spec, 'schema_version')
    spec = mOrSpec.spec;
    error('bma:fit:modelNoRhs', ...
        '模型结构缺少 m.rhs，看起来是未构建的 spec。请改用 bma.model.build(spec)。');
end
error('bma:fit:modelUnknown', '无法识别的模型输入（既不是 build 结果也不是 modelSpec）。');
end
