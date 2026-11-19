function ops = fvOps(geometry, n)
%FVOPS 1D finite-volume coefficients for slab/cylinder/sphere cell centers.
%   ops = bma.spec.pde.fvOps('slab', 16)
%
% Cell centers x_i = (i-0.5)*dx, faces x_{i±1/2}. The ODE diffusion term is
%   dC_i/dt = kex*( aR(i)*(C_{i+1}-C_i) - aL(i)*(C_i-C_{i-1}) )
% with kex = De/dx^2. For a boundary Dirichlet condition, the half-cell ghost
% face coefficient is bR(n) (x1) or bL(1) (x0); Neumann zero flux has no term.
%
% Returns:
%   .geometry .n .dx_factor (always 1; dx is supplied by the caller)
%   .aL .aR   1×n interior face coefficients (aL(1)=0 for cylinder/sphere)
%   .bL .bR   boundary half-cell coefficients (scalar; slab b=2)
%   .dim      spatial dimension
geometry = lower(char(geometry));
n = double(n);
if n < 2 || n ~= round(n)
    error('bma:pde:badGrid', 'n 必须是 >=2 的整数');
end
switch geometry
    case 'slab'
        dim = 1;
    case 'cylinder'
        dim = 2;
    case 'sphere'
        dim = 3;
    otherwise
        error('bma:pde:badGeometry', '不支持的 1D 几何 "%s"（可用 slab/cylinder/sphere）', geometry);
end
i = (1:n)';
% Face radii in units of dx.
rLeft = (i - 1);
rRight = i;
% Cell volume / dx^dim and face area / dx^(dim-1).
if dim == 1
    v = ones(n, 1);
    aL = ones(n, 1);
    aR = ones(n, 1);
elseif dim == 2
    v = (rRight.^2 - rLeft.^2) / 2;
    aL = rLeft ./ v;
    aR = rRight ./ v;
else
    v = (rRight.^3 - rLeft.^3) / 3;
    aL = rLeft.^2 ./ v;
    aR = rRight.^2 ./ v;
end
aL(1) = 0;  % center face has zero area for radial geometries
% Half-cell boundary coefficient: 2*A_face/V_cell*dx.
bL = 2 * (rLeft(1)^(dim - 1)) / v(1);
bR = 2 * (rRight(n)^(dim - 1)) / v(n);
ops = struct('geometry', geometry, 'n', n, 'dim', dim, ...
    'aL', aL(:).', 'aR', aR(:).', 'bL', bL, 'bR', bR, ...
    'cell_volume', v(:).', 'face_area_left', rLeft(:).'.^(dim - 1), ...
    'face_area_right', rRight(:).'.^(dim - 1));
end
