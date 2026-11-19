---
name: matlab-modeling-troubleshooting
description: bma_* 工具与 MATLAB 建模的常见错误码、单位/量纲、求解器刚性、负浓度、拟合失败、超时与可辨识性问题的排查手册；在工具报错或结果异常时加载。
whenToUse: bma_* 返回 BMA_* 错误、仿真/拟合失败或结果不合理、RPC 超时、或需要判断"模型错了还是数据错了"时。
---

# 故障排查手册

## 错误码

| 错误码 | 含义 | 处理 |
|---|---|---|
| `BMA_SPEC_INVALID` | 规格字段/引用不合法 | 看 errors[].path 与 hint，逐项修 |
| `BMA_UNIT_UNKNOWN` | 单位不在单位词表 | 用 kb/units.json 支持的写法：nM/uM/mM/M、s/min/h/day、1/s、1/(uM*s)、uM/min、person、cell、1、um^2/s、mV、uA/cm^2、mS/cm^2 等 |
| `BMA_RATE_INVALID` | 速率定律参数/物种/表达式非法 | 检查 kind、参数 id 是否存在、expression 只用白名单函数与已定义 id |
| `BMA_UNKNOWN_ID` | stoichiometry/species/output 引用未定义 id | 先定义 variables/parameters，再在 reactions 引用 |
| `BMA_NOT_IMPLEMENTED` | 该 MATLAB 模块/方法未安装 | 联系维护者；先用已有方法完成当前步骤 |
| `BMA_TIMEOUT` | MATLAB 单次调用超时 | **不要自动重试**：桥接会重启服务并返回；先 `matlab_status` 看 `busy/last_timeout`，再用 `bma_cancel`（hard=true）确认恢复；缩小 multistart/time_end/参数集后重试 |
| `BMA_SERVER_UNHEALTHY` | 服务刚超时/重启，暂不接受新调用 | 等几秒并 `matlab_status`；必要时 `bma_cancel`；不要并发重试 |
| `BMA_CANCELLED` | 调用被 `bma_cancel`/重启中止 | 正常现象；确认服务健康后缩小任务重跑 |
| `BMA_SERVER_ABSENT` | MATLAB 服务未运行 | 先调 matlab_status；仍失败报告用户 |
| `BMA_SERVER_EXITED` | MATLAB 进程异常退出 | 重试一次；连续失败报告用户并保留日志路径 |

## 单位/量纲

- 质量作用：二级反应 k 的单位必须是 `1/(浓度*时间)`，一级是 `1/时间`。
- Hill/米氏：`vmax` 与反应通量同单位（浓度/时间 或 质量/时间），`k`/`km` 为浓度，`n` 无量纲。
- 表达式中除法最常见错误：`beta*S*I/N` 要求 beta 是 1/时间、N 是同一浓度/计数单位。
- 输出量单位必须与数据列单位一致，否则拟合数值正确但解释错误。

## 仿真

- `ode15s` 适合刚性（酶结合、膜电位、快速可逆反应）；`ode45` 适合非刚性平滑系统。
- 负浓度警告：检查速率符号/stoichiometry；允许极小负值时可报告中说明，但不要静默忽略。
- 求解失败：缩短 `time_end`、增大 `rtol/atol`、换 solver、检查初值是否在物理范围（无 NaN/Inf）。
- 振荡模型看不到振荡：核验 Hill 指数/时滞/降解项是否足够（如 Goodwin 单负反馈需 Hill 指数足够大）；再看时间窗是否包含瞬态。

## 拟合

- 报局部极小：增加 multistart、给更好初值（文献值）、缩窄 bounds、先固定部分参数。
- 参数跑到边界：检查 bounds 是否合理；边界解通常意味着不可辨识或模型缺项。
- CI 巨大/NaN：数据不足或参数冗余；报告不可辨识而不是隐藏。
- 拟合完美但残差有结构：模型缺机制；比较竞争模型（bma_model_selection）而不是加参数。

## 文献解析

- 扫描版 PDF 无文本层：`warnings` 会提示；此时请用户提供文本版或手动录入关键数据，不要编造。
- 数字抽取是候选：必须回原文 quote 核对单位/条件（温度、pH、物种）。
- 表格识别失败：用 read 看 text.txt 表格区域，手动整理成 CSV。

## 交付前自检

- [ ] spec validate=true
- [ ] 模型能复现文献定性行为
- [ ] 参数都有 evidence 或 assumed 标签
- [ ] 拟合有指标 + CI + 可辨识性结论
- [ ] 报告含假设、局限、复现路径
- [ ] 没有未运行却被声称完成的步骤


## 0.3.0：陈旧 RPC / 服务卡住

- 若上一次调用导致 MATLAB 被强杀，新会话首次调用可能遇到旧 `state.json/outbox`。server 启动会清理陈旧 IPC；桥接层用 PID 判活并在 15 s 内快速重启，不再等满 240 s。
- 仍卡住时：`bma_model_* ` 调用先 `matlab_status` 确认 agent version；必要时删除 `<work_dir>/.bma/server/state.json` 后重试（不要删除整个 `.bma` 运行目录）。
- 长任务可写 `<work_dir>/.bma/server/cancel.flag`（桥接 `cancel()`）让 Sobol 在样本间退出，返回部分结果。


## 0.5.0：超时/卡死/沙箱/数值自检

### 卡死与健康
- `matlab_status` 现在返回 `server: BUSY current_call…`、`queue`、`last_timeout`、`last_error`、`restarts`、`workspace_writable`。**BUSY 不等于死**：先看 `last_timeout`，再决定等或取消。
- 超时后桥接会杀进程并重启，且**不重试**；原调用以 `BMA_TIMEOUT` 返回。不要连续重试同一调用；先 `bma_cancel` + `matlab_status`，再把 `multistart`/时间窗/参数集缩小。
- `bma_model_analyze` 默认对高维/高非线性模型跳过 `solve/vpasolve`，返回 `symbolic_skipped=true`、`analysis_mode="numeric_fallback"`。这是防卡死设计；数值守恒零空间 + 多起点稳态 + 数值 Jacobian 可用。只有小模型才用 `options.symbolic="on"` 强制符号求解。
- 如果 G6 仍不可行，用 `bma_gate_waive` 记录 reason/substitute/evidence；报告会显示，不能静默跳过。

### 沙箱 ACL / pwsh
- `SetNamedSecurityInfoW failed (Win32 5)` 或 `[sandbox: file access denied under workspace-write mode]` 是 DSH 沙箱 ACL 问题，不是 MATLAB 模型错误。先按 `diagnose-windows-sandbox-acl` 技能诊断；需要 `danger-full-access` 时让用户审批。
- PowerShell 执行策略错误：用 `-ExecutionPolicy Bypass` 或 `.cmd` 包装；仍失败时改用 `read/write` + `bma_*` 工具，不要把整个任务卡在 `pwsh` 上。
- `.bma` 对 MATLAB 批处理不可写时：把外部产物写到 `external_artifact_dir`，再用 `bma_artifact_import` 导入；报告会自动收集 `artifacts/` 并内嵌图片。

### MATLAB PDE / 自建 FEM
- 写任何自建 FEM/PDE 前，`bma_kb_search("PDE decsg geometry mesh")` 读取 `matlab_pde_toolbox_pitfalls`；求解后 `bma_kb_search("convergence residual")` 读取 `numerical_convergence_checklist`。
- 最小自检：无源检验（f=0 时 u≈u_amb）、反应体积（V_isl>0 且接近解析值）、算子零空间、方向检验（R_max 翻倍监测点必须下降）、归一化残差、1-D/球解析对照、网格收敛。
- 任何一项失败，先修几何/边界/符号/装配，不要继续拟合或调参；拟合会把物理错误吸收进参数。
- `decsg` 的 `R-I1` 会把内嵌区域挖成洞；目标是“介质中包含胰岛”时用 `R+I1` 或保留独立 face，并用单元质心计数验证。

## 0.6.0：control + heavy worker 双进程（彻底修复单线程卡死）

- 后端现在有两个 MATLAB 进程：**control**（`.bma/server`，轻调用）与 **heavy worker**（`.bma/worker/server`，literature/analyze/simulate/fit/validation/report/codegen）。`matlab_status` 会同时预热并报告两者；`worker server: idle/BUSY` 是独立字段。
- worker 卡在不可中断 builtin 时，control 仍能 `matlab_status`/`bma_cancel`；`bma_cancel(hard=true)` **只杀 worker**（下一次重调用惰性启动），control 不受影响。不要再手动重启整个 MATLAB 或删 `.bma`。
- 超时语义不变：`BMA_TIMEOUT` 不自动重试，worker 被杀后调用返回；下一次重调用会自动启动新 worker。先看 `matlab_status` 的 worker 字段，再缩小任务。重复超时说明该重任务不适合在当前时间窗/参数化下运行，记录降级。
- 首次 `matlab_status` 会并行启动两个 MATLAB（约 20–120 s）；之后两类调用都很快。若 worker 启动失败，control 仍可用，先读 `worker start_error`，必要时 `bma_cancel`。
- 两个进程使用各自的 `.tmp` pref/temp/home（worker 在 `.tmp/worker-server/`），不要手工共享 prefdir。
- 调试：control `<work_dir>/.bma/server/state.json`，worker `<work_dir>/.bma/worker/server/state.json`；日志在各自的 `matlab-stdout.log`/`server.log`。

## 0.8.2：A2/A3 求解器前置门（写循环之前）

> 来源：`E:\matlab建模\胰岛\NUMERICAL_PITFALLS.md` 的 A2（雅可比方向导数）与 A3（方程残差验收）。只放实现层检查，不含模型/复现结论。

- **触发条件**：任何自写 Newton/Picard/定点/`fsolve`/`fmincon` 包装、时间步/参数延拓循环、自建 FEM/PDE 装配。**先跑预检，再写循环**；预检失败时禁止写循环、禁止扫描/拟合。
- **A2 雅可比方向导数**：J 与 R 必须同源（同一套单元/权重/符号）。模板：

```matlab
eps = 1e-8 * max(1, norm(u));
rng(0); du = randn(numel(u), 1);
r1 = R(u + eps*du);
err = norm(r1 - R(u) - eps*J*du) / max(norm(r1), realmin);
% 目标 err < 1e-8；>1e-5 判失败；1e-8~1e-5 换解析 J/中心差分/复数步复测
```

- **A3 方程残差验收**：用 `r_rel = norm(R(u)) / max(norm(F), norm(K)*norm(u_ref), realmin)`（或量纲等价尺度）；不要用 `norm(u_new-u)`，也不要用 `|r|/c_amb`。正性钳位/阈值截断后必须重算 `R(u_clamped)`。默认 `r_rel <= 1e-6` 才接受；残差不降/卡住就停止，不得继续拟合或调参。
- **写证据**：`artifacts/solver_preflight.json` 至少含 `jacobian_rel_error`、`residual_rel`、`eps`、`du_seed`、`J_source`（analytic/fd）、`u_test`、`passed`、`equation`。报告引用实际数值，不写“已收敛”。
- **循环内**：每个接受步报告 `r_rel` 与步长；不能只报 `exitflag`/`||Δu||`。若残差卡在 1e-2 或方向导数误差 >1e-5，先修装配/边界/符号/权重，不要换 solver 掩盖。
- **PDE Toolbox 内置 `solvepde`**：没有自定义 J，A2 用制造解/无源解析对照，A3 用残差或制造解误差；一旦自写装配或循环，A2+A3 都必须做。
