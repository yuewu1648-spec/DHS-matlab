function v = jsonSafe(v)
%JSONSAFE Convert a value into something jsonencode always accepts.
%   Function handles, tables, datetimes, and handle objects are converted;
%   logicals and numeric values (including NaN/Inf, encoded as JSON null) are
%   preserved. Recursion goes through a local function so package-name
%   resolution never applies to nested values.
v = js(v);
end

function v = js(v)
if isstruct(v)
    if isscalar(v)
        out = struct();
        names = fieldnames(v);
        for k = 1:numel(names)
            out.(names{k}) = js(v.(names{k}));
        end
        v = out;
    else
        c = cell(1, numel(v));
        for k = 1:numel(v)
            c{k} = js(v(k));
        end
        v = c;
    end
elseif iscell(v)
    for k = 1:numel(v)
        v{k} = js(v{k}); %#ok<AGROW>
    end
elseif isa(v, 'function_handle')
    v = ['@' func2str(v)];
elseif istable(v)
    v = js(table2struct(v));
elseif isa(v, 'datetime') || isa(v, 'duration') || isa(v, 'calendarDuration')
    v = char(v);
elseif isa(v, 'string')
    v = cellstr(v);
elseif isa(v, 'categorical')
    v = cellstr(v);
elseif isa(v, 'containers.Map')
    ks = keys(v);
    out = struct();
    for k = 1:numel(ks)
        out.(matlab.lang.makeValidName(char(ks{k}))) = js(v(ks{k}));
    end
    v = out;
elseif islogical(v)
    % JSON booleans: keep as-is.
elseif isnumeric(v)
    if ~isreal(v)
        v = real(v);
    end
    if numel(v) > 200000
        v = v(1:200000);
    end
elseif isa(v, 'handle') || isobject(v)
    try
        names = properties(v);
        out = struct();
        for k = 1:numel(names)
            out.(names{k}) = js(v.(names{k}));
        end
        v = out;
    catch
        v = class(v);
    end
end
end
