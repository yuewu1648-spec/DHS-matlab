function h = hashText(txt, nHex)
%HASHTEXT 计算文本的稳定短哈希（纯 MATLAB 实现，不依赖 Java/工具箱）。
%   h = bma.io.internal.hashText(txt)         % 默认 8 个十六进制字符
%   h = bma.io.internal.hashText(txt, 12)     % 指定长度（最多 16）
%
%   算法：对 UTF-8 字节做 FNV-1a（32-bit），再拼接第二组 mod 2^32 多项式哈希，
%   得到 16 个十六进制字符。使用 double 分块乘法避免整数饱和与浮点精度丢失，
%   因此在任何 MATLAB 平台上结果一致（doc_id 可复现）。
if nargin < 2 || isempty(nHex)
    nHex = 8;
end
if isstring(txt)
    txt = char(txt);
end
try
    bytes = unicode2native(char(txt), 'UTF-8');
catch
    bytes = double(char(txt));
end
bytes = double(bytes(:));

% FNV-1a 32-bit: h = (h xor byte) * 16777619 mod 2^32
h1 = 2166136261;
for k = 1:numel(bytes)
    h1 = bitxor(h1, bytes(k));
    h1 = fnvMul32(h1, 16777619);
end
% 第二哈希（djb2 变体），增加短摘要长度
h2 = 5381;
for k = 1:numel(bytes)
    h2 = mod(h2 * 33 + bytes(k), 4294967291);
end
% 长度混入，降低不同长度文本的碰撞概率
h2 = mod(h2 * 31 + mod(numel(bytes), 65536), 4294967291);

hex = [hex32(h1), hex32(mod(h2, 4294967296))];
nHex = max(1, min(16, double(nHex)));
h = hex(1:nHex);
end

% ---------------------------------------------------------------------------
function h = fnvMul32(h, m)
%FNVMUL32 (h*m) mod 2^32，用 16-bit 分块保证 double 精确。
h0 = mod(h, 65536);
h1 = floor(h / 65536);
m0 = mod(m, 65536);
m1 = floor(m / 65536);
lo = h0 * m0;                     % < 2^32
mid = h0 * m1 + h1 * m0;          % < 2^33
lo = lo + mod(mid, 65536) * 65536;
h = mod(lo, 4294967296);
end

function s = hex32(v)
digits = '0123456789abcdef';
v = mod(round(v), 4294967296);
s = repmat('0', 1, 8);
for k = 8:-1:1
    d = mod(v, 16);
    s(k) = digits(double(d) + 1);
    v = floor(v / 16);
end
end
