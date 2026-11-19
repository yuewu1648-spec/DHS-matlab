function [code, info] = expressionCode(expr, refs)
%EXPRESSIONCODE Public wrapper around the restricted expression compiler.
%   [code, info] = bma.spec.expressionCode(expr, refs)
%
% Used by the native PDE Toolbox path to turn a bma rate expression into
% MATLAB code with refs such as u(1,:), u(2,:). The underlying parser is the
% same whitelist parser used by ODE compile/validate.
[code, info] = parseExpression(expr, refs);
end
