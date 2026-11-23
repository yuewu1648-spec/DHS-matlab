---
name: blind-literature-modeling
description: BLIND-LIT 盲文献建模协议：只用主文献摘要 + 全部参考文献重建主文献研究的问题/目标，机械封印主文献全文，逐篇参考文献逐字证据笔记，自检-修补-重建模多轮直到只剩 impossible/over_budget 问题，最后可选解封并对照原文献模型；在用户要求“摘要+参考文献”盲建模时加载。
whenToUse: 用户给出一篇主要原文献和全部参考文献，要求建模期间不得查看主文献摘要以外内容，或要求“盲重建/预注册”该文献的问题或模型时。
---

# BLIND-LIT：盲文献建模协议（0.15.0）

## 0. 三个不可协商的约束

1. **主文献只许看摘要。** 建模期间不得用 `read`/`pwsh`/`grep`/`bma_literature_ingest` 打开主文献文件；图、表、正文、参考文献表以外的内容都不行。唯一可读的是 `bma_blind_start` 写出的 `blind/primary_abstract.md`。`bma_literature_ingest` 会按路径和 SHA-256 拒绝主文献（同一工作区新建 run 也会被拒）；绕过封印的工具行为属于违反协议，不是“聪明”。
2. **每一篇参考文献都要看。** 不得抽样、不得只看标题、不得把主文献的参考文献表当作“读过全文”。每篇都要用 `bma_blind_note` 留下可核验笔记：至少一条逐字 `quote`（工具会到原文中比对，转述/编造会被拒绝），并说明它与主问题的关系。只有题录、扫描件无文本时，只能记 `citation_only` + `limited`，并在自检中作为证据缺口登记。
3. **停止必须满足判据，不能“感觉差不多了”。** 自检至少 `min_rounds`（默认 3）轮；所有问题只能是 `fixed` / `impossible` / `over_budget`；`impossible` 要说明为什么在一般情况下不可能解决（不是预算不够），`over_budget` 要满足已花费 ≥ 2× 申报预算。最后模型必须冻结（且每个 spec 通过 `bma_model_validate`）。

## 1. 与普通工作流的区别

普通流程 G1 是“通读主文献关键章节”。BLIND-LIT 中 G1/G2.5/G7（文献图复现）**不适用**：主文献的图与结果不可见，因此：

- 建模目标来自**摘要里的问题/目标**，不是主文献的结果或图；
- 机制、参数、条件只能来自**参考文献**；
- 不能承诺复现主文献图；能承诺的是“对摘要问题的可证伪预测 + 参考文献支持的结构/参数”；
- 解封后才可以（可选）读全文、看原图、对照原文献模型。

## 2. 产物布局

```
<run_dir>/blind/
├─ protocol.json            # 状态机：sealed/revealed、清单、coverage、selfcheck、freeze
├─ primary_abstract.md      # 唯一可读的主文献内容（摘要 + 元数据）
├─ seals.json              # 工作区级封印登记（在 <work_dir>/.bma/blind/）
├─ refs/<id>/text.txt      # 参考文献抽取文本缓存（供 quote 核验/阅读）
├─ notes/<id>.json         # 每篇参考文献的笔记与核验结果
├─ blind_summary.md        # stop 后生成的报告小节
├─ model_comparison.md     # 可选：解封后的模型对照
└─ model_comparison.json
```

## 3. 操作序列

### B0 识别材料（不要先偷看）

- 找主文献：用户明确给出的那一篇（路径/标题）。
- 找参考文献：一个目录（推荐）、一份 JSON 清单，或主文献的 References 列表。
- 分不清哪篇是主文献、或多篇候选时，用 `ask_user` 问一次；**不要**先 `bma_literature_ingest` 或 `read` 主文献来判断。
- 用 `todo_write` 建 B0–B8 列表（与普通 G0–G9 不混用）。

### B1 封印 + 摘要

```json
bma_blind_start({
  "primary_path": "<主文献绝对路径或相对 work_dir>",
  "references_dir": "<参考文献目录，递归扫描 PDF/DOCX/TXT/MD/HTML>",
  "min_rounds": 3,
  "budget_seconds": 0
})
```

- 摘要提取失败、或章节识别不可靠时：把**只含摘要**的 UTF-8 文本写成文件，用 `abstract_path` 传入。绝不“从正文里截一段当摘要”。
- 从主文献 References 列表起清单可用 `from_primary=true`：工具只返回题录字符串，不暴露正文；题录仍需逐篇找全文并读。
- 返回的 `run_dir` 固定不变；后续所有工具都传它。**不要中途换 run**（换 run 会丢掉协议；且同一工作区的封印登记仍会阻止读主文献）。
- 启动后 `matlab_status` 无需重复调用，除非后端异常。

### B2 问题/目标

```json
bma_blind_check({
  "run_dir": "<run_dir>",
  "action": "goal",
  "goal_json": {
    "question": "≥40 字：主文献摘要要研究/回答的问题（不是你的模型问题）",
    "objective": "≥20 字：本次建模要交付什么（结构、参数、可证伪预测）",
    "success_criteria": ["≥2 条可判定判据", "例如：能复现某方向/量级，或能区分两个机制"],
    "out_of_scope": ["明确不做什么（如主文献图复现、未给数据的定量拟合）"]
  }
})
```

问题必须来自摘要原文，不能自己发明一个更好做的问题。成功判据要能判定“通过/不通过”，不能写“模型合理”。

### B3 逐篇参考文献（核心）

先看 `bma_blind_check action:"status"` 的清单，拿到 `R1…Rn` 和 `path`。对每一篇：

1. **读**：`bma_literature_ingest` 处理该参考文件（或在 note 后读 `blind/refs/<id>/text.txt`），至少读摘要 + 结果/方法关键段；能做全文就全文。不要只看标题。
2. **记**：`bma_blind_note`，`note_json`：

```json
{
  "depth": "full_text",
  "title": "…",
  "year": 2019,
  "venue": "J Biol",
  "sections_read": ["abstract", "results", "methods"],
  "claims": [
    {
      "kind": "mechanism|parameter|condition|method|negative|review|background",
      "claim": "≥15 字：这条证据支持/否定了什么",
      "quote": "≥6 字符，必须能在原文中逐字找到（工具会核验）",
      "location": "Abstract / Results 第 2 段 / Fig. 3 caption"
    }
  ],
  "parameters": [{"symbol": "Km", "value": 12.5, "unit": "uM", "context": "葡萄糖，野生型"}],
  "relevance": {
    "question_link": "≥30 字：这篇文献与主文献摘要问题的关系",
    "modeling_use": "mechanism|parameter|constraint|comparison|background|none"
  },
  "modeling_use": "具体写它进了哪个候选机制/参数/约束",
  "limitations": "只能看摘要/数据条件不同等"
}
```

- **quote 是硬门**：工具把 quote 与参考文献文本（空白/引号/连字符归一化后）比对；找不到就报 `BMA_QUOTE_NOT_FOUND` 并列出失败项。不要改几个字“意思一样”；按 `blind/refs/<id>/text.txt` 或原文复制。
- **没有可用全文**：`depth:"citation_only"`、`access_limited_reason`（≥60 字）、`no_modeling_content:true` + `no_modeling_content_reason`（≥80 字）。它会记为 `limited`，必须在自检里作为证据缺口登记，不能充当已读。
- **确实无关的文献**：才可 `no_modeling_content:true`；工具/停止判据会限制比例（超过 30% 或 2 篇会阻止 stop）。不要把不相关当借口批量糊弄。
- 参数值只有在原文出现时才写 measured/estimated；否则在 spec 里写 assumed 并说明依据，别把参考文献里的“典型值”冒充实测。

### B4 建模

- 先写**≥2 个候选机制**（若证据只支持一个，也要写清为什么排除另一个：缺乏证据/与热力学矛盾/与时间尺度不符），各给可证伪预测（什么实验/观测会让它失败）。
- 按 `bio-modeling-workflow` 写 `bma.modelSpec.v1`：变量/参数/输出有单位；参数带 `evidence`（quote 必须来自参考文献，**不得伪造主文献正文引用**）或显式 `assumed`；速率定律只用白名单。
- 摘要没给的机制/参数，明确标注“文献未给/assumed/fitted”；模型是对摘要问题的**盲预测**，不是对主文献结果的拟合。
- 结构分析、仿真、拟合按普通流程做；自写 Newton/FEM/延拓先过 A2/A3（见 `bio-modeling-workflow` 6.5）。

### B5 自检循环（至少 3 轮，工具强制）

每一轮都必须是“检查 → 找问题 → 修补/重建模 → 再检查”，不是复述上一轮。用 `bma_blind_check action:"round"`：

```json
{
  "summary": "≥80 字：本轮查了什么、发现什么、怎么修、下轮做什么",
  "checks": [
    {"name": "alignment", "result": "pass|fail|skipped", "evidence": "对应成功判据/工具返回/数值"},
    {"name": "coverage", "result": "pass", "evidence": "read n/n; limited 0"},
    {"name": "spec", "result": "pass", "evidence": "bma_model_validate valid=true"},
    {"name": "structure", "result": "pass", "evidence": "conservation 2 laws; stable SS"},
    {"name": "numerics", "result": "pass", "evidence": "simulate t=0..30 min; r_rel=..."},
    {"name": "evidence", "result": "pass", "evidence": "每个参数有 quote/assumed 标记"}
  ],
  "issues": [
    {"category": "identifiability", "severity": "P1", "title": "…", "detail": "…"},
    {"id": "I1", "status": "fixed", "fix_kind": "model|parameter|evidence|report|method",
     "fix": "≥20 字怎么改的", "evidence": "≥10 字修复后的验证结果"}
  ],
  "model_specs": [{"name": "m1", "spec_path": "<run>/models/m1/spec.json", "role": "primary"}],
  "elapsed_seconds": 600
}
```

每轮至少要覆盖的审计维度（按模型实际能力取舍，但 `skipped` 必须写 reason）：

1. **对齐**：模型状态/输出是否真的回答 B2 的问题与成功判据（不是回答别的问题）。
2. **覆盖**：`coverage` 是否完整；`limited` 是否登记；有没有把题录当全文。
3. **机制**：≥2 候选、取舍理由、可证伪预测。
4. **结构**：`bma_model_validate`、`bma_model_analyze`（守恒/稳态/量纲）。
5. **数值**：仿真/拟合/敏感性/可辨识性；自写求解器 A2/A3；收敛/预算。
6. **证据**：参数值可溯源；quote 来自参考文献；assumed/fitted 标清。
7. **报告/诚信**：未读、未跑、不可辨识、超预算必须写明，不能声称完成。

问题台账规则（工具强制）：

- 每条问题必须有 `category`（evidence/coverage/units/structure/parameters/identifiability/numerics/reproduction/reporting/other）、`severity` P0–P3、`title`、`detail`。
- `fixed`：`fix` ≥20 字、`fix_kind`、`evidence` ≥10 字。
- `impossible`：`reason` ≥80 字 + `why_general` ≥60 字（为什么不是预算问题，而是原理上不可解）+ `evidence` ≥20 字（试过什么、为什么失败）。
- `over_budget`：`reason` ≥80 字 + `evidence` ≥20 字 + `budget:{spent_s,limit_s}`，且 `spent_s ≥ 2*limit_s`。
- 任何 `fix_kind:"model"` 必须提交新的 `model_specs` 且 spec SHA-256 与上一轮不同；只改措辞不算重建模。
- 每轮新增/关闭问题都要在下轮可见；不要用“已修复”关闭一个没有具体修复动作的问题。

### B6 冻结 + 停止

```json
bma_blind_check({"run_dir": "<run_dir>", "action": "freeze",
  "models_json": "[{\"name\":\"m1\",\"spec_path\":\"<run>/models/m1/spec.json\",\"role\":\"primary\"}]"})
```

- 冻结会对每个 spec 跑 `bma_model_validate`，必须 `valid=true`；hash 记录在协议里。
- 然后 `action:"stop"`。工具会计算：目标已记录、参考文献 read/limited 全覆盖、轮次 ≥ min_rounds、无 open 问题、impossible/over_budget 论证齐全、模型已冻结。任何一项不满足都会 `BMA_STOP_BLOCKED` 并列出原因。
- `verdict:"passed"` 表示没有剩余不可解问题；`verdict:"stopped_with_limits"` 表示有 impossible/over_budget 项，必须写 ≥60 字 `note`。
- stop 写入 `blind/blind_summary.md`，这是报告必须嵌入的小节。

**什么算 impossible（一般性）**：数据在原理上不可辨识（组合量也定不下来）、文献互相矛盾且无法用现有证据裁决、模型类缺少描述该现象的必要物理（如需要三维场但只能 1D）、参考文献全文确实不可得且无替代证据。**不算**：没时间、没预算、懒得再跑、工具超时（这些要么记为 over_budget 并给 2× 预算，要么继续）。

### B7 可选解封与对照（用户要求或 stop 后）

```json
bma_blind_reveal({"run_dir": "<run_dir>", "action": "reveal",
  "reason": "用户要求/交付需要对照"})
```

- `reveal` 只在 stop 通过且模型冻结后允许；失败会恢复封印。
- 解封后可以 `read` 主文献 `text.txt`、看 `figures/`、重新考虑机制。**这时才允许读全文。**
- 对照必须用 `action:"compare"`，8 个维度全给：

```json
{
  "dimensions": [
    {"key":"question","agent":"…","paper":"…","agreement":"match|partial|diverge|not_comparable","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"model_class","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"state_variables","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"mechanisms","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"parameters","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"assumptions","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"behavior","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"},
    {"key":"evidence_use","agent":"…","paper":"…","agreement":"…","evidence":"…","gap":"…","follow_up":"…"}
  ],
  "verdict": "close|partial|diverge|not_comparable",
  "summary": "≥100 字：哪些一致、哪些不一致、为什么（数据/摘要信息量/机制选择）",
  "limitations": "摘要未给数值、limited 文献、不可辨识参数等"
}
```

- `partial`/`diverge` 维度必须给 `follow_up`。`paper` 没写就写“文中未给出……”，不能留空。
- 对照结论要诚实：盲建模期间没看到的内容，不能在报告里说成建模时已知；解封后修正的内容要标注“解封后修正”。

### B8 交付

- `bma_report_build` 的 `extra_sections_json` 必须包含：
  1. `blind/blind_summary.md`（协议、覆盖、轮次、问题台账、停止判定）；
  2. 若已解封：`blind/model_comparison.md`。
- 报告的“局限”必须写：只用了摘要 + 参考文献；主文献全文未参与建模；哪些参考文献 limited；哪些 impossible/over_budget；模型对摘要问题的预测能力边界。
- 最终答复用中文：**结论 → 盲建模协议摘要（覆盖/轮次/停止判定）→ 模型与证据 → 自检发现与修补 → （可选）解封对照 → 局限与下一步**。
- 用户没要求解封时，不要擅自解封；如果用户要求“看看原文模型”，先确认是否已 stop/冻结，再 reveal。

## 4. 常见失败模式（自检时优先查）

| 失败 | 表现 | 正确做法 |
|---|---|---|
| 偷看主文献 | 用 read/ingest 打开主文献；引用主文献正文 | 只用摘要；ingest 会被拒；引用必须来自参考文献 |
| 摘要式敷衍 | 每篇参考文献只写一句“相关” | 每篇至少一条可核验 quote + 与主问题的关系 |
| 题录当全文 | `from_primary` 后直接说“读完了” | 找全文；没有就 limited + 证据缺口 |
| 把无建模价值当免死金牌 | 大量 `no_modeling_content` | 超过 30%/2 篇会阻止 stop；补读或记为缺口 |
| 伪修复 | `fix_kind:"model"` 但 spec hash 未变 | 真正改模型并提交新快照，或改 fix_kind |
| 假停止 | 还有 open 问题就 stop | 先修/降级并写理由；工具会拒绝 |
| 滥用 impossible | 因为跑得慢就写 impossible | 慢/贵记 over_budget（≥2× 预算）；impossible 只给原理性障碍 |
| 摘要误抽 | 摘要夹带引言/正文 | 用 `abstract_path` 提供只含摘要的文本 |
| 解封后改写历史 | 把原文机制说成建模时就用了 | 对照表 `evidence_use` 如实写盲建模用了什么；解封后修正要标注 |

## 5. 最小命令序列（伪代码）

```text
todo_write(B0..B8)
bma_blind_start(primary_path, references_dir, min_rounds=3)
read(blind/primary_abstract.md)
bma_blind_check(action="goal", goal_json={...})
for each R in status.references:
    bma_literature_ingest(ref.path) / read(blind/refs/R/text.txt)
    bma_blind_note(R.id, note_json={claims:[{quote,...}], relevance:{...}})
write spec.json
bma_model_validate(spec_path) -> valid
bma_model_analyze/simulate/fit/...  # 按需
for round in 1..min_rounds:
    bma_blind_check(action="round", round_json={summary, checks, issues, model_specs})
    if open issues: 修补 -> 重新 validate/analyze -> 下一轮
bma_blind_check(action="freeze", models_json=[{name,spec_path,role:"primary"}])
bma_blind_check(action="stop", verdict="passed|stopped_with_limits", note=...)
# 可选（用户要求）：
bma_blind_reveal(action="reveal")
read(主文献 text.txt / figures)
bma_blind_reveal(action="compare", comparison_json={8 dims, verdict, summary})
bma_report_build(..., extra_sections_json=["blind/blind_summary.md","blind/model_comparison.md"])
```
