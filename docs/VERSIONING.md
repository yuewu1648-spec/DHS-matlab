# Version, update discipline & workspace isolation (agent 版本更新纪律与工作区隔离)

本文件定义 BioModel-MATLAB agent 的**版本语义、发布流程、工作区隔离模型与回滚方式**。任何影响对外契约的改动都必须走本流程。

## 1. 版本唯一来源

| 来源 | 内容 | 用途 |
|---|---|---|
| `VERSION` | `MAJOR.MINOR.PATCH`（如 `0.1.0`） | agent 对外版本；`bma.version()`、`server.ping/info`、`run.json`、`matlab_status` 读取 |
| `bridge/package.json` → `version` | 必须与 `VERSION` 相同 | DSH bundle 安装/升级识别 |
| `CHANGELOG.md` | 每个版本的变更条目 | 升级者阅读，必须与版本同步 |
| `MANIFEST.sha256` | 全部交付源文件的 SHA-256 | 完整性证明；`check_agent.ps1` 校验 |

每次建模的 `run.json` 都会记录 `agent_version / bundle_version / spec_schema / matlab_version`，
请在研究项目/论文中引用该版本，保证模型可复现。

## 2. SemVer 语义

| 变更类型 | 版本位 | 例子 |
|---|---|---|
| **MAJOR**：破坏性变更——工具名称/参数/返回结构不兼容、`bma.modelSpec` schema 升版且不向后兼容、preset 组成需要手工迁移、MATLAB 最低版本提高 | `X.0.0` | 把 `bma_model_fit` 的参数 `options_json` 改为对象；spec v2 |
| **MINOR**：向后兼容的新能力——新增工具/方法/知识库条目/报告小节、新增可选参数、spec v1 内新增可选字段 | `0.X.0` | 新增 `bma_model_selection`；KB 增加新 archetype |
| **PATCH**：不改契约的修复——bug fix、提示词/描述改进、性能、文档、测试 | `0.0.X` | 修 dispatch 的 `server.ping`；报告排版 |

规则：
- 工具**名称**、**必填参数**、**输出 schema 的 required 字段**、**`bma.modelSpec.v1` 必填字段**的变化一律按 MAJOR。
- 工具参数只增可选字段、返回只加字段 → MINOR。
- 任何产物格式变化（report/model_card/run.json 结构）都要在 CHANGELOG 写明并考虑 MINOR。
- 不确定时按更高版本位处理。

## 3. 发布/更新 checklist

1. 修改代码/知识库/文档；在 `CHANGELOG.md` 写好条目。
2. **升版本并封版**（自动更新 VERSION、bundle version、CHANGELOG，并生成完整性清单）：
   ```powershell
   .\scripts\update_agent.ps1 -Version 0.2.0 -Note "新增 ..." -Seal
   ```
3. **重新安装 bundle**（DSH 内，需 Full access；删除+安装确保 patch 层重新组合）：
   - `plugin_manager remove_bundle { target: "@local/dsh-bio-matlab" }`
   - `plugin_manager install_bundle { target: "E:\matlab系统建模\bridge" }`
4. **自检**：
   ```powershell
   .\scripts\check_agent.ps1        # 版本一致 / manifest / bundle / MATLAB 后端 / 15 工具冒烟
   .\scripts\check_isolation.ps1    # 工作区隔离（两个独立工作区 + agent 源码零改动 + 越界拒绝）
   ```
   两者都必须全绿。
5. 在 DSH 新会话选择 preset 做一次冒烟（`matlab_status` 应返回新 `agent version`）。

> 只改 `bridge/lib/*.js` 或 `matlab/**.m` 不需要重装 bundle（junction 实时读取，但长驻 MATLAB
> 需要 `clear functions; rehash` 或重启服务）；改 `cordis.patch.yml`/preset 必须重装。

## 4. 工作区隔离模型（在其他工作区使用 agent）

三层隔离，运行期不需要也不应该写 agent 安装目录：

| 层 | 位置 | 内容 | 生命周期 |
|---|---|---|---|
| 安装层（本仓库） | `E:\matlab系统建模` | MATLAB 源码、bridge 插件、知识库、示例、文档 | 只在安装/升级/维护窗口变化 |
| 工作区层 | `<work_dir>/.bma/` | 每次运行的 run 目录、spec、fit、figures、report、RPC server 状态 | 随研究工作区；可整体删除 |
| 临时层 | `<work_dir>/.tmp/` | MATLAB pref/temp/home、安装缓存 | 可随时删除 |

保证措施：
- MATLAB 进程以 `<work_dir>` 为 cwd 启动，pref/temp/HOME 重定向到 `<work_dir>/.tmp`；
- bridge 只写 `<work_dir>/.bma/server/` 日志与状态；
- 每个工作区独立启动/复用自己的 MATLAB 服务，工作区之间不共享可变状态；
- **越界保护**：dispatch 拒绝把运行产物写到 `<work_dir>` 之外（`BMA_WORKSPACE_ESCAPE`）；
- 输入文件（文献、数据）可以位于工作区之外（只读访问），但输出只落在工作区。

**自检**：`scripts\check_isolation.ps1` 在两个独立临时工作区各跑一次建模调用，断言：
产物只落在各自工作区、agent 源码文件哈希零改动、越界 `run_dir` 被拒绝、两个工作区互不包含对方产物。

## 5. 回滚

- 升级失败/结果异常：把 `VERSION`、`bridge/package.json`、`CHANGELOG.md` 恢复到上一个版本 →
  DSH 内 remove/install bundle → `check_agent.ps1` + `check_isolation.ps1`。
- 保留上一个版本的 `MANIFEST.sha256`（或复制整个目录）可随时比对/回退；研究的 `run.json` 记录了
  建模所用 agent_version，可据此说明复现条件。
- 破坏性升级（MAJOR）必须在 CHANGELOG 给出迁移说明（spec schema 转换、工具参数迁移、preset 变更）。

## 6. 兼容性契约

- **`bma.modelSpec.v1`**：v1 内只做向后兼容扩展；0.7.0 新增可选 `kind:"pde"` + `pde` 子树与 `initial.param/expression`，旧 ODE 规格行为不变；0.8.0 在同一 `pde` 子树上新增 `dim=2|3`/`solver`/`geometry`/`mesh`/`probes` 原生字段（1D MOL 不变）；0.8.4 新增文献图复现工作流（不改 spec）；破坏性修改升 v2 并提供迁移工具（未来）。
- **工具面**：`bma_*` 工具名稳定；0.5.0 起共 18 个（新增 `bma_cancel` / `bma_artifact_import` / `bma_gate_waive`，属于 MINOR 向后兼容扩展）；0.6.0 把重调用分流到独立 heavy worker（`serverSubdir`/worker health 为新增字段），工具名与必填参数不变；0.7.0 PDE 通过编译期展开复用同一工具面；0.8.0 新增 `bma_pde_simulate`（共 19 个，原生 PDE Toolbox，MINOR），旧工具名/必填参数不变；参数只增不改；输出 `summary` 字段始终存在。
- **产物**：`run.json`/`model_card.json` 字段只增；`report.html` 章节可增不可删（PATCH 可调整排版）。0.5.0 新增 `gates.json`、`artifacts.json`、`analysis.symbolic/analysis_mode`；0.6.0 新增 `.bma/worker/server/` 与 `state.server_subdir/last_method`；0.7.0 新增 `m.pde`/model card `pde`/报告“2B. PDE 离散与边界条件”；0.8.3 新增后端空闲自动回收（`BMA_IDLE_SHUTDOWN_SECONDS`，默认 300 s，0=关闭）；0.8.4 报告新增“文献图复现”矩阵；0.8.5 report 图片去重 + 全局 max-width/表格 fixed layout。
- **MATLAB**：基线 R2024a；提高最低版本按 MINOR（若影响工具箱授权则 MAJOR）。
- **知识库**：archetype/principle 的 `id` 稳定；删除或重命名按 MINOR 记录在 CHANGELOG。
