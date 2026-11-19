---
name: bio-model-report
description: 生物系统建模最终报告的结构、证据表、假设与局限写法，以及向用户交付的规范；在调用 bma_report_build 或撰写最终答复前加载。
whenToUse: 模型与拟合/验证已完成、准备生成报告并向用户交付结论时。
---

# 建模报告规范

## 报告必须回答的 7 个问题

1. **文献说了什么机制？**（引用 section + 逐字 quote）
2. **我们建了什么模型？**（方程、变量定义、单位、结构图）
3. **假设是什么？**（充分混合、恒温、时间尺度分离、忽略空间/随机性…）
4. **参数从哪来？**（measured / estimated / assumed / fitted + quote/CI）
5. **模型能否复现文献现象？**（仿真 vs 报道值，图 + 数值；优先原图/复现图并排；“文献图复现”矩阵覆盖成功与失败 panel）
6. **模型是否被数据约束？**（拟合指标、可辨识性、敏感性、交叉验证、残差）
7. **局限与下一步实验？**（不可辨识参数、数据不足、竞争模型未排除、建议测量）

无法回答的问题必须显式写"证据不足"，不得用泛泛表述掩盖。

## 文献图复现（报告必须有）

- 在 G1 读 `figures/figures.json` 与图注，G2.5 定“必复现 panel”；复现图放 `<run_dir>/figures/reproduction/`。
- 报告增加“文献图复现”章节，逐 panel 表格：

| 图/panel | 文献展示（caption/quote） | 复现条件与模型输出 | 原图 | 复现图 | 判据/指标 | 状态 | 局限 |
|---|---|---|---|---|---|---|---|
| Fig.2A | 时间过程，x=min，y=µM | dose=…, 输出=… | ![](path/orig.png) | ![](path/repro.png) | digitized RMSE=… / 趋势 | quantitative/qualitative/not_reproduced | … |

- 原图与复现图都要嵌入（本地路径；报告会复制并 base64）。没有原图、矢量图未栅格化、或没有 digitized 数据时，明确写"原图不可得/仅定性"，不得声称"定量一致"。
- 未复现的 panel 也要列出并解释：参数缺失、条件不可控、模型缺机制、图不可读等；不能只报成功的图。
- **复现矩阵（强制）**：每个 panel 必须有 `status=quantitative|qualitative|not_reproduced`；`not_reproduced` 必须带 `reason` + `unblock_precondition` 两栏，不能只写“失败”。
- **文献类型/验证强度**：先判定原始研究/综述/理论文章；综述或理论文章通常没有实验数据，所有拟合只能写“in-silico recovery/discrimination”，不得写 validated/验证；`data_origin` 要标注（synthetic_from_published_parameters / experimental）。
- **参数可得性**：复现前把模型参数与文献正文/图注/SI 做差集；SI 不可得或参数缺失时，先声明该 panel 降级为机制/定性复现，不得用假定值冒充文献数值。
- **公式/插图不可读**：公式只有位图、矢量图无法栅格化（`figure_class=vector`/`vector_or_mask`, `rasterized=false`）时，在局限里写明“原图不可得/需外部渲染器”，并用图注数值/趋势判据，不能声称并排图已比较。
- **经典形式优先**：极限环/振荡必须有相平面图（后段闭合环加粗），不要只放时间序列；剂量响应用剂量-响应曲线；双稳/开关用相图/稳态图；酶动力学用 v-S 或抑制曲线；时空 PDE 用场快照。
- **一张图只出现一次**：`bma_report_build` 0.8.5 已按内容哈希去重；仍要检查 `figures_used`/warnings，避免同一图既在 extra section 又在 §11。经典图与文献原图对照时，用并排表而不是重复贴同一张图。
- 优先展示 2–4 张与机制结论最相关的复现对照图；其余放报告附录。

## 调用方式

```
bma_report_build({
  spec_path: "<run>/models/<name>/spec.json",
  fit_result_path: "<run>/fits/<fit>/fit.json",   // 可选
  analysis_path: "<run>/models/<name>/analysis.json", // 可选
  title: "竞争性抑制的米氏动力学：从文献到可验证模型",
  references_json: "[{\"citation\":\"Lineweaver H, Burk D. 1934. JACS 56:658\",\"doi\":\"10.1021/ja01318a036\"}]",
  extra_sections_json: "[{\"title\":\"实验设计建议\",\"markdown\":\"...\"}]"
})
```

## 参数证据表（报告中必须有）

| 参数 | 值 | 单位 | 类型 | 来源（section / quote / CI） |
|---|---|---|---|---|
| Vmax | 0.24 | µM/s | measured | Results, "Vmax = 0.24 µM s−1" |
| Km | 12.5 | µM | measured | Results, "Km = 12.5 µM" |
| kdeg | 0.02 | 1/min | assumed | 未报道，取典型蛋白半衰期量级 |

## 写作要求

- 中文主文；方程用 LaTeX 或纯文本 `dS/dt = -Vmax*S/(Km+S)` 均可，但符号必须与 spec 一致。
- 每个结论后面跟证据（图号、数值、section、quote）；避免"显著""明显"等无量化表述。
- 数值统一保留有效数字（参数 2-3 位有效数字，CI 给区间）。
- 局限部分要具体：哪个参数不可辨识、哪组实验条件未覆盖、哪个竞争机制未被排除。
- 复现命令写清楚：run 目录、spec 路径、数据路径、工具调用顺序。

## 交付

1. `present` 报告 HTML 与 2-4 张关键图（仿真、拟合、参数 CI/可辨识性）。
2. 最终答复结构：**结论（3-5 句）→ 模型 → 证据与参数 → 验证结果 → 局限 → 下一步**。
3. 明确指出生成物路径（报告、spec、代码、数据），让用户可复现或修改。


## 0.3.0：补充章节正文

- `extra_sections_json` 用 `[{"title":"...","markdown":"# 标题
- 要点
| a | b |
|---|---|"}]`；`markdown/body/content` 都会被完整渲染到 HTML/Markdown，文件路径也可。
- 参数可给多条 `evidence`，报告会逐条列出类型/引文；无证据的参数显示 assumed，不会被静默省略。


## 0.5.0：图片、外部产物与质量门豁免

- `extra_sections_json` 现在真正接受**文件路径**：可以是 `.json`（数组或单对象）或 `.md`；大段正文/表格建议写入文件再传路径，避免 JSON 字符串过长。工具层不再把路径误当 JSON 解析。
- Markdown 图片 `![alt](path)` 会渲染成 `<img>`；本地图片会复制到 `report/figures/`，HTML 内嵌为 base64，Markdown 使用 `figures/...` 相对路径。图片不存在/远程 URL/格式不支持会进入 `warnings`，必须如实说明。
- 若图片/数据在 run_dir 之外（沙箱里 MATLAB 批处理只能写外部目录），先 `bma_artifact_import` 导入 `artifacts/`；报告会扫描 `artifacts/` 并内嵌图片。不要把 run_dir 外的绝对路径留在报告里。
- 质量门豁免（`bma_gate_waive`）会渲染到“4B. 质量门与豁免（显式记录）”一节，并写入 model card 的 `gates`；局限性也会列出。报告正文必须引用这些记录，不能把豁免写成“已完成”。
- 报告构建返回的 `warnings` 要逐条处理：缺图、空章节、图片未内嵌、JSON 解析失败都不是“无所谓的噪声”。

## 0.8.5：报告图片去重与自适应宽度

- 报告会在 `report/figures` 生成 extra section 的图片副本；0.8.5 起不再把这些副本再次收进 §11“图表”，并按源路径/内容 SHA-256 排除 extra section 已用的图，避免同一张图出现 2–3 次。
- 大图/并排图自动受 `max-width:100%;height:auto` 约束；Markdown 表格用 fixed layout，原图/复现图不会撑破页面。
- 如果同一图片仍需在不同章节重复出现，这是内容选择而不是报告 bug；多数情况下应只在“文献图复现”矩阵展示一次。
