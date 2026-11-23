# BLIND-LIT 盲文献建模协议（0.15.0）

> 目标：只用**主文献摘要** + **全部参考文献**，重建主文献所研究的问题/目标对应的数学模型；建模期间机械封印主文献全文；自检-修补-重建模多轮，直到剩余问题只能是“一般不可解”或“极度过预算”；最后可选解封，对照自己的模型与原文献模型。
>
> 这是 `bma_blind_*` 四个工具的规范性说明。agent 的操作流程见 `bridge/skills/blind-literature-modeling/SKILL.md`；工具/方法对照见 `docs/TOOL_REFERENCE.md`。

## 1. 设计立场

普通建模流程假定可以通读主文献。BLIND-LIT 刻意破坏这个前提，用来检验 agent 是否真的能从**问题陈述（摘要）**与**邻近证据（参考文献）**独立构建可证伪模型，而不是把主文献的结论“抄”进模型。

因此协议有三条不可协商的规则：

1. 主文献只暴露摘要；全文的读取由工具拒绝，不靠自觉。
2. 每一篇参考文献都要留下**逐字可核验**的证据笔记；quote 由工具到原文比对。
3. 停止由台账判据决定，不由“感觉差不多了”决定；剩余问题必须分类为 fixed / impossible / over_budget。

## 2. 工具与 RPC

| 工具 | MATLAB 方法 | Worker | 用途 |
|---|---|---|---|
| `bma_blind_start` | `blind.start` | heavy | 封印主文献、只抽摘要、建参考文献清单 |
| `bma_blind_note` | `blind.note` | heavy | 逐篇参考文献笔记 + quote 核验 + coverage |
| `bma_blind_check` | `blind.check` | control | goal / references / round / freeze / stop 台账 |
| `bma_blind_reveal` | `blind.reveal` | heavy | 解封（stop 后）+ 8 维模型对照 |

`bma.io.ingest` 在读取前调用 `bma.blind.enforceSeal`，因此任何调用路径（包括 `bma_literature_ingest` 以及 MATLAB 内部直接调用）都会命中封印。

## 3. 封印模型（两层）

| 层 | 文件 | 作用 |
|---|---|---|
| run 级 | `<run_dir>/blind/protocol.json` 的 `guard.sealed` | 保护当前 run 的 ingest |
| 工作区级 | `<work_dir>/.bma/blind/seals.json` | 防止“新建一个 run 再 ingest”绕过封印 |

匹配规则：主文献**规范路径相同**或**SHA-256 相同**都拒绝。`bma_blind_reveal` 在 ingest 之前把两层都置为未封印；若 ingest 失败则回滚为封印。

诚实性边界：agent 仍拥有通用文件工具，若违反协议直接用 `read`/`pwsh` 打开主文献，工具层无法检测。协议把它定义为**违反协议**，并在报告的诚信声明中要求写明“未读取全文”。机械封印覆盖的是“误调用 ingest / 换 run 绕过 / 复制文件改名”这类可自动阻止的路径。

## 4. 数据模型（`protocol.json`，schema `bma.blindProtocol.v1`）

```json
{
  "schema": "bma.blindProtocol.v1",
  "run_id": "r20261123-...",
  "status": "sealed",
  "created_at": "2026-11-23T...",
  "updated_at": "...",
  "primary": {
    "source_path": "<abs>",
    "source_rel": ".bma/.../paper.pdf",
    "bytes": 123456,
    "sha256": "64 hex",
    "title": "...",
    "format": "pdf",
    "abstract": {
      "text": "只含摘要",
      "source": "section|regex_heading|regex_inline|provided_file",
      "section_id": "s2",
      "confidence": "high|medium|low",
      "chars": 1234,
      "warnings": []
    },
    "sealed_at": "..."
  },
  "guard": {"sealed": true, "ingest_blocked": true, "full_text_exposed": false, "note": "..."},
  "options": {"min_rounds": 3, "budget_seconds": 0, "max_references": 300, "allow_citation_only": true},
  "question": {
    "question": "≥40 字，来自摘要",
    "objective": "≥20 字",
    "success_criteria": ["≥2 条可判定判据"],
    "out_of_scope": [],
    "recorded_at": "..."
  },
  "references": [
    {
      "id": "R1", "citation": "...", "path": "...", "abs_path": "...",
      "url": "", "doi": "", "bytes": 0, "sha256": "...", "format": "pdf",
      "access": "file|citation_only|url", "status": "pending|read|limited",
      "note_path": "blind/notes/R1.json", "text_path": "blind/refs/R1/text.txt",
      "text_chars": 0, "depth": "full_text|abstract_only|citation_only",
      "verified": true, "read_at": "...", "access_limited_reason": "",
      "added_from": "dir|list|bibliography", "source": "file|list|bibliography",
      "no_modeling_content": false, "claims_count": 0,
      "quotes_verified": 0, "note_status": "verified"
    }
  ],
  "coverage": {
    "total": 0, "read": 0, "verified": 0, "limited": 0, "pending": 0,
    "no_modeling": 0, "with_claims": 0, "percent": 0, "complete": false,
    "blocking_ids": [], "limited_reasons": [],
    "depths": {"full_text": 0, "abstract_only": 0, "citation_only": 0, "none": 0}
  },
  "model": {
    "frozen": false, "current": 0, "versions": [],
    "primary_spec": "", "primary_sha256": "", "latest": {"round": 1, "models": []}
  },
  "selfcheck": {
    "rounds": [], "issues": [], "rounds_completed": 0,
    "started_at": "...", "elapsed_seconds": 0,
    "stop": {"met": false, "verdict": "", "note": "", "evaluated_at": "", "reasons": []},
    "summary_path": "blind/blind_summary.md"
  },
  "reveal": null
}
```

## 5. 摘要提取

优先级：

1. `abstract_path` 提供的外部摘要（权威）；
2. sectionize 识别到的 Abstract/Summary 章节（`confidence=high`）；
3. 行锚点 `^\\s*Abstract\\s*$`（`medium`）；
4. 行内 `Abstract: ...`（`low`，可能夹带引言，出现 warning）。

都失败时抛 `bma:blind:abstract_not_found`，**不猜**、不返回正文。摘要长度上限：外部 12000、section 6000、行内 4000 字符；截断会 warning。摘要档案 `blind/primary_abstract.md` 只含摘要与元数据。

真实出版社/双栏 PDF 的 Abstract 可能被 Text Analytics 拆散或乱序（例如 "Abstract" 后直接正文、摘要在版面上被前一栏截断）。这种情况工具宁可报 `BMA_ABSTRACT_NOT_FOUND`，也不返回半段摘要或正文；请用 `abstract_path` 提供只含摘要的 UTF-8 文本。已实测：合成 fixture `paper.pdf` 可得到 section 摘要（1360 字符）；Springer 双栏 review `s00421-002-0676-3.pdf` 会正确拒绝（需外部摘要）。

## 6. 参考文献

来源可组合：

- `references_dir`：递归扫描 `.pdf/.docx/.txt/.md/.markdown/.html/.htm`，排除主文献（路径 + SHA-256）。
- `references_json`：JSON 数组或 JSON 文件路径；元素为字符串（题录）或 `{citation, path, url, doi}`。
- `from_primary=true`：只从主文献 References 章节抽题录字符串（工具内部解析，不暴露正文/参考文献章节原文）。

`bma_blind_note` 的核验：

- 对有文件的条目：抽取全文文本到 `blind/refs/<id>/text.txt`（按 SHA-256 缓存），把每条 claim 的 `quote` 归一化（大小写/空白/弯引号/破折号/软连字符）后做子串匹配；失败报 `BMA_QUOTE_NOT_FOUND` 并列出失败 quote。
- 对只有题录的条目：只能核对题录字符串；`depth=citation_only`、`access_limited_reason`（≥60 字），status=`limited`。
- 无法抽取文本的扫描件：同样只能 limited；不能假装 verified。
- `no_modeling_content=true` 需要 reason（≥80 字）；coverage 记录 `no_modeling` 比例，`evaluateStop` 对“超过 30% 或 2 篇”的情况阻止 stop，防止“批量标记无关”的形式主义。

## 7. 自检与问题台账

`round` 输入：

```json
{
  "summary": "≥80 字",
  "checks": [{"name": "...", "result": "pass|fail|skipped", "evidence": "..."}],
  "issues": [
    {"category": "evidence|coverage|units|structure|parameters|identifiability|numerics|reproduction|reporting|other",
     "severity": "P0|P1|P2|P3", "title": "≥10", "detail": "≥20",
     "status": "open|fixed|impossible|over_budget",
     "fix": "≥20", "fix_kind": "model|parameter|evidence|report|method", "evidence": "≥10",
     "reason": "≥80", "why_general": "≥60", "budget": {"spent_s": 0, "limit_s": 0},
     "covers_references": ["R3"]}
  ],
  "model_specs": [{"name": "m1", "spec_path": "...", "role": "primary|alternative"}],
  "elapsed_seconds": 600
}
```

校验规则：

- ≥3 个 checks；每个必须有 name/result/evidence；有 `fail` 必须至少一条 issue。
- 新 issue 必须有 category/severity/title/detail；id 由工具分配（`I1…`），更新已有 issue 必须带 id。
- `fixed`：fix ≥20、fix_kind ∈ {model,parameter,evidence,report,method}、evidence ≥10。
- `impossible`：reason ≥80、why_general ≥60、evidence ≥20。
- `over_budget`：reason ≥80、evidence ≥20、budget.spent_s ≥ 2×limit_s（limit_s>0）。
- `fix_kind="model"`：必须提交 `model_specs`，且至少一个 spec 的 SHA-256 与上一轮不同；否则 `BMA_MODEL_UNCHANGED`。
- 每个 spec 必须是可通过 `bma.spec.validate` 的 `bma.modelSpec.v1`；否则 `BMA_MODEL_INVALID`。

每个 round 保存 checks/issues/新增与关闭项/model 快照；round 会重置 stop（需要重新判定）。

## 8. 停止判据（`stop`）

全部满足才允许：

1. `question.question` 已记录；
2. 参考文献总数 > 0；`read == total`，或 `limited`/`pending` 的 id 全部被某个 `impossible`/`over_budget` 问题的 `covers_references` 覆盖；`no_modeling` 不超限；
3. `rounds >= min_rounds`（默认 3，最小 2）；
4. 没有 `open` 问题；
5. 每个 `impossible`/`over_budget` 重新校验论证字段与预算比例；
6. `model.frozen == true` 且至少有一次冻结版本。

不满足时 `bma:blind:stop_blocked` 返回全部原因。`stop` 写 `blind/blind_summary.md`；`verdict=passed|stopped_with_limits`，后者需要 `note ≥60` 字。

## 9. 解封与对照

`reveal` 的前置：`status=sealed` + stop 通过 + 模型冻结。步骤：

1. 把 `guard.sealed=false`（run + 工作区登记）并保存；
2. `bma.io.ingest` 主文献到 `<run_dir>/literature/<doc_id>/`；
3. 失败则回滚封印；
4. 记录 `reveal {revealed_at, doc_id, text_path, sections_path, figures_path, char_count}`。

`compare` 要求 8 个维度齐全：

`question, model_class, state_variables, mechanisms, parameters, assumptions, behavior, evidence_use`

每维：`{key, agent≥8, paper≥8, agreement:match|partial|diverge|not_comparable, evidence≥10, gap, follow_up}`；`partial`/`diverge` 必须给 `follow_up≥10`。顶层：`verdict`、`summary≥100`、`limitations?`。写 `blind/model_comparison.json|md`。

## 10. 产物与报告

| 产物 | 用途 |
|---|---|
| `blind/protocol.json` | 状态机与全部台账（可审计） |
| `blind/primary_abstract.md` | 唯一允许阅读的主文献内容 |
| `blind/refs/<id>/text.txt` | 参考文献缓存（供 quote 核验/精读） |
| `blind/notes/<id>.json` | 逐篇笔记 + 核验结果 |
| `blind/blind_summary.md` | stop 后生成的报告小节（覆盖/轮次/问题/停止判定） |
| `blind/model_comparison.md` | 解封后 8 维对照 |

报告必须把 `blind_summary.md`（和已生成的 `model_comparison.md`）作为 `bma_report_build` 的 `extra_sections_json` 嵌入；局限必须写明盲建模证据边界。

## 11. 版本兼容

- 0.15.0 新增，MINOR：4 个 `bma_blind_*` 工具、`blind.*` RPC 方法、`blind/` 产物；旧工具名/参数/返回不变。
- `bma.io.ingest` 新增封印检查；没有 blind 协议的 run 行为完全不变。
- `bma.util.sha256File` 为复用工具（artifact import 改为调用它，行为不变）。
