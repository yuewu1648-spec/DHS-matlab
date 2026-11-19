function uc = checkUnits(spec)
%CHECKUNITS 模型规格的量纲检查（供 bma.model.checkUnits 与 validate 复用）。
%   uc = bma.spec.checkUnits(spec) 中 spec 可以是结构体或 spec JSON 路径。
%   返回字段：
%     .checked / .ok / .dimensional_ok / .n_units_checked
%     .issues（cell，{code,path,message,hint,severity}）
%     .errors / .warnings / .n_errors / .n_warnings / .note
%   ok 表示单位字符串均可解析（无错误级问题）；dimensional_ok 还要求没有量纲不一致警告。
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
if ~isstruct(spec) || isempty(spec)
    error('bma:spec:spec_invalid', 'checkUnits 需要模型规格结构体或 JSON 路径');
end
norm = bma.spec.normalize(spec);
if isfield(norm, 'kind') && strcmpi(char(norm.kind), 'dde')
    % delay(...) expressions are compiled by bma.dde.compile; the generic
    % ODE units walker does not understand them. DDE compile performs the
    % structural checks; mark unit checking as not performed rather than
    % reporting a false positive.
    uc = struct('checked', false, 'ok', true, 'dimensional_ok', true, ...
        'n_units_checked', 0, 'issues', {{}}, 'errors', {{}}, 'warnings', {{}}, ...
        'n_errors', 0, 'n_warnings', 0, 'applicable', false, ...
        'reason', 'dde_units_not_derived', ...
        'note', 'DDE 延迟表达式暂不进入通用量纲引擎；结构/延迟单位由 bma.dde.compile 检查');
    return
end
if isfield(norm, 'kind') && strcmpi(char(norm.kind), 'bvp')
    uc = struct('checked', false, 'ok', true, 'dimensional_ok', true, ...
        'n_units_checked', 0, 'issues', {{}}, 'errors', {{}}, 'warnings', {{}}, ...
        'n_errors', 0, 'n_warnings', 0, 'applicable', false, ...
        'reason', 'bvp_units_not_derived', ...
        'note', 'BVP 边值条件/空间单位暂不进入通用量纲引擎；结构由 bma.bvp.compile 检查');
    return
end
if isfield(norm, 'kind') && strcmpi(char(norm.kind), 'dae')
    uc = struct('checked', false, 'ok', true, 'dimensional_ok', true, ...
        'n_units_checked', 0, 'issues', {{}}, 'errors', {{}}, 'warnings', {{}}, ...
        'n_errors', 0, 'n_warnings', 0, 'applicable', false, ...
        'reason', 'dae_units_not_derived', ...
        'note', 'DAE 残差/导数项暂不进入通用量纲引擎；结构由 bma.dae.compile 检查');
    return
end
if isfield(norm, 'kind') && strcmpi(char(norm.kind), 'pde')
    try
        norm = bma.spec.pde.expand(norm);
    catch err
        uc = struct('checked', false, 'ok', false, 'dimensional_ok', false, ...
            'n_units_checked', 0, 'issues', {{struct('code', 'BMA_PDE_INVALID', ...
            'path', 'pde', 'message', err.message, 'hint', ...
            '检查 PDE 子树与 C[i]/统计量语法。', 'severity', 'error')}}, ...
            'errors', {{}}, 'warnings', {{}}, 'n_errors', 1, 'n_warnings', 0, ...
            'note', 'PDE 展开失败，无法检查量纲');
        return
    end
end
uc = checkUnitsCore(bma.spec.normalize(norm));
end
