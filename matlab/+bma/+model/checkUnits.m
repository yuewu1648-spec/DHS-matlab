function ok = checkUnits(m)
%CHECKUNITS 模型量纲检查（供 validate / analyze 复用，DESIGN §5.3）。
%   ok = bma.model.checkUnits(m)
%   m 可以是 bma.model.build 返回的模型结构、模型规格结构体或 spec JSON 路径。
%   ok=true 表示所有单位可解析、且各反应通量与物种变化率的量纲一致。
if ischar(m) || isstring(m)
    m = bma.model.build(char(m));
end
if ~isstruct(m)
    error('bma:model:model_invalid', 'bma.model.checkUnits 需要模型结构或模型规格');
end
if isfield(m, 'spec') && isstruct(m.spec)
    spec = m.spec;
elseif isfield(m, 'schema_version') && isfield(m, 'variables')
    spec = m;
else
    error('bma:model:model_invalid', '无法从输入识别模型规格：请传入 bma.model.build 的返回值或模型规格');
end
uc = bma.spec.checkUnits(spec);
ok = uc.dimensional_ok;
end
