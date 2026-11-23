---
name: bio-modeling-workflow
description: 从生物文献证据到 bma.modelSpec.v1 模型、MATLAB 仿真/拟合/验证/报告的完整建模工作流与规格编写规范；在开始任何建模任务或需要写/改模型规格 JSON 时加载。
whenToUse: 开始一个新的文献建模任务、需要撰写或修改 bma.modelSpec.v1、或不确定下一步该调用哪个 bma_* 工具时。
---

# 生物系统建模工作流

> **BLIND-LIT 模式**：若用户要求只用主文献摘要 + 全部参考文献建模、且建模期间不得查看主文献全文/图/表，**不要**按本文 G1/G2.5 执行。加载 `blind-literature-modeling`，按 B0–B8 与 `bma_blind_*` 工具推进；本文的 spec、仿真、拟合、验证、证据规范仍然适用（只是证据只能来自摘要与参考文献）。

## 产物布局

所有产物在 `<work_dir>/.bma/runs/<run_id>/`：

```
literature/<doc_id>/text.txt|sections.json|numbers.json|tables.json
models/<name>/spec.json|analysis.json|code/<name>_ode.m
data/*.csv
fits/<fit_id>/fit.json|params.csv|predictions.csv|figures/*.png
figures/*.png
report/report.html|report.md|model_card.json
```

一次任务固定用一个 `run_dir`，后续工具都传它。

## 步骤与质量门

0. **任务列表**：开始前用 `todo_write` 建立覆盖 G0–G9 的完整列表（一个 `in_progress`，其余 `pending`）。每完成一步立即重发**整表**更新状态；失败/跳过的项改成 `completed` 并注明“（未执行：原因）”或删除。最终回答前再发一次，确认返回 `0 pending, 0 in progress`；否则不要结束。
1. **环境**：`matlab_status`；同时看 `server`（busy/queue/last_timeout）与 `workspace_writable`。若 `pwsh` 因 ACL/执行策略不可用，改用 `read/write` 与 `bma_*` 工具，不要反复重试。
2. **文献解析**：`bma_literature_ingest`（pdf/docx/txt/md/html）。读 `text.txt` 与 `sections.json`，建立证据表：

   | claim_id | section_id | quote（逐字） | 类型 |
   |---|---|---|---|
   | C1 | results | "kcat = 4.8 s−1" | 参数 |
   | C2 | results | "the repressor binds the promoter cooperatively" | 机制 |

   `numbers.json` 里的数字只是候选，必须回原文核对上下文。同时读 `figures/figures.json`（或 ingest 返回的 figures），登记每张图/panel 的 caption、page、图片路径、x/y 轴/单位与实验条件；矢量图未栅格化时标“原图不可得”。
2.5 **文献图目标**：从图清单挑出与模型可观测量对应的必复现 panel（时间过程/剂量响应/空间剖面/相图），写清图号、条件、模型输出、判据（digitized 点的 RMSE/相对误差/R²，或定性方向/排序/峰值时间）。示意图/方法图可标“不复现”并说明。
3. **知识匹配**：`bma_kb_search`（中英文均可）→ `bma_kb_get`。把 archetype 的 spec_template 当作结构起点，但参数值必须替换成文献值/assumed，并补 evidence。
4. **机制假设**：≥2 个候选（如"直接抑制"vs"间接抑制"），写出可证伪预测；选最简单者先建模。
5. **写规格**：`<run_dir>/models/<name>/spec.json`，字段见下。
6. **校验**：`bma_model_validate` 直到 `valid=true`；`spec_path` 用上一步的路径。
6.5 **求解器前置门（A2/A3）**：在写任何自写 Newton/Picard/时间步/参数延拓/自建 FEM 循环之前，先跑两个一次性校验：A2 用 `eps=1e-8*max(1,norm(u))`、`du=randn` 检查 `||R(u+eps*du)-R(u)-eps*J*du||/||R(u+eps*du)|| < 1e-8`（>1e-5 判失败；1e-8~1e-5 换解析 J/中心差分复测）；A3 用 `||R(u)||/scale`（`||F||` 或 `||K||*||u_ref||`）验收，钳位后重算残差，`<=1e-6` 才接受。两项写入 `artifacts/solver_preflight.json`。预检失败时不要写循环、不要扫描/拟合，先修装配/边界/符号/权重。
7. **结构分析**：`bma_model_analyze`（仅 ODE/MOL：守恒律、稳态/稳定性、量纲）。默认会对高维/高非线性模型跳过符号稳态，返回 `symbolic_skipped=true`、`analysis_mode="numeric_fallback"`；这是正常降级，用数值守恒零空间 + 多起点数值稳态 + 数值 Jacobian。若仍不可行，用 `bma_gate_waive` 记录 G6 reason/substitute/evidence，不要卡死。2D/3D 原生 PDE 不做状态向量符号分析，改用 `bma_pde_simulate` 的 probes/field_stats 与稳态。
8. **仿真**：先判断空间维度。1D/需要 fit/identifiability → `bma_model_simulate`；真正的 2D/3D/非规则几何、需要场分布且 PDE Toolbox 已授权 → `bma_pde_simulate`（直接 `createpde`→`generateMesh`→`solvepde`，不转 ODE）。**DDE/BVP/DAE**：常量延迟 `kind:"dde"`（`dde23`），状态依赖延迟 `ddesd`（`delays[].expression`），中性型 `ddensd`（`dde_mode:"neutral"` + `delay_deriv`，`time.start` 大于最大延迟）；边值问题 `kind:"bvp"`（`bvp4c`，`domain`+`bc`）；全隐式 DAE `kind:"dae"`（`dae.residuals`+`decic/ode15i`），线性隐式 DAE 也可用 `options_json:{"mass_matrix":[[...]]}`（`ode15s` Mass）。DDE/BVP 可做仿真目标 fit/identifiability，但无解析灵敏度；DDE 可 codegen。**系统辨识/符号解/随机**用 `bma_advanced_solve`（`method=system_id|symbolic|sde|ssa`；`ssa` 是精确 Gillespie，`sde` 是 Euler-Maruyama）。给 `max_dof`/`max_seconds`；超预算先增大 `mesh.hmax` 或降维，不要盲目重跑。**仿真条件要对齐步骤 2.5 的文献图 panel**（时间窗/剂量/空间范围/单位），在 `<run_dir>/figures/reproduction/` 生成相同坐标/图例/轴范围的对照图；不能只用通用模拟图。**经典形式优先**：2D 振荡/极限环给相平面并画出后段闭合环（2 状态模型自动附带 phase，或 `options_json:{"plots":["phase"]}`）；剂量响应给响应曲线；双稳/开关给相图与稳态；酶动力学给 v-S/抑制曲线；时空 PDE 给场快照。对照文献的定性/定量行为；不符则回到步骤 4/5。
9. **参数**：文献值优先 → `bma_model_fit`（`data_csv` + `output_map_json`）；记录 CI。拟合只用于 ODE/MOL 状态向量；2D/3D 原生 PDE 不能直接拟合，需降维或明确不估计。
10. **可辨识性/敏感性**：`bma_model_identifiability`、`bma_model_sensitivity`；不可辨识组合写入局限。
11. **验证**：`bma_model_validate_fit`（交叉验证+残差）；竞争结构用 `bma_model_selection`。
12. **交付**：`bma_report_build`、可选 `bma_codegen`（含 SimBiology 导出）、`present` 报告与图。报告必须有“文献图复现”矩阵（panel → 条件/输出 → 原图/复现图 → 判据/状态/局限）；原图与复现图用 `extra_sections_json` 的 Markdown 图片并排嵌入。若图/数据在 run_dir 外，先用 `bma_artifact_import` 导入 `artifacts/`；报告会内嵌图片并列出 warnings。质量门豁免会渲染到报告“质量门与豁免”一节。
13. **收尾任务列表**：在给出最终答复前，最后一次 `todo_write` 把所有项设为 `completed`（未执行/阻塞项注明原因或删除），确认工具返回 `0 pending, 0 in progress`；任务列表还显示未完成时不得结束。

## spec.json 最小正确骨架

```json
{
  "schema_version": "bma.modelSpec.v1",
  "name": "enzyme_mm_inhibited",
  "title": "竞争性抑制的米氏动力学",
  "kind": "ode",
  "time": {"unit": "s", "start": 0, "end": 600, "n": 1201},
  "variables": [
    {"id": "S", "name": "底物", "unit": "uM", "initial": {"value": 50}},
    {"id": "P", "name": "产物", "unit": "uM", "initial": {"value": 0}}
  ],
  "parameters": [
    {"id": "vmax", "name": "最大速率", "unit": "uM/s", "value": {"value": 0.24},
     "estimate": true, "bounds": [0.001, 10],
     "evidence": [{"type": "measured", "quote": "Vmax = 0.24 µM s−1", "section_id": "sec_results"}]},
    {"id": "km", "name": "米氏常数", "unit": "uM", "value": {"value": 12.5},
     "estimate": true, "bounds": [0.01, 1000],
     "evidence": [{"type": "measured", "quote": "Km = 12.5 µM", "section_id": "sec_results"}]}
  ],
  "reactions": [
    {"id": "catalysis", "name": "催化", "stoichiometry": {"S": -1, "P": 1},
     "rate": {"kind": "michaelis_menten",
              "parameters": {"vmax": "vmax", "km": "km"},
              "species": {"substrate": "S"}}}
  ],
  "outputs": [{"id": "P_obs", "name": "产物浓度", "unit": "uM", "expression": "P"}],
  "assumptions": ["充分混合", "准稳态假设（ES 不显式建模）"]
}
```

### 速率定律写法

- `mass_action`: `parameters:{k}`, `species:{S:1, E:1}` → `k*S*E`
- `michaelis_menten`: `parameters:{vmax,km}`, `species:{substrate}`, 可选 `inhibitor:{species,ki,type:"competitive"|"noncompetitive"}`
- `hill`: `mode:"activation"|"repression"`, `parameters:{vmax,k,n}`, `species:{regulator}`
- `constant`: `parameters:{k}`
- `expression`: `expression:"beta*S*I/N"`（只允许 + - * / ^ exp log sqrt min max 与已定义 id、括号、数字）
- `matlab`（flex-1，自定义函数）：`{function:"my_rate", file:"ext/my_rate.m", arguments:["S","k"], unit:"uM/s"}` → `my_rate(y(1),p(2))`。`unit` **必填**且是声明值（函数体量纲无法推导），校验会给 `BMA_RATE_DECLARED_UNIT` 警告，报告须写“declared”而非“推导”；`file` 会自动 addpath，函数必须留在路径上。PDE(MOL) 路径不支持。
- `stoichiometry` 用负号表示消耗；别在同一反应重复计通量。

### 常见坑

- 变量 id 与参数 id 不能重名，不能以数字开头；`initial` 缺省为 0 会告警。
- 单位不能省：`1/s`、`uM`、`1/(uM*s)`、`nM/min`、`person`、`day`、`1`。
- 参数值应为数值（不是字符串）；`estimate:false` 的固定参数也建议给 `bounds` 或说明依据。
- `outputs[].expression` 只能用变量 id 与白名单函数；观测量单位要与数据列一致。
- 数据 CSV 第一列必须是 `time`，列名与 `output_map_json` 的值一致。

## 证据表模板（写入报告）

| 参数 | 值 | 单位 | 证据类型 | 来源 | 备注 |
|---|---|---|---|---|---|
| Km | 12.5 | µM | measured | Results, "Km = 12.5 µM" | Fig.2 拟合 |
| kcat | 4.8 | 1/s | measured | Results | 25 °C |
| kdeg | 0.02 | 1/min | assumed | — | 未报道，按典型值取 |


## 0.3.0：代数变量 / signed / 单位

- 化学平衡、热力学耦合可把辅助量写成 `kind:"algebraic"` 变量，编译期展开；不要把它们写进 stoichiometry 或 mass_action species。
- 可正可负的状态（ΔG、化学势）加 `"signed": true`。
- 热力学/功率/压强用 `kJ/mol`、`W/kg`、`mmHg`；质量摩尔浓度用 `mmol/kg`（≠ mM），并在 assumptions 说明 kg≈L 的近似。


## 0.4.0：文献引用（推荐用法）

- ingest 后优先看 `sentence_count` 与 `numbers[].sentence_id`；证据引用写 `section_id/sentence_id`，不要只写页码。
- PDF 位图在 `figures/`（figures.json 有 width/height/page/caption）；纯矢量图 PDF 可能 0 图，报告里要如实说明“未能栅格化”，不要编造图内容。
- 跨行下标已合并（ks⏎2→ks2）；仍建议用 `context` 原文复核每个数值。


## 0.5.0：卡死恢复、质量门豁免与数值自检

- **超时不再自动重试**：`BMA_TIMEOUT` 会重启 MATLAB 服务并立即返回；先 `matlab_status` 看 `busy/last_timeout`，再决定是否缩小任务。卡死的调用用 `bma_cancel`（hard=true）恢复，不要另起服务。
- **analyze 降级**：高维/高非线性模型的符号稳态会被预判跳过；看 `a.symbolic.skipped/reason` 与 `a.analysis_mode`。数值守恒零空间 + 多起点稳态 + 数值 Jacobian 是合格替代。
- **质量门豁免**：确实不可行时调用 `bma_gate_waive(gate, reason, substitute, evidence)`；报告与 model card 会显示。禁止“没跑也不记录”。
- **外部产物**：沙箱让 MATLAB 批处理无法写 `.bma` 时，先写 `external_artifact_dir`（如 `E:\...\fem_out`），再用 `bma_artifact_import` 导入；报告会自动收集 `artifacts/` 图片。
- **数值自检**：写自建 FEM/PDE 或任何新数值实现前，检索 `matlab_pde_toolbox_pitfalls` 与 `numerical_convergence_checklist`，至少做无源检验、反应体积、方向检验、归一化残差、解析极限/网格收敛；失败时先修装配，不要继续拟合。
- **双栏 PDF**：`literature_ingest` 会返回 `section_confidence` 与 low-confidence 计数；引用 section/heading 前回 `text.txt` 核对，句级 `sentence_id` 仍可用。

## 0.8.0：原生 PDE Toolbox（何时用、怎么用）

- **不要一律 MOL**：1D slab/cylinder/sphere、需要 fit/identifiability/analyze 时用 `bma_model_simulate`（MOL）；真正的 2D/3D/规则外几何、需要场分布/探针且预算允许时用 `bma_pde_simulate`，它直接建 PDE Toolbox 模型，不展开成 ODE。
- **校验**：`bma_model_validate` 对 `pde.dim>=2` 走原生校验；2D 支持 `rectangle`/`circle`/`polygon`，3D 支持 `box` 或 `stl`（`domain.file`）。`pde.solver="toolbox"`。
- **预算**：先给 `options_json:{"max_dof":50000,"max_seconds":300}`；返回 `stats.nodes/elements/elapsed_s`。超预算先增大 `mesh.hmax` 或降维；不要盲目重跑。
- **输出**：用 `pde.probes` 给观测点，`field_stats` 给 max/min/mean/integral；CSV/PNG 自动写入 run_dir。
- **边界**：2D 用 `edge`（1..NumEdges 或 "all"），3D 用 `face`；支持 `dirichlet{value}`、`neumann{flux}`（含**非零**通量）、`robin{q,g}`；flux/q/g 可为有限标量、参数 id 或按物种的长度 N 向量。1D MOL 展开仍只支持零通量（ghost-point 只消去了零通量情形）。
- **不要伪装**：原生 PDE 结果不能直接喂 `bma_model_fit`/`bma_model_identifiability`；需要参数估计时降维成 1D MOL 或明确写"未做参数估计"。

```json
{"kind":"pde","pde":{"dim":2,"solver":"toolbox",
  "domain":{"geometry":"rectangle","size":[1,1],"mesh":{"hmax":0.1}},
  "diffusion":[{"species":"C","coeff":"De"}],
  "bc":[{"edge":"all","type":"dirichlet","value":"Co"}],
  "probes":[{"id":"C_center","species":"C","x":0.5,"y":0.5}]}}
```

## 0.6.0：control + heavy worker

- 后端 split 成 control（轻调用：validate/spec/kb/run/status）与 heavy worker（literature/analyze/simulate/fit/identifiability/validation/report/codegen）。worker 卡死不会冻结 control；`matlab_status` 同时报告两者。
- 首次 status 会并行启动两个 MATLAB；之后重任务走 worker。超时/取消只杀 worker，下一次重调用惰性启动；control 仍可 status/cancel；不要把“worker busy”误判为整个后端死掉。
- 调用重任务前先确认 `worker server: idle`（status 输出）；如果 worker 正在跑，不要并发再发一个重任务，等它完成或 `bma_cancel`。
