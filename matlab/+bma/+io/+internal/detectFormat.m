function fmt = detectFormat(path)
%DETECTFORMAT 根据扩展名判断文献格式与读取方式。
%   fmt = bma.io.internal.detectFormat(path)
%   字段：ext / format / binary / supported / reader
[~, ~, ext] = fileparts(char(path));
ext = lower(ext);
fmt = struct('ext', ext, 'format', '', 'binary', false, ...
    'supported', false, 'reader', '');
switch ext
    case '.pdf'
        fmt.format = 'pdf';
        fmt.binary = true;
        fmt.supported = true;
        fmt.reader = 'extractFileText';
    case '.docx'
        fmt.format = 'docx';
        fmt.binary = true;
        fmt.supported = true;
        fmt.reader = 'extractFileText';
    case '.txt'
        fmt.format = 'txt';
        fmt.reader = 'readText';
        fmt.supported = true;
    case '.md'
        fmt.format = 'markdown';
        fmt.reader = 'readText';
        fmt.supported = true;
    case '.markdown'
        fmt.format = 'markdown';
        fmt.reader = 'readText';
        fmt.supported = true;
    case {'.html', '.htm'}
        fmt.format = 'html';
        fmt.reader = 'htmlTree';
        fmt.supported = true;
    otherwise
        % 末知格式，保留 ext 供报错提示
end
end
