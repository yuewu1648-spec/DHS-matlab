---
name: model-fit-identifiability
description: MATLAB 参数估计、多起点策略、剖面似然、Sobol/局部敏感性、结构/实用可辨识性的操作规范与结果判读；在拟合参数或报告可辨识性时加载。
whenToUse: 文献缺少参数值需要估计、拟合报局部极小/病态、需要判断哪些参数被数据约束、或准备写"参数估计与可辨识性"小节时。
---

# 参数估计与可辨识性

## 数据准备

CSV 首列 `time`，其余列与 spec 的 output id 对应：

```
time,P_obs,S_obs
0,0,50
5,1.2,48.7
```

`output_map_json`：`{"P_obs":"P_obs","S_obs":"S_obs"}`。
一个观测列对应一个 spec output；缺失值用 `NaN`。

## 拟合（bma_model_fit）

`options_json`：

```json
{"params_to_fit": ["vmax","km"], "multistart": 8, "max_iter": 200,
 "weights": [1,0.5], "param_bounds": {"km": [0.01, 1000]}}
```

要点：
- 先固定"文献已报道且可信"的参数，只估缺失/不确定的；估计参数过多会迅速不可辨识。
- 多起点至少 8；`bounds` 用生理/物理范围，不要给 0 宽度。
- 数据量少（<10 点/输出）时不要奢望恢复全部基元参数；报告派生量（Km、Vmax、R0、周期）更诚实。
- 拟合指标：R²>0.95 且 NRMSE<0.2 通常可接受；但指标好不代表参数可辨识。

**结果判读**：
- CI 跨数量级、SE 远大于参数值 → 该参数实际不可辨识。
- 多起点收敛到不同值且代价相近 → 多解/弱可辨识，必须在报告中说明。
- 残差有结构（滞后自相关）→ 模型缺机制项，不要继续加参数硬拟合。

## 可辨识性（bma_model_identifiability）

- **结构可辨识性**：由模型结构+观测决定；若输出对某参数组合不敏感，任何数据都救不了。
- **实用可辨识性**：需给 `data_csv`+`output_map_json`。看 Fisher 信息矩阵条件数、参数相关矩阵、剖面似然 CI。
- 剖面似然：`options_json` 传 `{"param":"km"}` 可查看单参数曲线；CI 明显不对称/无界 → 不可辨识。
- 结论写法："kf 与 kcat 只能辨识其比值/组合（相关系数 0.98），因此我们报告 kcat/Km 而不是分别的 kf、kr、kcat"。

## 敏感性（bma_model_sensitivity）

- 局部弹性系数：参数 ±5% 引起输出变化的相对比例，适合局部解释。
- Sobol 一阶/总效应：全局重要性排序，用于实验设计建议。
- 只对 `bounds` 合理的参数做；范围乱设会产生误导性 Sobol 指数。

## 报告必须包含

1. 哪些参数用文献值、哪些拟合、哪些 assumed；
2. 拟合指标与 CI；
3. 可辨识性结论与不可辨识组合；
4. 敏感性排序（1-2 句结论）；
5. 交叉验证/残差诊断结果（bma_model_validate_fit）；
6. 局限：数据量、实验条件、模型假设导致的偏差。


## 0.3.0：Sobol 成本预算（必读）

- `bma_model_sensitivity` 现在默认只做局部弹性；需要 Sobol 时显式 `method:"sobol"`。
- 默认 `sobol_n=64`，执行前用一次基准仿真估算 `N*(P+2)` 成本；超过 120 s 默认**跳过**并返回 `skipped/budget/suggestion`。不要用 `force` 掩盖刚性时间尺度问题；先在静态/降阶代理模型上估成本，或减少参数/缩短 time_end。
- 单样本/总墙钟有上限（`max_sample_seconds`/`max_seconds`）；收到 `partial=true` 或 `cancelled=true` 时结果不完整。


## 0.5.0：超时后的正确恢复

- `fit.estimate`/`identifiability`/`sensitivity` 超时返回 `BMA_TIMEOUT` 后，桥接不会自动重试，并会重启 MATLAB 服务。先 `matlab_status` 看 `busy/queue/last_timeout`；仍有问题用 `bma_cancel`（hard=true）。
- 恢复后不要原样重跑：把 `multistart` 从 8 降到 4、缩短 `time_end`、先固定部分参数，或先做剖面/局部敏感性再决定是否 Sobol。
- 同一调用连续超时两次，说明模型/时间窗/参数化不适合该分析；在报告中记录“未完成/降级”，不要反复消耗会话。
- `bma_gate_waive` 可用于记录 G8 的降级（如用局部弹性替代 Sobol），但必须写 reason 和 substitute，不能把未运行的分析写成已完成。
