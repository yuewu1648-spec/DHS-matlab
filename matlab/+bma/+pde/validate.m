function report = validate(spec)
%VALIDATE Lightweight validation for the native 2D PDE Toolbox path.
%   report = bma.pde.validate(spec)
%
% This does not build a mesh or solve. It checks the fields required by
% bma.pde.simulate and returns the same {valid,errors,warnings,summary}
% shape as bma.spec.validate, so the agent's G5 gate can accept a 2D native
% spec before calling bma_pde_simulate.
if ischar(spec) || isstring(spec)
    spec = bma.spec.load(char(spec));
end
errors = {};
warnings = {};
if ~isstruct(spec) || isempty(spec)
    errors{end+1} = issue('BMA_PDE_INVALID', 'spec', 'PDE 规格必须是非空对象');
    report = pack(spec, errors, warnings);
    return
end
spec = bma.spec.normalize(spec);
pde = getF(spec, 'pde', struct());
if ~isstruct(pde) || isempty(pde)
    errors{end+1} = issue('BMA_PDE_INVALID', 'pde', 'kind="pde" 需要 pde 子树');
else
    dim = getF(pde, 'dim', []);
    if ~isnumeric(dim) || ~isscalar(dim) || ~any(dim == [2 3])
        errors{end+1} = issue('BMA_PDE_INVALID', 'pde.dim', '原生 PDE Toolbox 支持 dim=2/3');
    end
    domain = getF(pde, 'domain', struct());
    geom = lower(char(getF(domain, 'geometry', '')));
    if ~any(strcmp(geom, {'rectangle', 'circle', 'polygon', 'box', 'stl'}))
        errors{end+1} = issue('BMA_PDE_INVALID', 'pde.domain.geometry', ...
            '原生支持 rectangle/circle/polygon/box/stl');
    else
        switch geom
            case 'rectangle'
                sz = getF(domain, 'size', []);
                if isempty(sz)
                    ext = getF(domain, 'extent', struct());
                    sz = getF(ext, 'value', []);
                end
                if ~isnumeric(sz) || numel(sz) ~= 2 || any(sz <= 0)
                    errors{end+1} = issue('BMA_PDE_INVALID', 'pde.domain.size', ...
                        'rectangle 需要 size=[width height]');
                end
            case 'circle'
                r = getF(domain, 'radius', []);
                if isempty(r), r = getF(getF(domain, 'extent', struct()), 'value', []); end
                if ~isnumeric(r) || ~isscalar(r) || r <= 0
                    errors{end+1} = issue('BMA_PDE_INVALID', 'pde.domain.radius', ...
                        'circle 需要 radius>0');
                end
            case 'polygon'
                pts = getF(domain, 'points', []);
                if ~isnumeric(pts) || size(pts, 2) ~= 2 || size(pts, 1) < 3
                    errors{end+1} = issue('BMA_PDE_INVALID', 'pde.domain.points', ...
                        'polygon 需要 N×2 点（N>=3）');
                end
            case 'box'
                sz = getF(domain, 'size', []);
                if isempty(sz)
                    ext = getF(domain, 'extent', struct());
                    sz = getF(ext, 'value', []);
                end
                if ~isnumeric(sz) || numel(sz) ~= 3 || any(sz <= 0)
                    errors{end+1} = issue('BMA_PDE_INVALID', 'pde.domain.size', ...
                        'box 需要 size=[Lx Ly Lz]');
                end
            case 'stl'
                f = getF(domain, 'file', '');
                if isempty(f)
                    errors{end+1} = issue('BMA_PDE_INVALID', 'pde.domain.file', ...
                        'stl 需要 file 路径');
                end
        end
    end
    diff = itemize(getF(pde, 'diffusion', []));
    if isempty(diff)
        errors{end+1} = issue('BMA_PDE_INVALID', 'pde.diffusion', '至少一个 {species,coeff}');
    end
    vars = itemize(getF(spec, 'variables', []));
    species = cellfun(@(v) char(getF(v, 'id', '')), vars, 'UniformOutput', false);
    for k = 1:numel(diff)
        sid = char(getF(diff{k}, 'species', ''));
        if ~any(strcmp(sid, species))
            errors{end+1} = issue('BMA_PDE_INVALID', sprintf('pde.diffusion[%d].species', k-1), ...
                sprintf('未知变量 "%s"', sid));
        end
        coeff = getF(diff{k}, 'coeff', []);
        if ~ischar(coeff)
            errors{end+1} = issue('BMA_PDE_INVALID', sprintf('pde.diffusion[%d].coeff', k-1), ...
                'coeff 必须是参数 id');
        end
    end
    reacs = itemize(getF(spec, 'reactions', []));
    if isempty(reacs)
        errors{end+1} = issue('BMA_PDE_INVALID', 'reactions', '原生 PDE 需要至少一个反应/源项');
    end
    bc = itemize(getF(pde, 'bc', []));
    for k = 1:numel(bc)
        typ = lower(char(getF(bc{k}, 'type', '')));
        if ~any(strcmp(typ, {'dirichlet', 'neumann'}))
            errors{end+1} = issue('BMA_PDE_INVALID', sprintf('pde.bc[%d].type', k-1), ...
                '必须是 dirichlet/neumann');
        elseif strcmp(typ, 'neumann')
            flux = getF(bc{k}, 'flux', 0);
            if ~isnumeric(flux) || ~isscalar(flux) || flux ~= 0
                errors{end+1} = issue('BMA_PDE_INVALID', sprintf('pde.bc[%d].flux', k-1), ...
                    'v1 只支持 flux=0');
            end
        end
    end
end
if license('test', 'PDE_Toolbox') ~= 1
    errors{end+1} = issue('BMA_PDE_TOOLBOX_UNAVAILABLE', 'pde', ...
        'PDE Toolbox 未授权；请改用 1D MOL 或安装授权');
end
report = pack(spec, errors, warnings);
end

function r = pack(spec, errors, warnings)
r = struct();
r.valid = isempty(errors);
r.ok = r.valid;
r.errors = errors;
r.warnings = warnings;
r.n_errors = numel(errors);
r.n_warnings = numel(warnings);
r.kind = 'pde';
r.name = char(getF(spec, 'name', ''));
r.normalized_spec = spec;
r.summary = struct('kind', 'pde', 'name', char(getF(spec, 'name', '')), ...
    'n_species', numel(itemize(getF(spec, 'variables', []))), ...
    'n_parameters', numel(itemize(getF(spec, 'parameters', []))), ...
    'n_estimated_parameters', 0, ...
    'n_reactions', numel(itemize(getF(spec, 'reactions', []))), ...
    'n_pde_species', numel(itemize(getF(spec, 'variables', []))));
end

function e = issue(code, path, message)
e = struct('code', code, 'path', path, 'message', message, ...
    'hint', '检查 pde 子树；原生 2D 见 docs/DESIGN.md §3.3。', 'severity', 'error');
end

function items = itemize(x)
if iscell(x)
    items = x(:).';
elseif isstruct(x)
    items = num2cell(x(:).');
elseif isempty(x)
    items = {};
else
    items = {x};
end
end

function v = getF(s, f, d)
if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
    v = s.(f);
else
    v = d;
end
end
