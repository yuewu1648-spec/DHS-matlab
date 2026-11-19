# BioModel-MATLAB 知识库（kb/）

> agent 的「生物系统学 + 数学/物理/化学生物学」知识来源：读文献 → `bma_kb_search` 检索 → `bma_kb_get` 取条目 → 用 `spec_template` 作为 `bma.modelSpec.v1` 起点 → 校验/仿真/拟合。内容不是文献摘要，而是**可执行的建模知识**：识别信号、方程、可直接粘贴的规格片段、参数典型范围、拟合与可辨识性提示、真实经典文献。

维护：kb-author；契约：`docs/DESIGN.md` §3（模型规格）、§9（知识库格式）。本 README 是 kb 格式的单一事实来源。

## 1. 目录与文件

```
kb/
├─ README.md                      本文件
├─ ontology.json                  生物层次 × 尺度 × 模型类别（含 MATLAB 实现建议）
├─ units.json                     单位权威词表（84 单位 / 20 量纲；供 spec 单位校验）
├─ archetypes/                    13 个模型原型
│  enzyme_kinetics · gene_expression · hill_regulation_toggle · negative_feedback_oscillator
│  receptor_ligand_dose_response · mapk_cascade · metabolic_pathway · population_dynamics
│  sir_seir · pharmacokinetics · hodgkin_huxley · reaction_diffusion_turing · chemotaxis
└─ principles/                    14 个建模原理
   mass_action · conservation_stoichiometry · dimensional_analysis · qssa_approximation
   hill_cooperativity · fick_diffusion · nernst_potential · thermodynamic_constraints
   stochasticity_noise · network_motifs · stability_hopf · r0_next_generation
   matlab_pde_toolbox_pitfalls · numerical_convergence_checklist
```

29 个 JSON：UTF-8 无 BOM、`jsondecode` 可解析、全局 `id` 唯一、单文件 8-20.5KB。

## 2. 通用字段

| 字段 | 说明 |
|---|---|
| `id` / `type` | 全局唯一 snake_case；`archetype`\|`principle`（ontology/units 的 type 分别为 `ontology`/`units`） |
| `name` / `name_en` | 中/英文名称；`summary` 3-6 句中文摘要 |
| `domain` / `scale` / `model_class` | 领域；`scale` 取 ontology.levels id（molecule/pathway/cell/tissue/organ/organism/population/ecosystem）；`model_class` 取 ontology.model_classes id（ode/dae/pde/stochastic/discrete/boolean/constraint_based/statistical/hybrid） |
| `keywords` / `tags` | 中英混合关键词（io 检索按中文 2-gram、英文词加权）；英文短标签用于 `kb_list(tag)` |
| `related` | 关联条目 id（跨 archetype/principle） |
| `metadata` | author、version、design_ref；可有 sibling_example / pde_note |

`bma.kb.index` 应只把 `archetypes/*.json` 与 `principles/*.json` 当可检索条目；`ontology.json`/`units.json` 为单例资源（按 id 特殊处理）。

## 3. archetype 字段

| 字段 | 说明 |
|---|---|
| `when_to_use` | 文献识别信号：出现什么术语/实验设计/数据形态时选该模型 |
| `equations` | `{name, latex, plain, terms}`；latex+plain 双版本；terms 解释符号与单位 |
| `spec_template` | **完整 bma.modelSpec.v1 对象**（见 §5），可直接粘贴/校验 |
| `spec_notes` | 变体与扩展（抑制、反馈、二室、PDE 离散、随机化等） |
| `variables` / `parameters` | 目录 `{id,name,unit,typical_range,notes}`（参数另含 `symbol`）；id 必须与 spec_template 一致 |
| `assumptions` | 建模假设（报告强制引用） |
| `evidence_cues` | 参数级证据线索（文献中数值+单位+符号形式，如 `Km = 12.5 uM`、`R0 ≈ 2.5`） |
| `fitting_notes` | 数据变换、权重、初值、多起点、模型比较、失败处理 |
| `identifiability_notes` | 哪些参数/组合不可辨识、需补什么实验、哪些近似导致偏差 |
| `references` | `{citation, authors[], year, title, journal, volume?, pages?, doi?, note?}`；真实文献，DOI 不确定则省略 |

**terms key 约定**：`terms`/`formulas` 对象 key 一律 ASCII（`S`、`dx`、`usage`、`note`），中文解释在 value 中——MATLAB `jsondecode` 会用 `makeValidName` 改写非 ASCII key（`"Δx"`→`"x_x"`），ASCII key 保证 `bma_kb_get` 可读。

## 4. principle 字段

`statement`（正式陈述+适用条件）、`formulas[]`（latex+plain+terms）、`modeling_implications`（对建模决策的影响）、`how_to_apply`（可操作步骤）、`pitfalls`（常见误用）、`matlab_notes`（bma.* 实现建议）、`spec_mapping`（落到哪个速率 kind/字段）、`diagnostics`（自检指标）、`references`。

## 5. spec_template 与 bma.modelSpec.v1 的映射

`spec_template` 是完整 spec：`schema_version:"bma.modelSpec.v1"`、`name`（`[A-Za-z][A-Za-z0-9_]*`）、`title`、`description`、`kind:"ode"`、`time:{unit,start,end,n}`、`compartments?`、`variables`、`parameters`、`reactions`、`outputs`、`assumptions`、`metadata`。

- `variables[]`：`{id,name,unit,initial:{value,note?}}`（可选 compartment）。
- `parameters[]`：`{id,name,unit,value:{value},estimate,bounds?}`；`estimate:true` 必须有递增 bounds，初值落在 bounds 内。
- `reactions[]`：`{id,name,stoichiometry:{species_id:coef},rate:{kind,...}}`（系数负=消耗、正=生成）。
- 速率定律仅 5 类：`mass_action`（k, species{id:order}）、`michaelis_menten`（vmax,km,substrate；可选 inhibitor{species,ki,type}）、`hill`（vmax,k,n,regulator,mode）、`constant`（k）、`expression`（仅变量/参数/compartment id 与 `+ - * / ^ exp log sqrt min max`、括号、数字）。
- `outputs[]`：`{id,name,unit,expression}`（变量 id 或受限表达式，可用于缩放/比值/派生通量）。
- **速率参数只写参数 id 字符串**（`"k":"kf"`），数值全部在 `parameters[].value`。
- **单位取 `kb/units.json` 的 id/aliases**；已声明示例：`nM uM mM M`、`s ms min h day`、`1/s 1/min 1/h 1/day`、`1/(uM*s) 1/(nM*s) 1/(nM*min) 1/(nM*h)`、`uM/s uM/min nM/min nM/s`、`person individual cell`、`L mL uL`、`mg L mg/L`、`um cm mm um^2/s cm^2/s`、`mV mV/ms uA/cm^2 mS/cm^2 uF/cm^2`、无量纲 `"1"`。
- v1 仅 `kind:"ode"`：PDE 用空间离散成 ODE 交换项；随机/离散模型在 metadata 记录随机化参数（体积、初始分子数、种子）并在报告说明。
- 模板的估计参数只给典型初值、无文献 evidence；validate 会报 `BMA_SPEC_WARN_NO_EVIDENCE`（有意为之），agent 使用时按实际文献补 evidence（measured/estimated/assumed/fitted）。

## 6. units.json（schema `bma.kb.units.v2`）

```json
{"schema_version":"bma.kb.units.v2",
 "dimensions":{"concentration":"...", ...},
 "units":[{"id":"uM","dim":"concentration","factor":1e-6,"base":"M","symbol":"uM",
           "aliases":["µM","μM","umol/L"],"note":"..."}, ...],
 "conventions":[...], "model_spec_unit_rules":{...}, "notes":[...]}
```

- **`units` 是数组而非 id 键对象**：`jsondecode` 会把非法标识符 key 改写（`"1"→"x1"`、`"1/s"→"x1_s"`），数组元素字段全 ASCII（id/dim/factor/base/symbol/aliases/note），id 原样保留。旧对象格式已废弃（Lead 已更新 DESIGN）。
- 查找：按 `units[i].id`（大小写敏感）；`aliases` 只作附加别名；`base` 必须是另一 unit id（`count` 等基准已声明）。`factor` = 换算到 base 的倍数（`uM→1e-6 M`、`min→60 s`、`1/(uM*s)→1e6 1/(M*s)`）。
- spec.validate 的 units_check 以本表为权威：找不到 → `BMA_UNIT_UNKNOWN`（hint 列相近 id）；同 dim 不同 factor 相加减 → `BMA_UNIT_MISMATCH`。复合单位（`mS/cm^2`、`uA/cm^2`、`mV/ms`、`um^2/s`、`1/(nM*h)`）已显式列入，**禁止大小写回退现场解析**（历史上 `mS` 被 `strcmpi` 误配 `ms`=毫秒）。
- 电生理量纲需 8 个 base（…/count/**current**）；`voltage/current_density/conductance_per_area/capacitance_per_area/voltage_rate` 映射见 dimensions/notes。
- 约定：微写 `u`（uM、um、uL、uA）不写 µ/μ；速率参数时间单位与 `spec.time.unit` 一致或可换算；新增单位同步更新全部字段并登记。

## 7. ontology.json

`levels[]`（分子→通路→细胞→组织→器官→个体→种群→生态系统，含 description/examples/typical_questions/common_models/model_spec_class/time_scale/matlab_impl）；`scales[]`（空间 nm→km、时间 ms→year，附建模提示）；`model_classes[]`（ode/dae/pde/stochastic/discrete/boolean/constraint_based/statistical/hybrid，含 when/spec_mapping/matlab_impl）；`cross_cutting_rules[]`（选粒度、v1 限制、单位/区室声明、可辨识性随层次变化）。archetype 的 `scale/model_class` 使用相同词表。

## 8. agent 使用流程

1. `bma_kb_list`/`bma_kb_search(query,tags)`：用机制词、模型名、参数名（中英混合）检索，先看 `summary` 是否同构。
2. `bma_kb_get(id)`：核对 `when_to_use`/`assumptions` 与文献；取 `spec_template` 为起点，改 `name/title/time/初值/参数值`，补 `metadata.source_docs` 与参数 `evidence`。
3. 读对应 `principles/*` 解释假设（QSSA 条件、单位、热力学约束、稳定性判据等）。
4. `bma_model_validate` → 修复（错误码/hint）→ `bma_model_analyze`（守恒/稳态/稳定性/量纲）→ `bma_model_simulate`。
5. 参数确定：优先 `evidence_cues` 数值；`fitting_notes` 给加权/多起点建议；`identifiability_notes` 解释偏差与补实验设计。
6. 报告：引用条目 `assumptions` 与 `references`；用了 `spec_notes` 变体（PDE 离散、随机化、二室）须在局限性中说明。

检索契约：条目含 `id/type/name/summary/tags/keywords`；`kb.search` 返回 `score/matched_terms/path`；`kb.get` 返回完整 JSON。

## 9. 覆盖矩阵

| archetype | domain | scale | model_class | spec 速率 kind |
|---|---|---|---|---|
| enzyme_kinetics | enzyme_kinetics | molecule | ode | michaelis_menten, mass_action |
| gene_expression | gene_expression | cell | ode | constant, hill, mass_action |
| hill_regulation_toggle | gene_regulation | pathway | ode | hill, mass_action |
| negative_feedback_oscillator | dynamics | pathway | ode | hill, constant, mass_action |
| receptor_ligand_dose_response | receptor_pharmacology | molecule | ode | mass_action |
| mapk_cascade | signaling | pathway | ode | expression, constant, mass_action |
| metabolic_pathway | metabolism | pathway | ode | michaelis_menten, constant, mass_action |
| population_dynamics | population | population | ode | expression, mass_action |
| sir_seir | epidemiology | population | ode | expression, mass_action |
| pharmacokinetics | pharmacokinetics | organism | ode | mass_action |
| hodgkin_huxley | electrophysiology | cell | ode | expression |
| reaction_diffusion_turing | spatial_pattern | tissue | pde（v1 离散为 ode） | expression, mass_action |
| chemotaxis | cell_migration | cell | pde（v1 两室 ode） | expression, mass_action, constant |

| principle | 核心判据/公式 |
|---|---|
| mass_action | v=k∏x^ν；k 单位随级数；kf/kr=Keq |
| conservation_stoichiometry | lᵀS=0→守恒；S·v=0→稳态通量 |
| dimensional_analysis | 量纲齐次；π 定理；尺度不变性→不可辨识 |
| qssa_approximation | ε=E0/(S0+Km)<<1；tQSSA 二次式 |
| hill_cooperativity | θ=xⁿ/(Kⁿ+xⁿ)；n≤位点数；MWC/Adair |
| fick_diffusion | J=-D∇c；t~L²/D；Da/Thiele |
| nernst_potential | E_X=(RT/zF)ln(out/in)；GHK |
| thermodynamic_constraints | ΔG<0 方向；细致平衡/Wegscheider；Haldane |
| stochasticity_noise | CME/SSA；Fano=1+b；内外禀分解 |
| network_motifs | FFL coherent/incoherent；自调控噪声 |
| stability_hopf | Re λ<0 稳定；Hopf Re λ=0；鞍结 det J=0 |
| r0_next_generation | R0=ρ(FV⁻¹)；R0<1⇔DFE 稳定；Hc=1−1/R0 |
| matlab_pde_toolbox_pitfalls | decsg 集合运算/系数方向/源项符号/相切几何等静默陷阱；A2/A3 求解器预检 |
| numerical_convergence_checklist | 收敛≠正确；A2 雅可比方向导数、A3 方程残差、守恒、方向、解析极限、网格收敛 |

覆盖检查：12 个必需 archetype 主题（酶、基因表达、Hill/toggle、负反馈振荡、受体-配体、级联、代谢、种群、SIR/SEIR、PK、HH、Turing）全覆盖；趋化单独成文件（共 13）。12 个必需 principle 全覆盖，0.5.0 新增 2 个数值工程 principle（PDE 陷阱、收敛自检）。

## 10. 校验与自检

MATLAB 侧（`bma.spec.validate`，共享 RPC，2026-11-12，core 修复后第三轮）：13 个 `spec_template` 逐个提交（params `{"spec":<spec_template>,"run_dir":".bma/runs/kb-validate"}`）。

| 结果 | 数量 | 说明 |
|---|---|---|
| `valid=true` | **13/13** | 0 error；仅 `BMA_SPEC_WARN_NO_EVIDENCE`（模板典型值非文献证据，预期） |
| `units_check.dimensional_ok=true` | **13/13** | 全部模板量纲自洽，无 `BMA_UNIT_MISMATCH` |

过程记录：首轮验证 12/13 valid（`hodgkin_huxley` 15 errors，根因在 core：`matlab/+bma/+spec/private/evalExprDims.m` 参数 cell 赋值 bug、电学单位/8 维量纲缺失、`parseUnit` 的 `strcmpi` 把 `mS` 误配 `ms`）。matlab-core 修复后重验，HH 通过。随后 kb-author 修掉 9 个模板的 `dim_ok=false` 告警（输出表达式中无量纲 epsilon 常数、PK 中 `100-A_gut`、Turing 的 `rho*a²` 应为 `rho_h*a²`（1/(nM*s)）、HH 公式中的 mV/速率常数用 `mV_unit`/`per_ms_unit` 带单位参数表达），最终 13/13 valid + 13/13 dimensional_ok。

最终自检（2026-11-12）：① `kb/units.json` 全部 84 个单位逐个经 `bma.spec.checkUnits` 解析 **0 失败**（jsondecode 为 struct array，与 core 加载器一致；4 个维度名 mass_concentration/rate_per_concentration/count_rate/diffusion_coefficient 在 core 侧由单位组合推导，如 `mg/L`、`1/(nM*s)`，实测 dim_ok=true）；② 本节复验命令实测可用（`--params-file .tmp/validate_hodgkin_huxley.json` → valid=true、dimensional_ok=true）；③ README 引用的 kb/spec/docs 路径均存在（占位符 `*.json`、`<id>` 除外）。

复验命令（core 改动后建议先 `dev.eval` 执行 `clear functions; rehash`）：`node bridge/lib/rpc-cli.mjs --work-dir "E:\matlab系统建模" --method spec.validate --params-file .tmp/validate_<id>.json --timeout 120`。注意 `.tmp/validate_*.json` 是 RPC params 包装（`{"spec":..., "run_dir":...}`），**kb 存储格式是 archetype JSON 内嵌的裸 `spec_template`**，两者不要混淆。

开发机自动检查（全部通过）：29/29 JSON 解析；UTF-8 无 BOM；id 唯一；13 个 `spec_template.name` 合法互异；spec 字段齐全、速率 kind ∈ 5 类、参数 id 引用、stoichiometry 物种、单位词表、`estimate:true` 递增 bounds；expression 白名单且可求值；units.json 的 dim/base/alias 自洽；archetype 顶层变量参数与模板一致；principle 必填字段；references 非空、DOI 仅在确定时给出。

MATLAB `kb.*` 集成实测（io 实现）：`kb.list` 返回 54 条目（13 archetype + 14 principle + 9 ontology_class + 8 ontology_level + 9 ontology_scale + ontology 单例），无空 summary/name_en；`kb.search("米氏 抑制")` 首位命中 `enzyme_kinetics`（score 11.6，matched_terms=米氏/抑制）；`kb.get` 返回完整条目。ontology 的 levels/classes/scales 均补齐 `name_en`/`description`（scales 原先只有中文名，会导致检索条目 summary 为空——已修）。

**jsondecode 解码形态提醒（给 core/io）**：对象数组各元素字段集不一致时 jsondecode 返回 cell（如 8/13 个模板的 `parameters` 因部分有/无 `bounds`；`spec/examples/goodwin.json` 同理）。validate/normalize 与 kb 加载器需兼容 cell 与 struct array。

## 11. 维护规范

- 新增 archetype：文件名=id；含 §3 全字段与完整 spec_template；`spec_template.name` 唯一；≥2 篇真实文献。
- 新增 principle：含 §4 字段；公式 latex+plain+terms；≥2 篇文献。
- 文献：只写确实存在的（作者/年/标题/期刊/卷页），DOI 不确定时省略，禁止编造。
- 单位：只用 units.json 已声明 id；新增需更新全部字段并在此登记。
- **量纲一致性**：输出/速率表达式中不要用无量纲数值与带量纲量相加减（除零保护靠表达式结构，不加 `+1e-9` 之类 epsilon）；物理常数写成带单位的参数（如 HH 的 `mV_unit`、`per_ms_unit`，数值取 1 不改变动力学）——这样 `spec.validate` 的 `units_check.dimensional_ok` 才能为 true。
- 修改 spec_template 后重跑 §10 自检（`spec.validate` + 本地 JSON/结构检查）；超 DESIGN §3 契约的字段先与 Lead 确认。
- 版本：v1.2（2026-11-12，kb-author，task-4）；变更见 §13。

## 12. 已知限制

1. v1 仅 ODE：Turing/趋化给空间离散/两室粗化模板，完整 PDE 解析与二维验证留后续。
2. 随机/离散/约束类模型只给映射与参数化建议，spec 为确定性均值模型；随机模拟由 MATLAB 侧自实现。
3. HH 模板现已通过（valid + dimensional_ok）；其模板公式为便于量纲检查做了单位标度参数化（`mV_unit`、`per_ms_unit`，数值均为 1），机制参数与标准 HH 完全一致，报告中可直接引用经典形式。
4. DOI 保守：部分经典文献未写 DOI，核实后可补。
5. PK/群体免疫阈值等临床参数为文献常见范围，应用以原始文献/监管资料为准，报告标注不确定度。
6. 模板估计参数无 evidence 属有意设计（见 §5）；参数典型范围来自教科书/综述量级，跨物种/条件需重新标定。

## 13. 交付统计（v1.3，2026-11-12）

| 指标 | 数值 |
|---|---|
| 文件 | 28（27 JSON + README） |
| JSON 总字节/字符 | 375,619 B / 268,280 chars |
| 单文件 | 8.0-20.5 KB（最大 reaction_diffusion_turing 20,463 B） |
| archetypes | 13 个；spec_template 共 80 反应、42 条受限 expression |
| principles | 12 个 |
| units / dimensions | 84 / 20（模板实际用 28 个不同单位 id） |
| ontology | 8 层次、9 模型类别、9 尺度条目（均含中英名称与 description） |
| references | 111 条 |
| spec.validate | **13/13 valid，13/13 dimensional_ok=true**（仅预期 NO_EVIDENCE 警告） |
| kb.list / kb.search | 54 条目（含 ontology 子条目）；中文检索实测 top1 命中正确、score/matched_terms 正常 |

变更记录：
- v1.0 初版（13 archetypes + 12 principles + units 对象格式）。
- v1.1 units 改数组格式（schema `bma.kb.units.v2`）、terms keys ASCII 化（343 处）、补 MATLAB 验证结果与解码提醒、新增 `count`/`1/(nM*h)`/电学基准等 8 个单位。
- v1.2 量纲一致性修复（matlab-core 修复 core bug 后）：5 个模板输出表达式去 epsilon 常数、PK 剂量参数化（`dose`）、Turing 增 `rho_h`（1/(nM*s)）、HH 增 `mV_unit`/`per_ms_unit` 单位标度参数；结果 13/13 valid + 13/13 dimensional_ok。
- v1.3 补 ontology 子条目元数据（levels/classes/scales 的 `name_en`/`description`，修复 `kb.list` 中空 summary），MATLAB `kb.list/kb.search/kb.get` 集成实测通过；README 同步验证记录、维护规范与统计。
