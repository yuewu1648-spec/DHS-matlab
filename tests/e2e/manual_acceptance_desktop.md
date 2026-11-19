# 桌面 preset 会话人工验收步骤（真实 LLM E2E）

> 背景：headless profile 按设计禁用了托管凭据库，DeepSeek 账号登录（device records）在
> headless 下不能当作 API key 使用（实测 `MISSING_CREDENTIAL: llm-deepseek: no API key
> for provider route "deepseek-official"`）。因此**真实模型的端到端验收以桌面 Web GUI 的
> preset 会话为正式路径**；`tests/e2e/run_headless_e2e.ps1` 保留为设置 `DEEPSEEK_API_KEY`
> 后的自动验收路径。

## 前置条件

1. `bridge/` 插件包已交付并安装到当前可用 profile；`bridge/cordis.patch.yml` 已插入
   `preset-bio-matlab`（Lead 负责）。
2. Web GUI（本机 `http://127.0.0.1:52086`）正常打开，账号已登录。
3. 新建会话时可选择 agent preset「MATLAB 生物系统建模」。

## 步骤

1. **新建会话**，选择 preset「MATLAB 生物系统建模」，工作目录设为
   `E:\matlab系统建模\.qa\manual-e2e\<时间戳>`（或任意空目录；建议独立目录便于收集产物）。
2. **投喂文献**：把 `tests/fixtures/literature/enzyme_kinetics/` 下的
   `paper.md` 与 `data/*.csv` 复制到该工作目录的 `literature/` 与 `data/` 下
   （**不要**复制 `expected_facts.json`，那是验收真值）。
3. **发送任务提示词**：内容取自 `tests/e2e/headless_task_prompt.md`（把其中
   `__WORKSPACE__`/`__LITERATURE_FILE__`/`__DATA_FILES__`/`__EXPECTED_FIT__`
   替换为实际路径；例如 literature/paper.md、data/progress_curve_S50.csv）。
4. 等待 agent 自主完成：文献解析 → 建模假设 → spec → 校验 → 仿真 → 拟合 →
   可辨识性/验证 → 报告 → 代码导出。中途允许它提问（人可回答，但不要替它写 spec）。
5. **自动断言**（在 agent 完成后执行，与 headless 路径共用）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass `
     -File tests\e2e\assert_e2e.ps1 `
     -Workspace "<第 1 步的工作目录>" -Fixture enzyme_kinetics `
     -OutDir "<该工作目录>\..\assertions"
   ```
   断言内容：run 布局、`bma.modelSpec.v1` spec、每个参数有单位与
   measured/estimated/assumed/fitted 证据、模型族匹配 expected_facts、参数恢复
   （名称或数值匹配 + 容差）、拟合结果 R²、报告含参数表/假设/证据/图。
6. 记录结果（截图/产物路径）到 `docs/ACCEPTANCE.md` §8 表。

## 通过标准（与 DESIGN §10.6 一致）

- 生成 `.bma/runs/<run_id>/` 且包含 `models/<name>/spec.json`（schema_version 正确、
  `spec.validate` 通过）；
- 至少一个参数估计结果（`fits/*/fit.json` 且 R² ≥ 0.80，或 agent 明确报告拟合并给出原因）；
- `report/report.{md,html}` 与 `model_card.json` 存在；报告含参数表、**参数证据**与
  **假设清单**；
- 所有参数均有 evidence 或显式 `assumed` 标注（无编造）；
- 通过 `assert_e2e.ps1`（退出码 0）。

## 本次 headless 尝试记录（供参考，不构成产品失败）

第一次 headless 运行（`tests/e2e/artifacts/headless-*/`）中，runner 与断言链路本身工作正常，
但两步被环境事实阻断：
1. 插件相对路径挂载失败：`bio-matlab-tools (file:///E:/matlab系统建模/tests/e2e/bridge):
   failed to import: ERR_MODULE_NOT_FOUND` → 已改为生成 patch 时使用绝对路径
   `E:/matlab系统建模/bridge/lib/index.js`。
2. headless 凭据限制：`MISSING_CREDENTIAL: llm-deepseek: no API key for provider route
   "deepseek-official"` → 真实 LLM 改走本文件所述的桌面 preset 会话；
   `DEEPSEEK_API_KEY` 可用时 headless 脚本仍可自动验收。
