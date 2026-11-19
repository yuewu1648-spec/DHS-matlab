# 工具参考（bma_* ↔ MATLAB RPC）

DSH agent 通过 19 个 `bma_*` 工具调用 MATLAB。工具参数中的复杂结构用 JSON 字符串（`*_json`）传递；`work_dir` 默认会话工作目录。所有工具都声明了自带超时（30s–40min）。

## 文件式 JSON-RPC 协议（bridge ↔ MATLAB）

- 目录：`<work_dir>/.bma/server/{state.json,inbox,outbox,claims,done,server.lock}`
- 请求：`{schema:"bma.rpc.v1", id, token, method, params, work_dir, run_dir?, timeout_s}`
- 响应：`{schema,id,ok:true,elapsed_ms,result}` 或 `{ok:false,error:{code,message,details,stack}}`
- 无网络端口；MATLAB 服务由 bridge 自动启动（`matlab -batch "…bma.server.start(...)"`），单线程串行处理。
- 错误码：`BMA_SPEC_INVALID`、`BMA_UNIT_UNKNOWN`、`BMA_RATE_INVALID`、`BMA_UNKNOWN_ID`、`BMA_NOT_IMPLEMENTED`、`BMA_TIMEOUT`、`BMA_SERVER_ABSENT`、`BMA_SERVER_EXITED`、`BMA_AUTH`、`BMA_INTERNAL`。

## 工具一览

| # | 工具 | MATLAB 方法 | 作用 | 关键参数 | 返回要点 |
|---|---|---|---|---|---|
| 1 | `matlab_status` | `server.info`（control + worker） | 启停/健康检查 MATLAB 后端 | `work_dir?` | 版本、授权工具箱、control/worker pid、busy/queue/last_timeout、workspace_writable |
| 2 | `bma_kb_search` | `kb.search` | 检索知识库（13 archetype + 14 principle） | `query, tags?, limit?` | hits: id/type/name/summary/score/path |
| 3 | `bma_kb_get` | `kb.get` | 取完整条目（方程/假设/典型范围/spec_template/文献） | `id` | 条目全文（截断） |
| 4 | `bma_literature_ingest` | `literature.ingest` | 解析 PDF/DOCX/TXT/MD/HTML → 章节/数值事实/表格 | `path, run_dir?` | 章节目录、数值候选（值+单位+quote）、产物路径 |
| 5 | `bma_model_validate` | `spec.validate` | 模型规格质量门 | `spec_path` 或 `spec_json`, `run_dir?` | valid、errors(code/path/message/hint)、normalized spec 路径 |
| 6 | `bma_model_analyze` | `model.analyze` | 守恒律/稳态/稳定性/量纲 | `spec_path, options_json?, run_dir?`（options: substitute_guards/symbolic=auto\|on\|off/symbolic_max_states/symbolic_max_score/numeric_budget_seconds/multistart） | conservation_laws、steady_states（稳定性/特征值）、symbolic_skipped/reason、analysis_mode、guard_substitution、analysis_path |
| 7 | `bma_model_simulate` | `model.simulate` | ODE/MOL 仿真；2D 原生 spec 自动路由 PDE Toolbox | `spec_path, options_json?, run_dir?`（options: time_end/n/solver/outputs/include_series） | states+outputs 时间序列 CSV、outputs_final、图 `timeseries_<sim_id>.png`、warnings |
| 8 | `bma_pde_simulate` | `pde.simulate` | 原生 2D/3D PDE Toolbox（不转 ODE） | `spec_path, options_json?, run_dir?`（options: steady/n/time_end/max_dof/max_seconds/mesh/probes） | mesh nodes/elements、probes、field_stats、PDE CSV/PNG、预算/警告 |
| 9 | `bma_model_simulate_cases` | `model.simulate_cases` | 情景/参数扫描对比 | `spec_path, cases_json, run_dir?` | 每 case 摘要 + `comparison_figure`（cases_<id>.png）|
| 10 | `bma_model_fit` | `fit.estimate` | 参数估计（多起点有界最小二乘） | `spec_path, data_csv, output_map_json, options_json?, run_dir?` | 参数值±CI、R²/RMSE/AICc/BIC、预测/残差 CSV、fit 路径 |
| 11 | `bma_model_identifiability` | `fit.identifiability` | 结构/实用可辨识性、相关矩阵、剖面似然 | `spec_path, data_csv?, output_map_json?, options_json?` | 秩/相关/条件数/不可辨识组合 |
| 12 | `bma_model_sensitivity` | `fit.sensitivity` | 局部弹性 + Sobol 一阶/总效应 | `spec_path, params_json?, outputs_json?, method?, options_json?`（method 默认 local；options: sobol_n/force/budget_seconds/max_seconds/seed） | 排序表、图、budget/skipped/partial/cancelled |
| 13 | `bma_model_selection` | `validate.model_selection` | 竞争模型 AICc 比较 | `candidates_json, data_csv, output_map_json` | 比较表、AICc 权重、最佳模型 |
| 14 | `bma_model_validate_fit` | `validate.cross_validation` | k 折交叉验证 + 残差诊断 | `spec_path, data_csv, output_map_json, k?` | 每折 train/test 指标、诊断、图 |
| 15 | `bma_report_build` | `report.build` | 生成最终报告 | `spec_path, title, fit_result_path?, analysis_path?, references_json?, extra_sections_json?`（JSON 数组或 .json/.md 文件路径） | report.html/md、model_card（含 gates）、图（内嵌 base64）、warnings |
| 16 | `bma_codegen` | `codegen.model` | 导出独立 MATLAB 代码/SimBiology | `spec_path, simbiology?, run_dir?` | .m 文件、model card、可选 .sbproj |
| 17 | `bma_cancel` | `server.cancel`（桥接实现） | 取消当前重任务/恢复 heavy worker | `work_dir?, hard?, grace_seconds?` | worker/control 的 cancelled/killed/restarts_on_next_call/method、health（busy/queue/timeout） |
| 18 | `bma_artifact_import` | `run.import_artifact` | 把 run_dir 外产物导入 `artifacts/` 并登记 SHA-256 | `source_path, run_dir?, name?, kind?, recursive?` | imported、artifacts、artifacts.json、warnings |
| 19 | `bma_gate_waive` | `run.waive_gate` | 显式记录质量门豁免 | `gate, reason, substitute?, evidence?, run_dir?` | gates.json、count、duplicate |

## 其他 RPC 方法（内部/开发）

| 方法 | 用途 |
|---|---|
| `server.ping` / `server.stop` | 健康检查 / 优雅停止 |
| `test.run {filter}` | 运行 `matlab/tests/run_all_tests.m` 指定测试 |
| `dev.eval {code}` | 在常驻 MATLAB 工作区执行代码并返回 `evalc` 输出（仅开发自测） |
| `run.init {name?}` / `run.list` / `run.info` | 运行目录管理 |
| `fit.profile` | 单参数剖面似然 |
| `model.build {spec}` | 构建 ODE 模型并落盘 |
| `pde.simulate {spec, options}` | 原生 PDE Toolbox 2D/3D 求解（bma_pde_simulate 的底层方法） |
| `validate.residuals {fit_result_path}` | 残差诊断 |

## bma.modelSpec.v1 速查

- 顶层：`schema_version, name, title, kind:"ode"|"pde", time{unit,start,end,n}, variables[], parameters[], reactions[], outputs[], assumptions[], metadata`
- 变量：`{id, name, unit, initial:{value|param|expression}}`；参数：`{id, name, unit, value:{value}, estimate, bounds?, evidence?}`
- 反应：`{id, stoichiometry:{species:系数}, rate:{kind, parameters, species, mode?, expression?}}`
- 速率 kind：`mass_action` / `michaelis_menten`（含 inhibitor）/ `hill`（activation|repression）/ `constant` / `expression`
- 输出：`{id, name, unit, expression}`；PDE 额外支持 `C[i]` / `max(C)` / `min(C)` / `mean(C)` / `mean_over_domain(C)` / `integral(C)`
- PDE（0.7.0）：`pde:{dim:1, domain:{geometry:slab|cylinder|sphere, extent:{value,unit}, grid:{type:"uniform",n}, approximation,zones?}, diffusion:[{species,coeff}], bc:[x0,x1], discretization?}`；`x0` 左/深层、`x1` 右/体相；`De` 单位 length²/time
- 原生 PDE（0.8.0，`bma_pde_simulate`）：`pde:{dim:2|3, solver:"toolbox", domain:{geometry:rectangle|circle|polygon|box|stl, size|radius|points|file, mesh:{hmax,hgrad}}, diffusion, bc:[{edge|face,type,value|flux}], probes:[{id,species,x,y,z?}]}`；预算 `options_json.max_dof/max_seconds`
- 证据：`evidence:[{type: measured|estimated|assumed|fitted, quote, section_id?, source?, note?}]`

完整契约见 `docs/DESIGN.md` §3。


## 0.3.0 补充约定（issue 升级）

- **代数变量**：`variables[]` 可写 `{"id":"Km","kind":"algebraic","unit":"uM","expression":"(kr+kcat)/kf"}`；只允许在 `expression` 速率与 outputs 中使用，编译期展开，不进入状态向量/守恒律。
- **signed 变量**：热力学量（ΔG 等）写 `"signed": true`，可负、不触发负浓度告警。
- **Sobol**：默认只做局部敏感性；需要 Sobol 时显式 `method:"sobol"` 并先看 `sobol_n`/预算；返回 `skipped=true` 时按 `suggestion` 缩小模型或 `options.force=true`。
- **单位**：新增 J/kJ/kJ·mol⁻¹/W/W·kg⁻¹/mmHg/Pa/mmol·kg⁻¹ 等；`mmol/kg` 与 `mM` 分属 molality/concentration，不能直接互换（1 kg≈1 L 仅作近似，需在 assumptions 中声明）。
- **报告**：`extra_sections_json` 支持 `{title, markdown}` 和文件路径，正文会完整渲染。


## 0.4.0 文献引用（ISS-12）

- `bma_literature_ingest` 返回 `sentence_count/sentences_path/figure_count/figures_path`；每个 number 带 `sentence_id`（形如 `s3#s7`），可直接引用。
- 图的 `rel_path` 相对 `work_dir`，`figures.json` 含 width/height/page/caption/bytes/filter；图注为 best-effort。
- 纯矢量/JPX/CCITT/扫描 PDF 无位图可抽：返回 0 图 + warning。需要栅格化时安装外部渲染器（PyMuPDF/PDFBox/Ghostscript）后再处理。


## 0.5.0 稳定性、报告图片与质量门豁免

- **`matlab_status` 健康字段**：`server_alive`、`busy`、`current_call`、`busy_ms`、`queue_depth`、`last_timeout`、`last_error`、`restarts`、`workspace_writable`。忙碌时返回快照而不是排队等 `server.info`。
- **超时策略**：`BMA_TIMEOUT` 会重启 MATLAB 服务且**不自动重试**；返回的 `details` 含 `restarted/retried/timeout_ms`。重复等待同类调用不再是默认行为。
- **`bma_cancel`**：先写 `cancel.flag`，默认 `grace_seconds=3`；仍在跑则杀进程并重启，返回 `cancelled/restarted/method/health`。
- **`bma_model_analyze` 降级**：状态数 > `symbolic_max_states`（默认 6）或静态非线性 score > `symbolic_max_score`（默认 12）时跳过 `solve/vpasolve`，返回 `symbolic_skipped=true`、`symbolic.reason`、`analysis_mode="numeric_fallback"`；数值多起点受 `numeric_budget_seconds`（默认 120 s）限制。
- **`bma_report_build`**：`extra_sections_json` 接受 `.json`/`.md` 文件路径；Markdown `![alt](path)` 渲染为 `<img>` 并内嵌 base64；run_dir 外本地图片复制进 `report/figures`；缺失/远程/不支持图片进入 `warnings`。报告新增“4B. 质量门与豁免（显式记录）”章节。
- **`bma_artifact_import`**：把外部 `.mat/.png/.csv` 等复制到 `<run_dir>/artifacts/`，写 `artifacts.json`（name/kind/rel_path/bytes/sha256）；报告自动扫描 `artifacts/` 图片。
- **`bma_gate_waive`**：写 `<run_dir>/gates.json`，报告与 model card 显示 `gate/reason/substitute/evidence/recorded_at`。
- **双栏 PDF**：`literature_ingest` 新增 `section_confidence`（high/medium/low）、`low_confidence_sections`、`low_confidence_ratio`；分节不可靠时 warnings 明确提示回 `text.txt` 核对，句级 `sentence_id` 仍可用。
- **KB 新条目**：`matlab_pde_toolbox_pitfalls`（8 类 PDE 静默陷阱 + 自检）与 `numerical_convergence_checklist`（收敛≠正确）。

## 0.6.0 control + heavy worker（彻底修复单线程卡死）

- **两进程**：`matlab_status` 并行启动/检查 `<work_dir>/.bma/server`（control）与 `<work_dir>/.bma/worker/server`（heavy worker）。control 负责 `server.*`、`kb.*`、`run.*`、`spec.validate`、`model.build`；worker 负责 `literature.ingest`、`model.analyze/simulate(_cases)`、`fit.*`、`validate.*`、`report.build`、`codegen.model`、`simbiology.export`。
- **隔离**：worker 卡在不可中断 builtin 时，control 仍能回答 `matlab_status`/`bma_cancel`；`bma_cancel(hard=true)` 默认只杀 busy worker，下一次重调用惰性启动，control 不受影响。两个进程使用各自的 pref/temp/home（worker 在 `.tmp/worker-server/`）。
- **状态**：`matlab_status` 返回 `- worker: idle|BUSY pid=...` 与 `- worker server: ...`；`state.json` 增加 `server_subdir/last_method`。worker 首次启动与 control 并行，约 20–120 s。
- **超时**：worker 超时仍返回 `BMA_TIMEOUT` 且不自动重试；只杀当前 worker，下一次重调用惰性启动。连续超时说明任务本身不可行，缩小 multistart/time_end 或记录降级。
- **测试**：`bridge/test/worker-isolation.test.mjs` 证明 control 在 worker 阻塞时 138 ms 响应、`bma_model_analyze` 实际走 worker、cancel 只杀 worker 且 replacement 惰性启动。

## 0.7.0 PDE / MOL

- `kind:"pde"` 通过 `bma_model_validate`；`bma_model_build`/`bma_model_simulate`/`bma_model_fit` 等工具面不变（编译期展开为节点 ODE）。
- 支持 1D `slab`/`cylinder`/`sphere`、uniform 网格、各向同性标量扩散、Dirichlet/零通量 Neumann；`De` 单位按 length²/time 转换到 extent/time 单位。
- `outputs` 用 `C[i]`、`max(C)`、`min(C)`、`mean(C)`、`mean_over_domain(C)`、`integral(C)`；`argmax(C)` 不支持。
- `initial:{param:"p0"}` / `initial:{expression:"p0*2"}`（Gap A）已支持；`validate` 会检查参数存在。
- 报告增加“2B. PDE 离散与边界条件”；model card 增加 `pde` 元数据（geometry/n/dx/faces/expander_version/sha256）；codegen 生成 `_ode.m` + `<name>_pde.m` 元数据。
- 限制：2D、非结构网格、自由边界、对流/变张量扩散、DAE+PDE 不在 v1。

## 0.8.0 原生 PDE Toolbox

- `bma_pde_simulate`：`kind:"pde"` + `pde.dim=2|3` + `pde.solver="toolbox"`，直接 PDE Toolbox，不转 ODE。2D 几何 `rectangle`/`circle`/`polygon`；3D `box`/`stl`。
- 校验：`bma_model_validate` 对 `pde.dim>=2` 自动路由到原生校验（不再要求 MOL 1D）。
- 网格：`pde.mesh.hmax/hgrad`；预算：`options_json.max_dof`/`max_seconds`；超 `max_dof` 明确拒绝。
- 边界：2D `edge`、3D `face`，编号或 `"all"`；只支持 Dirichlet 与零通量 Neumann。
- 输出：`pde.probes`（最近节点时间序列）、`field_stats`（max/min/mean/integral）、CSV/PNG；返回 `stats.nodes/elements/elapsed_s`。
- 决策：1D / 需要 fit/identifiability/analyze → MOL；真正 2D/3D / 不规则几何 / 场输出且预算允许 → 原生 PDE。原生结果不能直接拟合。

## 0.8.3 后端空闲自动回收

- 每个 work_dir 的 control/worker 对在最后一次 `bma_*` 调用后默认空闲 **300 s** 自动 `stop()`；可用环境变量 `BMA_IDLE_SHUTDOWN_SECONDS` 调整（上限 3600，0 关闭）。
- 自动关闭后下一次 `bma_*` 调用会惰性重启（约 20–120 s）；这是正常资源回收，不要手动 `taskkill` MATLAB。
- DSH 插件 dispose/退出时也会停止所有已知后端。
- `matlab_status` 的 `server/worker not running` 在空闲回收后出现属正常，下一次调用会重启。

## 0.8.4 文献图复现

- `bma_literature_ingest` 的 `figures/figures.json` 是图清单；G1 读图注并登记 panel；G2.5 定必复现 panel 与判据。
- G7 仿真对齐文献条件，图放 `<run_dir>/figures/reproduction/`；G9 用 `bma_report_build` 的 `extra_sections_json` Markdown 图片并排嵌入原图/复现图。
- 报告矩阵逐 panel 给状态 `quantitative|qualitative|not_reproduced`；没有 digitized 数据只能标 qualitative；失败 panel 也列。

## 0.8.5 report 图片去重与宽度

- `bma_report_build` 不再回扫 `report/figures` 的输出副本；extra section 已引用的图片按源路径 + 内容 SHA-256 从 §11“图表”排除，同一图片即使换名/换目录也只出现一次。
- CSS 全局 `img{max-width:100%;height:auto;}`；Markdown 表格 `table-layout:fixed`，并排原图/复现图不会撑破页面。
- 旧报告需重新调用 `bma_report_build` 才会应用；回归测试 `matlab/tests/test_report_images.m`。

## 0.8.6 经典形式图

- `bma_model_simulate`：2 状态/2 输出模型自动生成 timeseries + phase；`options_json.plots:["phase"]` 只出相图，`phase_x`/`phase_y` 指定轴；3 状态以上可显式投影。
- `bma.plot.phase`：默认丢弃前 40% 瞬态，尾部最后一个平均穿越周期用粗蓝线标为极限环；检测不到周期时标“后段轨迹”，不硬说极限环。
- 经典形式：极限环→相图；剂量响应→剂量-响应曲线；双稳→相图/稳态；酶→v-S/抑制曲线；时空 PDE→场快照；不要只用时间序列替代。
- 0.8.5 report 去重仍生效：同一张图只出现一次。

## 0.9.0 扩展求解

- **DDE**：`kind:"dde"`，顶层 `delays:[{id,lag,unit}]`；速率表达式 `delay(S,tau)`；`bma_model_simulate` 使用 `dde23`。延迟单位必须等于 `time.unit`（v1 不做换算），只支持 expression 速率；DDE 不支持 analyze/fit/codegen。
- **BVP**：`kind:"bvp"`，`domain:{x0,x1,n}`，`bc:[{side:"left"|"right",expression}]`；`bma_model_simulate` 使用 `bvp4c`，BC 数必须等于变量数。
- **DAE**：ODE 规格 + `bma_model_simulate` 的 `options.mass_matrix`（N×N），使用 `ode15s` 的 `Mass/MassSingular`；奇异矩阵需一致初值。
- **bma_advanced_solve**（第 20 个工具，heavy worker）：
  - `system_id`：`problem_json` 提供 `data_csv/time_column/output_column/input_columns/model(tfest|ssest|arx)/order`；
  - `symbolic`：`equations/variables/conditions` 交给 `dsolve`；
  - `sde`：`variables/parameters/drift/diffusion/time_end/n/paths`，Euler-Maruyama。
- 高级 PDE（任意 CAD、各向异性/非线性、PDE 特征值）仍不支持；DAE 是常质量矩阵线性隐式形式。

## 0.10.0 DDE/BVP/DAE 增强

- **DDE**：`dde_mode:"constant"|"state_dependent"|"neutral"`；常量 `dde23`，状态依赖 `ddesd`（`delays[].expression`），中性型 `ddensd`（`delay_deriv(S,tau)`；`time.start` > 最大延迟）。DDE 可 fit/identifiability（仿真目标、有限差分）并 codegen（dde23/ddesd/ddensd）。
- **BVP**：一维 `kind:"bvp"` 可 fit/identifiability；观测为空间剖面（`res.outputs` 优先）。
- **DAE**：`kind:"dae"`，`dae.residuals`（导数写 `xdot`）+ `dae.initial_derivative`；`decic` + `ode15i`。质量矩阵 DAE 的 fit 用 `options.mass_matrix`。
- **bma_advanced_solve**：新增 `method:"ssa"`（精确 Gillespie direct method，表达式 propensity）；`sde` 仍是 Euler-Maruyama。
- 限制：`ode15i` 实际以 index-1 为主，任意高阶 DAE 需人工 index reduction；高级 PDE 不做。

## 0.11.0 NatRevMolCellBiol issues

- `bma_model_simulate`：`phase_x/phase_y` 可写 species id；`plots:["phase3d"]` + `phase_z`；返回值含 `oscillation`（period/amplitude/min/max/mean/oscillation_exists）。
- `bma_model_selection`：`options.candidate_seconds`，每候选状态写 `candidate_status`，部分结果 `model_selection.partial.json`。
- `bma_model_fit`：`timeGuard` 已实现；wall-clock 停止转 fmincon；`early_stop_r2`（默认 0.999，至少 4 起点）与 `early_stop_min_starts`；`multistart_diagnostics`；拟合图在各自 `fits/<id>/figures/`。
- `bma_model_simulate_cases`：`cases_summary.csv` 全量 summary；`n_cases`。
- `bma_model_identifiability`：接受 `options.param`（profile）与 `params_to_fit`。
- DDE：表达式延迟用过去时刻约定；常量表达式自动 dde23；DDE `units_check` 标 not applicable；DDE codegen 同步。
- PDF ingest：`figure_class`/`vector_only`/`rasterized`/`reason`；`text_chars/text_chars_total/truncated`；公式编号占位符告警。
- 无量纲模型：`time.unit="1"`；长 output name 放标题换行，轴用短 id/unit。
