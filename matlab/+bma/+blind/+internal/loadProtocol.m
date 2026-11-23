function p = loadProtocol(runDir, required)
%LOADPROTOCOL Read <run_dir>/blind/protocol.json.
%   p = bma.blind.internal.loadProtocol(runDir)
%   p = bma.blind.internal.loadProtocol(runDir, true)  % error when missing
%
%   Returns [] when the protocol does not exist and required is false.
if nargin < 2 || isempty(required)
    required = false;
end
file = bma.blind.internal.protocolFile(runDir);
if ~isfile(file)
    if required
        error('bma:blind:not_started', ...
            '该 run 尚未启动盲建模协议（缺少 %s）。先调用 bma_blind_start。', file);
    end
    p = [];
    return
end
p = bma.util.readJson(file);
if ~isstruct(p)
    error('bma:blind:corrupt', '盲建模协议文件无法解析：%s', file);
end
% Normalize JSON-array-backed lists into cell arrays of structs/strings so the
% rest of the code can append/update without struct-array field mismatches.
p = bma.blind.internal.fillProtocolDefaults(p);
end
