# headless_task_prompt.md — E2E 任务提示模板
#
# 由 tests/e2e/run_headless_e2e.ps1 读取，替换占位符后通过 stdin 传给
# `dsh --profile headless --patch <overlay> -`。
#
# 占位符：
#   __FIXTURE_ID__       fixture 标识（enzyme_kinetics / gene_oscillator / epidemic_sir）
#   __LITERATURE_FILE__  工作区内文献相对路径（literature/paper.md）
#   __DATA_FILES__       工作区内数据文件相对路径清单（逗号分隔）
#   __EXPECTED_FIT__     推荐拟合数据与输出映射说明
#
# 注意：本提示只给任务与质量要求，不给模型答案；模型类型/参数由 agent 自主决定。

当前工作目录 `__WORKSPACE__` 是本次任务的独立工作区（`work_dir`，所有产物写入其
`.bma/runs/`）。文献文件：`__LITERATURE_FILE__`。配套实验数据：`__DATA_FILES__`。

请完成一次完整的自主生物系统建模任务：

1. 用 `bma_literature_ingest` 解析文献（doc_id 记录在总结里），然后用 read 通读全文。
2. 从文献中抽取机制、变量、参数（数值+单位+来源章节/引文）。
3. 用 `bma_kb_search` 检索匹配的模型原型，确定模型类型与机制假设。
4. 写出 `bma.modelSpec.v1` JSON 规格（变量/参数/反应/输出/假设齐全，参数带单位、
   bounds 与 evidence；不确定的参数标 assumed 或 estimated，禁止无来源数字）。
5. 用 `bma_model_validate` 校验，按错误 hint 修复直到 valid=true。
6. `bma_model_simulate` 检查定性行为是否与文献一致。
7. 用配套数据做参数估计：推荐拟合数据为 `__EXPECTED_FIT__`（`output_map` 见
   `expected_facts.json` 之外的 README 说明；若列名不匹配，按文献/数据表头自行映射）。
8. 做可辨识性/敏感性分析；用 `bma_model_validate_fit` 做残差与交叉验证。
9. 用 `bma_report_build` 生成报告（必须包含：模型方程、参数表（值/单位/CI/证据）、
   假设清单、估计与可辨识性、验证指标、残差与图、局限、复现命令）。
10. `bma_codegen` 导出可独立运行的 MATLAB 代码。

质量要求（硬性）：
- 每个参数必须有 unit 与 evidence（type=measured/estimated/assumed/fitted）。
- 报告必须包含假设小节与参数证据表。
- 拟合失败或参数不可辨识时，要如实报告原因并给出替代方案（如固定参数/改用
  assumed 值），不能伪造结果。
- 完成后输出一段中文总结：模型类型、关键参数（含单位）、拟合指标（R²/RMSE）、
  证据缺口与报告路径。
