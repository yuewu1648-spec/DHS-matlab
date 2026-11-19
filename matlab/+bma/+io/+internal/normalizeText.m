function txt = normalizeText(txt)
%NORMALIZETEXT 统一文本的换行、空白与常见 Unicode 变体。
%   txt = bma.io.internal.normalizeText(txt)
%
%   归一化规则（保证幂等：normalizeText(normalizeText(x)) == normalizeText(x)）：
%     * 换行统一为 LF；
%     * 去掉 NUL 与控制字符（保留 \n 与 \t）；
%     * 常见 Unicode 空格替换为普通空格，零宽字符删除；
%     * en dash / em dash / Unicode 减号统一为 ASCII '-'（便于单位与区间解析）；
%     * 行尾空白删除，连续空行压缩为最多 1 个空行。
%
%   ingest 后的 text.txt 与 sections/numbers/tables 的字符偏移都以本函数输出
%   的文本为准，因此各模块必须共享同一份归一化文本。
if isstring(txt)
    txt = char(txt);
end
txt = char(txt);
if isempty(txt)
    return
end

% 换行统一为 LF
txt = regexprep(txt, '\r\n|\r', '\n');

% 控制字符（保留 \n 与 \t）
txt = regexprep(txt, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '');

% 常见空白类 Unicode 字符 -> 普通空格
spaceCodes = [160, 8192:8202, 8239, 8287, 12288];
for k = 1:numel(spaceCodes)
    txt = strrep(txt, char(spaceCodes(k)), ' ');
end
% 零宽字符 / BOM / 非字符删除（PDF 抽取常把连字 ligature 映射为 U+FFFD/FFFE/FFFF，
% 典型如 "Introduc<U+FFFF>on"；删除后配合标题模糊匹配可恢复）
zeroWidthCodes = [8203, 8204, 8205, 65279, 65533, 65534, 65535];
for k = 1:numel(zeroWidthCodes)
    txt = strrep(txt, char(zeroWidthCodes(k)), '');
end
% 破折号、减号统一为 '-'
dashCodes = [8211, 8212, 8722];
for k = 1:numel(dashCodes)
    txt = strrep(txt, char(dashCodes(k)), '-');
end

% 行尾空白、连续空行、整体首尾空白
txt = regexprep(txt, '[ \t]+(?=\n)', '');
txt = regexprep(txt, '\n{3,}', '\n\n');
txt = regexprep(txt, '^\s+', '');
txt = regexprep(txt, '\s+$', '');
end
