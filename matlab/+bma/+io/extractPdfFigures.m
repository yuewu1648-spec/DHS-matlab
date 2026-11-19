function out = extractPdfFigures(pdfPath, outDir, opts)
%EXTRACTPDFFIGURES 从 PDF 中抽取位图插图（无外部依赖的最小实现）。
%   out = bma.io.extractPdfFigures(pdfPath, outDir, opts)
%
% 支持：/DCTDecode（直接写 .jpg）与 /FlateDecode（Inflater 解压后写 .png）；
% 8 位 DeviceRGB/DeviceGray/DeviceCMYK/ICCBased；1 位灰度；PNG Predictor 12/15。
% 返回 struct：ok, count, figures(结构体数组), warnings, figures_json
%
% 说明：这是“够用”的抽取器：不渲染矢量图、不处理 JPX/CCITT，不对页面内容流做
% 完整解释；页码按对象在文件中出现顺序估算，图注由 ingest 用正文 "Fig. N" 匹配。

if nargin < 3 || isempty(opts)
    opts = struct();
end
if ischar(pdfPath) || isstring(pdfPath)
    pdfPath = char(pdfPath);
end
if ~isfile(pdfPath)
    error('bma:io:pdfNotFound', 'PDF 文件不存在：%s', pdfPath);
end
outDir = char(outDir);
bma.util.ensureDir(outDir);
maxFigures = getOpt(opts, 'max_figures', 40);
maxBytes = getOpt(opts, 'max_bytes', 25 * 1024 * 1024);
skipSmall = getOpt(opts, 'min_pixels', 32);

out = struct('ok', false, 'count', 0, 'figures', struct([]), ...
    'warnings', {{}}, 'figures_json', '', 'figure_class', '', ...
    'vector_only', false, 'rasterized', false, 'reason', '', ...
    'mask_count', 0, 'mono_skipped', 0);
try
    fid = fopen(pdfPath, 'r');
    if fid < 0
        error('bma:io:pdfOpen', '无法打开 PDF：%s', pdfPath);
    end
    bytes = fread(fid, Inf, 'uint8=>uint8');
    fclose(fid);
catch err
    out.warnings{end+1} = err.message;
    return
end
s = char(bytes(:).');
n = numel(s);
idx = regexp(s, '/Subtype\s*/Image', 'start');
if isempty(idx)
    out.figure_class = 'vector';
    out.vector_only = true;
    out.rasterized = false;
    out.reason = 'no_renderer';
    out.warnings{end+1} = ['PDF 中没有找到位图 XObject：插图是矢量图；' ...
        '本机无外部渲染器，rasterized=false（reason=no_renderer）。' ...
        '可用 pdftoppm/office-render 按页渲染后再做原图对照。'];
    return
end
figures = struct('index', {}, 'file', {}, 'width', {}, 'height', {}, ...
    'page', {}, 'caption', {}, 'bytes', {}, 'filter', {}, 'format', {});
seen = {};
count = 0;
maskSkipped = 0;
monoSkipped = 0;
for k = 1:numel(idx)
    if count >= maxFigures
        out.warnings{end+1} = sprintf('达到最多 %d 张图的上限，已停止抽取。', maxFigures);
        break
    end
    pos = idx(k);
    % 所在对象与字典
    objStart = lastObjStart(s, pos);
    if objStart < 1
        continue
    end
    dictEnd = regexp(s(pos:min(n, pos + 8000)), 'stream\r?\n', 'once');
    if isempty(dictEnd)
        continue
    end
    dict = s(objStart:pos + dictEnd);
    if ~isempty(regexp(dict, '/ImageMask\s+true', 'once'))
        maskSkipped = maskSkipped + 1;
        continue
    end
    w = dictNum(dict, 'Width');
    h = dictNum(dict, 'Height');
    bpc = dictNum(dict, 'BitsPerComponent');
    if isnan(w) || isnan(h) || w < skipSmall || h < skipSmall
        continue
    end
    if isnan(bpc), bpc = 8; end
    filters = regexp(dict, '/Filter\s*(?:\[\s*)?/([A-Za-z0-9]+)', 'tokens');
    filter = '';
    for f = 1:numel(filters)
        filter = filters{f}{1};
    end
    cs = parseColorSpace(dict);
    streamStart = pos + dictEnd + numel('stream') - 1;
    % skip CR/LF
    while streamStart <= n && (s(streamStart) == sprintf('\r') || s(streamStart) == sprintf('\n'))
        streamStart = streamStart + 1;
    end
    endPos = strfind(s(streamStart:end), 'endstream');
    if isempty(endPos)
        continue
    end
    dataEnd = streamStart + endPos(1) - 2;
    data = bytes(streamStart:dataEnd);
    if numel(data) > maxBytes
        out.warnings{end+1} = sprintf('图 %d 超过 25MB，已跳过。', k); %#ok<AGROW>
        continue
    end
    page = 1 + numel(regexp(s(1:objStart), '/Type\s*/Page(?!s)', 'start'));
    fn = '';
    fmt = '';
    try
        if strcmpi(filter, 'DCTDecode') || strcmpi(filter, 'DCT')
            if isempty(data) || data(1) ~= uint8(255) || data(2) ~= uint8(216)
                continue
            end
            fmt = 'jpg';
            fn = sprintf('fig%02d.jpg', count + 1);
            writeBinary(fullfile(outDir, fn), data);
        else
            raw = data;
            if strcmpi(filter, 'FlateDecode') || strcmpi(filter, 'Fl')
                raw = inflateBytes(data);
            elseif ~isempty(filter) && ~strcmpi(filter, 'FlateDecode')
                out.warnings{end+1} = sprintf('图 %d 使用不支持的滤镜 %s，已跳过。', k, filter); %#ok<AGROW>
                continue
            end
            [img, ok] = rawToImage(raw, w, h, bpc, cs, dict);
            if ~ok
                out.warnings{end+1} = sprintf('图 %d 的像素格式暂不支持（bpc=%d, cs=%s, filter=%s, raw=%d, need=%d），已跳过。', k, bpc, cs, filter, numel(raw), w*h*3); %#ok<AGROW>
                continue
            end
            fmt = 'png';
            fn = sprintf('fig%02d.png', count + 1);
            % 跳过空白/掩膜图（软掩膜、背景层常是单色，抽取出来没有信息）
            if isempty(img) || std(double(img(:))) < 1.0
                monoSkipped = monoSkipped + 1;
                continue
            end
            imwrite(img, fullfile(outDir, fn));
        end
    catch err
        out.warnings{end+1} = sprintf('图 %d 解码失败：%s', k, err.message); %#ok<AGROW>
        continue
    end
    if isempty(fn) || ~isfile(fullfile(outDir, fn))
        continue
    end
    if any(strcmp(seen, fn))
        continue
    end
    seen{end+1} = fn; %#ok<AGROW>
    count = count + 1;
    info = dir(fullfile(outDir, fn));
    figureItem = struct('index', count, 'file', fn, ...
        'width', w, 'height', h, 'page', page, 'caption', '', ...
        'bytes', info.bytes, 'filter', filter, 'format', fmt);
    figures(end+1) = figureItem; %#ok<AGROW>
end
out.figures = figures;
out.count = numel(figures);
out.ok = out.count > 0;
out.mask_count = maskSkipped;
out.mono_skipped = monoSkipped;
if out.count == 0
    if maskSkipped > 0 || monoSkipped > 0
        out.figure_class = 'vector_or_mask';
        out.vector_only = true;
        out.rasterized = false;
        out.reason = 'no_renderer';
        out.warnings{end+1} = sprintf([ ...
            '未抽出颜色位图：%d 个 ImageMask、%d 个 1-bit/近似单色对象。' ...
            '这些通常是矢量曲线图的掩膜/背景层，不是"单色插图"；' ...
            'rasterized=false（reason=no_renderer）。可用 pdftoppm 或 office-render 按页渲染。'], ...
            maskSkipped, monoSkipped);
    else
        out.figure_class = 'unknown';
        out.rasterized = false;
        out.reason = 'no_raster_image_found';
    end
else
    out.figure_class = 'bitmap';
    out.rasterized = true;
    if maskSkipped > 0 || monoSkipped > 0
        out.warnings{end+1} = sprintf( ...
            '跳过 %d 个 ImageMask 和 %d 个 1-bit/单色对象（其余 %d 张颜色位图已抽取）。', ...
            maskSkipped, monoSkipped, out.count);
    end
end
manifest = struct('schema', 'bma.literatureFigures.v1', ...
    'source', pdfPath, 'figures', figures, 'count', out.count, ...
    'figure_class', out.figure_class, 'vector_only', out.vector_only, ...
    'rasterized', out.rasterized, 'reason', out.reason, ...
    'mask_count', maskSkipped, 'mono_skipped', monoSkipped);
jsonPath = fullfile(outDir, 'figures.json');
bma.util.writeJsonAtomic(jsonPath, manifest);
out.figures_json = jsonPath;
if out.count == 0 && isempty(out.warnings)
    out.warnings{end+1} = '未抽取到可用位图（可能是矢量图、JPX/CCITT 或纯文本 PDF）。';
end
end

% ---------------------------------------------------------------------------
function v = getOpt(opts, name, default)
v = default;
if isstruct(opts) && isfield(opts, name) && ~isempty(opts.(name))
    v = opts.(name);
end
end

function p = lastObjStart(s, pos)
p = -1;
starts = regexp(s(1:max(1, pos)), '\d+\s+0\s+obj', 'start');
if ~isempty(starts)
    p = starts(end);
end
end

function v = dictNum(dict, key)
v = NaN;
tok = regexp(dict, ['/' key '\s+(\d+)'], 'tokens', 'once');
if ~isempty(tok)
    v = str2double(tok{1});
end
end

function cs = parseColorSpace(dict)
cs = 'RGB';
tok = regexp(dict, '/ColorSpace\s*/([A-Za-z0-9]+)', 'tokens', 'once');
if ~isempty(tok)
    name = tok{1};
    if any(strcmpi(name, {'DeviceGray', 'CalGray', 'G'}))
        cs = 'Gray';
    elseif any(strcmpi(name, {'DeviceCMYK', 'CMYK'}))
        cs = 'CMYK';
    elseif any(strcmpi(name, {'DeviceRGB', 'CalRGB', 'RGB'}))
        cs = 'RGB';
    elseif strcmpi(name, 'ICCBased')
        nTok = regexp(dict, '/N\s+(\d+)', 'tokens', 'once');
        if ~isempty(nTok)
            nComp = str2double(nTok{1});
            if nComp == 1, cs = 'Gray'; elseif nComp == 4, cs = 'CMYK'; end
        end
    elseif strcmpi(name, 'Indexed')
        cs = 'Indexed';
    end
end
end

function raw = inflateBytes(data)
%INFLATEBYTES zlib inflate via java.util.zip.Inflater (no toolbox needed).
inflater = java.util.zip.Inflater();
inflater.setInput(int8(typecast(uint8(data(:)'), 'int8')));
chunks = {};
total = 0;
buffer = zeros(1, 65536, 'int8');
try
    while ~inflater.finished()
        count = inflater.inflate(buffer);
        if count <= 0
            if inflater.needsInput() || inflater.needsDictionary()
                break
            end
            break
        end
        part = typecast(buffer(1:count), 'uint8');
        chunks{end+1} = part; %#ok<AGROW>
        total = total + numel(part);
        if total > 80 * 1024 * 1024
            break
        end
    end
finally
    try
        inflater.end();
    catch
    end
end
if isempty(chunks)
    raw = zeros(1, 0, 'uint8');
else
    raw = [chunks{:}];
end
end

function [img, ok] = rawToImage(raw, w, h, bpc, cs, dict)
img = [];
ok = false;
if bpc == 1 && strcmpi(cs, 'Gray')
    need = ceil(w / 8) * h;
    if numel(raw) < need
        return
    end
    bits = de2bi(raw(1:need), 8, 'left-msb');
    bits = reshape(bits.', 1, []);
    pix = reshape(bits(1:w * h), w, h).';
    img = uint8(pix) * 255;
    ok = true;
    return
end
if bpc ~= 8
    return
end
% /ColorSpace 可能是 [/Indexed /DeviceRGB ...] 数组；上面的正则只会抓到
% DeviceRGB，此时 raw 实际是 1 字节索引。先尝试按调色板还原。
if strcmpi(cs, 'RGB') && numel(raw) >= w * h && numel(raw) < w * h * 3
    pal = parseIndexedPalette(dict);
    if ~isempty(pal)
        idx = double(raw(1:w * h)) + 1;
        idx = min(idx, size(pal, 1));
        rgb = pal(idx, :);
        img = reshape(uint8(rgb), w, h, 3);
        img = permute(img, [2 1 3]);
        ok = true;
        return
    end
    % 没有调色板时，退化为灰度复制（图仍可见，颜色不保证）
    img = repmat(reshape(uint8(raw(1:w * h)), w, h).', [1 1 3]);
    ok = true;
    return
end
nComp = 1;
if strcmpi(cs, 'RGB'), nComp = 3; end
if strcmpi(cs, 'CMYK'), nComp = 4; end
if strcmpi(cs, 'Indexed')
    return
end
need = w * h * nComp;
if numel(raw) < need
    return
end
% PNG predictor（/Predictor >= 10）：逐行反滤波
pred = NaN;
tok = regexp(dict, '/Predictor\s+(\d+)', 'tokens', 'once');
if ~isempty(tok)
    pred = str2double(tok{1});
end
if isfinite(pred) && pred >= 10
    raw = undoPredictor(raw, w, h, nComp);
    if isempty(raw)
        return
    end
end
pix = reshape(raw(1:need), nComp, w, h);
pix = permute(pix, [3 2 1]);   % h × w × nComp
switch upper(cs)
    case 'GRAY'
        img = repmat(uint8(pix), [1 1 3]);
    case 'RGB'
        img = uint8(pix);
    case 'CMYK'
        c = double(pix(:, :, 1)); m = double(pix(:, :, 2));
        y = double(pix(:, :, 3)); kk = double(pix(:, :, 4));
        r = 255 - min(255, c + kk);
        g = 255 - min(255, m + kk);
        b = 255 - min(255, y + kk);
        img = uint8(cat(3, r, g, b));
    otherwise
        return
end
ok = true;
end

function out = undoPredictor(raw, w, h, nComp)
%UNDOPREDICTOR Undo PNG row predictors 10-15 (filter byte at start of each row).
rowBytes = w * nComp;
need = h * (rowBytes + 1);
if numel(raw) < need
    out = [];
    return
end
out = zeros(1, h * rowBytes, 'uint8');
prev = zeros(1, rowBytes, 'uint8');
for r = 1:h
    offset = (r - 1) * (rowBytes + 1);
    ft = double(raw(offset + 1));
    row = double(raw(offset + 2:offset + 1 + rowBytes));
    cur = zeros(1, rowBytes);
    for j = 1:rowBytes
        a = 0; b = 0; c = 0;
        if j > nComp, a = cur(j - nComp); end
        b = prev(j);
        if j > nComp, c = prev(j - nComp); end
        switch ft
            case 0
                pred = 0;
            case 1
                pred = a;
            case 2
                pred = b;
            case 3
                pred = floor((a + b) / 2);
            case 4
                p = a + b - c;
                pa = abs(p - a); pb = abs(p - b); pc = abs(p - c);
                if pa <= pb && pa <= pc
                    pred = a;
                elseif pb <= pc
                    pred = b;
                else
                    pred = c;
                end
            otherwise
                pred = 0;
        end
        cur(j) = mod(row(j) + pred, 256);
    end
    out(offset - (r - 1) + 1:offset - (r - 1) + rowBytes) = uint8(cur);
    prev = uint8(cur);
end
end

function pal = parseIndexedPalette(dict)
%PARSEINDEXEDPALETTE Parse a direct /Indexed palette from a PDF image dict.
pal = [];
tok = regexp(dict, '/Indexed\s*/\w+\s+\d+\s*<([0-9A-Fa-f\s]+)>', 'tokens', 'once');
if isempty(tok)
    return
end
hex = regexprep(tok{1}, '\s+', '');
if mod(numel(hex), 6) ~= 0
    return
end
n = numel(hex) / 6;
pal = zeros(n, 3, 'uint8');
for k = 1:n
    triple = hex((k - 1) * 6 + (1:6));
    pal(k, :) = uint8([hex2dec(triple(1:2)), hex2dec(triple(3:4)), hex2dec(triple(5:6))]);
end
end

function writeBinary(path, data)
fid = fopen(path, 'w');
if fid < 0
    error('bma:io:writeFigure', '无法写入 %s', path);
end
fwrite(fid, uint8(data), 'uint8');
fclose(fid);
end
