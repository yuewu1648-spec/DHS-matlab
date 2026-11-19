# NatRevMolCellBiol issues → 0.11.0 处理结果

对应 `E:\matlab建模\NatRevMolCellBiol\issues\ISSUE-001..018`。版本 0.11.0，完整套件 38/38 PASS。

| Issue | 状态 | 修复/结论 |
|---|---|---|
| 001 ddesd 表达式延迟无效 | 已修复 | `ddesd/ddensd` 的 delay callback 返回过去时刻 `t-τ`，不是 τ；表达式为常量时自动走 dde23。回归 maxdiff=0。 |
| 002 pwsh workspace ACL | 环境问题，未改代码 | 属 DSH Windows workspace-write ACL；本仓库无法修复。当前 full-access 会话不复现。 |
| 003 phase 从不产出 | 已修复 | `phase_x/y` 支持 species id；dispatch 显式 phase 返回 figures；失败给 warning。 |
| 004 model_selection 超时无部分结果 | 已修复 | `candidate_seconds` 独立预算、`candidate_status`、`model_selection.partial.json`。 |
| 005 timeGuard/多起点 | 已修复 | 补 `timeGuard`；wall-clock 停止转 fmincon；默认至少 min(4,multistart) 起点；`multistart_diagnostics`。 |
| 006 PDF 矢量图 0 张 | 已修复告警/分类 | `figure_class=bitmap|vector|vector_or_mask`、`rasterized=false`、`reason=no_renderer`；不再误报单色。 |
| 007 DDE 量纲 ok=false checked=0 | 已修复 | `units_check.applicable=false, ok=true, reason=dde_units_not_derived`；工具摘要显示 not applicable。 |
| 008 profile 选项键 | 已修复 | `options.param` 与 `params_to_fit/params` 都接受；全 estimate:false 时用默认参数向量继续扫描。 |
| 009 cases 截断 12 行 | 已修复 | 返回 `n_cases`；写 `cases_summary.csv`（全部 case）；工具输出完整路径/截断提示。 |
| 010 fit 图路径冲突 | 已修复 | 图写入 `fits/<fit_id>/figures/fit.png`。 |
| 011 无量纲 time.unit=1 | 已修复 | 允许 `"1"`；d/dt 按无量纲处理。 |
| 012 振荡器指标/延拓/3D | 部分 | 已加 period/amplitude/min/max/mean/oscillation_exists + phase3d；**参数延拓/不稳定分支仍未做**。 |
| 013 PDF 文件大小告警 | 已修复 | 文件字节只提示；截断按 `text_chars`，返回 `text_chars/total/truncated`。 |
| 014 SI 参数缺失 | 流程层 | 非软件缺陷；report skill 已要求参数可得性差集与“机制/数值复现”分栏。 |
| 015 方程仅位图 | 已改善 | ingest 检测公式编号占位符并告警；report 要求声明公式来源/降级。 |
| 016 未复现 panel 清单 | 流程层 | report skill 强制复现矩阵：status + reason + unblock_precondition。 |
| 017 无实验数据验证 | 流程层 | report skill 要求文献类型判定、data_origin、禁止 validated 措辞、SSE≈0 时 CI=NaN（不可估）。 |
| 018 长中文轴标签重叠 | 已修复 | y 轴改用短 id/unit，长 name 放标题并自动换行。 |

## 仍需后续

- ISSUE-012B：参数延拓/伪弧长/不稳定分支。
- ISSUE-002：需在 DSH/Windows ACL 层修复，或改用 full-access/非受限会话。
- ISSUE-014/015/016/017：文献数据不可得或流程约束，已在 report skill 规范化，不是代码可完全修复项。
