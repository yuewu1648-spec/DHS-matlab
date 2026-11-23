# 灵活性上限：现状、已落地扩展与后续路线

> 起因：对照 MathWorks 官方 MATLAB MCP Server（可执行任意 MATLAB 代码）时，本后端的短板被总结为
> “速率定律只有 5 种白名单、PDE 边界只支持 Dirichlet/零 Neumann、原生 PDE 不能拟合”。
> 本文记录这些限制的**真实成因**、本次已落地的扩展、以及剩余项的实现路线与代价。
> 版本：0.13.0（0.12.0 + flex-1，2026-11-22）。

## 1. 成因：不是"没做"，是"为了可审计而受限"

`bma.modelSpec.v1` 是**声明式规格**：一条速率定律编译成代码字符串（`rateParse` → `r.code` →
`str2func('@(y,p) ...')`），因此后端能自动得到

- 通量表达式的符号形式（报告里的方程、模型卡）；
- 参数 → 通量的依赖关系（`params_used`，拟合与可辨识性要用）；
- 量纲（`checkUnitsCore` 逐项推导）。

一旦允许"随便写代码"，这三件事同时失去。所以正确的方向不是"把 spec 变成脚本"，而是**分层**：

| 层 | 表达力 | 可审计性 | 现状 |
|---|---|---|---|
| L0 内建速率定律 | 低（5 种） | 全自动（量纲/符号/参数依赖） | 已有 |
| L1 声明式外部函数 `kind:"matlab"` | 中高（任意函数体） | 单位需**声明**，参数依赖仍可追踪 | **本次实现** |
| L2 表达式内引用注册函数 | 中 | 单位可推导（若函数声明返回量纲） | 未实现，见 §4 |
| L3 原生 PDE 参数估计 | — | 需预算与降级策略 | 未实现，见 §4 |
| L4 原始代码逃生舱 `bma_eval` | 无上限 | **无**（只能标注 unvalidated） | 未实现，见 §4 |

## 2. 本次实现（flex-1）

### 2.1 `kind:"matlab"`：自定义 MATLAB 函数速率

```json
{
  "id": "inhibited_uptake",
  "stoichiometry": {"S": -1, "P": 1},
  "rate": {
    "kind": "matlab",
    "function": "my_uptake_rate",
    "file": "ext/my_uptake_rate.m",
    "arguments": ["S", "I", "vmax", "km", "ki"],
    "unit": "uM/s",
    "display": "vmax*S/(km*(1+I/ki)+S)"
  }
}
```

函数签名按 `arguments` 顺序：

```matlab
function v = my_uptake_rate(S, I, vmax, km, ki)
v = vmax .* S ./ (km .* (1 + I ./ ki) + S);
end
```

语义与校验规则：

- `function` 是**函数名**（不带 `.m`）；`file` 可选，给相对路径时按当前工作目录 / 规格目录解析，并把所在目录 `addpath`。
- 编译结果与内建速率完全同构：`m.vfuns{k}`、`m.rhs`、拟合/可辨识性/敏感性全部照常工作（实测见 §2.3）。
- `unit` **必填**：函数体量纲无法静态推导，只能声明。声明值随后仍会与化学计量要求的“物种量纲/时间”比较（不一致照样报 `BMA_UNIT_MISMATCH`）。
- 校验时额外产生一条 `BMA_RATE_DECLARED_UNIT` 警告，报告中必须写明该单位是 **declared（声明）** 而非推导。
- `m.rate_functions` 记录 `{reaction, function, file, unit}`，供模型卡与代码生成提示“该 .m 必须保持在路径上”。

涉及文件：`+bma/+spec/private/rateParse.m`（新 case）、`+bma/+spec/normalize.m`（字段白名单补 5 个字段——
否则 `function/unit` 会在归一化时被静默丢弃，这是本次第一个坑）、`+bma/+spec/compile.m`（收集 `rate_functions`）、
`+bma/+spec/private/checkUnitsCore.m`（声明单位 + 警告）、`+bma/+report/build.m`（方程渲染）。

已知边界：**PDE(MOL) 路径不支持** `kind:"matlab"`。1D PDE 的展开器要解析解析式来组装刚度矩阵，
任意函数无法向量化到节点。需要自定义 PDE 源项时用原生路径的 `f` 系数（该系数本是函数句柄，天然支持）。

### 2.2 非零 Neumann / Robin 边界（原生 PDE 路径）

PDE Toolbox 的 Neumann 边界本就是 `n·(c∇u) + q·u = g`，所以非零通量与 Robin 几乎零成本：

```json
"pde": {"bc": [
  {"edge": "all", "type": "neumann", "flux": 0.5},
  {"edge": 1, "type": "robin", "q": 1, "g": 0}
]}
```

- `flux` / `q` / `g` 支持：有限标量、参数 id、或按物种给出长度 N 的向量/结构体。
- 校验放宽（`+bma/+pde/validate.m`），求解时走 `applyBoundaryCondition(..., 'q', qvec, 'g', gvec)`（`+bma/+pde/simulate.m`）。
- 1D MOL 展开器（`+bma/+spec/+pde/expand.m`）仍只支持零通量：它用镜像节点消去 ghost point，
  非零通量需要额外 ghost 方程。想用非零通量请把该模型写成 `dim>=2` 的原生 PDE。

### 2.3 验证

`matlab/tests/test_flex_extensions.m`（新增）：

1. `v = k*S` 的自定义速率，`m.vfuns{1}([2;0],0.3) = 0.6`，5 s 仿真与解析解 `2·exp(-0.3·5)` 相对误差 < 1e-6；
2. 缺 `unit` → `BMA_SPEC_MISSING_FIELD`；函数不在路径 → `BMA_RATE_INVALID`；
3. 声明单位 → `BMA_RATE_DECLARED_UNIT` 警告确实出现（不允许静默当成“已推导”）；
4. 2D 矩形域：`neumann flux=0.5` 与 `robin q=1` 通过校验；实际求解后中心 probe 由 0 升到 0.01604（质量确实注入）；
5. `type` 非法 → 判无效。

## 3. 还没有解决的：原生 PDE 不能拟合

这是三项里成本最高的一项，原因不是 PDE Toolbox，而是**目标函数形态**：

- `bma_model_fit` 依赖 `@(y,p)` 形式的状态向量 RHS 与（可选）解析/有限差分灵敏度；
- 原生 `solvepde` 每次调用都是"建几何→网格→装配→求解"，单次几秒；
- 一次 3 参数 × 8 起点 × 50 次迭代 ≈ 1200 次求解 ≈ 数十分钟，且每次求解器噪声会污染有限差分梯度。

可行路线（按推荐顺序）：

1. **MOL 代理拟合 + 原生复核**（推荐）：若几何可张量化（矩形/圆柱/球），自动生成 1D 或低维 MOL 模型做拟合，
   再把最优参数代回原生 `solvepde` 做一次前向复核，报告"拟合用代理、验证用原生"。
2. **降维观测模型**：只拟合 probe/field_stats 的集总量（如中心浓度、总量），不追求场分布。
3. **直接无导数优化**：`patternsearch`/`fminsearch` 包 `solvepde`，限 1–3 个参数、`max_dof` 很小，
   每次报告 `elapsed_s`；仅作为"能跑但慢"的兜底，并强制在报告里标注成本。

短期最诚实的做法：在 `bma_pde_simulate` 返回里明确 `"fittable": false` + 上述替代路径提示，而不是让人误以为可以拟合。

## 4. 后续路线（按性价比排序）

| 优先级 | 项 | 改动点 | 代价 | 收益 |
|---|---|---|---|---|
| P1 | `bma_eval` 逃生舱 | `bridge/lib/tools.js` + 新 RPC 方法 | 中（策略/沙箱/产物回收） | 彻底对齐官方“任意代码”，但必须标 `provenance: raw_code`，禁止进入 validated 结论 |
| P1 | 原生 PDE 拟合的 MOL 代理 | 新 `+bma/+pde/+fit/`，写 `fittable` 标志 | 高 | 把“不能拟合”变成“有条件能拟合” |
| P2 | 表达式内注册函数 `f(S;unit)` | `parseExpression` + 函数注册表 | 中 | 比 `kind:"matlab"` 更细的粒度；可保留量纲推导 |
| P2 | 1D MOL 非零通量 | `expand.m` ghost-point 方程 | 中 | 一维反应-扩散的标准需求（如表面通量边界） |
| P3 | 速率定律插件注册表 | `rateParse` 改为 `containers.Map` 查找 | 低 | 第三方速率定律不必改核心代码 |

## 5. 不变的原则

扩展表达力的同时，以下四条不能松：

1. **参数必须可追踪**：任何进入拟合的参数都要能从 spec 里找到 id；自定义函数只能通过 `arguments` 列出的 id 影响通量。
2. **单位必须有来源**：要么推导（L0/L2），要么声明（L1），二者在报告里显示方式不同。
3. **降级要留痕**：做不到的部分用 `bma_gate_waive` 或 `warnings` 显式记录，不能静默跳过。
4. **自由度的代价要说清**：L1/L4 让模型更强，但也让“自动量纲检查/自动方程渲染”部分失效——报告必须写明哪一层被使用。
