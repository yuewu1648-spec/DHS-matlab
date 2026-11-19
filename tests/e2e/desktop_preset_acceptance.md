# Desktop preset 人工验收（真实 LLM 端到端）

> 用途：headless profile 不读取桌面登录凭据（需要 DEEPSEEK_API_KEY），因此
> **真实大模型端到端验收走 DSH Web GUI 的 preset 会话**。以下步骤 3 分钟。

## 前置

- MATLAB R2024a 可用；bundle `@local/dsh-bio-matlab` 已安装（preset 列表中可见 **MATLAB 生物系统建模**）。
- 工作目录：`E:\matlab系统建模`（或任意文献目录）。

## 步骤

1. DSH Web GUI → **新建会话** → agent preset 选择 **MATLAB 生物系统建模**。
2. 工作目录选 `E:\matlab系统建模`。
3. 复制以下任务文本发送（可整体粘贴）：

```text
请阅读 tests/fixtures/literature/enzyme_kinetics/paper.md（必要时也读 paper.pdf），
依据其中的实验数据自主构建酶动力学数学模型：
1) 解析文献并提取机制与参数证据（逐字 quote + section）；
2) 检索知识库匹配模型族与原理；
3) 写 bma.modelSpec.v1 规格并通过 bma_model_validate；
4) 做结构分析（守恒律/稳态/量纲）；
5) 用 data/progress_curve_S50.csv 与 data/substrate_velocity.csv 做参数估计，
   并做可辨识性/敏感性分析；
6) 交叉验证并比较至少一个替代模型；
7) 生成中文报告，导出 MATLAB 代码；
8) 最终用中文总结：模型、证据链、参数、验证结论、局限与下一步实验。
```

## 验收检查（自动）

在项目根运行（agent 完成后）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e\assert_e2e.ps1 -Workspace "E:\matlab系统建模" -Fixture enzyme_kinetics
```

或人工检查：

- [ ] `.bma/runs/<run_id>/models/*/spec.json` 存在且 `schema_version=bma.modelSpec.v1`
- [ ] 每个参数有 `unit` 与 `evidence`（type ∈ measured/estimated/assumed/fitted，quote 逐字来自文献）
- [ ] `analysis.json` 含守恒律/稳态；`fits/*/fit.json` 含 R² 与参数 CI
- [ ] `report/report.html` 含方程、参数证据表、假设、验证指标、图、局限
- [ ] agent 最终答复为中文，明确区分 measured/estimated/assumed 并报告不可辨识参数

## 失败时收集

- 会话中的工具错误（`BMA_*`）文本；
- `<workspace>/.bma/server/matlab-stdout.log`；
- 报告路径与 run 目录，提交给维护者。
