function c = toCellstr(x)
%TOCELLSTR 将 char / string / cell / 空值统一为 1×N cellstr。
c = {};
if isempty(x)
    return
end
if ischar(x)
    c = {x};
elseif isstring(x)
    if isscalar(x)
        c = {char(x)};
    else
        c = reshape(cellstr(x), 1, []);
    end
elseif iscell(x)
    n = numel(x);
    c = cell(1, n);
    for k = 1:n
        e = x{k};
        if ischar(e)
            c{k} = e;
        elseif isstring(e) && isscalar(e)
            c{k} = char(e);
        else
            c{k} = '';
        end
    end
else
    c = {char(string(x))};
end
end
