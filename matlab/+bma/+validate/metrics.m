function s = metrics(y, yhat, k, n)
%METRICS 计算拟合优度与信息准则指标。
%   s = bma.validate.metrics(y, yhat, k, n)
%
% 输入：
%   y, yhat   观测值与预测值（向量或同尺寸矩阵，按元素配对；允许 NaN）
%   k         模型参数个数（用于 AIC/BIC/AICc，默认 0）
%   n         观测数（可选；缺省为有效配对个数）
% 输出 struct：
%   r2, rmse, nrmse, mae, sse, sst, loglik, aic, aicc, bic, n, k, dof
%
% 公式：
%   R²    = 1 - SSE/SST
%   RMSE  = sqrt(SSE/n)
%   NRMSE = RMSE / (max(y)-min(y))
%   logL  = -n/2 * (log(2*pi*sigma2) + 1)，sigma2 = SSE/n（高斯残差 MLE）
%   AIC   = -2logL + 2k
%   AICc  = AIC + 2k(k+1)/(n-k-1)
%   BIC   = -2logL + k*log(n)

if nargin < 3 || isempty(k)
    k = 0;
end
k = double(k);
y = double(y(:));
yhat = double(yhat(:));
if numel(y) ~= numel(yhat)
    error('bma:validate:metricsSize', ...
        '观测值(%d)与预测值(%d)元素个数不一致。', numel(y), numel(yhat));
end
valid = isfinite(y) & isfinite(yhat);
yv = y(valid);
yhv = yhat(valid);
nObs = numel(yv);
if nargin < 4 || isempty(n) || ~isfinite(n) || n <= 0
    n = nObs;
else
    n = double(n);
end

s = struct();
s.r2 = NaN;
s.rmse = NaN;
s.nrmse = NaN;
s.mae = NaN;
s.sse = NaN;
s.sst = NaN;
s.loglik = NaN;
s.aic = NaN;
s.aicc = NaN;
s.bic = NaN;
s.n = nObs;
s.k = k;
s.dof = nObs - k;
s.n_used_for_ic = n;
if nObs == 0
    return
end
resid = yv - yhv;
sse = sum(resid .^ 2);
sst = sum((yv - mean(yv)) .^ 2);
s.sse = sse;
s.sst = sst;
s.mae = mean(abs(resid));
s.rmse = sqrt(sse / nObs);
rng = max(yv) - min(yv);
if rng > 0
    s.nrmse = s.rmse / rng;
end
if sst > 0
    s.r2 = 1 - sse / sst;
else
    s.r2 = NaN;
end
if sse > 0
    sigma2 = sse / nObs;
    s.loglik = -0.5 * nObs * (log(2 * pi * sigma2) + 1);
else
    s.loglik = Inf;
end
s.aic = -2 * s.loglik + 2 * k;
if n - k - 1 > 0
    s.aicc = s.aic + 2 * k * (k + 1) / (n - k - 1);
else
    s.aicc = Inf;
end
s.bic = -2 * s.loglik + k * log(max(n, 2));
end
