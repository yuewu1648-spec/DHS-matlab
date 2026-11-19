# ISSUE：BioModel-MATLAB agent（bma_* 工具链）升级清单

> 来源会话：`session-10cc77dd`（工作目录 `E:\matlab建模\能量`，MATLAB R2024a，agent 0.2.0 / bundle 0.2.0）
> 任务类型：复现一篇 2003 年的肌肉能量代谢 **ODE 仿真**论文 + 应用 2026 年更正，并做参数估计/敏感性/可辨识性
> 模型特征（后续所有问题都与之相关）：6 状态（其中 1 个为 τ=1 ms 的代数弛豫）、8 反应、33 参数、22 输出；**刚性时间尺度 1 ms → 900 s**；单次仿真窗口 2–2000 s
> 结果：模型已交付（规格/仿真/拟合/报告），但过程中遇到 **2 次整机级卡死**、**3 次工具级崩溃/静默丢数据**、**若干表达力不足**

## 0. 问题总览

| ID | 严重度 | 标题 | 组件 |
|---|---|---|---|
| ISS-01 | **P0 阻塞** | 全局 Sobol 在本类模型上可跑数小时，无预算/超时/取消，直接卡死 agent | `bma_model_sensitivity` / `bma.fit.sensitivity` |
| ISS-02 | **P0 阻塞** | 强杀后的陈旧 `outbox/state.json` 让下一次 `matlab_status` 等满 240 s；桥接层不重试 | `bma.server.start` / RPC 桥 |
| ISS-03 | P1 表达力 | 速率表达式**括号嵌套上限 32**，化学平衡类模型无法内联代数解；缺“代数辅助量”机制 | `spec.validate` / `parseExpression` |
| ISS-04 | P1 数据丢失 | `extra_sections_json` 的**正文被静默丢弃**，只写入标题，无任何报错 | `bma_report_build` |
| ISS-05 | P1 崩溃 | 参数有 **≥2 条 evidence** 时模型卡/报告构建崩溃 | `cardParameters` |
| ISS-06 | P1 可用性 | 输出量既不进 CSV 也不进仿真摘要（只给状态），`include_series` 无法从工具触达 | `bma_model_simulate` / dispatch |
| ISS-07 | P1 静默降级 | 速率里出现 `min/max` 就**静默跳过**符号稳态求解，无提示、无法标记“护栏” | `bma_model_analyze` |
| ISS-08 | P2 单位 | 单位表缺 J/kJ/mmHg/W，且 `mmol/kg ≠ mM`，热力学量只能塞 `unit:"1"` | `kb/units.json` |
| ISS-09 | P2 告警噪声 | 合法可为负的变量（ΔG）触发“负浓度”告警 | `bma.model.simulate` |
| ISS-10 | P2 图表 | 时间序列图固定文件名（每次覆盖）、只画前 6 个输出；`bma.plot.cases` **不存在**但 `simulate_cases` 承诺对比图 | `+bma/+plot` |
| ISS-11 | P2 路径 | 结果里的 `run_dir`/CSV 路径与请求的 `run_dir` 不一致（指向另一个 run）；请求的剖面似然静默不产出 | `identifiability` / `fit` |
| ISS-12 | P2 文献 | 文献解析不抽图（本次必须自己写 PDF 位图提取器才能数字化曲线）；section 切分到“栏片段”级，引用语义很弱 | `bma_literature_ingest` |
| ISS-13 | P3 噪声 | `estimate:false` 时 `bounds` 一律告警“不会被使用”，但 Sobol 正需要它抽样 | `spec.validate` |
| ISS-14 | P3 反馈 | `multistart` 提前收敛只报一句；参数表正文被截断，CI 要人去读 `fit.json` | `bma_model_fit` |

---

## ISS-01（P0）全局 Sobol 可跑数小时 → 卡死 agent

**复现步骤**

```matlab
bma_model_sensitivity(spec_path="<6 状态动力学模型 spec>", run_dir="<run>", ...)
% 未显式给 method → 默认 'both' → 走 sobolIndices
```

**现象**

- 该调用**永不返回**。DSH 侧等满 240 s 超时；此后单线程 MATLAB 被该任务占住，`matlab_status`、`bma_kb_search` 等一切调用全部排队 → 整机会话“卡死”，只能强杀 DSH。
- `.bma/server/matlab-stdout.log` 里成片重复同一调用栈的积分失败告警（`ode15s` 在 `t≈0.78` 处无法满足容差 → 自适应步长缩到机器精度），调用栈为：
  `bma.fit.sensitivity > sobolIndices (第 361 行) > evalMetrics (第 427 行) > simMatrix (第 141 行) > simulatePredictions (第 88 行) > localIntegrate (第 253 行) > ode15s (第 690 行)`
- 成本估算（读源码得到，`bma/+fit/sensitivity.m`）：Saltelli 成本 = `N*(P+2)` 次仿真，`N` 默认 **128**。22 参数 → **3072 次**，每个样本要积分 600 s 的刚性 ODE；而失败样本会触发反复缩步，单样本从 80 ms 恶化到分钟级 → 总时长无上界。
- 对照：同一分析搬到“静态代数变体”（无 PCr 动力学、τ=0.2 s、2 s 窗口）后 **约 40 s 跑完**（21 参数 × 128 基础样本）。所以问题不是“Sobol 本身慢”，而是**成本与模型刚度/时间窗的耦合完全没有防护**。

**建议**

1. **预算前置**：按 `N*(P+2)*tCost` 估算，`tCost` 用一次基准仿真测得；超过阈值（例如 120 s）默认拒绝并返回“预计耗时 + 缩小建议 + 允许 `force`”。
2. **暴露 `sobol_n`**：工具层没有 `options_json` 入口，用户无法把 N 降到 32/64（源码支持 `opts.sobol_n`）。
3. **`method` 默认值**：`'both'` 对刚性模型是陷阱，建议默认 `'local'`，`sobol` 需显式请求。
4. **单次积分限时/限步**：失败样本应快速返回 NaN（给 `ode15s` 设 `MaxStep`/`Events` 或外层 `toc` 超时），不要让一个坏样本吃掉几分钟。
5. **可取消 + 心跳**：`state.json` 里有 `heartbeat`，但长任务期间没有“进度”（已完成样本数）；建议写入进度并支持 `server.cancel`，让 agent 能主动放弃而不是把会话拖死。
6. **文档/技能层**：在 `model-fit-identifiability` 技能里写死一条“sobol 前先用静态/降阶代理模型估算成本”。

---

## ISS-02（P0）强杀后的陈旧 RPC 状态导致下一次调用等满 240 s

**时间线（来自 `.bma/server/server.log` 与 `matlab-stdout.log`）**

```
（ISS-01 的 sobol 任务在跑，用户强杀 DSH）           → MATLAB 子进程一并被杀
17:21:57.753 | server start pid=47480 ...            → 新会话首次 matlab_status 拉起服务
17:35:50.515 | server start pid=46564 ...            → 又一次拉起（前一个已死）
17:35:55.240 | r-1794475917964-19e32d80 server.info ok=1 4701ms
17:35:55.288 | r-1794476150589-60828310 server.info ok=1 16ms
（此后无任何记录；工具调用仍等到 240 s 超时；进程随后消失）
```

**实际观察**

- 服务**起来了也答了**（`server.info` 4.7 s 返回），响应文件却**留在 `outbox/` 没被取走**（`outbox/r-1794475917964-19e32d80.json`，749 B）。
- 之后 `Get-Process` 查不到任何 MATLAB 进程，但 `state.json` 里仍写着 `pid:46564` 与一个更新的 `heartbeat`。
- 用一次毫秒级的 `bma_kb_search` 探活即可恢复（说明是**桥接层与文件队列的配对失败**，不是 MATLAB 坏了）。

**建议**

1. `bma.server.start` 启动时除清理 `claims/` 外，**同时清理 `outbox/`、`done/` 里的陈旧响应**（现在只清了 `claims`）。
2. 桥接层对每个请求按 `request-id` 精确取响应；取不到时**超时重试**（例如 5 s × 3），而不是一直等。
3. 若桥接层判定超时，应**主动结束对应 MATLAB 进程**，避免留下“心跳还在但进程已死”的僵尸 `state.json`。
4. `matlab_status` 这类“探活”调用建议内置 20 s 上限并降级返回（“服务未响应，建议重启”），不要让探活本身变成 240 s 的空等。
5. 客户端重试语义：`server.info` 是幂等的，重试安全；可作为默认恢复动作。

---

## ISS-03（P1）速率表达式嵌套上限 32，化学平衡类模型无法直接写

**复现**

把 CHEP（肌酸激酶+腺苷酸激酶）平衡的闭式解内联进 Eq.13 的速率表达式（[ADP] 是 [PCr]、pH 的代数函数，而 pH 又是 Pi、乳酸、PCO₂ 的函数），`bma_model_validate` 直接失败：

```
BMA_SPEC_INVALID: 模型规格编译失败：速率表达式编译失败：
错误: {、[ 和 ( 的嵌套深度不能超过 32。
```

**实测深度**（我按 `parseExpression` 的加括号规则写了一个预测器，与报错一致）：
PH 9 → HH([H⁺]) 13 → A(M2·[H⁺]) 15 → Q 21 → [ADP] 23 → ΔG 22 → φ 26 → `max(ADP·φ)` 28 → V̇O₂,ss **33** → 速率 36–37。

**为什么这在本类模型里是硬阻塞**：热力学/平衡态模型的速率律天然要“多级代入”（自由能 → 驱动因子 → 速率），任何忠实实现都会超过 32。

**我踩出来的三种绕法（建议写进技能/文档）**

1. **把共同子表达式变成“弛豫状态”**：`dX/dt = k·(X_alg − X)`，`k` 远大于最慢时间常数。本次把 pH 变成 τ=1 ms 状态，深度 33 → 28。
2. **按可加性拆分反应**：`d[PCr]/dt = Σ_i f_i` 可以拆成多条各自 `stoichiometry:{PCr:±1}` 的反应，深度对半砍；因为 ODE 对通量是线性的，拆分**严格等价**。
3. **把单位换算常数提成参数**（`1000` → `Hconv`），既降深度也让量纲检查通过。
4. （应急）另建一个去 `min/max` 的“分析变体”供符号稳态用（见 ISS-07）。

**建议**

- 提高编译器嵌套上限（或改成不依赖 `str2func` 的求值，例如生成扁平化的中间变量 `tmp1..tmpN`）。
- 更根本：在 spec 里支持 **auxiliary/algebraic 变量**（`kind:"algebraic"`，用 expression 定义，可被其他速率与输出引用），这样平衡态模型不用“假装成状态”。
- 至少在 `validate` 报错时给出“当前深度 36 / 上限 32，最深的子表达式是 …”和上面三种绕法的链接。

---

## ISS-04（P1）`extra_sections_json` 正文被静默丢弃

**复现**：`bma_report_build(..., extra_sections_json='[{title:"4. 复现 B：…", markdown:"<约 900 字 + 表格 + 图片>"}, …]')`（约 9 KB）。

**现象**：工具回报 `Report built.`（成功）。抽查 `report.md`：
- 我提交的 9 个新标题**都在**；
- 每节正文**全为空**（`## 4. 复现 B：…` 后接若干空行，直接跳到下一个标题）；
- HTML 里我给的图片路径出现 **0 次**（`report.html` 中 `spec_src` 计数为 0）。

无 error、无 warning、无日志。这类“成功但丢一半内容”比报错更危险——我一度以为报告已完整，是抽查 `report.md` 才发现。

**建议**：入口处做长度/编码校验，超限**报错**（而不是截断）；正文落盘为 `report/sections/<n>.md` 并在 HTML 中 include；或干脆让 `extra_sections_json` 接受**文件路径**，避免大字符串走 JSON 参数通道。

---

## ISS-05（P1）参数有 ≥2 条 evidence 时报告构建崩溃

**复现**：某个参数的 `evidence` 数组放 2 条（我一开始给 ΔG_ox 和 ks2 各放了“原文值 + 更正值”两条）。

```
BMA_MATLAB_SCALARSTRUCREQUIRED: 此赋值需要标量结构体。
{"stack":["cardParameters:1911","buildModelCard:1857","build:168","callModule:737",
          "buildReport:587","dispatch:250","processOne:169","start:144"]}
```

原因显然是 `jsondecode` 把 2 元素数组解成 struct array，而 `cardParameters` 按标量结构体赋值。

**影响**：与 workflow 的要求直接冲突——工作流要求“每个参数可溯源到 quote”，而**一个参数值被更正的场景天然需要多条证据**（原文值 + 更正值）。我为此被迫把第二条证据降级成 `note` 里的自由文本，损失了结构化溯源。

**建议**：`cardParameters` 用 `numel(ev)` 循环；报告里把多条证据渲染成子行（`值 A ← quote A`、`值 B ← quote B`）。同时给 `evidence` 增加 `supersedes`/`applies_to` 字段，便于表达“这条更正值取代那条原值”。

---

## ISS-06（P1）输出量既不进 CSV 也不进摘要

**现象**：仿真后 `data/sim-*/timeseries.csv` 的表头是 `time,<variables.id>`，**只有状态**；工具的返回文本只给 `final values`（状态）与 `range`（状态）。22 个输出（ADP、ΔG、VLa、糖酵解占比…）算出来了却拿不到数值——我为了读到输出的**一个**数值，只能去 `figures/timeseries.png` 里用 Pillow 裁图放大看纵轴（还差点被 MATLAB 的 `×10⁻³` 刻度标注误导）。

**源码确认**：`+bma/+model/simulate.m` 里其实有 `opts.include_series` → `res.outputSeries`（“默认关闭，避免 RPC 回传大数组”），`summarizeSimulation` 也把 `res.outputs` 塞进了结果；但**工具层没有 `options.include_series` 入口，返回文本也不渲染**。

**建议**

1. `timeseries.csv` **同时写输出列**（或提供 `options.export_csv="states|outputs|both"`）。
2. 返回摘要里加 `outputs_final`（哪怕只列前若干个）。
3. 暴露 `options.include_series` / 单独的 `bma_model_simulate_outputs`。
4. 这一条对“复现类”任务特别致命：复现判据几乎全在输出量上（V̇O₂%、乳酸、pH、ΔG），而不是状态量。

---

## ISS-07（P1）`min/max` 静默禁用符号稳态分析

**现象**：`bma_model_analyze` 只给一句

```
notes: 速率表达式包含 min/max 等非光滑函数，跳过符号稳态求解。
```

于是没有稳态、没有 Jacobian、没有特征值——而这恰恰是“机制是否自洽”的核心证据。为了拿到稳态+稳定性，我**另建了一个去掉 `min/max` 的平行规格**（`..._smooth.json`），并手工保证两边除护栏外完全一致。这是**双份维护 + 潜在不一致**。

而这些 `min`/`max` 只是**数值护栏**（`max(ADP·φ, 1e-9)`、`max([la⁻], 0.05)`、`min(1, …)`），在物理区间内根本不起作用。

**建议**

- spec 支持“软护栏”标记（例如 `rate.guards` 与 `rate.expression` 分离），符号分析时自动剥离；
- 或 `bma_model_analyze` 增加 `options.substitute_guards=true`，内部把 `max(x,c)`→`x`、`min(1,x)`→`x` 后用同一份 spec 做符号求解；
- 至少在 note 里给出“哪些反应含护栏、其生效区间”。现在这句 note 太弱，容易被误读成“模型不可分析”。

---

## ISS-08（P2）单位表缺口：热力学/压力/功率，以及 mmol/kg 与 mM 的互斥

本次需要的量：`kJ/mol`（ΔG、ΔG0、RT）、`mmHg`（PCO₂）、`W/kg`（机械功率）、`mmol/kg`（原文的磷酸盐浓度）。

- `kb/units.json` 里**没有** J/kJ、mmHg、W，只有 `mass/volume/time/length/count/current` 等基本量与若干派生量。
- 更要紧的是把 **volume 与 mass 当作独立维度**，于是 `mmol/kg`（肌肉代谢的惯用单位）与 `mM`(=mmol/L) **量纲不同**，任何“质量基浓度”的模型都会在 `checkUnitsCore` 里报不一致。

我的处理：全部改写成 `mM` 并在 assumptions 里声明“1 kg 湿肌 ≈ 1 L 内水空间”，热力学量一律 `unit:"1"` + 在 `name` 里写“(kJ/mol)”。**结果是 22 个输出里有 12 个、33 个参数里有 13 个的单位字段是 `"1"`**，量纲检查的意义被明显削弱。

**建议**

- 补 `J`/`kJ`、`J/mol`/`kJ/mol`、`W`、`W/kg`、`mmHg`（并允许 `°C` 若需要）。
- 提供“组织基浓度”单位（`mmol/kg`）并把质量/体积按**可声明**的换算（`1 kg ≈ 1 L`）处理，或新增 `dim:mass_concentration_mol` 一类，让 `mmol/kg` 与 `mM` 可互转并在报告中显式记录换算因子。
- 现在这个折衷实际上让“单位齐全且量纲自洽”这条硬规则**部分失效**。

---

## ISS-09（P2）合法可为负的变量触发“负浓度”告警

把 ΔG（−30…−70 kJ/mol）作为状态携带时：

```
warnings: 出现负浓度（数值误差或模型本身不守恒）：DGst(-62.6609)。
```

建议：变量上加 `signed:true`（或 `unit:"1"` 且 `name` 含能量）时跳过该检查。

---

## ISS-10（P2）图表产物：文件名固定、只画 6 条、`plot.cases` 缺失

1. `bma.plot.timeseries` 把 `opts.name` 固定为 `timeseries.png`，dispatch 也不透传 name → **每次 `bma_model_simulate` 都覆盖 `figures/timeseries.png`**。我做了 6 次不同工况的仿真，只能在每次调用后立刻把 PNG 拷出 run 目录才能保留。
2. 只画**前 6 个 output**（`nO = min(numel(ids),6)`）且无法从工具指定画哪 6 个 → 我被迫**调整 outputs 顺序**（把 V̇O₂%、VLa%、CLaM、CLaB、PCr、pH 放最前）来让默认图对上论文版式。
3. `simulate_cases` 的工具描述承诺 “Returns … a comparison figure path”，但 `+bma/+plot/` 下**没有 `cases.m`**，dispatch 用 `if ~isempty(which('bma.plot.cases'))` 静默跳过 → 多工况对比图**永远不会有**，也不报警。

**建议**：文件名带 `sim_id`；透传 `options.outputs` 与 `options.figure_name`；实现 `bma.plot.cases`（或在缺失时明确 warning）。

---

## ISS-11（P2）run_dir / 产物路径不一致；剖面似然静默缺失

- 请求 `run_dir=.bma/runs/r-20261112-163853-154-d091bb`，`bma_model_fit` 返回的 `predictions_path` 却是 `.bma/runs/r-20261112-175627-138-277181/fits/...`；`bma_model_identifiability` 返回 `.bma/runs/r-20261112-175708-713-4a8dfe/fits/ident-.../identifiability.csv`，而该目录**在磁盘上不存在**（`Get-ChildItem` 确认只有原始 run dir）。
- 我在 `identifiability` 里传了 `options_json={"param":"ks2"}` 请求剖面似然，返回文本里**没有任何剖面信息**，也没有“未计算”的标记（源码 `profile.m` 存在）。
- `bma_model_fit` 的参数表在返回文本里被截断（“... (13 more)”），CI 只能自己读 `fit.json`。

**建议**：所有产物路径必须落在调用方给的 `run_dir` 下并回显绝对/相对路径；可选分析未执行时返回 `requested/executed:false + reason`；返回文本包含**全部**被估计参数（或明确分页）。

---

## ISS-12（P2）文献解析：不抽图 + section 粒度过碎

- 两张 PDF 共 258 个数字、0 张表；`sections: 143`，但 heading 多为 **“ATP,cyt”“1DG”“S[A]”** 这类栏内断行碎片。结果是 `section_id` 虽然稳定，**语义上不可读**；报告里的引用只能靠“quote + s60”这种组合，人很难定位。
- **没有抽取插图**。而本次“数字化论文曲线做参数估计”这一步，恰恰要求先把图从 PDF 里拿出来——我只好自己写了一个最小 PDF 解析器（扫 `obj … endobj`、找 `/Subtype /Image`、`DCTDecode` 直接给 Pillow、`FlateDecode` 用 `zlib` + `Width/Height/BitsPerComponent/ColorSpace` 重组）。**建议把它内置**：`literature/<doc_id>/figures/fig01.png …` 并在 ingest 返回里列出（尺寸 + 所属页码）。

**建议**

- ingest 增加图抽取（≥100 dpi，命名对齐 `Fig. N`，若 PDF 有 figure caption 就配对）。
- section 切分改为“段落/句子级 + 语义 heading”，或保留现有 id 但额外提供 `sentence_id`（`s12#3`）；否则证据溯源形同虚设。
- 顺带：`numbers.json` 抽出的 `ks = 3.500e-4` 之类把下标拆到下一行（`ks` 与 `2` 分离），容易误取——建议对“符号 + 下标 + 数值”做合并规则。

---

## ISS-13（P3）`estimate:false` 时 `bounds` 的告警与 Sobol 需求冲突

`bma_model_sensitivity(method="sobol")` 用 `spec.parameters(q).bounds` 作为抽样区间（`bma/+fit/sensitivity.m::paramRange`）。但 `spec.validate` 对 `estimate:false` 且有 `bounds` 的参数逐个报 `BMA_SPEC_WARN_BOUNDS_UNUSED`（本次 21 条）。于是“为了 Sobol 加 bounds”必然产生 21 条噪声告警。

**建议**：新增 `sample_bounds`（或 `bounds` 增加 `purpose:"sampling"`），或对 `estimate:false` 的 bounds 静默接受。

---

## ISS-14（P3）拟合反馈不足

- `warnings: 多起点提前结束（已找到高优度解（R²>0.999））：实际运行 2/8 个起点。` —— 合理，但缺少“每个起点的目标函数值 / 是否落到边界”，无法判断是否早停过早。
- 参数表文本截断（13 个参数没显示），CI 需另读 `fit.json`；`params` 条目的字段是 `ci_low/ci_high/se`（不是 `ci`），文档没写，脚本里试错了一次才读对。

---

# 附：本次会话的正面反馈（同样建议保留/加强）

1. `bma_model_validate` 的**量纲检查抓到了真问题**：我把 `mol/L→mmol/L` 的 `1000` 写成裸常数时，它准确指出“运算符 + 两侧量纲不一致（无量纲 vs amount^-6·volume^6）”，逼我把标准态换算显式化（`Hconv`）。修完后 **63 个单位、0 warning**。这是本次最有价值的质量门。
2. `bma_model_analyze` 给出的**唯一稳态 + 特征值 + 反馈符号**（λ_max=−1.09e−3、∂(dPCr/dt)/∂V̇O₂=+0.232、∂(dV̇O₂/dt)/∂PCr=−0.0085）是“机制自洽”的核心证据，直接用进了报告。
3. `bma_model_fit` + `bma_model_identifiability` 在**降维后**（3 个自由参数、69 个观测）表现很好：R²=0.9999，并正确报出条件数 1.69e4、`r(ΔG_ox, ks2)=0.995`、ks2 相对标准误 1.32 —— 这条“结构可辨识但实用退化”的判断直接改变了结论的表述方式。
4. `bma_codegen` 与 `bma_report_build`（在修好 ISS-05 之后）产物可用、报告结构完整。
5. KB（`metabolic_pathway`、`thermodynamic_constraints`、`conservation_stoichiometry`）对“把文献映射到模型族”的帮助明显，尤其是守恒律/热力学约束那两条。

---

# 附 A：复现命令（供升级验证）

```matlab
% —— ISS-01：Sobol 卡死（动态刚性模型，默认 method=both）
bma_model_sensitivity(spec_path="<6 状态模型>.json", run_dir="<run>")
% 对照：静态变体（无 PCr 动力学、τ=0.2 s、2 s 窗口）→ 约 40 s 完成
bma_model_sensitivity(method="sobol", spec_path="<static>.json", run_dir="<run>",
    params_json='["dGox","ks2","ks1","ks3","M2","SC"]', outputs_json='["VO2_pct","vla_pct"]')

% —— ISS-03：嵌套深度 32（把平衡闭式解内联进速率）
bma_model_validate(spec_path="<inline-algebra>.json", run_dir="<run>")

% —— ISS-04：extra_sections 正文丢失（约 9 KB）
bma_report_build(spec_path="<spec>.json", title="t",
    extra_sections_json='[{"title":"A","markdown":"<900 字>"}]')
% 然后检查 report/report.md：标题在、正文空

% —— ISS-05：参数两条 evidence
% 把某参数 evidence 复制一份（同一对象改 quote），再
bma_report_build(spec_path="<spec-2evidence>.json", title="t")

% —— ISS-06/ISS-10：输出不落盘 + 图被覆盖
bma_model_simulate(spec_path="<spec>.json", options_json='{"time_end":600,"n":1201}')
% 观察 data/sim-*/timeseries.csv 只有状态列；figures/timeseries.png 每次被覆盖
```

# 附 B：本次会话产物（可作为升级回归样本）

```
spec_src/mader2003_chep_energy_ks2corr.json          主模型（6 状态/8 反应/33 参数/22 输出）
spec_src/mader2003_chep_energy_ks2corr_smooth.json   去 min/max 的分析变体（应可被 analyze 直接吃下）
spec_src/mader2003_chep_energy_ks2corr_static.json   钳制 PCr 的静态特征变体（Sobol 的廉价代理）
spec_src/mader2003_chep_energy_sobol_static.json     同上 + 21 个有界参数
data_figs/fig6_digitized.csv                         从 PDF 位图数字化的 3 条曲线 / 23 点
报告_Mader2003复现.md / .html                        最终报告（含两次增补）
pdf_figs/*.png                                       从 PDF 抽出的 10 幅插图（对象 19/23/…/64 ↔ Fig.1–10）
extract_pdf_images.py / digitize_fig6.py             上述两个“本应由工具提供”的自建脚本
```

# 附 C：优先级建议（若只能修三条）

1. **ISS-01 + ISS-02**：不加预算/取消/重试，任何一次“看起来能跑”的全局分析都会让整个会话报废——这是最伤信任的一类失败。
2. **ISS-03**：决定工具链能否表达“平衡态/热力学耦合”这一大类模型（系统生物学里非常多）；它同时会让 ISS-07 的双份维护消失。
3. **ISS-06 + ISS-04**：都是“成功但拿不到东西”的静默降级，直接决定 agent 能不能**自查**（没有输出量与完整报告正文，我只能靠读 PNG 和抽查 Markdown 来验证自己）。
