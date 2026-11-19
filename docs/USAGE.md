# 使用说明（安装 / 运行 / 验收 / 排障）

## 1. 环境要求

| 组件 | 版本/路径 | 说明 |
|---|---|---|
| MATLAB | R2024a，默认 `C:\Program Files\MATLAB\R2024a\bin\matlab.exe` | 需要 SimBiology / Symbolic Math / Optimization / Statistics / Text Analytics / Report Generator / Curve Fitting / Global Optimization 授权 |
| DSH | 当前 Desktop 安装 | 用于 agent 会话（preset「MATLAB 生物系统建模」） |
| Node.js | 24.x（DSH 自带运行时亦可） | 仅 bridge（插件）需要 |
| 本项目 | `E:\matlab系统建模` | 若移动目录，需重新安装 bundle 并更新 `bridge/cordis.patch.yml` 中的 skills 路径 |

## 2. 安装 DSH bundle（一次）

本机已完成安装（`@local/dsh-bio-matlab` → `E:\matlab系统建模\bridge`）。重装/迁移：

1. 确认 `bridge/node_modules` 存在（插件依赖 `@deepseek-ai/dsh-tools`）：
   ```powershell
   cd E:\matlab系统建模\bridge
   npm install --cache ..\.tmp\npm-cache --no-audit --no-fund
   ```
2. 在 DSH 中安装 bundle（会写入当前 profile，需完全权限；本机 profile 为 desktop）：
   - 对当前 DSH agent 说：`安装 bundle：E:\matlab系统建模\bridge`，或
   - 调用 `plugin_manager install_bundle { target: "E:\\matlab系统建模\\bridge" }`
3. 校验：`plugin_manager list_bundles` 应包含 `@local/dsh-bio-matlab`；preset 列表中应出现 **MATLAB 生物系统建模**（id `bio-matlab`，order 5）。

> 卸载：`plugin_manager remove_bundle { target: "@local/dsh-bio-matlab" }`。

## 3. 使用 agent（推荐路径）

1. DSH Web GUI → **新建会话** → 在 agent preset/seat 选择 **MATLAB 生物系统建模**。
2. 工作目录选项目根 `E:\matlab系统建模`（或存放文献的目录；产物写到该目录 `.bma/runs/`）。
3. 输入任务（示例）：

   ```text
   阅读 tests/fixtures/literature/enzyme_kinetics/paper.md，
   依据其中的实验数据构建酶动力学数学模型：
   1) 提取参数与证据；2) 写 bma.modelSpec.v1；3) 校验并做结构分析；
   4) 用 data/progress_curve_S50.csv 做参数估计与可辨识性分析；
   5) 交叉验证并生成中文报告；6) 导出 MATLAB 代码。
   ```

4. agent 首次调用工具时会自动启动 MATLAB（约 20-90 秒），此后同一目录内复用。
5. 产物：
   ```
   <work_dir>/.bma/runs/<run_id>/
     literature/...  models/<name>/spec.json|analysis.json|code/
     fits/<fit_id>/  figures/  report/report.html|report.md|model_card.json
   ```

## 4. 独立 MATLAB 使用（不经过 DSH）

```matlab
cd('E:\matlab系统建模')
startup_bma
demo_end_to_end                       % 完整示例：validate→simulate→fit→validate→report
run_all_tests('Filter','test_')       % 运行 MATLAB 测试
```

可选：启动本地文件式 RPC 服务（供 bridge/自测使用）：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\matlab_batch.ps1 -Code "bma.server.start('E:/matlab系统建模/.tmp/dev-manual','manual-token')"
```

## 5. 验收

### A. MATLAB 测试（必须全绿）
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\matlab_batch.ps1 -Filter test_ -TimeoutSec 3600
```

### B. 工具层端到端（无 LLM，原有 15 个 bma_* 等价方法；新工具另测）
```powershell
# 先在一个 pwsh 调用内启动私有服务，再跑脚本（服务随该调用存活）
node bridge\lib\rpc-cli.mjs --work-dir .tmp\tool-layer --start
powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e\tool_layer_e2e.ps1 -WorkDir .tmp\tool-layer
```

### C. 真实 LLM 端到端（人工，走 desktop preset）
1. 新建会话选 **MATLAB 生物系统建模**，工作目录 `E:\matlab系统建模`。
2. 投喂 `tests/fixtures/literature/enzyme_kinetics/paper.md`，任务文本可用 `tests/e2e/headless_task_prompt.md`。
3. 验收标准（`tests/e2e/assert_e2e.ps1` 同款断言）：
   - `.bma/runs/` 下有 spec/analysis/fit/report 产物；
   - spec `schema_version=bma.modelSpec.v1`，每个参数有单位与 evidence 类型；
   - 报告含参数表、假设、证据、图；
   - agent 最终答复中文总结模型、验证与局限。

### D. headless 端到端（需 `DEEPSEEK_API_KEY`）
headless profile 不读取桌面登录凭据，因此需要 API key：
```powershell
$env:DEEPSEEK_API_KEY='sk-...'
powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e\run_headless_e2e.ps1 -Fixture enzyme_kinetics
```
详见 `tests/e2e/README.md`。

## 6. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 工具报 `BMA_SERVER_ABSENT` | MATLAB 服务未启动/被清理 | 再调用一次工具（会自动重启）；或 `node bridge/lib/rpc-cli.mjs --work-dir <dir> --start` |
| 首次工具调用很慢（20–120s） | MATLAB 冷启动；0.6.0 并行启动 control + heavy worker | 正常；同目录后续调用很快；`matlab_status` 会显示 worker 是否 idle/BUSY |
| 任务结束后 MATLAB 自己退出 | 0.8.3 空闲自动回收（默认 300 s，`BMA_IDLE_SHUTDOWN_SECONDS` 可调） | 正常资源回收；下一次 `bma_*` 会按需重启（20–120s），不要手动 `taskkill` |
| `BMA_SERVER_EXITED` | 某个 MATLAB 进程异常退出 | control 日志 `<work_dir>/.bma/server/`，worker 日志 `<work_dir>/.bma/worker/server/`；桥接只重启对应进程 |
| `BMA_TIMEOUT` | 单次拟合/模型选择/符号分析过长 | **0.5.0 起不会自动重试**；**0.6.0 只杀 worker**（下一次重调用惰性启动），control 仍可用。先 `matlab_status` 看 worker `busy/last_timeout`，用 `bma_cancel(hard=true)` 恢复，再减小 `multistart`/时间窗/参数集 |
| `BMA_SERVER_UNHEALTHY` / `BMA_CANCELLED` | 刚超时/重启，或调用被取消 | 等待数秒 + `matlab_status`；缩小任务重跑，不要并发重试 |
| worker 启动失败（`worker: NOT READY`） | 第二个 MATLAB 启动失败/资源不足 | control 仍可用；看 `.bma/worker/server/matlab-stdout.log`；关闭其他 MATLAB 后 `bma_cancel`/重新 status |
| `SetNamedSecurityInfoW failed` / `[sandbox: file access denied ...]` | DSH 沙箱 ACL，不是模型错误 | 按 `diagnose-windows-sandbox-acl` 技能诊断；需要 `danger-full-access` 时让用户审批；临时改用 `read/write` + `bma_*` |
| `pwsh` 报执行策略禁止脚本 | PowerShell ExecutionPolicy | 用 `-ExecutionPolicy Bypass` 或 `.cmd` 包装；不要把任务卡在 `pwsh` |
| `.bma` 对 MATLAB 批处理不可写 | 沙箱 ACL/进程权限 | 产物先写外部目录，再 `bma_artifact_import` 导入 `artifacts/`；报告会内嵌图片 |
| 报告图片为空/引用外部绝对路径 | extra_sections 图片缺失或未导入 | 看 `bma_report_build` 的 warnings；本地图复制到 `report/figures`，外部产物先 `bma_artifact_import` |
| 质量门因符号分析不可行 | 高维非线性/符号求解不可判定 | `bma_model_analyze` 会自动数值降级；仍不可行时用 `bma_gate_waive` 记录 reason/substitute，禁止静默跳过 |
| preset 未出现在列表 | bundle 未安装/激活失败 | `plugin_manager list_plugins` 查 `include:preset-bio-matlab`；重装 bundle |
| 报告里图为空 | MATLAB 无显示器时绘图失败 | 已用 `visible off + exportgraphics`；若仍失败看 report warnings |

## 7. 目录与产物清理

- 运行产物：`<work_dir>/.bma/`（可随时删除）
- 开发临时：`.tmp/`（可删除；其中 `matlab_pref_template` 用于沙箱内快速初始化 prefdir）
- 插件依赖：`bridge/node_modules/`（删除后需重新 npm install）

## 8. 工作区隔离（在其他工作区使用 agent）

**设计保证**：agent 目录只是“安装目录”，运行期不写入。

- 所有产物写到 **会话工作区**：`<work_dir>/.bma/runs/`（spec/fits/report）、`<work_dir>/.bma/server/`（RPC 状态）、
  `<work_dir>/.tmp/`（MATLAB pref/temp/home）。
- MATLAB 以会话工作区为当前目录启动；知识库/源码通过绝对路径只读加载。
- 不同工作区互不影响：各自独立的 run 目录、独立的 MATLAB 服务；一个工作区的 `.bma/` 可整体删除。
- **越界保护**：工具只允许把产物写到当前会话工作区，传入工作区之外的 `run_dir` 会返回
  `BMA_WORKSPACE_ESCAPE`。

**自检**：

```powershell
.\scripts\check_isolation.ps1
```

它会在两个独立临时工作区各跑一次建模调用，断言：产物只落在各自工作区、agent 源码零改动、越界路径被拒绝。

**清理**：`<work_dir>/.bma` 与 `.tmp` 可安全删除；残留 MATLAB 服务用
`scripts\stop_matlab_servers.ps1 -WorkDir <work_dir>` 清理。

## 9. 版本更新纪律（摘要）

1. 代码/知识库/文档改动；
2. 升版本并封版：`scripts\update_agent.ps1 -Version 0.2.0 -Note "..." -Seal`
   （自动更新 `VERSION`、`bridge/package.json`、`CHANGELOG.md`，并重算 `MANIFEST.sha256`）；
3. DSH 内 `plugin_manager remove_bundle` → `install_bundle`（重新组合 patch 层）；
4. `scripts\check_agent.ps1` 全绿 + `scripts\check_isolation.ps1` 全绿；
5. 在 DSH 新会话选择 preset 做一次冒烟（`matlab_status` 应返回新 `agent version`）。

SemVer 语义、兼容性契约、回滚见 `docs/VERSIONING.md`。每次建模的 `run.json` 中记录
`agent_version/bundle_version/spec_schema/matlab_version`，请在论文/报告中引用。
