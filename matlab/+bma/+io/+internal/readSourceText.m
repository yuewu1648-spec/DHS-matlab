function [txt, titleHint, warnings, info] = readSourceText(path, fmt, maxBytes)
%READSOURCETEXT 按格式读取文献原始文本（UTF-8），并做大小保护。
%   [txt, titleHint, warnings, info] = bma.io.internal.readSourceText(path, fmt, maxBytes)
%
%   * PDF / DOCX：Text Analytics extractFileText（二进制格式需整体解析，
%     超过 maxBytes 时提示并截断解析结果）；
%   * TXT / MD / HTML：分块读取原始字节后统一按 UTF-8 解码，
%     避免多字节字符被块边界截断，超过 maxBytes 时截断并 warning。
if nargin < 3 || isempty(maxBytes)
    maxBytes = 2 * 1024 * 1024;
end
warnings = {};
titleHint = '';
info = struct('bytes', 0, 'truncated', false, 'reader', fmt.reader);
d = dir(path);
if ~isempty(d)
    info.bytes = d(1).bytes;
end

if fmt.binary
    % ISSUE-013: file bytes are only a preliminary notice; truncation is
    % decided by parsed text characters and reported with explicit counts.
    if info.bytes > maxBytes
        warnings{end + 1} = sprintf( ...
            '文件较大（%.2f MB > %.2f MB）：将按解析后的文本字符数检查截断，而非文件字节。', ...
            info.bytes / 1048576, maxBytes / 1048576);
    end
    if strcmpi(fmt.format, 'docx')
        % DOCX：优先用 docxToText 保留表格结构
        [txt, docxWarnings] = bma.io.internal.docxToText(path, maxBytes);
        warnings = [warnings, docxWarnings];
    else
        try
            raw = extractFileText(path);
        catch err
            error('bma:io:readFailed', ...
                '无法读取 %s（%s 格式）：%s。请确认 Text Analytics Toolbox 已授权且文件未损坏。', ...
                path, fmt.format, err.message);
        end
        txt = char(raw);
    end
    info.text_chars_total = numel(txt);
    if numel(txt) > maxBytes
        txt = txt(1:maxBytes);
        info.truncated = true;
        warnings{end + 1} = sprintf( ...
            '解析文本较长（%d 字符 > %d）：已截断至前 %d 个字符。', ...
            info.text_chars_total, round(maxBytes), round(maxBytes));
    end
    info.text_chars = numel(txt);
else
    [bytes, truncated] = readBytesLimited(path, maxBytes);
    info.truncated = truncated;
    if truncated
        warnings{end + 1} = sprintf( ...
            '文件较大（%.2f MB > %.2f MB），已截断为前 %d 个字符（分块读取）。', ...
            info.bytes / 1048576, maxBytes / 1048576, round(maxBytes));
    end
    txt = decodeUtf8(bytes);
    info.text_chars_total = numel(txt);
    info.text_chars = numel(txt);
    if strcmpi(fmt.format, 'html')
        [txt, titleHint] = bma.io.internal.htmlToText(txt);
        info.text_chars = numel(txt);
    end
end
end

% ---------------------------------------------------------------------------
function [bytes, truncated] = readBytesLimited(path, maxBytes)
fid = fopen(path, 'r', 'n');
if fid < 0
    error('bma:io:readFailed', '无法打开文件：%s', path);
end
cleaner = onCleanup(@() fclose(fid));
chunkSize = 256 * 1024;
bytes = zeros(0, 1, 'uint8');
while numel(bytes) < maxBytes
    want = min(chunkSize, maxBytes - numel(bytes));
    chunk = fread(fid, want, '*uint8');
    if isempty(chunk)
        break
    end
    bytes = [bytes; chunk]; %#ok<AGROW>
end
atEof = feof(fid);
truncated = ~atEof && numel(bytes) >= maxBytes;
if numel(bytes) > maxBytes
    bytes = bytes(1:maxBytes);
    truncated = true;
end
clear cleaner;
end

function txt = decodeUtf8(bytes)
txt = '';
if isempty(bytes)
    return
end
try
    if numel(bytes) >= 2 && bytes(1) == 255 && bytes(2) == 254
        txt = native2unicode(bytes(:)', 'UTF-16LE');
    elseif numel(bytes) >= 2 && bytes(1) == 254 && bytes(2) == 255
        txt = native2unicode(bytes(:)', 'UTF-16BE');
    else
        txt = native2unicode(bytes(:)', 'UTF-8');
    end
catch
    txt = char(bytes(:)');
end
if isempty(txt)
    return
end
% UTF-8 BOM
if double(txt(1)) == 65279
    txt = txt(2:end);
end
% 截断可能留下的替换字符
while ~isempty(txt) && double(txt(end)) == 65533
    txt = txt(1:end - 1);
end
end
