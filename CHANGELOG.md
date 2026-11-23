# Changelog

本文件记录 BioModel-MATLAB agent 的**对外可见变更**（工具面、模型规格 schema、preset 组成、MATLAB 后端行为）。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer 2.0](https://semver.org/lang/zh-CN/)。
更新纪律见 `docs/VERSIONING.md`。

## [0.15.0] - 2026-11-23

### Added（BLIND-LIT：只用摘要 + 全部参考文献的盲建模）
- **4 个新工具 + `blind.*` RPC**：`bma_blind_start`（`blind.start`）、`bma_blind_note`（`blind.note`）、`bma_blind_check`（`blind.check`）、`bma_blind_reveal`（`blind.reveal`）。工具面 20 → 24，属 MINOR 向后兼容扩展；旧工具名/必填参数/返回不变。
- **主文献封印（两层）**：`bma_blind_start` 只抽取并返回摘要，写 `blind/primary_abstract.md`；`bma.io.ingest` 在读取前调用 `bma.blind.enforceSeal`，按规范路径 + SHA-256 拒绝主文献（`BMA_SEALED`）。除 run 级 `blind/protocol.json` 外，新增工作区级 `<work_dir>/.bma/blind/seals.json`，新建 run 也不能绕过。`reveal` 前全文永不落盘。
- **摘要提取兜底**：`abstract_path` 外部摘要优先；否则 sectionized Abstract/Summary → 行锚点 → 行内标记（带 confidence/warning）；都不可靠时 `BMA_ABSTRACT_NOT_FOUND`，不猜、不返回正文。
- **参考文献清单**：`references_dir` 递归扫描 PDF/DOCX/TXT/MD/HTML；`references_json` 清单；`from_primary=true` 只从主文献 References 抽题录字符串（正文/参考文献章节原文不暴露）。主文献按路径 + SHA-256 从清单剔除。
- **逐篇笔记 + quote 硬核验**：`bma_blind_note` 抽取参考文献文本到 `blind/refs/<id>/text.txt`（SHA-256 缓存），把每条 claim 的 `quote` 归一化（大小写/空白/弯引号/破折号/软连字符）后做子串匹配；失败 `BMA_QUOTE_NOT_FOUND` 并列出失败项。只有题录/无文本可 `citation_only` + `access_limited_reason`，status=`limited`，必须在自检中登记证据缺口。
- **防形式主义**：`no_modeling_content` 需 ≥80 字理由；coverage 统计比例，`evaluateStop` 对超过 30%（或 2 篇）的情况阻止 stop。
- **自检台账**：`bma_blind_check` 支持 `status/goal/references/round/freeze/stop`。round 要求 summary≥80、≥3 checks（name/result/evidence）；问题分类 category/severity/status；`fixed` 需 fix/fix_kind/evidence；`impossible` 需 reason≥80 + why_general≥60 + evidence≥20；`over_budget` 需 spent_s ≥ 2×limit_s；`fix_kind="model"` 必须提交 hash 变化且 `bma.spec.validate` 通过的 spec（`BMA_MODEL_UNCHANGED` / `BMA_MODEL_INVALID`）。
- **停止判据**：goal 记录；参考文献 read 或由 impossible/over_budget 的 `covers_references` 覆盖；rounds ≥ min_rounds（默认 3）；无 open 问题；关闭论证齐全；模型已 `freeze`。否则 `BMA_STOP_BLOCKED` + 全部原因；通过后写 `blind/blind_summary.md`。
- **可选解封 + 8 维对照**：`bma_blind_reveal action:"reveal"` 仅在 stop 通过且模型冻结后解封并 ingest 全文，失败回滚封印；`action:"compare"` 校验 8 维（question/model_class/state_variables/mechanisms/parameters/assumptions/behavior/evidence_use），写 `blind/model_comparison.json|md`。
- **persona / skills**：preset 新增“盲文献建模模式（BLIND-LIT）”硬规则与 B0–B8；新增 skill `blind-literature-modeling`；`bio-modeling-workflow` / `bio-model-report` 增加盲建模衔接；任务列表纪律增加 B0–B8 整表。
- **复用工具**：新增 `bma.util.sha256File`（JVM SHA-256），`bma.run.importArtifact` 改为调用它（行为不变）。

### Tests
- 新增 `matlab/tests/test_blind_protocol.m`：摘要不泄漏正文、两层封印、转述 quote 拒绝、coverage、伪修复拒绝（hash 未变）、over_budget 2× 阈值、未冻结 stop 拒绝、freeze/stop、reveal 后全文可读、8 维 compare + 缺维拒绝、无 Abstract 时 abstract_path 兜底、from_primary 题录-only limited。
- `bridge/test/plugin-smoke.mjs`：注册 24/24 工具；端到端跑 `bma_blind_start` → `bma_literature_ingest` 被 `BMA_SEALED` 拒绝 → `bma_blind_note` quote 核验 → goal → 2 轮 round → freeze → stop → reveal → 8 维 compare。
- 全量 MATLAB 套件见 `docs/ACCEPTANCE.md` §7.24；`check_agent.ps1`（版本/manifest/bundle/MATLAB/插件冒烟）与 `check_isolation.ps1` 全绿。

### Docs
- 新增 `docs/BLIND_PROTOCOL.md`（数据模型、封印语义、工具/停止判据、诚实性边界）；更新 `docs/TOOL_REFERENCE.md`（24 工具、blind 小节、错误码）、`docs/DESIGN.md`、`docs/VERSIONING.md` §6、`docs/MODELING_METHODOLOGY.md` §8、`docs/USAGE.md`、`README.md`。

### Compatibility
- MINOR：`bma.modelSpec.v1` 不变；旧工具签名与 `summary` 字段不变；无 blind 协议的 run 的 ingest 行为不变；`blind/` 与 `.bma/blind/seals.json` 为新增产物。`bma_blind_*` 的 run_dir 必须显式给出（不自动新建），避免误建空协议。


## [0.14.0] - 2026-11-22

### Fixed
- **原生 2D PDE 永久挂起**（`+bma/+pde/simulate.m`）: 非线性求解器给出的试探状态可能是负值或 NaN;
  `qmax·u/(K_M+u)` 在 `u=-K_M` 处有极点, 一但返回 NaN, 误差控制器拒绝每一步、步长坍缩, `solvepde`
  不再返回且不报错. 真实案例(Stewart 2016 Case 4B, Monod 葡萄糖消耗)复现两次 1780 s RPC 超时.
  现在: 速率按 `u>=0` 求值(负试探状态钳位, 计入 `res.diagnostics.clamped_states`);
  初始化时 MATLAB 的 all-NaN 探针调用**原样透传**(若把它置 0, 雅可比退化为 0, 会静默返回
  无反应的均匀场——调试中实际出现过); 若有限状态仍产生非有限源项则**明确报错**
  `bma:pdeToolbox:nonfiniteSource`, 不再静默置 0.
  同一模型: 修复前 >90 s 未返回; 修复后 5.6 s 完成, 共钳位 545195 个负试探值, 非有限值 0.
- **`startup_bma.m` 根目录解析**: `fileparts` 多剥一层, root 被解析成盘符 `E:\` 并 addpath 到不存在的
  `E:\matlab`; 现在按 `VERSION` 标记定位, 兼容"放在仓库根"与"低一层"两种布局.

### Added
- **硬预算看门狗 `scripts/pde_watchdog.ps1`**: 在子 MATLAB 进程里执行同一次 `bma.pde.simulate`,
  `-DeadlineSeconds` 到点用 `taskkill /T /F` 强制终止, 返回
  `{status: completed|timeout, elapsed_s, result_mat, log}`; 结果以 `guarded_result.mat` 落盘。
  支持 `-OptionsFile`(JSON 文件) 以避免 Windows 命令行对 JSON 引号的剥离。
  已实测: completed 17.2 s / timeout 5.03 s 强杀。子进程日志经 ASCII 临时路径中转
  (`Start-Process` 重定向到非 ASCII 路径会静默失败, 这是此前"空日志"的真因)。
- 返回结构新增 `res.budget`(advisory/max_seconds/elapsed_s/interruptible/note) 与
  `res.diagnostics`(clamped_states/nonfinite_source) (只增字段). 真实 2D 案例端到端复核:
  钳位 517366 次后探针值与独立椭圆稳态解逐点一致 (97.46/79.93/73.95 vs 97.46/79.93/73.94).
- 新增回归测试 `matlab/tests/test_pde_nonlinear_budget.m`: 未正则化 Monod 必须完成且梯度方向正确、
  `budget` 必须如实标注 advisory、`steady:true` 必须给出均匀 C0 场.

### Changed
- `max_seconds` 语义**不变**(仍是求解后告警): `solvepde` 没有回调, `setInitialConditions` 只接受
  标量或长度 N 的向量(不能注入节点场), 因此进程内无法强制截止时间; `res.budget` 如实标注
  `advisory=true, interruptible=false`. 早前尝试的"分块续算"方案经实测不可行(MATLAB 无法注入节点场续算)已移除.
- 文档: `docs/TOOL_REFERENCE.md`(工具表/原生 PDE 小节)、`docs/VERSIONING.md` §6 兼容性契约、
  `README.md` 增补本节.

## [0.13.0] - 2026-11-22

### Added（flex-1：灵活性扩展）
- **`kind:"matlab"` 自定义速率定律**（`+bma/+spec/private/rateParse.m`）：`{function, file?, arguments[], unit, display?}`
  编译为 `fn(y(i), p(j), ...)`，与内建速率同构（`m.vfuns` / `m.rhs`），仿真/拟合/可辨识性/敏感性无需改动：
  - `unit` **必填**（函数体量纲无法静态推导），并产生 `BMA_RATE_DECLARED_UNIT` 警告；声明单位仍与化学计量要求的量纲比对；
  - `file` 自动 `addpath`，函数缺失报 `BMA_RATE_INVALID`；
  - `m.rate_functions` 记录 `{reaction,function,file,unit}`，代码生成在头注释里提示“必须保持在路径上”；
  - `+bma/+spec/normalize.m` 的 rate 白名单补齐 `function/file/arguments/unit/display`（否则字段会被归一化静默丢弃）。
- **非零 Neumann 与非零 Robin 边界**（原生 PDE）：`neumann{flux}` 支持非零通量，新增 `robin{q,g}`；
  `flux/q/g` 可为有限标量、参数 id 或按物种的 N 维向量。
- `docs/FLEXIBILITY.md`：记录三项限制的真实成因、本次落地内容、原生 PDE 拟合的可行路线与优先级。

### Tests
- 新增 `matlab/tests/test_flex_extensions.m`：自定义速率与解析解一致（`2·exp(-0.3·5)`，相对误差 < 1e-6）、
  缺 unit / 函数缺失的报错码、声明单位警告、代码生成提示、非零 Neumann 实际求解（probe 0 → 0.01604）、Robin 校验。
- 回归：`spec` / `model_*` / `pde` / `report_build` 共 12 个测试文件全部通过（0 失败）。

## [0.12.0] - 2026-11-19

### Added
- **PDF 矢量插图使用 PyMuPDF**：`bma.io.extractPdfFigures` 默认调用 Python + PyMuPDF；新增 `matlab/+bma/+io/private/pdf_figures_pymupdf.py`：
  - 提取嵌入位图（PNG/JPG）；
  - 对 `page.get_drawings()` 的 figure-sized 矢量 drawing 区域做 bbox 聚类，按 `dpi` 渲染为 `kind=vector_render` PNG；
  - 返回 `figure_class=bitmap|vector|vector_or_mask|mixed`、`vector_only`、`rasterized`、`reason`、`renderer=pymupdf`；
  - 页面无图幅级 cluster 时标记 `figure_class=vector, reason=no_figure_region`，可用 `render_pages=true` 渲染整页。
  - PyMuPDF/ Python 不可用时回退内置纯 MATLAB 位图解析器，并保留明确 warning。

### Tests
- 新增矢量 PDF fixture `tests/fixtures/upgrade/pdf/vector_figure.pdf`；`test_io_figures` 断言 PyMuPDF `vector_render`、`figure_class=vector`、`rasterized=true`。
- 完整套件见 `docs/ACCEPTANCE.md` §7.23。

## [0.11.1] - 2026-11-19

### Added
- `LICENSE`（MIT，Copyright (c) 2026 yuewu1648-spec）。
- `.gitattributes`：文本文件统一 LF；`.pdf/.docx/.png/.mat/.stl` 按二进制处理；`tests/fixtures/literature/*/paper.txt|html` 保留原始 CRLF。

### Changed
- `README.md` / `docs/USAGE.md`：快速开始改为「克隆 → `scripts\install_bundle.ps1` → `plugin_manager install_bundle`」，去掉本机安装路径。
- `scripts/install_bundle.ps1`：新增 `-MatlabExe` 参数（默认仍为 `C:\Program Files\MATLAB\R2024a\bin\matlab.exe`）。
- `MANIFEST.sha256` 重新封版（326 个文件），使 Windows 克隆后的行尾与完整性校验一致。
- 修复 `.gitignore` 中 `models/`、`figures/` 未锚定到仓库根的问题：此前会误伤 `matlab/tests/models/` 下 3 个测试夹具，导致完整性清单与仓库内容不一致。

### Notes
- 运行期目录 `.bma/`、`.tmp/`、`.qa/`、`tests/e2e/artifacts/`、`node_modules/` 由 `.gitignore` 排除，不进入版本库。
- 两篇第三方论文 PDF（`tests/fixtures/upgrade/pdf/`）仅作本地测试样本，仓库保持私有。

## [0.11.0] - 2026-11-19

### Fixed（按 NatRevMolCellBiol issues）
- **ISSUE-001 DDE 表达式延迟无效**：`ddesd`/`ddensd` 的延迟函数返回的是**过去时刻 t-τ**，不是 τ；已在 simulate 中改为 `t - delayFun`。常量值表达式延迟（如 `expression:"tau"`）自动归一到 `dde23`，与 `lag` 轨迹一致（回归 maxdiff=0）；`m.delays`/`m.requested_mode` 保留数值快照。DDE codegen 同步修正。
- **ISSUE-003 相图不产出**：`phase_x/phase_y` 现在可命名 species id（不只是 output id）；dispatch 显式 `plots:["phase"]` 会返回 `figures`，失败时给 `figure_warning`。新增 `phase3d`（`phase_x/y/z`，ISSUE-012C）。
- **ISSUE-004 模型选择超时**：每个候选有 `candidate_seconds` 独立预算；`candidate_status` 标记 ok/failed，每算完一个候选写 `model_selection.partial.json`，已完成的 AICc 行保留。
- **ISSUE-005 fit 回退/多起点**：补上缺失的 `timeGuard` OutputFcn 实现；wall-clock 停止的 lsqnonlin 转入 fmincon 而不是伪收敛；多起点默认至少探索 `min(4,multistart)` 个起点，`early_stop_r2`/`early_stop_min_starts` 可配；返回 `multistart_diagnostics`。
- **ISSUE-006/013 PDF**：区分 `figure_class=bitmap|vector|vector_or_mask`、`rasterized`/`reason=no_renderer`；不再把矢量掩膜误报为“单色插图”；文件字节只做提示，截断按解析文本字符数并返回 `text_chars/text_chars_total/truncated`。
- **ISSUE-007 DDE 量纲**：`units_check` 返回 `applicable=false, ok=true, reason=dde_units_not_derived`，不再用 `ok=false checked=0` 冒充失败。
- **ISSUE-008 profile 选项**：`bma_model_identifiability` 同时接受 `options.param` 与 `params_to_fit/params`；全参数 `estimate:false` 时 profile 用默认参数向量继续扫描，不再直接失败。
- **ISSUE-009 cases 截断**：`simulate_cases` 返回 `n_cases`，写 `cases_summary.csv`（全部 case 的 initial/final/min/max），工具输出给出完整路径与截断提示。
- **ISSUE-010 fit 图覆盖**：`persistFit` 的图写入各自 `fits/<fit_id>/figures/fit.png`，不再共享 `run/figures/fit.png`。
- **ISSUE-011 无量纲时间**：允许 `time.unit:"1"`，`d/dt` 按无量纲处理，Rössler/Lorenz 类模型不再需要 `k0` 补丁。
- **ISSUE-018 长中文轴标签**：多子图 y 轴改为短 `id [unit]`，长 `name` 放子图标题并自动换行，避免相邻子图叠字。
- **ISSUE-012A 振荡指标**：`bma.model.simulate` 增加 `oscillation`（period/amplitude/min/max/mean/oscillation_exists/peak_times），工具摘要显示可识别振荡。

### Added
- `bma.plot.phase3d`；`oscillationMetrics`；`test_dde_simulate` 表达式/常量等价、DDE profile；`test_cases_summary`、`test_dimensionless_time`、`test_fit_figure_isolation`、`test_model_selection_partial`。

### Notes
- ISSUE-002 是 DSH workspace-write 的 Windows ACL 环境问题，本仓库代码无法修复；当前 full-access 会话不复现该错误。
- ISSUE-012B（参数延拓/不稳定分支）仍是后续能力；ISSUE-014/015/016/017 是文献数据/流程问题，已在 report skill 增加复现矩阵、文献类型/SI 可得性、公式位图降级规则。
- 完整套件：38/38 PASS（817.5 s）。

## [0.10.0] - 2026-11-18

### Added
- **DDE 全谱**：`dde_mode:"constant"|"state_dependent"|"neutral"`。
  - 常量延迟：`dde23`；
  - 状态/时间依赖延迟：`delays[].expression`（如 `1+0.2*sin(t)`），`ddesd`；
  - 中性型：`dde_mode:"neutral"` + `delay_deriv(S,tau)`，`ddensd`（要求 `time.start` > 最大导数延迟；v1 只提供导数延迟，不提供延迟状态）。
  - 表达式白名单新增 `sin/cos/tan/abs`。
  - **DDE fit/identifiability**：`bma_model_fit`/`bma_model_identifiability` 走 `bma.model.simulate` 的仿真目标（有限差分，无解析灵敏度）；DDE **codegen** 生成 `dde23`/`ddesd`/`ddensd` 独立 `.m`。
- **BVP fit/identifiability**：一维 `bvp4c` 模型可用空间剖面数据做 `bma_model_fit`；输出生成/拟合路径修复（`res.outputs` 优先）。
- **DAE**：
  - 新增 `kind:"dae"`，`dae.residuals` + `dae.initial_derivative`，用 `decic` 一致化初值后 `ode15i` 解全隐式 DAE；
  - 质量矩阵 DAE 支持 `bma_model_fit` 的 `mass_matrix` 选项（`simulatePredictions` 透传）。
- **SDE/SSA**：`bma_advanced_solve` 新增 `method:"ssa"`，表达式 propensity 的精确 Gillespie direct-method 随机模拟（mean/std/paths）；原有 `sde` Euler-Maruyama 保留。
- **测试**：DDE 增加 ddesd/ddensd/fit/identifiability/codegen；BVP 加 fit/identifiability；DAE 加质量矩阵 fit 与 `test_dae_implicit`（ode15i fit）；advanced 加 SSA。

### Notes
- `ode15i` 是通用全隐式形式，但实际可靠范围仍以 index-1 为主；任意高阶 DAE 仍需人工指标约化（index reduction）。
- 中性 DDE 的 `ddensd` 只给导数延迟，不能直接使用 `delay(S,tau)`；用 `delay_deriv(S,tau)`。`time.start` 必须大于导数延迟。
- DDE/BVP 的 fit 是仿真目标优化，不是解析灵敏度；参数多/延迟大时计算量大，报告需说明。
- 高级 PDE（任意 CAD、各向异性/非线性、PDE 特征值）仍不做。

## [0.9.0] - 2026-11-18

### Added
- **DDE**：新增 `kind:"dde"`，顶层 `delays:[{id,lag,unit}]`；速率表达式用 `delay(S,tau)`；`bma_model_validate` 校验，`bma_model_simulate` 用 `dde23` 解常量延迟。v1 要求 delay 单位与 `time.unit` 一致（不做静默换算），只支持 expression 速率；DDE 暂不支持 analyze/fit/codegen。
- **BVP**：新增 `kind:"bvp"`，`domain:{x0,x1,n}` + `bc:[{side:"left"|"right",expression}]`；`bvp4c` 解边值问题，输出空间剖面；BC 数量必须等于变量数。
- **DAE**：`bma_model_simulate` 新增 `options.mass_matrix`（N×N），用 `ode15s` 的 `Mass/MassSingular` 解线性隐式 DAE；奇异质量矩阵要求初值满足代数约束。
- **高级求解工具 `bma_advanced_solve`**（第 20 个工具，heavy worker）：
  - `system_id`：CSV + `tfest`/`ssest`/`arx` 黑箱系统辨识，返回 fit% 与对比图；
  - `symbolic`：`dsolve` 闭式 ODE 解，返回表达式/LaTeX；
  - `sde`：drift/diffusion 表达式的 Euler-Maruyama 随机模拟，返回 mean/std/paths。
- **回归**：`test_dde_simulate`（dde23 + dispatch + 延迟单位门）、`test_dae_mass`（质量矩阵 + 约束）、`test_bvp_simulate`（Poisson 解析解 + BC 门）、`test_advanced_solve`（dsolve/tfest/sde + dispatch）。

### Notes
- 高级 PDE（任意 CAD、各向异性/非线性系数、3D 复杂几何、PDE 特征值）仍不在一等支持范围；DAE 目前是常质量矩阵线性隐式形式，不是任意高指数 DAE。
- DDE/BVP 不进入 `bma_model_fit`/identifiability（fit 明确报 `bma:fit:unsupportedKind`）；DDE/BVP 代码生成也明确拒绝。
- 模型规格 schema 增加 `dde`/`bvp` 两种 kind；ODE/MOL/2D/3D PDE 行为保持兼容。

## [0.8.6] - 2026-11-18

### Added
- **经典形式图**：`bma_model_simulate` 对 2 状态/2 输出模型自动同时生成时间序列与相平面图；`options_json:{"plots":["phase"]}` 可只出相图，`phase_x`/`phase_y` 可指定轴。
- **极限环可视化**：`bma.plot.phase` 默认丢弃前 40% 瞬态，在尾部找最后一个平均穿越周期，用粗蓝线画出闭合环；检测不到周期时加粗后段并标“后段轨迹”，不会把瞬态硬说成极限环。相图仍保留完整轨迹（灰细线）、起点/终点与图例。
- **经典形式选择**：preset G7/G9 与 `bio-modeling-workflow`、`bio-model-report` 明确：振荡/极限环→相图（非仅时间序列）；剂量响应→剂量-响应曲线；双稳/开关→相图/稳态；酶动力学→v-S/抑制曲线；时空 PDE→场快照。
- **去重**：继续使用 0.8.5 的 report 内容哈希去重；同一经典图只出现一次，§11 与 extra sections 不重复。

### Tests
- `test_plot_outputs.m` 增加 Selkov 极限环：生成 `phase_limit_cycle.png`（163 KB），并验证 `model.simulate` dispatch 对 2 状态模型自动产生 2 张图（timeseries+phase）。
- 完整套件 **29/29 PASS（456.4 s）**。

### Notes
- 只改绘图/分发/preset/docs 与测试，模型规格与求解逻辑不变；按 SemVer 记 PATCH 0.8.6。
- 3 状态以上振荡模型默认不自动加投影相图；需要时显式传 `plots:["phase"]` 与 `phase_x/phase_y`。

## [0.8.5] - 2026-11-16

### Fixed
- **report 图片重复**：`collectFigures` 不再回扫 `report/figures`（该目录是 extra section 的输出副本）；extra section 引用的图片按**源路径 + 内容 SHA-256** 从 §11“图表”排除；同一图片即使以不同文件名/目录出现也只嵌入一次；不同图同名时用内容哈希后缀避免覆盖。
- **大图溢出横宽**：CSS 增加全局 `img{max-width:100%;height:auto;}`；Markdown 表格增加 `table-layout:fixed` 与 `td img{max-width:100%}`，原图/复现图并排时不会撑破 1080px 页面。
- **测试**：新增 `matlab/tests/test_report_images.m`：shared 图（extra section 引用）+ 同名副本（artifacts）+ 独立 model/artifact 图，断言报告只有 3 个唯一 data URI、§11 不重复、CSS 含 max-width/fixed layout；**PASS**。
- report 的 extra section 图片源路径现在由 `prepareExtraBody` 返回，供 `collectFigures` 做去重；图数量/`figures_used` 不会因扫描报告输出目录而膨胀。

### Notes
- 只改 `bma.report.build` 与测试；工具名/spec/MATLAB 求解不变；按 SemVer 记 PATCH 0.8.5。
- 旧报告不会自动变化；需要重新调用 `bma_report_build` 生成新 report。

## [0.8.4] - 2026-11-15

### Added
- **文献图复现成为强制工作流**：G1 除证据表外必须读 `figures/figures.json` 与图注，登记每张图/panel 的 caption、page、图片路径、x/y 轴/单位、实验条件与报道趋势/数值；无法抽图时记录“原图不可得”。
- **G2.5 文献图目标**：先于建模/仿真，从图清单挑出与模型可观测量对应的必复现 panel（时间过程、剂量响应、空间剖面、相图），写明条件、模型输出与判据（digitized 点的 RMSE/相对误差/R²，或定性方向/排序/峰值时间/平台）；示意图/方法图可标“不复现”并说明。
- **G7 条件对齐**：仿真必须使用文献图的时间窗/剂量/空间范围/单位，生成 `<run_dir>/figures/reproduction/` 下相同坐标/图例/轴范围的对照图；禁止用通用模拟图冒充文献图。
- **G9 文献图复现矩阵**：报告逐 panel 列出 图号/caption → 条件/模型输出 → 原图/复现图并排 → 判据/状态（quantitative/qualitative/not_reproduced）→ 局限；失败 panel 也必须列出，不能只报成功的图。
- preset/skills（`bio-modeling-workflow`、`bio-model-report`）与 `docs/MODELING_METHODOLOGY` 同步；明确没有 digitized 数据时只能标 qualitative，不得写“定量一致”。

### Notes
- 只改 agent 提示词、skills 与文档；工具面/模型规格/MATLAB 计算逻辑不变；按 SemVer 记 PATCH 0.8.4。
- 图的复现仍受原图可读性、矢量图未栅格化、参数/条件缺失限制；报告必须如实列出 not_reproduced，而不是用泛泛的“趋势一致”替代。

## [0.8.3] - 2026-11-15

### Added
- **MATLAB 后端空闲自动回收**：插件记录每个 work_dir 的 control/worker 对，最后一次 `bma_*` 调用结束后启动 idle 计时；默认 **300 s** 无调用即依次 `stop()` control+worker，删除 bridge 对，下一次调用惰性重启。计时器 `unref()`，不会单独拖住 DSH 进程。
- **`BMA_IDLE_SHUTDOWN_SECONDS`**：环境变量调整空闲秒数（上限 3600；`0` 关闭自动回收）。默认 300 s。
- **DSH 插件 dispose 清理**：`ctx.effect` 在插件卸载/DSH 退出时停止所有已知 MATLAB 后端，避免孤儿进程。
- preset G0/G9 与 `matlab_status` 工具说明：自动关闭是正常资源回收；不要手动 `taskkill` MATLAB；若需立即释放可设小空闲值或结束会话。
- 新测试 `bridge/test/idle-shutdown.test.mjs`：用 2 s 空闲值启动真实 control+worker，验证两者自动退出；**PASS**。

### Notes
- 不改工具名/必填参数、模型规格或 MATLAB 计算逻辑；按 SemVer 记 PATCH 0.8.3。
- 默认 300 s 是“任务结束后释放资源”与“避免频繁冷启动（20–120 s）”的折中；用户可设 `BMA_IDLE_SHUTDOWN_SECONDS=60` 等更短值。

## [0.8.2] - 2026-11-15

### Added
- **G6.5 求解器前置门（A2/A3）**：任何自写 Newton/Picard/定点/`fsolve`/`fmincon` 包装、时间/参数/延拓循环、自建 FEM/PDE 装配，在写循环之前必须先做 A2 雅可比方向导数校验与 A3 方程残差验收，并写入 `artifacts/solver_preflight.json`。
- **A2**：`eps=1e-8*max(1,norm(u))`, `rng(0)`, `du=randn(n,1)`；`err=||R(u+eps*du)-R(u)-eps*J*du||/||R(u+eps*du)||`；目标 `<1e-8`，`1e-8~1e-5` 复测，`>1e-5` 判失败；J 与 R 必须同源。
- **A3**：只以归一化方程残差 `||R(u)||/max(||F||,||K||*||u_ref||,realmin)` 验收，`<=1e-6` 才接受；正性钳位/截断后重算 `R(u_clamped)`；禁止用 `||u_new-u||`、`|r|/c_amb` 或单纯 exitflag。
- preset 与 `bio-modeling-workflow`/`matlab-modeling-troubleshooting` skills 增加强制预检步骤与 MATLAB 模板；KB 的 `numerical_convergence_checklist` 与 `matlab_pde_toolbox_pitfalls` 更新为 0.8.2，新增 A2/A3 公式、诊断与反例。
- 预检失败时禁止写求解循环、禁止参数扫描/拟合；先修装配/边界/符号/权重。PDE Toolbox 内置 `solvepde` 无自定义 J 时，A2 用制造解/无源解析对照，A3 仍用残差或制造解误差。

### Notes
- 本次只改 agent 提示词、skills 与知识库，不改 MATLAB 工具面/模型规格/求解器代码；按 SemVer 记 PATCH 0.8.2。
- 来源：`E:\matlab建模\胰岛\NUMERICAL_PITFALLS.md` 的 A2/A3；未引入任何模型/复现结论。

## [0.8.1] - 2026-11-14

### Fixed
- **任务列表结束仍显示未处理**：会话日志显示 agent 只在开头调用一次 `todo_write`，之后质量门/工具调用都不再更新；DSH 的 `todo` projection 按“整表替换 + turn/end 保留最后快照”工作，因此旧列表一直留在 UI。
- preset 新增“任务列表纪律（强制，每次会话）”：G0 前建表；每完成一个质量门立即重发完整列表；失败/跳过项改成 completed 并注明原因或删除；最终回答前必须最后一次 `todo_write`，确认 `0 pending, 0 in progress` 才可结束。
- `bio-modeling-workflow` skill 增加步骤 0（建表）与步骤 13（收尾清零），与 preset 同步。

### Notes
- 这是 agent 行为/提示词修复，不改工具面、模型规格或 MATLAB 后端；按 SemVer 记 PATCH 0.8.1。
- 任务列表仍由 DSH 内置 `@deepseek-ai/dsh-tool-todo` 管理；子代理各自维护自己的列表，不共享。

## [0.8.0] - 2026-11-14

让 agent 在合适场景**直接使用 MATLAB PDE Toolbox**，不再把所有 PDE 都展开成 ODE。按 `docs/VERSIONING.md` 记 **MINOR**：新增可选 `bma_pde_simulate` 工具、`kind:"pde"` 的 2D/3D 原生子路径与可选字段；旧 ODE 与 1D MOL 行为不变。

### Added
- **`bma_pde_simulate`（第 19 个工具）**：`kind:"pde"` + `pde.dim=2|3` + `pde.solver="toolbox"`，直接 `createpde -> geometry -> generateMesh -> specifyCoefficients -> applyBoundaryCondition -> setInitialConditions -> solvepde`，不转 ODE。
- **2D 几何**：`rectangle`（size）、`circle`（radius）、`polygon`（points）；**3D**：`box`（size，结构化四面体 mesh）与 `stl`（`domain.file`，PDE Toolbox `importGeometry`；需有效闭合 STL，CI 覆盖 box，STL 未作黄金值）。
- **物理与边界**：各向同性扩散 `c` 按物种列向量（多组分）；局部反应/源项 `f = S*rates` 支持 mass_action / michaelis_menten / hill / constant / expression；Dirichlet 与零通量 Neumann；2D `edge`、3D `face`，`"all"` 或编号。
- **输出/预算**：`pde.probes` 观测点（最近节点时间序列）、`field_stats`（max/min/mean/integral）、CSV、PNG；`max_dof`/`max_seconds` 预算门与 elapsed 报告。
- **Agent 决策**：preset/skill 明确“1D / 需要 fit/identifiability/analyze → MOL；真正 2D/3D / 非规则几何 / 场输出且预算允许 → PDE Toolbox”；原生 PDE 结果不能直接喂 `bma_model_fit` / `bma_model_identifiability`。
- **校验**：`bma_model_validate` 对 `pde.dim>=2` 路由到 `bma.pde.validate`（几何/网格/边界/扩散/许可），返回原生 PDE 专用 summary。
- **测试**：`matlab/tests/test_pde_toolbox.m` 覆盖 2D rectangle 瞬态/CSV/PNG、双组分、circle、3D box、max_dof 预算门；`bridge/test/plugin-smoke.mjs` 增加 2D 原生工具调用（19/19 注册）。

### Changed
- `bma.spec.validate`：`pde.dim>=2` 或 `pde.solver="toolbox"` 不再调用 MOL expand；走原生校验。
- `bma.server.dispatch`：新增 `pde.simulate`；`model.simulate` 在 2D 原生 spec 上自动路由到 `bma.pde.simulate`。
- `bridge/lib/index.js`：`pde.simulate` 加入 heavy worker 方法集；control 仍只做轻调用。
- 工具面从 18 增至 19；旧工具名/参数不变。

### Known limitations
- 原生 PDE 路径不做参数拟合/可辨识性；需要时用 1D MOL 降维，或在报告中明确“未做参数估计”。
- 3D `box` 用结构化四面体网格（不是 CAD 几何）；复杂 3D 需 STL。`stl` 的边界编号由几何导入决定；CI 只覆盖 `box`，STL 需有效闭合文件并调 `hmax`，不能假定一次导入即成功。
- 尚不支持非线性/各向异性张量 `c`、对流项、非零 Neumann 通量、移动边界、DAE+PDE；这些需后续版本。
- `field_stats` 的 `integral` 用“节点平均 × 总体积/面积”近似；严格积分需后续单元级求积。
- 2D/3D 原生路径没有 `bma_model_analyze` 的守恒/稳态符号分析；用 field/probe 与 steady solve 代替。

## [0.7.0] - 2026-11-14

按 `E:\matlab建模\生物膜\issues\0001-bma-pde-support.md` 实现 **PDE spec → MOL ODE spec** 编译器。按 `docs/VERSIONING.md` 记 **MINOR**：`kind:"pde"` 与 `pde` 子树是新增可选字段，旧 ODE 规格行为不变，工具名/必填参数不变。

### Added
- **`kind:"pde"` + `bma.spec.pde.expand`**：1D 规则几何 `slab`/`cylinder`/`sphere`，uniform 网格；编译期展开为节点状态 `C_1..C_n`，下游 simulate/fit/identifiability/validate/report/codegen 零改动复用。
- **有限体积算子 `bma.spec.pde.fvOps`**：面/体积系数、Dirichlet 半细胞系数；cylinder/sphere 使用面积/体积加权，避免把径向网格当成 slab。
- **PDE 子树**：`{dim:1, domain:{geometry,extent,grid,approximation,zones?}, diffusion:[{species,coeff}], bc:[x0,x1], discretization?}`；支持 Dirichlet（参数/数值）与零通量 Neumann；De 按 length²/time 转换到 extent/time 单位。
- **输出语法 `bma.spec.pde.rewriteExpression`**：`C[i]`、`max(C)`、`min(C)`、`mean(C)`、`mean_over_domain(C)`、`integral(C)`；`argmax(C)` 明确抛 `BMA_PDE_UNSUPPORTEDOUTPUT`。
- **Gap A**：`initial:{param:"p0"}` 或 `initial:{expression:"p0*2"}` 在 validate/compile 中解析；ODE 与 PDE 都支持，不再静默变成 0。`normalize` 保留 param/expression。
- **报告/模型卡/codegen**：报告新增“2B. PDE 离散与边界条件”并写入 approximation 限制；`m.pde` / model card `pde` 记录 geometry/n/dx/faces/expander_version/sha256；codegen 生成展开后的 `_ode.m` 与记录 PDE 元数据的 `<name>_pde.m`。
- **黄金值测试 `matlab/tests/test_model_pde.m`**：G1 零阶 slab 耗尽支、G2 全穿透支、G3 sphere 一阶（n=256 FV 收敛）、G4 Monod 柱 C1/C16/mu（与参考 run 0.5% 内）；PDE 量纲、initial.param、报告小节；1/1 PASS。
- **PDE fixtures**：`tests/fixtures/upgrade/pde/*.json`（4 个规格）。

### Changed
- `bma.spec.validate`：接受 `kind:"pde"`；先做 PDE 子树/单位/网格/BC 检查，再展开为 ODE 复用完整校验；`normalized_spec` 保持 PDE 规格。
- `bma.spec.checkUnits`：PDE 规格先展开再走 ODE 量纲引擎；`bma.spec.compile` 检测 pde 后编译展开模型并恢复 `m.kind/m.pde/m.spec`。
- `bma.spec.normalize`：initial 保留 `param/expression`；`bma.spec.validate` initial 分支支持参数/表达式并检查未知参数。
- `bma.codegen.modelCard` 写入 `pde` 元数据；报告 `pdeHtml/pdeMd` 渲染网格/边界/近似。

### Fixed
- 球坐标/柱坐标扩散面反应原先只写一对 ±1 化学计量，导致两个相邻单元体积不同时通量不守恒；现在每个单元各写一条面反应，按各自体积加权。
- `De` 单位与 time.unit 不同（如 `um^2/s` + `h`）时缺少换算因子；现在按 kb/units.json factor 计算 `conv` 并嵌入速率。
- PDE 输出的 `C[i]` 越界、未知场统计量、2D/非 uniform 网格、非零 Neumann 通量均给出明确错误，而不是静默降级。

### Known limitations
- 仅 1D 规则几何（slab/cylinder/sphere）+ uniform 网格；2D 矩形、非结构网格、自由边界、对流/变张量扩散、DAE+PDE 不在 v1。
- `argmax(C)` 作为标量时间序列输出不支持；需要后处理。
- G3 的 FV n=256 与解析/参考径向解差约 0.5–0.8%（离散误差）；报告应记录网格/收敛，不应宣称与解析解逐位一致。
- PDE 初始/边界只支持 1D 规则网格上的标量 Dirichlet/零通量 Neumann；非零 Neumann 需后续版本。

## [0.6.0] - 2026-11-14

彻底隔离 MATLAB 单线程卡死：把后端拆成 **control server** 与 **heavy worker** 两个独立进程，并修复 0.5.0 遗留的启动/取消边界问题。按 `docs/VERSIONING.md` 记 **MINOR**：工具名与必填参数不变，新增可选 `serverSubdir`、worker health 字段与测试资产。

### Added
- **heavy worker 进程（I1 根治）**：`bma.server.start(workDir, token, struct('serverSubdir','worker/server'))` 在 `<work_dir>/.bma/worker/server` 启动第二个 MATLAB；`matlab_status` 并行启动/检查 control+worker，返回 `worker: idle|BUSY pid=...`、worker queue/last_timeout。重调用（literature/analyze/simulate/fit/identifiability/validation/report/codegen）走 worker，control 保持可响应。
- **worker 生命周期**：`bma_cancel(hard=true)` 默认只杀 busy worker（不等待新 MATLAB 启动，避免 cancel 自己卡在冷启动）；worker 超时同样只杀当前进程，下一次重调用惰性启动新 worker；control 继续 status/kb/run/validate。两个进程使用各自的 `.tmp` pref/temp/home（worker 为 `.tmp/worker-server/`），不共享 prefdir。
- **状态可观测**：`state.json`/`server.info` 增加 `server_subdir`、`last_method`；worker 健康快照独立；`health()` 不再把自身 `server.info` 误报为 BUSY。
- **回归资产**：`bridge/test/worker-isolation.test.mjs`（15 断言：analyze 走 worker、worker 阻塞时 control 138 ms 响应、cancel 只杀 worker、replacement 惰性启动）；`bridge/test/plugin-smoke.mjs` 现在停止 control+worker。

### Changed
- `matlab_status` 超时 240 s，首次并行启动两个 MATLAB（20–120 s）；摘要分 control/worker 两段。
- `bma_cancel` 返回 `worker`/`control` 两份 cancelled/killed/restarts_on_next_call/method/health（不再声称同步重启）。
- `bridge-client` 支持 `serverSubdir`，请求带 `server_subdir`；`_spawnServer` 按 server 角色隔离 runtime 目录；`restart` 清理陈旧 `cancel.flag`，避免下一次重调用被误取消。
- 文档/技能/preset 更新：control+worker 拓扑、worker busy 判读、只杀 worker + 惰性重启、调试路径。

### Fixed
- `bma.server.start` 的 `maxIdleSeconds=0` 被当成“立即 idle 退出”，E2E/长驻服务启动即停；现在 `<=0` 表示不设 idle 超时。
- `tool_layer_e2e.ps1 -StartServer` 在沙箱下 `-batch` 引号/pref 重定向问题；现在用 `ProcessStartInfo` + 独立 pref/temp/home。
- worker 重启后全局 `cancel.flag` 残留导致后续 Sobol 误取消。
- `bma_cancel` 对空闲 worker 也写 cancel flag 的副作用；现在空闲时直接返回。

### Tests
- MATLAB 完整套件 **26/26 PASS（1121.4 s）**；0.5.0 回归 1/1；worker isolation 14/14；插件冒烟 18/18；工具层 E2E 31/31（见 docs/ACCEPTANCE.md §7.10–7.11）。
- 说明：完整套件 1121 s 主要来自 fit/validation 的计算量（单测 `test_validate_suite` 253 s），不是死锁；worker 架构保证这些慢任务不冻结 control。

### Known limitations
- 两个 MATLAB 进程增加内存/启动开销；首次 `matlab_status` 约 20–120 s。
- worker 仍可能被不可中断 builtin 占住；此时只能 cancel/杀 worker，下一次重调用重新启动，丢失该次部分计算，但 control 不受影响。
- SimBiology `.sbproj` 在沙箱下仍按环境限制跳过保存（模型构建成功）。
- 双栏 PDF 栏内重排、PDE 原生 kind、宿主 ACL 仍按 0.5.0 的已知限制处理。

## [0.5.0] - 2026-11-13

按 `tests/fixtures/upgrade/AGENT_ISSUE_buchwald2009.md`（来源会话：无血管胰岛氧输运复现，工作目录 `E:\matlab建模\胰岛`，agent 0.4.0）升级。重点是“卡死可恢复、降级有记录、报告自包含、数值结果可自检”，而不是继续增加模型表达力。

### Added
- **`bma_cancel`（I1/U1.1）**：先写 `cancel.flag`（Sobol/fit 在检查点协作退出），`grace_seconds` 后仍运行则杀进程并重启 MATLAB；返回 `cancelled/restarted/method/health`。工具绕过串行调用队列，因此可以取消正在阻塞的调用。
- **`matlab_status` 健康快照（I1/U1.3）**：新增 `server_alive/busy/current_call/busy_ms/queue_depth/last_timeout/last_error/restarts/workspace_writable`；忙碌时直接返回快照，不再排队等 `server.info`。MATLAB `state.json`/`server.info` 同步记录 busy/current_call/queue/last_call/last_error。
- **analyze 符号难度预判与数值降级（I1/U1.2）**：`steadyStates` 在符号求解前计算静态复杂度（状态数、状态乘积、有理项、幂、超越/护栏函数）；默认 `symbolic_max_states=6`、`symbolic_max_score=12`，超限直接走数值多起点，返回 `analysis.symbolic_skipped/reason/complexity`、`analysis_mode="numeric_fallback"`。数值多起点受 `numeric_budget_seconds`（默认 120 s）限制；仍可用 `symbolic:"on"` 强制。
- **`bma_artifact_import`（I2/I5）**：把 run_dir 外文件/目录复制到 `<run_dir>/artifacts/`，写 `artifacts.json`（name/kind/rel_path/bytes/sha256），用于沙箱里 MATLAB 批处理只能写外部目录的场景。
- **`bma_gate_waive`（I7）**：写 `<run_dir>/gates.json`（gate/reason/substitute/evidence/recorded_at/agent_version）；报告新增“4B. 质量门与豁免（显式记录）”章节，model card 增加 `gates.waivers`，局限性自动引用。
- **报告图片与路径（I5）**：`extra_sections_json` 接受 `.json`/`.md` 文件路径；Markdown `![alt](path)` 渲染为 `<img>`，本地图片复制到 `report/figures/` 并 base64 内嵌，`report.md` 使用相对路径；缺失/远程/不支持图片进入 `warnings`。`collectFigures` 支持 jpg/jpeg/gif/webp 并扫描 `artifacts/`。
- **KB `matlab_pde_toolbox_pitfalls`（I4）**：8 类 decsg/系数/源项/相切/只读 SolverOptions/assembleFEMatrices 静默陷阱，附反应体积、无源检验、方向检验、解析对照的修复写法。
- **KB `numerical_convergence_checklist`（I8）**：收敛≠物理正确；归一化残差、守恒、方向性、解析极限、网格收敛阶与证据落盘清单。
- **双栏 PDF 置信度（I6/U6.2）**：`sectionize` 为每个 section 增加 `section_confidence`（high/medium/low）；ingest 汇总 `section_confidence/low_confidence_sections/low_confidence_ratio`，低置信度时给出明确 warning，提示回 `text.txt` 核对；句级 `sentence_id` 保持可用。
- **回归资产**：`matlab/tests/test_upgrade_050.m`（6 组：analyze 降级、extra_sections 路径/图片、artifact import+RPC、gate waiver+RPC、section confidence、KB 检索）；`bridge/test/resilience.test.mjs`（超时不重试/重启/健康/cancel 9 断言）。

### Changed
- **超时语义（I1）**：`BMA_TIMEOUT` 不再被桥接自动重试；改为重启服务并立即返回结构化 `details{method,timeout_ms,elapsed_ms,restarted:true,retried:false}`。`BMA_SERVER_EXITED/AUTH/START_TIMEOUT` 仍重试一次。新增 `BMA_SERVER_UNHEALTHY`、`BMA_CANCELLED`。
- `bma_model_analyze` 工具摘要显示 `analysis_mode`、`symbolic.skipped/reason/complexity`、numeric budget；`options_json` 文档补齐 symbolic/预算参数。
- `bma_report_build` 的 `extra_sections` 正文/图片/warnings 处理重写；报告图 CSS 支持多种 MIME。
- `run` 布局新增 `artifacts/`；`bma.run.artifact` 支持 `kind="artifacts"`。
- preset persona 与 4 个 skills 更新：G0 沙箱 preflight、G6 数值降级/豁免、G8 超时后先 cancel、G9 artifact import/图片自包含；troubleshooting 增加 ACL/执行策略/PDE 自检。
- `bridge/package.json` 的 `files` 补齐 `lib/version.js`、`lib/rpc-cli.mjs`、`lib/server-keeper.mjs`，避免打包安装时缺文件。

### Fixed
- `extra_sections_json` 传文件路径被工具层当 JSON 解析而报 `invalid ... not valid JSON`（文档承诺与实际不符）。
- Markdown 图片 `![]()` 被渲染成 `<a href>` 链接、报告里看不到图；run_dir 外绝对路径图片不内嵌。
- 符号求解含 min/max 护栏时，候选解只写 `candidates` 未写 `candMethods/candResiduals/candCons`，后续筛选可能下标错位。
- `emptySections` 未包含新增 `section_confidence` 字段，导致 `sectionize` 的 struct 数组赋值报 `MATLAB:heterogeneousStrucAssignment`。
- `matlab_status` 摘要重复打印 `project root`。
- `run.import_artifact`/`run.waive_gate` 的 dispatch 路径与工具层参数名已对齐（测试覆盖）。

### Known limitations
- 双栏 PDF 的**栏内重排**未实现（Text Analytics 不暴露 x 坐标）；0.5.0 只提供低置信度标记与 warning。
- `SetNamedSecurityInfoW failed`/pwsh 执行策略是 DSH 沙箱/主机层问题；agent 提供 preflight、替代工作流与文档，不能代替宿主修复。
- MATLAB PDE 不是 `bma.modelSpec.v1` 原生 kind；KB/自检模板是知识层支持，自建 FEM 仍需 agent 手工执行并导入产物。
- `bma_cancel(hard=true)` 通过重启中止不可中断的 builtin，会丢弃该次调用的部分计算；协作取消只在 Sobol/fit 检查点生效。
- `symbolic:"on"` 仍可能在高维非线性模型上长时间不返回；只建议小模型使用。

## [0.4.0] - 2026-11-12

完成 ISS-12（文献插图/句子级引用），并补齐 ingest 的引用语义。

### Added
- **PDF 位图插图抽取（ISS-12）**：新增 `bma.io.extractPdfFigures`，纯 MATLAB 实现，无需 Python/PDFBox：
  - `DCTDecode` 直接导出 `.jpg`；`FlateDecode` 用 `java.util.zip.Inflater` 解压后导出 `.png`；
  - 支持 8 位 DeviceRGB/DeviceGray/DeviceCMYK/ICCBased、1 位灰度、PNG Predictor 10–15；
  - 支持 `/Indexed` 调色板（数组型 ColorSpace 不再误判为 RGB）；
  - 跳过空白/软掩膜图，限制最多 40 图、单图 25MB；页号按 Page 对象顺序估算，图注用正文 “Fig. N” 做 best-effort 匹配；
  - 明确告警：矢量图、JPX/CCITT、扫描版 PDF 无法在无外部渲染器时栅格化（返回 0 图 + warning，而不是假装成功）。
- **句子级引用（ISS-12）**：新增 `bma.io.sentenceize`，每个 section 增加 `sentences`（`section#sN`、绝对 char_start/char_end），ingest 写 `sentences.json`；句子切分跳过小数（3.5）、常见缩写（Fig./Eq./et al./e.g.）并剔除标题行。
- **数字→句子溯源**：`literature.ingest` 为每个 number 写 `sentence_id`；数字/句子偏移均可回取原文。工具摘要现在显示 section/sentence/figure 与每个数字的 sentence_id。
- **跨行下标符号合并**：`ks\n2 = 3.5e-4` 这类 PDF 断行可恢复为 `ks2`（新增 `symbolAcrossLineBreak`）。

### Changed
- `literature.ingest` 默认对 PDF 抽图（`ExtractFigures=true`，可用选项关闭），产物新增 `figures/`、`figures.json`、`sentences.json`；返回新增 `sentence_count/sentences_path/figure_count/figures_path/figure_warnings`。
- `bma_literature_ingest` 工具描述与摘要更新，明确“位图可抽、矢量/JPX 需外部渲染器”。

### Tests
- 新增 `matlab/tests/test_io_figures.m`：真实 PDF 抽 3 张位图 + 尺寸/清单校验；矢量 PDF 0 图 + 告警；ingest 集成；
- 新增 `matlab/tests/test_io_sentences.m`：93 个句子 id 唯一、偏移可回取、87/87 数字带 sentence_id、跨行 `ks2` 恢复；均 PASS；IO 套件 7/7 通过。

### Known limitations
- 纯矢量图 PDF（如 `s00421-026-06316-4.pdf`）无位图可抽，返回 0 图 + 显式 warning；要栅格化需要外部渲染器（PyMuPDF/PDFBox/Ghostscript），当前环境未安装。
- 图注按 `Fig. N` 与抽取顺序 best-effort 配对；多子图/非连续编号可能错位，引用时应人工核对。

## [0.3.0] - 2026-11-12

按 `tests/fixtures/upgrade/ISSUE_bma_agent_upgrade.md`（来源会话 session-10cc77dd，Mader 2003 肌肉能量代谢复现）升级；重点是“不卡死、不静默丢数据、能表达平衡态模型”。

### Added
- **Algebraic helper variables（ISS-03）**：`variables[].kind="algebraic"`（或 `algebraic:true`）+ `expression`，在编译期按依赖拓扑展开为 states/parameters 表达式后内联到速率/输出；不进入 ODE 状态、S 矩阵与守恒律。支持链式引用与循环检测（`bma:spec:spec_cycle`）；展开长度上限 20k，超出时提示拆分。
- **signed 变量（ISS-09）**：`variables[].signed=true` 的变量不触发“负浓度”告警（ΔG 等热力学量）。
- **Sobol 预算与取消（ISS-01）**：`bma.fit.sensitivity` 默认 `method='local'`；`sobol_n` 默认 64；执行前用一次基准仿真估算 `N*(P+2)` 成本，超过 `budget_seconds`（默认 120 s）直接跳过并返回 `skipped/budget/suggestion`（`force=true` 可强制）；支持 `max_seconds` 总墙钟上限、`max_sample_seconds` 单样本上限、`progress_path` 进度 JSON、`<work_dir>/.bma/server/cancel.flag` 协作取消；超时返回 `partial` 部分结果。ODE 积分增加墙钟 Events 守卫，坏样本快速失败为 NaN。
- **多工况对比图（ISS-10）**：新增 `bma.plot.cases`；`simulate_cases` 现在实际生成 `cases_<id>.png` 并把 `comparison_figure` 写入结果。
- **热力学/功率/压强/质量摩尔浓度单位（ISS-08）**：kb/units.json 新增 J/kJ/J·mol⁻¹/kJ·mol⁻¹/W/W·kg⁻¹/Pa/kPa/mmHg/mol·kg⁻¹/mmol·kg⁻¹ 等维度；核心量纲表支持 energy/power/pressure/molar_energy/specific_power/molality。
- **fit 反馈（ISS-14）**：`solver_info` 每个起点的 sse/exitflag/iterations/converged/seconds 全量返回；参数表工具侧不再截断（最多 50 行），CI/固定/撞界信息保留。
- **profile-on-request（ISS-11）**：`bma_model_identifiability` 传 `options.param` 且有数据时实际执行剖面似然并把 `profile` 结果/路径写入返回；无法执行时明确给出 `profile_requested/profile_reason`。
- 新增 `matlab/tests/test_upgrade_features.m`（aux/signed/units/guards/budget/report extras）覆盖上述能力。

### Changed
- **报告（ISS-04/05）**：`extra_sections` 接受 `{title, markdown/body/content/text/file}` 与文件路径；正文完整渲染进 HTML/Markdown（支持标题/列表/表格/代码/粗体/链接）；多 `evidence` 参数不再崩溃，模型卡与参数表逐条渲染；空正文给出 warning。
- **仿真输出（ISS-06）**：dispatch 的 `timeseries.csv` 现在同时写 states 与 outputs；结果增加 `outputs_final` 与 `series_columns`；仿真图按 `timeseries_<sim_id>.png` 命名，支持 `options.outputs` 选择输出。
- **护栏剥离（ISS-07）**：分析含 min/max 的模型时，对纯数值护栏自动剥离后尝试符号稳态（`guard_substitution.stripped`），数值稳态仍用原始 RHS；可用 `options.substitute_guards` 控制。
- **RPC 健壮性（ISS-02）**：server 启动清理陈旧 inbox/outbox/claims/done 与 cancel.flag；桥接层用 PID 判活（无法探测时仅信任 15 s 内心跳），重启时清理 2 分钟前的陈旧请求；新增桥接 `cancel()`；`matlab_status` 超时 180 s 并在服务死亡时快速重启而非等满超时。
- **bounds 告警（ISS-13）**：`estimate=false` 的参数保留 bounds 不再被建议删除，明确说明其仍用于敏感性/Sobol 抽样。
- **run_dir 一致性（ISS-11）**：fit.estimate/profile/identifiability 均显式使用请求的 run_dir；报告/敏感性/参数表路径回显一致。
- 工具层：`bma_model_sensitivity`/`bma_model_analyze` 增加 `options_json`；sensitivity 摘要显示预算/跳过/取消/部分结果；simulate 摘要显示 outputs_final 与 CSV 列。

### Fixed
- 多 evidence（≥2 条）时 model card 构建崩溃（`struct('evidence', cell)` 被展开为 struct array）。
- `server.info` 在 MATLAB 死亡但心跳未过期时误判存活、导致调用等满超时。
- 内置 ODE 积分无墙钟上限，坏样本可长时间占用 MATLAB。
- `extra_sections` 的 `markdown` 字段被静默丢弃（只写标题）。

### Not included / 已知残留
- **ISS-12（文献 PDF 插图抽取、句子级引用、跨行下标合并）尚未实现**：当前 `literature_ingest` 仍只解析文本/表格，不抽 PDF 位图；建议下一版单独做。已在 issue 记录中标注。
- 代数变量目前仅支持在 `expression` 速率与 output 表达式中使用；不得出现在 `stoichiometry`、mass_action 的 species 列表或作为 ODE 状态。
- 数值护栏剥离只处理“一侧为纯数值常数”的 min/max；非数值护栏（min(x,y)）仍会跳过符号求解并告警。
- 仿真单样本墙钟守卫依赖 ODE Events（MATLAB R2024a 可用）；极端病态模型仍可能在单步内耗时较久，但总 Sobol 成本有上限且可取消。

## [0.2.1] - 2026-11-12

绘图标准化版本（无工具/规格契约变更，PATCH）。

### Added
- 新增 `matlab/tests/test_plot_outputs.m`：覆盖 timeseries / phase / fit / profile / sensitivity 五类图，断言 PNG 合法、分辨率、figure 全部关闭。

### Changed
- 所有报告图统一走 MATLAB 内置图形系统：`figure` + `plot/scatter/barh/area/yline/xline/tiledlayout/nexttile/legend/exportgraphics`；新增 `bma.plot.internal.newFigure/styleAxes` 统一白底、紧凑排版、中文字体自适应（Microsoft YaHei/SimHei 等）与 200 dpi 导出；timeseries/fit 改用 `tiledlayout`，替代 `subplot`。
- 报告 HTML 内嵌图随导出分辨率提高（示例约 120KB → 187KB）。

## [0.2.0] - 2026-11-12

版本纪律与工作区隔离版本。

### Added
- 版本纪律：`VERSION`（SemVer）为唯一来源，`bridge/package.json` 必须一致；`agent_version / bundle_version / spec_schema / matlab_version` 写入 `bma.version()`、`server.ping/info`、每次 `run.json` 与 `matlab_status` 工具输出；新增 `scripts/make_manifest.ps1`（交付文件 SHA-256 清单）、`scripts/check_agent.ps1`（版本/完整性/bundle/后端/工具冒烟自检）、`scripts/update_agent.ps1`（受控版本升级）、`scripts/check_isolation.ps1`（工作区隔离自检）。
- 工作区隔离：运行产物只写会话工作区（`<work_dir>/.bma`、`<work_dir>/.tmp`）；MATLAB 以会话工作区为 cwd，pref/temp/home 重定向到会话工作区；bridge 只写 `<work_dir>/.bma/server`；dispatch 拒绝把运行产物写到工作区之外（`BMA_WORKSPACE_ESCAPE`）。
- 隔离验证：`bridge/test/isolation.test.mjs` 在两个独立临时工作区各跑建模调用，断言产物只落各自工作区、agent 源码哈希零改动、越界 `run_dir` 被拒绝。

### Changed
- `run.json`/`server.info`/`matlab_status` 输出增加版本字段（向后兼容）。
- 文档重写：`docs/VERSIONING.md`（SemVer 语义、发布/回滚、隔离模型、兼容性契约）、`docs/USAGE.md` §8-9、README “版本与工作区隔离”。

### Removed
- 移除只读模式脚本：其 NTFS deny ACE（`(W)` 含 SYNCHRONIZE）曾导致工作区不可读、连带 DSH 启动崩溃；改为上述工作区隔离模型，不再修改文件系统权限。


## [0.1.0] - 2026-11-12

首个可交付版本。

### Added
- MATLAB 计算后端 `matlab/+bma/`：spec（模型规格 v1 校验/单位/量纲）、model（ODE 构建、守恒律、稳态/稳定性、ode15s/45 仿真）、fit（有界多起点参数估计+CI、剖面似然、Sobol/局部敏感性、可辨识性）、validate（AICc 模型选择、交叉验证、残差）、plot、report（自包含 HTML/MD/模型卡）、io（PDF/DOCX/TXT/MD/HTML 解析、数值事实抽取、表格）、run、kb、codegen、simbiology（可选）、server（文件式 JSON-RPC）、util。
- 知识库 `kb/`：13 个机制 archetype、12 条第一性原理、ontology、84 单位表；13 个可直接验证的 spec_template。
- DSH bundle `@local/dsh-bio-matlab`：agent preset「MATLAB 生物系统建模」、15 个 `bma_*` 工具、4 个 skills、MATLAB 桥（自动启动/重试/状态管理）。
- 示例与验收资产：`spec/examples/`（3 个模型+合成数据）、`tests/fixtures/literature/`（3 篇原创文献×5 格式）、`tests/e2e/`（31 项工具层 E2E、headless overlay、桌面人工验收步骤）、`docs/ACCEPTANCE.md`。

### Known limitations
- headless profile 需 `DEEPSEEK_API_KEY`；真实 LLM 正式路径为桌面 preset 会话。
- SimBiology 可选导出：模型构建、`.sbproj` 保存/回读、`sbiosimulate` 可运行；sir 示例数值等价通过，enzyme/goodwin 等价性未达 1e-3（P2 遗留），失败时生成回退 `.mat` + `export_simbio.m`。
- 酶示例数据未覆盖结合瞬态，kf/kr 个体不可辨识（报告如实记录，验收采用派生 Km/Vmax + kcat）。
- 长驻 MATLAB RPC 会话修改 `.m` 后需 `clear functions; rehash`（或重启服务）。
