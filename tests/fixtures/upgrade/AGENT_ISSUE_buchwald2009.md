# Agent Issue：生物建模会话中暴露的工具链与工作流缺陷（含"卡死"事故）

| 项 | 内容 |
|---|---|
| 任务 | 复现 Buchwald P. (2009) *Theor Biol Med Model* 6:5 —— 无血管胰岛氧输运的 FEM 模型 |
| 会话产物 | `run_dir = .bma/runs/r-20261113-101335-420-d091bb`；文献 doc_id `pde-pmc2678100-c7b5151c8a` |
| 环境 | Windows / MATLAB R2024a 24.1.0.2537033；沙箱 workspace-write；工作目录 `E:\matlab建模\胰岛` |
| 实际耗时 | ≈ 4 小时（其中 **≈ 55 分钟消耗在两类"卡死/无法继续"上**） |
| 撰写人 | 执行该任务的 agent（本文是自述，包含 agent 自身的失误） |

---

## 0. 一句话摘要

本次任务最终完成了定量复现（六个报告值中五个吻合到 7 个百分点内），但路径上踩了三类**会让 agent 失去行动能力**的坑：**(A) 沙箱/权限使 pwsh 与 MATLAB 批处理完全不可用；(B) `bma_model_analyze` 把单线程 MATLAB 服务锁死，并连带让后续调用排队超时；(C) MATLAB PDE 工具箱存在一批"能跑、会收敛、但结果是错的"静默陷阱。** 其中 (B) 是用户直接观察到的那次"卡死"，也是本文的重点。

---

## 1. 严重度总览

| ID | 问题 | 严重度 | 本次损失 | 是否可自愈 |
|---|---|---|---|---|
| I1 | `bma_model_analyze` 锁死 MATLAB 服务，连带后续调用排队超时 | **P0 卡死** | ≈ 40 min，且 G6 质量门永久失效 | 否，只能重启 |
| I2 | `.bma/` 目录对 pwsh/MATLAB 子进程不可写 | **P0** | 产物被迫外置，工作流被打碎 | 否 |
| I3 | 沙箱 ACL 缺陷使 pwsh 100% 不可用 | **P0** | ≈ 20 min | 需人工审批 |
| I4 | MATLAB PDE 工具箱静默错误陷阱簇（6 类） | P1 | ≈ 90 min | 是，但无提示 |
| I5 | `bma_report_build` 的图片与 `extra_sections` 路径处理 | P2 | ≈ 15 min | 否 |
| I6 | 双栏 PDF 分节/句级溯源错位 | P2 | 引文归属不直观 | 否 |
| I7 | 强制质量门缺少"计算上不可行"的豁免机制 | P1 | 直接引发 I1 | — |
| I8 | 知识库缺少"数值收敛不等于解正确"的检查清单 | P2 | 反覆犯同类错误 | — |

---

## 2. I1【P0·卡死】`bma_model_analyze` 锁死服务，后续调用雪崩

### 2.1 现象（时间线，可复现）

1. 8 状态耦合非线性 ODE 模型（球壳氧输运）`bma_model_validate` → `valid=true`，一切正常。
2. 按工作流 G6 调用 `bma_model_analyze`。**调用在 600 s 后返回 `Error: tool call timed out after 600000ms`。**
3. 立刻改用轻量的 `bma_model_simulate`（该模型单次仿真实际只需秒级），**同样在 900 s 后超时**。
4. 此时 `matlab_status` 显示 `rpc pid` 由 `33516` 变为 `34172`——**服务是重启过的，说明先前那次调用把 MATLAB 卡死到了无法回收的程度**。
5. 重启后，同一个 `bma_model_simulate` 调用**秒级返回正确结果**（`c_core = 0.18616 mol/m³`，与独立 MATLAB 校验一致）。

### 2.2 根因分析

- `bma_model_analyze` 尝试对 8 个状态、含 `c/(c+K)` 有理非线性 + 耦合交换项的稳态方程做**符号求解**（Symbolic Math `solve`）。这类方程组没有闭式解，符号引擎进入不可判定的搜索。
- **MATLAB 服务是单线程的**，符号求解不响应中断 → 后续所有 RPC 调用只能排队 → 表现为"连一个 2 秒的仿真也超时"。
- **排队与运行对调用方不可区分**：两次超时的错误文案完全相同（`tool call timed out`），agent 无法判断是"算得慢"还是"服务已死"，因此浪费了一次 900 s 的盲目重试。
- 没有取消令牌：agent 无法中止一个已经开始的重任务。

### 2.3 影响

- 直接损失 ≈ 40 min。
- **G6（结构分析）在本任务中永久缺失**；连带的 G8 `bma_model_identifiability` 也因此没敢运行，报告里的可辨识性结论**降级为敏感性矩阵的弹性证据**。这是"卡死"造成的实质科研损失，而不只是浪费时间。

### 2.4 升级建议（按优先级）

**U1.1 强制看门狗 + 可取消（P0）**

- 每个 `bma_*` 调用在服务端带 **deadline**，超时由服务自己 `dbstop`/中断并返回 `BMA_TIMEOUT`（结构化错误码 + 已运行时长 + 建议的降级选项），而不是让调用方从外部硬超时。
- 提供 `bma_cancel(run_id)`：能打断当前重任务，且能被后续调用复用同一 MATLAB 进程。
- 单线程队列必须能"排空"：一个任务被判超时后，队列中其余请求应立即失败并报告"服务不健康"，而不是各自再等 600 s。

**U1.2 `analyze` 的难度预判与优雅降级（P0）**

- 进入符号求解前先估计难度（状态数 × 非线性项数；有理式是否可解），超过阈值时**跳过符号稳态**，改为返回：
  - 守恒律（数值零空间，`null(S)`，O(n³) 且永远可算）；
  - 稳态（数值 Newton，多个初值）；
  - Jacobian 特征值（数值）。
- 输出中显式写明"符号稳态求解已被跳过，原因 / 替代结果"。

**U1.3 健康度可观测（P1）**

- `matlab_status` 增加：`busy_since`、`current_call`、`queue_depth`、`last_timeout`。
- 让 agent 能区分"忙"与"死"，这条几乎零成本、收益极高。

**验收标准**
- 对一个刻意无闭式解的 10 状态模型，`bma_model_analyze` 在 ≤ 60 s 内返回"符号部分跳过 + 数值替代结果"，服务保持可用，后续 `simulate` 正常。

---

## 3. I2【P0】`.bma/` 对子进程不可写，产物被迫外置

### 3.1 现象

- `pwsh` 写 `.bma/runs/.../code/fem/dbg1.m`：`Set-Content : Access to the path ... is denied` + `[sandbox: file access denied under workspace-write mode]`。
- MATLAB 批处理 `save('...\.bma\runs\...\fig12_h1mm_H12.mat')`：`无法写入文件 ...：权限被拒绝`。
- 但 **`write` 工具可以正常写入同一目录**（agent 自身写 spec/代码没问题）。

### 3.2 影响

- agent 启动的 MATLAB 批处理**无法把 .mat / .png 落在自己的 run_dir**，被迫改用 `E:\matlab建模\胰岛\fem_out\`。工作流文档里"所有产物在 `<run_dir>`"的约定被破坏。
- 更隐蔽的连锁：报告里的图片因此是 run_dir **之外**的绝对路径，见 I5。

### 3.3 升级建议

- **U2.1** 明确 `.bma` 对 agent 启动的子进程（pwsh / matlab batch）可写，或
- **U2.2** 引入官方概念 `external_artifact_dir`：run_dir 下放一个指针文件，`bma_report_build` 据此把外置产物**拷贝进报告包**（顺带解决 I5 的自包含问题）。
- 无论哪种，**文档必须写清**：agent 用 pwsh 跑 MATLAB 时产物该落哪里。

**验收标准**：`pwsh → matlab -batch → save('<run_dir>/x.mat')` 成功；或在尝试失败时返回带 `nextAction` 的结构化提示。

---

## 4. I3【P0】沙箱 ACL 使 pwsh 完全不可用

### 4.1 现象

- 任何 `pwsh` 调用（包括 `Get-ChildItem`）直接失败：
  `Error: SetNamedSecurityInfoW failed (Win32 5): grantWrite(E:\matlab建模\胰岛)`
- 按 `diagnose-windows-sandbox-acl` 技能诊断：该目录 `writeDac=true, writeOwner=false`，缺少 WRITE_OWNER，沙箱无法授予写权限。
- 修复后 **PowerShell 执行策略**又拦住脚本：`cannot be loaded because running scripts is disabled on this system`（需 `Set-ExecutionPolicy -Scope Process Bypass`）。
- **两次都需要用户审批**（`danger-full-access`）。

### 4.2 升级建议

- **U3.1** 会话启动时做一次 preflight：目录可写性 + 脚本执行策略，**在用户第一次下指令之前**就把问题暴露，并自动给出修复入口（或直接走审批）。
- **U3.2** 失败文案要**可操作**：现在只说 `SetNamedSecurityInfoW failed (Win32 5)`，没有告诉 agent "去跑 ACL 诊断技能"。应带 `hint` 与 `nextAction`。
- **U3.3** 技能脚本应自带执行策略规避（用 `-ExecutionPolicy Bypass` 调用，或提供 `.cmd` 包装），避免第二次审批。

---

## 5. I4【P1】MATLAB PDE 工具箱的静默陷阱簇

这一类最危险，因为**程序能跑完、Newton 残差能到 1e-16、数值看起来完全合理，但物理是错的**。

| # | 陷阱 | 表面症状 | 真实后果 |
|---|---|---|---|
| I4.1 | `decsg(gd,'R-I1-I2-I3',ns)` 只返回一个子域，圆盘被挖成**空洞** | 网格生成成功、求解收敛、无报错 | **胰岛区域根本没有被网格化**，反应项体积 = 0，解恒为 c_amb。曾据此得出"完全无缺氧"的假结论 |
| I4.2 | 系数函数返回值方向 | `... should have returned a matrix with 500 columns. Instead it returned a matrix with 1 columns.` | 必须返回 **1×npts 行向量**（列向量会被当成 1 列矩阵） |
| I4.3 | `state` 依赖的 `f` 似乎从不重算 | 瞬态 `solvepde` 在所有时刻返回**初值** | 非线性"收敛"其实是只做了一次线性解 |
| I4.4 | `setInitialConditions` 只接受标量 | `Specify initial conditions as a scalar or a column vector of length PDESystemSize` | **无法注入节点场**做延拓，只能标量 |
| I4.5 | `decsg` 的 NS 必须是 cellstr | `Geometry description and name-space matrix define different number of shapes` | 文档不提；`char('R','I1')` 是 4×2 而它按**列**取名字 |
| I4.6 | 圆盘与边界**相切** | `Unable to compute geometry-mesh associativity because the geometry is invalid or the mesh size is insufficient` | 零角点是退化几何；只能让胰岛"嵌入板底 5%" |
| I4.7 | `model.SolverOptions` 整体只读 | `无法识别类 'PDEModel' 的 'SolverOptions' 属性，因为它是只读的` | 必须逐字段赋值 |
| I4.8 | `assembleFEMatrices(model,'nullspace','off')` | `Third argument must be a structure array with time and solution data` | 签名与文档不一致 |

### 5.1 根因

- 这些 API 的错误信息**不指向根因**（I4.6 说"网格尺寸不足"，实际是几何退化；I4.2 说"500 列"，实际是行列方向）。
- 更致命的是 **I4.1 完全不报错**。

### 5.2 升级建议

- **U4.1 新增知识库条目 `matlab_pde_toolbox_pitfalls`**：把上表 8 条 + 修复写法固化为可检索条目，`bma_kb_search("PDE 网格 / decsg / 系数")` 直接命中。
- **U4.2 提供"数值自检模板"**（比知识条目更有用）：一个可运行的自检脚本，agent 落地任何自写 FEM 前后跑一遍：
  1. **无源检验**：`f=0` 时 `K\F` 应等于边界值处处相等（本次正是靠这条发现边界条件没生效）；
  2. **算子零空间**：`norm(K*ones)≈0`；
  3. **反应体积检验**：`sum(V_isl)` 应等于解析胰岛面积/体积（**本次靠这条抓到 I4.1**）；
  4. **方向检验**：把 `R_max` 翻倍，监测点浓度必须单调下降（抓符号错误）；
  5. **解析对照**：1-D 板 / 球的闭式解，报告收敛阶。
- **U4.3** 若可行，`bma_model_simulate` 对"空间离散 ODE"（本次的球壳模型）自动做第 3、4 条自检。

---

## 6. I5【P2】`bma_report_build` 的图片与路径处理

- **现象 1**：`extra_sections_json` 传文件路径 `.bma/runs/.../report_sections.json` →
  `invalid extra_sections_json: not valid JSON (Unexpected token '.', ".bma/runs/"... is not valid JSON)`。
  **文档写着"A file path is also accepted"，实际不接受。**
- **现象 2**：Markdown 图片 `![](path)` 在 HTML 里被渲染成 `<a href>` **链接**，不是 `<img>`，报告里看不到图。只能事后手工改 HTML。
- **现象 3**：run_dir 之外的绝对路径图片不会被内嵌，报告不自包含。

### 升级建议

- **U5.1** `extra_sections_json` 真正支持文件路径（或从 schema 文档里删掉该说法）。
- **U5.2** Markdown `![]()` 渲染为 `<img>`；外部图片**拷贝进报告包**并转 base64/相对路径，保证自包含。
- **U5.3** 报告构建返回 `warnings`：哪些图没被内嵌、哪条引用解析失败。

---

## 7. I6【P2】双栏 PDF 的分节与溯源

- `numbers.json` 里，所有模型参数被归到 `s12`（section_heading = "Background"），但内容是 Methods 正文；句级 `context` 明显是两栏交错的乱序文本（如 `"...Gd 22 OO H 22 calculations, c = 0.200 mol·m-3..."`）。
- 后果：**证据表能溯源到句子 id，但章节归属是错的**，报告里要额外人工解释。
- **U6.1** 双栏检测 + 栏内重排（按 x 坐标分栏后再自上而下）。
- **U6.2** 分节失败的章节在输出里标 `section_confidence: low`，提示 agent 谨慎引用。

---

## 8. I7【P1】强制质量门缺少"计算上不可行"的豁免机制

工作流把 G6 `bma_model_analyze` 定为必须通过的硬门。但存在一类模型（强非线性、多状态），其符号分析在物理时间内不可完成。

**后果**：agent 面临"跑就卡死、不跑就违规"的两难，本次正是因此卡死。

### 升级建议

- **U7.1** 质量门支持**显式豁免**：`bma_gate_waive(gate='G6', reason=..., substitute=...)`，记录进 model card 与报告。
- **U7.2** 给每道门一个"降级替代"清单（如 G6 → 数值守恒律零空间 + 数值 Jacobian 特征值）。
- **U7.3** 文档明确：**宁可留下"已声明未完成"的记录，也不要发起一个已知会挂死的调用**。

---

## 9. I8【P2】知识库缺少"收敛 ≠ 正确"的检查清单

本次反覆出现同构错误：**解在数值上收敛得很漂亮，但物理是错的**。

- 残差判据取错：用 `|r|/c_amb` 判断收敛，在 `c_amb=0.2`、`K~1e-9` 的量级下，**10% 的相对误差看起来像 1e-10**。正确做法是对 `‖K‖·c_amb` 归一化。
- 符号约定反覆出错：PDE 工具箱的 `f` 是**源项**；我把消耗写成 `f=+|R|`，结果氧被"生产"到 5.25 mol/m³。
- 自由边界/阈值开关使 Newton 在折点处停滞（残差卡在 1e-2），被误读为"已收敛"。

**U8.1** 新增条目 `numerical_convergence_checklist`：残差归一化、方向性检验、守恒量检验、网格收敛阶、解析极限对照。

---

## 10. agent 自身的失误（供校准，不是工具缺陷）

诚实记录，便于后续会话避免：

1. **过早相信"跑通了"**：I4.1 的空洞几何让程序安静地算出了"全无缺氧"，我在若干轮之后才用 `sum(V_isl)==0` 抓到。教训：**任何新写的数值实现，先验证"源项确实被施加"**。
2. **符号错误连发**：PDE `f` 的方向、1-D 解析对照用错坐标轴（厚度沿 y 却拿 x 去比）、`accumarray` 的 element-major/ node-major 顺序（`repmat` vs `repelem`）。每一次都表现为"数值离谱但不报错"。
3. **在错误的抽象层级上纠缠**：为了绕开 PDE 工具箱的接口缺陷，先后试了 4 种求解策略（延拓 Newton → 瞬态 → 时间推进 → 半光滑 Newton）。**若一开始就自写 P1 装配 + 牛顿**（最终方案，400 行），可以省下约 1 小时。
4. **没有及早缩小问题**：面对"结果全错"，应先跑一个 5 分钟可完成的解析对照（1-D 板），而不是继续加功能。

---

## 11. 建议的升级路线图

| 阶段 | 动作 | 预期收益 |
|---|---|---|
| **立即** | U1.1 看门狗 + `bma_cancel`；U1.3 服务健康度；U3.1 启动 preflight | 消除"卡死"这一类事故 |
| **立即** | U2.1/U2.2 `.bma` 可写或 `external_artifact_dir` | 恢复"产物在 run_dir"的约定 |
| **短期** | U1.2 `analyze` 难度预判与降级；U7 质量门豁免 | 让 G6 不再成为陷阱 |
| **短期** | U4.2 数值自检模板 + U4.1 PDE 陷阱条目；U8.1 收敛检查清单 | 直接消灭本次最耗时的 90 分钟 |
| **中期** | U5 报告图片/路径；U6 双栏 PDF 分节 | 交付质量与溯源准确性 |

---

## 12. 附：可直接复现的失败片段

```powershell
# I3：pwsh 完全不可用
pwsh -Command "Get-ChildItem -Force"      # SetNamedSecurityInfoW failed (Win32 5)

# I2：.bma 不可写
pwsh -Command "Set-Content -Path '.bma\x.txt' -Value hi"
# [sandbox: file access denied under workspace-write mode]

# I5：extra_sections 路径不被接受
# bma_report_build(extra_sections_json='.bma/runs/<id>/report_sections.json')
# invalid extra_sections_json: not valid JSON (Unexpected token '.')
```

```matlab
% I4.1：几何被挖成空洞，且不报错
gd = [3;4;-375e-6;375e-6;375e-6;-375e-6;0;0;1e-3;1e-3];
gd = [gd, [1; 0; 75e-6; 100e-6; zeros(6,1)]];
dl = decsg(gd,'R-I1',{'R','I1'});     % 只返回介质域，圆盘是洞
% → 单元质心落在圆盘内的数量 = 0，反应项体积 = 0

% I4.3：瞬态求解返回初值
specifyCoefficients(m,'m',0,'d',1,'c',cFcn,'a',0,'f',fFcn);  % f 依赖 state.u
res = solvepde(m,[0 10 100 1000]);    % 所有时刻的 min/max 都等于初值

% I4.6：相切退化（错误信息指向"网格尺寸"）
% → Unable to compute geometry-mesh associativity because the geometry is
%   invalid or the mesh size is insufficient for capturing all geometric details.
```

---

## 13. 本次表现良好、建议保持的部分

为避免只列缺点，一并记录（这些在本次确实救了场）：

- `bma_literature_ingest`：句级 id + 逐字 quote + `numbers.json` 的 `context`，让证据表可以真正逐条核对。**这是全流程里质量最高的一环。**
- `bma_model_validate`：错误带 `code` + `path` + `hint`，一次就能改对；对 16 条 expression 速率律的检查零误报。
- `bma_model_simulate_cases`：参数覆盖 + 对比图一次成型，非常适合做直径/密度扫描。
- `bma_model_sensitivity`：局部弹性直接给出了可辨识性的关键证据（D 与 R_max 弹性等值反号 ⇒ 只可辨识组合），比形式化分析更便宜也更有说服力。
