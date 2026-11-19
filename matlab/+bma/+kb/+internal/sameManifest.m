function tf = sameManifest(a, b)
%SAMEMANIFEST 判断两个文件清单是否一致（路径集合 + mtime + 字节数）。
tf = false;
if ~isstruct(a) || ~isstruct(b)
    return
end
if numel(a) ~= numel(b)
    return
end
for k = 1:numel(a)
    if ~strcmp(char(a(k).path), char(b(k).path))
        return
    end
    if abs(double(a(k).mtime) - double(b(k).mtime)) > 1e-9
        return
    end
    if double(a(k).bytes) ~= double(b(k).bytes)
        return
    end
end
tf = true;
end
