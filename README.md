# BioModel-MATLAB · 生物系统自主建模智能体（MATLAB 后端）

一个**基于 MATLAB** 的生物领域自主建模 agent：读取给定文献资料，运用**生物系统学**以及相关**数学 / 物理 / 化学生物学**知识，自主提出机制假设、构建数学模型，并用 MATLAB 完成符号分析、仿真、参数估计、可辨识性分析、验证与报告交付。

- 交付形态：**DeepSeek Harness (DSH) agent preset「MATLAB 生物系统建模」 + 独立 MATLAB 计算工程**
- MATLAB 侧负责全部科学计算（R2024a；SimBiology / Symbolic / Optimization / Statistics / Text Analytics / Report Generator 等已授权）
- DSH 侧负责对话编排与大模型推理；两者通过**文件式 JSON-RPC**（无网络端口）连接
- 本项目为独立实现，不引用本地已有的 non-MATLAB agent

```
用户（DSH Web GUI，新建会话选 preset）
      │
      ▼
DSH agent loop（DeepSeek + 生物建模方法论 + 质量门）
      │  bma_* 工具（20 个）
      ▼
bridge（Node 插件）──文件式 JSON-RPC──► MATLAB R2024a 常驻服务
                                          ├─ +spec   规格校验/单位/量纲
                                          ├─ +model  ODE 构建/符号分析/仿真
                                          ├─ +fit    估计/剖面似然/敏感性/可辨识性
                                          ├─ +validate 指标/模型选择/交叉验证/残差
                                          ├─ +plot/+report 图与 HTML/MD 报告
                                          ├─ +io     文献解析(PDF/DOCX/TXT/MD/HTML)
                                          ├─ +kb     生物系统学知识库检索
                                          └─ +codegen/+simbiology 导出
```

## 快速开始

1. 确认已安装 DSH 与 MATLAB R2024a（默认 `C:\Program Files\MATLAB\R2024a\bin\matlab.exe`；工具箱要求见 `docs/USAGE.md`）。
2. 克隆并安装 DSH bundle：

   ```powershell
   git clone https://github.com/yuewu1648-spec/DHS-matlab.git
   cd DHS-matlab
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_bundle.ps1
   ```

   然后在 DSH 会话中执行（需要完全权限）：

   ```text
   plugin_manager install_bundle { "target": "<克隆目录>\\bridge" }
   ```

   `install_bundle.ps1` 会把 `bridge/cordis.patch.yml` 的 skills 路径改成当前检出目录，补齐 bridge 依赖，并检查 MATLAB。
3. 在 DSH Web GUI **新建会话 → 选择 preset「MATLAB 生物系统建模」**。
4. 上传/给出文献路径，输入任务，例如：
   > 阅读 `tests\fixtures\literature\enzyme_kinetics\paper.md`，依据其中的实验数据构建酶动力学数学模型，完成参数估计与验证，输出中文报告。

Agent 会按质量门自动执行：文献解析 → 证据抽取 → 知识库匹配 → 机制假设 → spec 校验 → 结构分析 → 仿真 → 拟合 → 可辨识性 → 验证 → 报告。

无 GUI 的独立 MATLAB 用法见 `matlab/examples/demo_end_to_end.m`；纯工具层验证见 `tests/e2e/`。

## 目录

| 路径 | 内容 |
|---|---|
| `matlab/+bma/` | MATLAB 核心包：spec/model/fit/validate/plot/report/io/run/kb/server/codegen/simbiology/util |
| `matlab/tests/` | MATLAB 单元/集成/契约测试（`run_all_tests.m`） |
| `kb/` | 知识库：13 个机制 archetype + 12 条第一性原理 + ontology + 单位表 |
| `bridge/` | DSH 插件包：20 个 `bma_*` 工具、MATLAB 桥、preset、skills |
| `spec/examples/` | 3 个模型规格样例 + 合成数据 + 真值 |
| `tests/fixtures/literature/` | 3 篇原创验收文献（md/txt/html/docx/pdf）+ 数据 + 期望事实 |
| `tests/e2e/` | 工具层 E2E、headless agent E2E、验收断言 |
| `docs/` | 设计契约、工具参考、使用说明、验收记录、建模方法论 |

## 已实现能力

- **模型规格 `bma.modelSpec.v1`**：变量/参数/反应/输出/单位/证据；5 类速率定律（质量作用、米氏含抑制、Hill 激活/抑制、常数、受限表达式）+ ODE 组装；0.7.0 新增 `kind:"pde"`（1D MOL），0.8.0 新增 2D/3D 原生 PDE Toolbox（`bma_pde_simulate`）。
- **校验与自纠错**：结构化错误码（`BMA_SPEC_*`/`BMA_UNIT_*`/`BMA_RATE_*`）+ JSON 路径 + 修复提示；agent 据此迭代到 `valid=true`。
- **结构分析**：化学计量矩阵、守恒律、稳态、Jacobian 稳定性、量纲检查；高维/高非线性模型自动跳过符号稳态，降级为数值守恒零空间 + 多起点稳态 + 数值 Jacobian（`symbolic_skipped/analysis_mode`）。
- **服务稳定性**：control + heavy worker 双进程；重任务卡死不影响 status/cancel；`BMA_TIMEOUT` 不自动重试、只重启 busy 的 server；`bma_cancel` 协作/硬取消；`matlab_status` 返回两边 busy/queue/last_timeout/workspace_writable 健康快照。
- **仿真**：ode15s/ode45、时间窗/初值/参数覆盖、情景对比、时间序列 CSV 与 PNG。
- **参数估计**：有界多起点 lsqnonlin（失败退 fmincon）、SE/95% CI、R²/RMSE/NRMSE/AICc/BIC/loglik。
- **可辨识性**：灵敏度矩阵秩、Fisher 信息、参数相关/条件数、剖面似然；**Sobol 全局敏感性**。
- **验证**：交叉验证、残差诊断、AICc 模型选择。
- **绘图**：全部使用 MATLAB 内置图形系统（figure/plot/tiledlayout/exportgraphics，200 dpi，中文字体自适应），无外部绘图依赖；报告内嵌 PNG。
- **交付**：自包含 HTML + Markdown 报告（方程、参数证据表、假设、拟合/可辨识性、验证、图、局限、复现命令、质量门豁免）、模型卡、独立 MATLAB ODE 代码、可选 SimBiology 导出；`extra_sections` 支持 `.json/.md` 路径与 Markdown 图片内嵌；`bma_artifact_import` 把外部产物导入 `artifacts/`。
- **文献解析**：PDF/DOCX/TXT/MD/HTML → 章节/数值事实（值+单位+上下文+位置）/表格，带字符偏移溯源；双栏/碎片分节返回 `section_confidence` 警告。
- **知识库**：13 archetype（酶动力学…趋化）+ 14 原理（质量作用、守恒、量纲、QSSA、Hill、Fick、Nernst、热力学、随机性、网络基序、稳定性/Hopf、R0、MATLAB PDE 陷阱、数值收敛自检）+ 单位表 + 本体。

## 版本与工作区隔离

- **版本唯一来源**：`VERSION`（SemVer）、`bridge/package.json`、`CHANGELOG.md`、`MANIFEST.sha256`（交付文件 SHA-256）。
  agent 版本会写入 `run.json`、`bma.version()`、`matlab_status` 工具输出，研究项目可据此记录“用哪个版本建了什么模型”。
- **更新纪律**：任何影响工具/规格/产物的改动 → 升版本 + CHANGELOG + 重新安装 bundle + `scripts\check_agent.ps1` 自检。
  流程见 [docs/VERSIONING.md](docs/VERSIONING.md)。
- **工作区隔离**：agent 目录是“安装目录”，运行期不会被写入；每次建模的产物只写到**会话工作区**的
  `<work_dir>/.bma/`（runs、server 状态）与 `<work_dir>/.tmp/`（MATLAB pref/temp/home）。MATLAB 进程以会话目录为
  cwd，知识库/源码只读加载；不同工作区互不干扰（各自独立的 run 目录与 MATLAB 服务），越界写入会被拒绝
  （`BMA_WORKSPACE_ESCAPE`）。
- **隔离自检**：`scripts\check_isolation.ps1` 在两个独立临时工作区各跑一次建模调用，断言产物只落在各自工作区、
  agent 源码零改动、越界路径被拒绝。
- **完整性校验**：`scripts\check_agent.ps1`（版本一致性、MANIFEST、bundle 安装、MATLAB 后端、工具插件冒烟）。


## 0.12.0（PDF 矢量插图 PyMuPDF）

- `bma.io.extractPdfFigures` 默认走 **PyMuPDF**：提取嵌入位图，并把 figure-sized 矢量 drawing 聚类渲染为 `vector_render` PNG；返回 `figure_class=bitmap|vector|vector_or_mask|mixed`、`rasterized`、`renderer`。
- 无图幅级矢量区域时标记 `figure_class=vector, reason=no_figure_region`；`render_pages=true` 可降级为整页渲染。
- PyMuPDF/Python 不可用时回退纯 MATLAB 位图解析器（明确 warning）。
- 回归 fixture：`tests/fixtures/upgrade/pdf/vector_figure.pdf`；`test_io_figures` 验证 890×723 矢量渲染。

## 0.11.0（NatRevMolCellBiol 复现 issues 修复）

- **DDE**：修复 `ddesd/ddensd` “过去时刻 vs 延迟”约定；常量表达式延迟自动走 `dde23`；DDE fit/profile/codegen。
- **相图**：`phase_x/phase_y` 支持 species id；新增 `phase3d`/`phase_z`；dispatch 不再静默不产图。
- **fit**：补 `timeGuard`；wall-clock 超时转 fmincon；多起点默认至少 4 个起点；`multistart_diagnostics`；拟合图写入各 fit 目录。
- **PDF**：`figure_class=bitmap/vector/vector_or_mask`、`rasterized/reason`；文件字节仅提示，文本截断按字符数报告；公式编号占位符告警。
- **其他**：DDE `units applicable=false`、profile `param` 别名、`cases_summary.csv`、`time.unit="1"`、长 CJK 标签短轴/标题换行、模型选择候选预算+partial、振荡 period/amplitude 指标。
- 已知未做：ISSUE-012B 参数延拓/不稳定分支；ISSUE-002 属 DSH/Windows ACL 环境；ISSUE-014/015/016/017 为文献数据与流程层，已写入 report skill 的复现矩阵/降级规则。

## 0.10.0（DDE 全谱 / BVP fit / 全隐式 DAE / SSA）

- **DDE**：常量 `dde23`；状态/时间依赖延迟 `ddesd`（`delays[].expression`）；中性型 `ddensd`（`dde_mode:"neutral"` + `delay_deriv(S,tau)`）。DDE 现在可 fit/identifiability（仿真目标+有限差分）并生成独立代码。
- **BVP**：一维 `bvp4c` 支持 `bma_model_fit`/`bma_model_identifiability`（空间剖面数据）。
- **DAE**：新增 `kind:"dae"`（`dae.residuals` + `decic` + `ode15i`）；质量矩阵 DAE 可带 `mass_matrix` 拟合。
- **SDE/SSA**：`bma_advanced_solve` 增加精确 Gillespie SSA（`method:"ssa"`），保留 Euler-Maruyama `sde`。
- **仍不做**：任意 CAD/各向异性/非线性高级 PDE、PDE 特征值、任意高阶 DAE（需人工 index reduction）。
- 测试：DDE/BVP/DAE/advanced 均有新增回归；完整套件见 `docs/ACCEPTANCE.md`。

## 0.9.0（DDE/BVP/DAE/系统辨识/符号解/SDE）

- **DDE**：`kind:"dde"` + `delays:[{id,lag,unit}]`，速率写 `delay(S,tau)`；`bma_model_simulate` 用 `dde23`。延迟单位必须与 `time.unit` 一致；v1 只支持 expression 速率。
- **BVP**：`kind:"bvp"` + `domain:{x0,x1,n}` + `bc`；`bvp4c` 解边值问题。BC 数量必须等于变量数。
- **DAE**：`bma_model_simulate` 的 `options.mass_matrix` 走 `ode15s` 质量矩阵；奇异矩阵按线性隐式 DAE 处理，初值需满足代数约束。
- **`bma_advanced_solve`（第 20 个工具）**：
  - `system_id`：CSV + `tfest`/`ssest`/`arx`；
  - `symbolic`：`dsolve` 闭式解；
  - `sde`：Euler-Maruyama 随机模拟。
- **不支持**：任意 CAD/各向异性/非线性高级 PDE、PDE 特征值、任意高指数 DAE；DDE/BVP 不进入 fit/identifiability/codegen（会明确报错）。
- 回归：DDE/BVP/DAE/advanced 四个新测试；完整套件见 `docs/ACCEPTANCE.md`。

## 0.8.6（经典形式图：极限环相图）

- **自动经典图**：2 状态/2 输出模型 `bma_model_simulate` 自动同时生成 timeseries 与 phase；`options_json` 支持 `plots:["phase"]`、`phase_x`/`phase_y`，3 状态以上可显式投影。
- **极限环**：`bma.plot.phase` 默认丢弃前 40% 瞬态，在尾部找最后一个平均穿越周期，白色细线为完整轨迹，粗蓝线为极限环，并标“极限环（后段闭合）”；检测不到周期时标“后段轨迹”，不硬说极限环。
- **经典形式规则**：振荡/极限环→相图；剂量响应→剂量-响应曲线；双稳/开关→相图/稳态；酶动力学→v-S/抑制曲线；时空 PDE→场快照；不要只用通用时间序列替代经典图。
- **去重**：沿用 0.8.5 的 report 内容哈希去重，同一经典图只出现一次，§11 与 extra sections 不重复。
- 测试：Selkov 极限环相图 + dispatch 自动 2 图；完整套件 **29/29 PASS（456.4 s）**。

## 0.8.5（report 图片去重与自适应宽度）

- **重复图修复**：`collectFigures` 不再扫描 `report/figures`（extra section 的输出副本）；extra section 已引用的图片按源路径 + 内容 SHA-256 从 §11“图表”排除；同一图片即使换名/换目录出现也只嵌入一次。
- **大图溢出修复**：全局 `img{max-width:100%;height:auto;}`；Markdown 表格 `table-layout:fixed` + `td img{max-width:100%}`，并排原图/复现图不会撑破 1080px 页面。
- **测试**：`test_report_images.m` 用 shared + 同名副本 + 独立图验证唯一 data URI、§11 不重复、CSS 约束；PASS。
- 旧报告不会自动变化，需要重新调用 `bma_report_build` 生成。

## 0.8.4（文献图复现）

- **G1**：除逐字证据表外，读 `figures/figures.json`/图注，登记每张图/panel 的 caption、page、图片路径、x/y 轴/单位、条件、报道趋势/数值；无法抽图标注“原图不可得”。
- **G2.5**：先于建模/仿真挑出必复现 panel，写明模型输出与判据（digitized 点 RMSE/相对误差/R²，或定性方向/排序/峰值时间）；示意图/方法图可标“不复现”。
- **G7**：仿真条件对齐文献图（时间窗/剂量/空间范围/单位），在 `<run_dir>/figures/reproduction/` 生成相同坐标/图例/轴范围的对照图。
- **G9**：报告必须有“文献图复现”矩阵，原图/复现图并排，逐 panel 给状态（quantitative/qualitative/not_reproduced）与局限；失败 panel 也要列出，不能只报成功的图。
- 没有 digitized 数据时只能标 qualitative，不得写“定量一致”；原图不可得/矢量图未栅格化要如实说明。

## 0.8.3（MATLAB 后端空闲自动回收）

- 每个 work_dir 的 control/worker 对在最后一次 `bma_*` 调用后启动空闲计时；默认 **300 s** 无调用即自动 `stop()` 两个 MATLAB 进程并删除 bridge 对，下一次调用按需重启。
- 环境变量 `BMA_IDLE_SHUTDOWN_SECONDS` 可调（上限 3600；`0` 关闭）；计时器 `unref()`，不会单独拖住 DSH。
- DSH 插件 dispose 时也会停止所有已知 MATLAB 后端，避免 DSH 退出后的孤儿进程。
- 自动关闭是正常资源回收，不是错误；工具说明/preset G0/G9 已明确不要手动 `taskkill` MATLAB。
- 测试 `bridge/test/idle-shutdown.test.mjs`：2 s 空闲值启动真实 control+worker，两者自动退出，**PASS**。

## 0.8.2（求解器前置门：A2 雅可比方向导数 + A3 方程残差）

按 `E:\matlab建模\胰岛\NUMERICAL_PITFALLS.md` 的 A2/A3 把两条检查前置到**写任何求解循环之前**（只放实现层检查，不含模型/复现结论）：

- **A2**：`eps=1e-8*max(1,norm(u))`、`du=randn(n,1)`、`rng(0)`；`err=||R(u+eps*du)-R(u)-eps*J*du||/||R(u+eps*du)||`；目标 `<1e-8`，`1e-8~1e-5` 复测，`>1e-5` 判失败。J 与 R 必须同源（同一套单元/权重/符号）。
- **A3**：只以归一化方程残差 `||R(u)||/max(||F||,||K||*||u_ref||,realmin)` 验收，`<=1e-6` 才接受；正性钳位/截断后重算 `R(u_clamped)`；禁止用 `||u_new-u||`、`|r|/c_amb` 或单纯 exitflag。
- 两项写入 `artifacts/solver_preflight.json`；预检失败时禁止写循环、禁止参数扫描/拟合。PDE Toolbox 内置 `solvepde` 无自定义 J 时，A2 用制造解/无源解析对照，A3 仍用残差/制造解误差。
- preset 新增 G6.5；`bio-modeling-workflow` 增加步骤 6.5；`matlab-modeling-troubleshooting` 增加 0.8.2 模板；KB 两原则更新为 0.8.2。

## 0.8.1（任务列表纪律修复）

- 复现任务结束时任务列表仍显示 pending/in_progress：会话日志确认 agent 只在开头调用一次 `todo_write`，后续从未更新；DSH todo projection 按“整表替换、turn/end 保留最后快照”工作，所以旧列表一直可见。
- preset 新增强制纪律：G0 前建表；每个质量门后重发**完整列表**；失败/跳过项改成 `completed` 并注明原因或删除；**最终回答前必须最后一次 `todo_write`，确认 `0 pending, 0 in progress`**。
- `bio-modeling-workflow` skill 增加步骤 0（建表）与步骤 13（收尾清零）。PATCH 版本，工具面/模型规格/MATLAB 后端不变。

## 0.8.0（原生 PDE Toolbox：不再强制 MOL）

按“应该在 PDE 求解、预算许可时就用 PDE Toolbox”的要求新增原生后端：

- **`bma_pde_simulate`（第 19 个工具）**：`kind:"pde"` + `pde.dim=2|3` + `pde.solver="toolbox"`，直接 `createpde → generateMesh → specifyCoefficients → applyBoundaryCondition → solvepde`；不展开成 ODE。
- **几何**：2D `rectangle`/`circle`/`polygon`；3D `box`（结构化四面体）或 `stl`（`domain.file`，需有效闭合几何；CI 覆盖 box）。网格 `hmax/hgrad`，预算 `max_dof/max_seconds`。
- **物理**：多组分对角扩散（`c` 列向量）、局部反应源项 `f=S*rates`（五类速率）、Dirichlet/零通量 Neumann；2D `edge`、3D `face`。
- **输出**：`pde.probes` 观测点时间序列、`field_stats` max/min/mean/integral、CSV、PNG；`max_dof` 超限直接拒绝并提示增大 `hmax` 或降维。
- **决策规则**：1D / 需要 fit/identifiability/analyze → MOL；真正 2D/3D / 非规则几何 / 场输出且预算允许 → PDE Toolbox；原生结果不能直接喂 `bma_model_fit`/`bma_model_identifiability`。
- **验收**：`test_pde_toolbox.m` 覆盖 2D rectangle 瞬态、双组分、circle、3D box、预算门；`plugin-smoke` 19/19 工具并实际跑通 2D 原生调用。

限制：非零 Neumann、对流/各向异性张量 `c`、移动边界、DAE+PDE、原生参数拟合仍不在本版；3D 复杂几何需 STL。

## 0.7.0（PDE：`kind:"pde"` + 1D MOL 编译器）

按 `E:\matlab建模\生物膜\issues\0001-bma-pde-support.md` 实现。核心是“PDE spec → MOL ODE spec”编译器，而不是替换求解器：

- **kind="pde"**：1D 规则几何 `slab` / `cylinder` / `sphere`，uniform 网格，各向同性标量扩散，Dirichlet/零通量 Neumann；编译期展开为节点 ODE（`C_1..C_n`），下游 simulate/fit/identifiability/validate/report 零改动复用。
- **输出与初值**：`C[i]`、`max/min/mean/mean_over_domain/integral(C)`；`initial.param`/`initial.expression`（Gap A）不再静默变成 0。`argmax(C)` 明确不支持。
- **单位与时间**：`De` 按 length²/time 转换到 `extent.unit²/time.unit`（如 `um^2/s` + `h`），`time` 恒为真实时间；PDE 量纲检查复用扩展后的 ODE spec。
- **报告/模型卡**：新增“2B. PDE 离散与边界条件”，记录 geometry/grid/BC/approximation；`m.pde` 记录 `n/dx/faces/expander_version/sha256`；codegen 额外生成 `<name>_pde.m` 元数据文件（积分仍用 `_ode.m`）。
- **验收**：G1/G2 slab 解析值、G4 Monod 柱 C1/C16/mu 与参考 run 一致（0.5% 内）；G3 sphere 用 n=256 FV 收敛到解析比值（2% 内）。新测试 `matlab/tests/test_model_pde.m` 1/1。

## 0.6.0（control + heavy worker：彻底隔离单线程卡死）

把 MATLAB 后端拆成两个进程，解决“一个 builtin 卡住，整个会话跟着卡”的结构性问题：

- **control server**：`.bma/server`，只跑 status、kb、run、spec.validate、model.build 等轻调用；**heavy worker**：`.bma/worker/server`，跑 literature/analyze/simulate/fit/identifiability/validation/report/codegen。
- worker 卡在 `vpasolve`/病态 `ode15s`/长 `fit` 时，control 仍能 `matlab_status`/`bma_cancel`；`bma_cancel(hard=true)` 默认只杀 busy worker（下一次重调用惰性启动新 worker，cancel 本身不会卡在冷启动），control 继续可响应。两个进程使用各自的 pref/temp/home，互不污染。
- `matlab_status` 并行预热/检查两者，输出 `worker: idle|BUSY`；首次约 20–120 s，之后复用。`state.json` 增加 `server_subdir/last_method`。
- 新增 `bridge/test/worker-isolation.test.mjs`：证明 analyze 实际走 worker、worker 阻塞时 control 138 ms 响应、cancel 只杀 worker、replacement 惰性启动、control 存活。

## 0.5.0（稳定性、报告图片、PDE 自检与质量门豁免）

按 `tests/fixtures/upgrade/AGENT_ISSUE_buchwald2009.md`（无血管胰岛氧输运复现）升级，重点是“不卡死、失败可恢复、降级有记录”：

- **超时/卡死恢复**：`BMA_TIMEOUT` 不再自动重试；桥接重启目标 server 并返回结构化 `details`。新增 `bma_cancel`（协作取消 + 硬重启）、`matlab_status` 健康字段（busy/queue/last_timeout/workspace_writable），后续调用不再排在一个卡死的符号求解后面。
- **analyze 符号难度预判**：状态数 > 6 或静态非线性 score > 12 时跳过 `solve/vpasolve`，改用数值守恒零空间 + 多起点稳态 + 数值 Jacobian；返回 `symbolic_skipped/reason/analysis_mode`。G6 不再因符号不可解而永久失效。
- **质量门豁免**：新增 `bma_gate_waive`，把 gate/reason/substitute/evidence 写入 `gates.json`；报告新增“质量门与豁免”章节，model card 记录 `gates`。
- **报告图片/外部产物**：`extra_sections_json` 真正接受 `.json`/`.md` 路径；Markdown `![]()` 渲染为 `<img>` 并 base64 内嵌；缺失/远程图片进 warnings。新增 `bma_artifact_import` 把 run_dir 外产物导入 `artifacts/`（SHA-256 登记），报告自动收集。
- **PDE/数值自检 KB**：新增 `matlab_pde_toolbox_pitfalls` 与 `numerical_convergence_checklist`，覆盖 decsg 空洞、系数方向、源项符号、残差归一化、解析对照/网格收敛。
- **双栏 PDF**：`literature_ingest` 新增 `section_confidence/low_confidence_*`；分节不可靠时明确 warning，句级 `sentence_id` 仍可用。

## 0.4.0（文献插图与句子级引用）

- `bma_literature_ingest` 现在输出 **figures/`figures.json`**（PDF 内嵌位图，DCT/Flate/索引调色板）与 **sentences.json**（`section#sN` 引用 id，带字符偏移）。
- 每个抽取数字带 `sentence_id`，可直接引用到句；跨行下标（`ks`⏎`2`）合并为 `ks2`。
- 纯矢量/JPX/扫描 PDF 无位图可抽时返回 0 图 + 明确 warning（当前环境无外部 PDF 渲染器）。

## 0.3.0（issue 驱动升级，摘要）

按 `tests/fixtures/upgrade/ISSUE_bma_agent_upgrade.md` 修复 13/14 项：Sobol 预算/取消（不再卡死）、陈旧 RPC 快速恢复、代数辅助变量（ISS-03）、报告正文与多证据（ISS-04/05）、仿真输出入 CSV（ISS-06）、min/max 护栏剥离（ISS-07）、热力学/功率/压强/质量摩尔浓度单位（ISS-08）、signed 变量（ISS-09）、cases 对比图（ISS-10）、run_dir/profile 路径（ISS-11）、bounds 告警（ISS-13）、fit 反馈（ISS-14）。**ISS-12（PDF 插图/句子级引用）仍未实现**。详见 [CHANGELOG.md](CHANGELOG.md) 与 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) §7.8。

## 文档

- [docs/DESIGN.md](docs/DESIGN.md) — 架构、模型规格、RPC 协议、模块契约、验收标准
- [docs/USAGE.md](docs/USAGE.md) — 安装、preset 使用、故障排查、手动验收步骤
- [docs/TOOL_REFERENCE.md](docs/TOOL_REFERENCE.md) — 19 个 bma_* 工具与 MATLAB 方法参考
- [docs/MODELING_METHODOLOGY.md](docs/MODELING_METHODOLOGY.md) — agent 的建模方法论与质量门
- [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md) — 验收矩阵、测试与限制
- [docs/VERSIONING.md](docs/VERSIONING.md) — 版本语义、发布/更新流程、工作区隔离、回滚与兼容性契约
- [kb/README.md](kb/README.md) — 知识库格式与覆盖矩阵

## 验证状态（2026-11-13）

| 验证层 | 结果 | 证据 |
|---|---|---|
| MATLAB 完整测试套件（fresh `matlab -batch`） | **38/38 PASS（736.1 s）** | `matlab/tests/run_all_tests.m`；含 spec/model/io/kb/fit/validate/report/integration/upgrade/PDE MOL/原生 PDE Toolbox/report 图片回归/经典相图/DDE 全谱/DAE/BVP/系统辨识/符号解/SDE/SSA/cases 汇总/模型选择 partial/无量纲时间/拟合图隔离/PyMuPDF 矢量图；拟合类测试较慢但全部有限完成 |
| 0.6.0 worker 隔离 | **15/15 PASS** | `bridge/test/worker-isolation.test.mjs`：analyze 走 worker、worker 阻塞时 control 138 ms 响应、cancel 只杀 worker、replacement 惰性启动 |
| 0.8.3 后端空闲回收 | **1/1 PASS** | `bridge/test/idle-shutdown.test.mjs`：2 s 空闲后 control+worker 均退出；`ctx.effect` dispose 清理 |
| 0.8.5 report 图片去重/宽度 | **1/1 PASS** | `matlab/tests/test_report_images.m`：shared/同名副本/独立图 → 3 个唯一 data URI；§11 不重复；全局 max-width + md fixed table |
| 0.8.6 经典形式/极限环 | **1/1 PASS** | `test_plot_outputs.m`：Selkov 极限环相图 163 KB；2 状态 dispatch 自动 timeseries+phase |
| 0.9.0 DDE/DAE/BVP/高级求解 | **4/4 PASS** | `test_dde_simulate`、`test_dae_mass`、`test_bvp_simulate`、`test_advanced_solve` |
| 0.10.0 DDE 全谱/隐式 DAE/SSA | **5/5 PASS** | ddesd/ddensd + DDE fit/ident/codegen；BVP fit/ident；`test_dae_implicit`；SSA |
| 0.11.0 复现 issues | **5/5 PASS** | DDE 表达式等价、phase species/phase3d、fit 图隔离、cases 汇总、模型选择 partial、无量纲时间 |
| 0.12.0 PyMuPDF 矢量图 | **1/1 PASS** | vector_figure.pdf → 890×723 vector_render；真实综述 PDF 18 figures（mixed） |
| 0.7.0 PDE/MOL 黄金值 | **1/1 PASS** | `matlab/tests/test_model_pde.m`：G1/G2 slab、G3 sphere、G4 Monod 柱；`initial.param`；PDE 报告小节 |
| 0.8.0 原生 PDE Toolbox | **1/1 PASS** | `matlab/tests/test_pde_toolbox.m`：2D rectangle/双组分/circle、3D box、预算门；`plugin-smoke` 19/19 并跑通 2D 原生调用 |
| 0.5.0 回归（analyze 降级/报告图片/artifact/gate/section confidence/KB） | **1/1 PASS** | `matlab/tests/test_upgrade_050.m`，6 组断言；`bridge/test/tool-params.test.mjs` PASS（路径当 JSON 的回归） |
| 桥接超时/取消/健康 | **11/11 PASS** | `bridge/test/resilience.test.mjs`：超时 8.9 s 内被杀且不重试、replacement 惰性启动、`bma_cancel` 后调用 `BMA_CANCELLED`、服务可复用 |
| 集成测试（4 文件：契约/文献/拟合工具面/全链路） | **4/4 PASS** | `matlab/tests/test_integration_*.m`；3 模型 × 8 步全链路，参数恢复 R²≥0.999 |
| 工具层 E2E（原有 15 个 `bma_*` 等价 RPC，31 项断言） | **31/31 PASS** | `tests/e2e/artifacts/tool-layer-20261114-003431/summary.md`；0.6.0 下 control server 直连复跑 |
| 插件冒烟（19 个工具 + control/worker） | **PASS** | `bridge/test/plugin-smoke.mjs`：19/19 注册、status 报告 worker idle、2D PDE Toolbox 原生调用成功 |
| DSH 插件挂载（headless profile） | **PASS**（无 "entry did not activate"） | `tests/e2e/headless.mount.patch.yml` |
| 独立 MATLAB 全链路 demo | **PASS** | `matlab/examples/demo_end_to_end.m` |
| 真实 LLM 端到端 | 需 DSH 会话（人工 2 分钟） | `docs/USAGE.md` §5、`tests/e2e/desktop_preset_acceptance.md` |
| 版本纪律 / 工作区隔离 | **已实现并自检** | `VERSION`+`CHANGELOG.md`+`MANIFEST.sha256`；`scripts\check_agent.ps1`、`scripts\check_isolation.ps1`；见 [docs/VERSIONING.md](docs/VERSIONING.md) |

已修复的关键缺陷：dispatch 包函数探测（`which` 替代 `exist`）、server.ping 结构体空展开、JSON 递归序列化、请求抢占与 state 原子写、文献解析 `\b`/连字/DOCX 表格、拟合多起点与报告 struct-array、守恒律整数基与稳态物理筛选、SimBiology 模型构建等。

**已知限制**：
- 0.6.0 起常驻两个 MATLAB 进程（control + worker），内存/首次启动开销增加；首次 `matlab_status` 约 20–120 s。
- worker 仍可能被不可中断 builtin 占住；`bma_cancel(hard=true)` 只杀 worker，下一次重调用重新启动，会丢弃该次部分计算，但 control 不受影响。
- SimBiology（可选交付项）：模型构建、`.sbproj` 保存/回读、`sbiosimulate` 仿真均可用；sir 示例数值等价性通过（3.5e-5），enzyme/goodwin 的等价性未达 1e-3（P2，疑为中间物种/初值映射差异），失败时生成回退产物 `<name>_simbio_model.mat` + `export_simbio.m`，桌面 MATLAB 可直接打开/仿真/另存。
- headless profile 不读桌面登录凭据，自动化真实 LLM 验收需 `DEEPSEEK_API_KEY`；正式路径为桌面 preset 会话。
- 酶示例进度曲线采样 t≥5 s，未覆盖 ~0.2 s 结合瞬态，故 `kf/kr` 个体不可辨识（验收采用派生 `Km/Vmax` + `kcat`，并在报告中记录该局限）。
- 双栏 PDF 的**栏内重排**仍未实现（Text Analytics 不暴露 x 坐标）；0.5.0 只提供 `section_confidence`/warnings 降级标记，引用 section/heading 时需回 `text.txt` 核对。
- PDE 路径：0.7.0 的 1D MOL 仅支持规则几何/uniform 网格；0.8.0 原生 PDE Toolbox 支持 2D rectangle/circle/polygon 与 3D box/STL，但不支持非零 Neumann、对流/各向异性张量 c、移动边界、DAE+PDE；原生路径不做参数拟合/可辨识性。`argmax(C)` 作为标量输出不支持。
- `SetNamedSecurityInfoW failed`/pwsh 执行策略属于 DSH 沙箱/主机层问题；agent 提供 preflight 提示与替代工作流（write/bma_*、`bma_artifact_import`），不能替代宿主修复。
- `bma_cancel(hard=true)` 通过重启 MATLAB 中止不可中断的 builtin，会丢弃该次调用的部分计算；协作取消只在 Sobol/fit 等检查点生效。
- MATLAB 长驻 RPC 会话中修改 `.m` 后需 `clear functions; rehash`（或重启）才能加载新代码。

## 许可

本项目以 [MIT License](LICENSE) 发布，Copyright (c) 2026 yuewu1648-spec。

