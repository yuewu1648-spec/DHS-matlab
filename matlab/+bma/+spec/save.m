function spec = save(spec, path)
%SAVE 将 bma.modelSpec.v1 规格以 UTF-8 JSON 原子写入文件。
%   spec = bma.spec.save(spec, path)
%   spec = bma.spec.save(spec_path, out_path)  % 先 load 再另存（归一化后）
%   返回被写入的（归一化后的）规格结构体，便于链式调用。
if nargin < 2 || isempty(path)
    error('bma:spec:spec_invalid', 'bma.spec.save 需要 (spec, path) 两个参数');
end
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec) || isempty(spec)
    error('bma:spec:spec_invalid', 'bma.spec.save 需要模型规格结构体');
end
path = char(path);
try
    spec = bma.spec.normalize(spec);
    bma.util.writeJsonAtomic(path, spec);
catch err
    error('bma:spec:spec_invalid', '保存模型规格失败（%s）：%s', path, err.message);
end
end
