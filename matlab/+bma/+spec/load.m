function spec = load(path)
%LOAD 读取 bma.modelSpec.v1 JSON 规格文件（UTF-8）。
%   spec = bma.spec.load(path)
%   失败时抛出带中文提示的异常（bma:spec:load / BMA_SPEC_INVALID）。
if nargin < 1 || isempty(path)
    error('bma:spec:spec_invalid', 'bma.spec.load 需要文件路径');
end
path = char(path);
if ~isfile(path)
    error('bma:spec:spec_invalid', '模型规格文件不存在：%s', path);
end
try
    spec = bma.util.readJson(path);
catch err
    error('bma:spec:spec_invalid', '读取模型规格 JSON 失败（%s）：%s', path, err.message);
end
if ~isstruct(spec) || isempty(spec)
    error('bma:spec:spec_invalid', '模型规格文件内容必须是 JSON 对象：%s', path);
end
end
