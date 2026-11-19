# BioModel-MATLAB 系统设计（v1）

> 项目目标：构建一个**基于 MATLAB** 的生物领域自主建模 agent。它读取给定文献资料，运用生物系统学（系统生物学）以及相关数学、物理、化学生物学知识，自主提出机制假设、构建数学模型、做参数估计与验证，并产出可复现的 MATLAB 工程与报告。
>
> 交付形态：**DeepSeek Harness (DSH) agent preset + MATLAB 计算后端**。DSH 侧负责对话与推理编排；MATLAB 侧负责文献解析、符号/数值建模、仿真、拟合、可辨识性、验证、绘图、报告生成等全部计算工作。项目完全独立实现，不引用本地已有的 non-MATLAB agent。

---

## 1. 总体架构

```
用户 (DSH Web GUI / dsh headless)
        │  选择 agent preset: "MATLAB 生物系统建模"
        ▼
┌──────────────────────────────────────────────┐
│ DSH Harness（进程内）                          │
│  · Agent loop + DeepSeek 模型                  │
│  · 系统提示（生物系统学建模方法论 + 质量门）      │
│  · 工具: bma_* / matlab_* / fs / todo / present│
│  · 技能: skills/（分步披露的建模流程、拟合规范）   │
└───────────────┬──────────────────────────────┘
                │ bridge/lib/bridge-client.js
                │ (文件式 JSON-RPC, 免端口/免防火墙)
                ▼
┌──────────────────────────────────────────────┐
│ MATLAB R2024a 常驻会话 (matlab -batch)         │
│  · +bma/+server: 命令循环 + 分发 + 心跳          │
│  · +bma/+io: 文献解析(PDF/DOCX/TXT/MD/HTML)     │
│  · +bma/+spec: 模型规格校验/单位/量纲           │
│  · +bma/+model: ODE 构建、符号分析、仿真          │
│  · +bma/+fit: 参数估计、剖面似然、敏感性、可辨识性  │
│  · +bma/+validate: 指标、模型选择、交叉验证、残差   │
│  · +bma/+plot / +report: 图与报告                │
│  · +bma/+kb: 知识库检索（生物系统学/数学/物理/化学）│
│  · +bma/+codegen / +simbiology: 导出 MATLAB 代码与 |
│    SimBiology 模型                              │
└───────────────┬──────────────────────────────┘
                ▼
  <work_dir>/.bma/  运行产物（spec、数据、图、报告、日志）
```

关键设计决策：

1. **MATLAB 是唯一计算后端**：所有模型推导、数值计算、拟合优化、绘图、报告均由 MATLAB 完成；Node/DSH 侧只做 IPC 与工具编排，不含建模算法。
2. **文件式 JSON-RPC，不用 TCP**：MATLAB 侧用 `matlab -batch` 常驻进程，通过 `inbox/outbox` 目录收发单文件 JSON。理由：避免 `tcpserver` 防火墙弹窗与 stdout 缓冲问题，Windows 下最稳，且天然可审计（每次调用都有落盘请求/响应）。
3. **LLM 只在 DSH 侧**：MATLAB 不直接调用大模型，保证“基于 MATLAB 的 agent”= MATLAB 承担全部科学计算，模型推理由 DSH 提供（用户已选：OpenAI 兼容 API Key / DSH 账号）。
4. **溯源是硬约束**：文献抽取结果带 `section_id` + `quote` 偏移；模型规格每个参数必须标注 `evidence`（measured/estimated/assumed/fitted）；报告强制渲染证据表。
5. **可自纠错的校验层**：`bma_model_validate` 给出结构化错误码与修复提示，agent 据此迭代修改 spec，直到通过。这是自主性的关键闭环。

---

## 2. 目录结构

```
E:\matlab系统建模\
├─ README.md                         # 项目总览 + 快速开始
├─ docs/
│   ├─ DESIGN.md                     # 本文件（契约与架构）
│   ├─ TOOL_REFERENCE.md             # 工具参数/返回参考（Lead 维护）
│   ├─ MODELING_METHODOLOGY.md       # 建模方法论（persona/skills 的内容母本）
│   ├─ USAGE.md                      # 安装、preset 使用、headless 用法
│   └─ ACCEPTANCE.md                 # 验收记录
├─ matlab/                           # MATLAB 工程（可独立运行）
│   ├─ startup_bma.m                 # addpath 入口
│   ├─ +bma/                         # 主包
│   │   ├─ +util/                    # 共享工具（Lead）
│   │   ├─ +io/                      # 文献解析（io 负责）
│   │   ├─ +run/                     # 运行目录管理（io 负责）
│   │   ├─ +kb/                      # 知识库加载/检索（io 负责）
│   │   ├─ +spec/                    # 模型规格校验（core 负责）
│   │   ├─ +model/                   # ODE 构建/符号分析/仿真（core）
│   │   ├─ +codegen/                 # 生成独立 .m（core）
│   │   ├─ +simbiology/              # 可选 SimBiology 导出（core）
│   │   ├─ +fit/                     # 参数估计/敏感性/可辨识性（fit）
│   │   ├─ +validate/                # 验证指标/模型选择（fit）
│   │   ├─ +plot/                    # 绘图（fit）
│   │   ├─ +report/                  # 报告生成（fit）
│   │   └─ +server/                  # IPC 服务循环/分发/心跳（Lead）
│   ├─ tests/                        # test_*.m（各自负责，run_all_tests.m 汇总）
│   ├─ examples/                     # demo_*.m 端到端示例
│   └─ tools/                        # 独立命令行脚本（run_bma_server.m 等）
├─ spec/examples/                    # 模型规格样例 + 合成数据（Lead 提供，团队共用）
├─ kb/                               # 知识库内容（kb-author 负责）
│   ├─ ontology.json
│   ├─ units.json
│   ├─ principles/*.json
│   ├─ archetypes/*.json
│   └─ README.md
├─ bridge/                           # DSH 插件包 @local/dsh-bio-matlab（Lead）
│   ├─ package.json
│   ├─ cordis.patch.yml              # 插入 preset-bio-matlab
│   ├─ lib/index.js                  # 工具插件（ctx.tools.register）
│   ├─ lib/bridge-client.js          # MATLAB 会话生命周期 + JSON-RPC
│   ├─ lib/tools.js                  # 工具定义（名称/描述/参数/渲染）
│   ├─ skills/                       # 面向 agent 的 skills（SKILL.md）
│   └─ test/                         # Node 侧自测（node --test）
├─ tests/
│   ├─ fixtures/literature/          # 自撰“经典范例”文献（QA）
│   └─ e2e/                          # 端到端验收脚本与产物（QA/Lead）
├─ scripts/                          # 安装/验证/清理脚本
└─ .bma/                             # 运行期产物（gitignore）
```

---

## 3. 模型规格 `bma.modelSpec.v1`

模型规格是 **agent 与 MATLAB 之间的唯一契约**。agent 读文献后自己写 JSON；MATLAB 校验、构建、仿真、拟合。

### 3.1 顶层字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema_version` | string | ✔ | 固定 `"bma.modelSpec.v1"` |
| `name` | string | ✔ | 英文 id（`[A-Za-z][A-Za-z0-9_]*`），同时作为目录名 |
| `title` | string |  | 中文/英文标题 |
| `description` | string |  | 机制一句话描述 |
| `kind` | string | ✔ | `ode` 或 `pde`（`pde` 由 1D 有限体积 MOL 展开为等价 ODE；`dae`/`steady_state` 预留） |
| `pde` | object | pde 必填 | 仅 `kind:"pde"`：`{dim:1, domain:{geometry,extent,grid,approximation,zones?}, diffusion, bc, discretization}` |
| `time` | object | ✔ | `{unit, start, end, n}`，仿真默认时间轴 |
| `compartments` | array |  | `[{id, volume, unit}]`，默认单室 `cell=1 L` |
| `variables` | array | ✔ | 状态变量（species） |
| `parameters` | array | ✔ | 参数（可估计/固定） |
| `reactions` | array | ✔ | 反应/通量列表 |
| `outputs` | array |  | 观测量（拟合/报告用） |
| `datasets` | array |  | 可选，内联数据引用 |
| `assumptions` | string[] |  | 建模假设（中文），报告强制列出 |
| `evidence` | array |  | 文献证据（可选，参数级证据为主） |
| `metadata` | object |  | 自由字段：`source_docs`、`agent_notes` 等 |

`variables[]`：`{id, name, unit, initial:{value, note?}, compartment?}`  
`parameters[]`：`{id, name, unit, value:{value, note?}, estimate:true|false, bounds:[lb,ub]?, evidence:[{type:"measured"|"estimated"|"assumed"|"fitted", quote, section_id?, source?, note?}]}`  
`outputs[]`：`{id, name, unit, expression, note?}`（expression 可以是变量 id 或受限表达式）
`datasets[]`：`{id, name, time_unit, time:[...], columns:{<output_id>:[...]}, source}`

### 3.2 速率定律 `reactions[].rate`

统一形式：`{kind, parameters:{...}, species:{...}}`，`v = f(...)`。

| kind | 字段 | 公式 |
|---|---|---|
| `mass_action` | `parameters:{k}`, `species:{S:1, E:1}` | `v = k * prod(x_i^order_i)` |
| `michaelis_menten` | `parameters:{vmax,km}`, `species:{substrate:S}`, 可选 `inhibitor:{species,ki,type:"competitive"|"noncompetitive"}` | `v = Vmax*S/(Km+S*(1+I/Ki))` 等 |
| `hill` | `parameters:{vmax,k,n}`, `species:{regulator:R}`, `mode:"activation"|"repression"` | activation: `Vmax*R^n/(k^n+R^n)`；repression: `Vmax*k^n/(k^n+R^n)` |
| `constant` | `parameters:{k}` | `v = k` |
| `expression` | `expression:"..."` | 允许变量/参数/compartment id 与 `+ - * / ^ exp log sqrt min max`；禁止任意函数调用 |

`reactions[]` 另需：`{id, name, stoichiometry:{<species_id>: 系数(可负)}}`。

ODE 组装：`d x_i / dt = sum_r S[i,r] * v_r`。若某变量无 `initial`，默认 0（validate 会警告）。

### 3.3 PDE 子树（0.7.0，1D MOL）

`kind:"pde"` 的 `variables` 是连续场（如 `C`），编译期按 `pde.domain` 展开为节点状态 `C_1..C_n`；`reactions` 的化学计量/速率按节点复制，扩散由生成的 face 反应表示。下游 fit/identifiability/validate/report 看到的仍是普通 ODE 模型。

```json
{
  "kind": "pde",
  "pde": {
    "dim": 1,
    "domain": {
      "geometry": "slab",                    // slab | cylinder | sphere
      "extent": {"value": 120, "unit": "um"},
      "grid": {"type": "uniform", "n": 16},
      "approximation": "representative column",
      "zones": [{"range": [1, 8], "params": {"rho": 12000}},
                {"range": [9, 16], "params": {"rho": 8000}}]
    },
    "diffusion": [{"species": "C", "coeff": "De"}],   // De 单位 length^2/time
    "bc": [{"face": "x0", "type": "neumann", "flux": 0},
           {"face": "x1", "type": "dirichlet", "value": "Co"}],
    "discretization": {"scheme": "finite_volume", "order": 2}
  }
}
```

- **face 约定**：`x0` 是左/深层端，`x1` 是右/体相端；slab 的 `x0` Dirichlet 是半细胞 ghost（系数 2），cylinder/sphere 的 `x0` 是零面积中心，必须用 `neumann flux=0`。
- **速率/边界**：`reactions[].rate.expression` 中的场 id（如 `C`）按节点替换；`rho_i` 这类 `<param>_i` 按 `zones[].params` 或基础参数逐节点取值；Dirichlet `value` 可引用参数（推荐）或数值。v1 只支持各向同性标量扩散、uniform 网格、1D。
- **输出**：`C[i]`（节点）、`max(C)`、`min(C)`、`mean(C)`、`mean_over_domain(C)`、`integral(C)`；`argmax(C)` 在 v1 明确不支持（需要后处理）。
- **时间**：`time.unit` 必须是真实时间单位；`De` 单位按 length²/time 换算到 `extent.unit²/time.unit`，因此 `um^2/s` + `h` 合法（kex=De/dx²）。
- **元数据**：`m.pde` / `metadata.pde` 记录 `geometry/n/dx/faces/expander_version/expander_sha256`；报告增加“2B. PDE 离散与边界条件”，模型卡记录 `pde`。
- **限制**：2D 矩形、自由边界、对流/变系数张量、DAE+PDE 不在 0.7.0；`approximation` 会写入报告局限，不得假装任意几何。
- **0.8.0 原生 PDE Toolbox 分支**：`pde.dim=2|3` + `pde.solver="toolbox"` 时 **不展开 MOL**，由 `bma_pde_simulate` 直接建 PDE Toolbox 模型：2D `domain.geometry=rectangle{size}/circle{radius}/polygon{points}`，3D `box{size}` 或 `stl{file}`；`pde.mesh.hmax/hgrad`、`pde.bc[].edge`（2D）/`face`（3D）、`pde.probes[{id,species,x,y,z?}]`；`max_dof/max_seconds` 预算门。该分支只做仿真/场输出，不进入 ODE fit/identifiability 状态向量；需要参数估计时降维为 1D MOL。

### 3.4 样例（节选，完整样例见 `spec/examples/`）

```json
{
  "schema_version": "bma.modelSpec.v1",
  "name": "enzyme_mm",
  "title": "米氏酶动力学（可逆结合 + 催化）",
  "kind": "ode",
  "time": {"unit": "s", "start": 0, "end": 60, "n": 601},
  "variables": [
    {"id": "E",  "name": "游离酶", "unit": "uM", "initial": {"value": 1}},
    {"id": "S",  "name": "底物",   "unit": "uM", "initial": {"value": 10}},
    {"id": "ES", "name": "酶-底物复合物", "unit": "uM", "initial": {"value": 0}},
    {"id": "P",  "name": "产物",   "unit": "uM", "initial": {"value": 0}}
  ],
  "parameters": [
    {"id": "kf",  "name": "结合速率常数", "unit": "1/(uM*s)", "value": {"value": 0.5}, "estimate": true, "bounds": [0.001, 100]},
    {"id": "kr",  "name": "解离速率常数", "unit": "1/s",      "value": {"value": 0.1}, "estimate": true, "bounds": [0.0001, 100]},
    {"id": "kcat","name": "催化速率常数", "unit": "1/s",      "value": {"value": 2.0}, "estimate": true, "bounds": [0.0001, 1000]}
  ],
  "reactions": [
    {"id": "bind", "name": "结合", "stoichiometry": {"E": -1, "S": -1, "ES": 1},
     "rate": {"kind": "mass_action", "parameters": {"k": "kf"}, "species": {"E": 1, "S": 1}}},
    {"id": "unbind", "name": "解离", "stoichiometry": {"E": 1, "S": 1, "ES": -1},
     "rate": {"kind": "mass_action", "parameters": {"k": "kr"}, "species": {"ES": 1}}},
    {"id": "catalyze", "name": "催化", "stoichiometry": {"ES": -1, "E": 1, "P": 1},
     "rate": {"kind": "mass_action", "parameters": {"k": "kcat"}, "species": {"ES": 1}}}
  ],
  "outputs": [{"id": "P_obs", "name": "产物浓度", "unit": "uM", "expression": "P"}],
  "assumptions": ["充分混合", "恒温恒容", "底物仅经该酶转化"]
}
```

---

## 4. MATLAB ↔ Node 文件式 JSON-RPC

### 4.1 目录

每个 `work_dir` 下有 **两个** 独立 RPC 服务（0.6.0）：

```
<work_dir>/.bma/server/            # control：status/kb/run/spec.validate/model.build
├─ state.json        # {pid, token, started_at, heartbeat, matlab_version, server_subdir, ...
├─ inbox/            # <req_id>.json   (Node → MATLAB)
├─ outbox/           # <req_id>.json   (MATLAB → Node)
├─ done/             # 已处理的请求（可选归档）
└─ server.log        # MATLAB 日志

<work_dir>/.bma/worker/server/     # heavy worker：literature/analyze/simulate/fit/report/...
└─ 同样的 state/inbox/outbox/done/server.log
```

两个目录使用同一套文件协议，但各自有独立的进程、token、lock、pref/temp/home（worker 在 `.bma/worker/server` 与 `.tmp/worker-server`）。`bridge/lib/index.js` 按方法分流：轻调用走 control，重调用走 worker；`bma_cancel` 默认只杀 busy worker，下一次重调用惰性启动。

### 4.2 请求/响应

请求（Node 写 `<req_id>.json`，先写 `.tmp` 再 `rename` 保证原子）：

```json
{
  "schema": "bma.rpc.v1",
  "id": "r-20261112-123456-abc123",
  "token": "<启动时约定的随机串>",
  "method": "model.simulate",
  "params": { "...": "..." },
  "work_dir": "E:\\matlab系统建模",
  "server_subdir": "worker/server",
  "run_dir": ".bma/runs/r20261112-120000",
  "timeout_s": 120
}
```

响应：

```json
{"schema":"bma.rpc.v1","id":"...","ok":true,"elapsed_ms":812,"result":{...}}
{"schema":"bma.rpc.v1","id":"...","ok":false,"elapsed_ms":5,
 "error":{"code":"BMA_SPEC_INVALID","message":"...","details":{"errors":[...]},"stack":"..."}}
```

约定：
- `result` 必须是可 `jsonencode` 的 struct/cell/number/char；大数组只允许小样本回传，完整数据写 CSV。
- 每个方法都要把**重要产物写入 run_dir** 并在 result 中给出相对 `work_dir` 的路径。
- 错误码见 §4.4；MATLAB 端捕获所有异常并返回 `ok:false`，绝不让服务进程崩溃。
- 服务端每 ~1s 更新各自 `state.json.heartbeat`；Node 超过 15s 无心跳视为该进程死亡并只重启它。
- 同一 `work_dir` 的 control 与 worker 各允许一个服务进程；`state.json.pid` 存活则复用。两者互不阻塞：worker 在不可中断 builtin 中时 control 仍响应 `server.info`/`bma_cancel`。

### 4.3 启动/停止

- 启动：`matlab -batch "addpath('<project>/matlab'); bma.server.start('<work_dir>', '<token>', struct('serverSubdir','worker/server'))"`；
  实际参数：`bma.server.start(workDir, token, opts)`；`opts.serverSubdir` 缺省 `server`，worker 用 `worker/server`。进程前台阻塞运行命令循环。
- 停止：调用 `server.stop` 方法 → 目标服务写响应后退出；Node 兜底 `kill`。`server.stop` 只停收到请求的那个 server（control 或 worker）。
- Node 侧 CLI 自测：`node bridge/lib/rpc-cli.mjs --work-dir ... --status`（control）；worker 用 `new MatlabBridge({workDir, serverSubdir:'worker/server'})`。
- `matlab_status` 并行启动/检查 control+worker，并返回两者健康；首次约 20–120 s，之后复用。

### 4.4 方法表（MATLAB 侧实现）

| method | 参数 | 结果（关键字段） |
|---|---|---|
| `server.ping` | — | `{matlab_version, toolboxes, project_root, work_dir}` |
| `server.info` | — | `{versions, licensed, features, limits}` |
| `server.stop` | — | `{stopped:true}` |
| `run.init` | `{name?, work_dir}` | `{run_dir, run_id, created}` |
| `run.list` | `{}` | `{runs:[{run_dir, run_id, created, models, reports}]}` |
| `kb.list` | `{tag?, limit?}` | `{items:[{id,type,name,summary,tags}], total}` |
| `kb.search` | `{query, tags?, limit?}` | `{hits:[{id,type,name,summary,score,matched_terms,path}], total}` |
| `kb.get` | `{id}` | `{item:{完整 JSON}, path}` |
| `literature.ingest` | `{path, run_dir?, doc_id?}` | `{doc_id, format, title, char_count, sections:[{id,heading,level,char_start,text}], numbers:[{value,unit,symbol,context,section_id,char_start}], tables?, text_path, sections_path, numbers_path, warnings}` |
| `spec.validate` | `{spec, run_dir?}` | `{valid, errors:[{code,path,message,hint}], warnings:[...], normalized_spec, summary, units_check, conservation}` |
| `model.build` | `{spec, run_dir}` | `{model_dir, rhs_function_path, species, parameters, reactions, ode_rhs_preview}` |
| `model.analyze` | `{spec, run_dir}` | `{analysis_path, conservation_laws, steady_states:[{values,stability,eigenvalues}], dimensional_ok, warnings, notes}` |
| `model.simulate` | `{spec, run_dir, options}` | `{sim_id, outputs:{<id>:{final,min,max,t}}, timeseries_path, figures, warnings, events?}` |
| `model.simulate_cases` | `{spec, run_dir, cases:[{name, time_overrides?, initial_overrides?, param_overrides?}]}` | `{cases:[{name, outputs_summary, figures}], comparison_figure, cases_path}` |
| `fit.estimate` | `{spec, run_dir, data_csv, output_map, options}` | `{fit_id, fitted_spec_path, params:[{id,value,se,ci_low,ci_high,fixed}], metrics:{r2,rmse,nrmse,aicc,bic,loglik,n}, predictions_path, residuals_path, figures, warnings}` |
| `fit.profile` | `{spec, run_dir, param, data_csv?, output_map?, options}` | `{param, profile_path, values, nll, ci:{low,high,threshold}, figure}` |
| `fit.sensitivity` | `{spec, run_dir, params?, outputs?, method}` | `{method, indices:{...}, table_path, figure, warnings}` |
| `fit.identifiability` | `{spec, run_dir, data_csv?, output_map?, options}` | `{structural:{...}, practical:{...}, correlations, rank, table_path, warnings}` |
| `validate.metrics` | `{predictions_path?, ...}` | 内部使用；fit 已返回指标 |
| `validate.model_selection` | `{candidates:[{name, spec_path, data_csv, output_map}], run_dir, options}` | `{table:[{name,k,aicc,bic,r2,aicc_weight}], best, table_path}` |
| `validate.cross_validation` | `{spec, run_dir, data_csv, output_map, k, options}` | `{folds:[{train_r2,test_r2,test_rmse}], summary, figure}` |
| `validate.residuals` | `{fit_result_path or predictions_path, run_dir}` | `{diagnostics:{normality_p, autocorr_lag1, heteroscedastic}, figure, warnings}` |
| `report.build` | `{run_dir, title, spec_path, fit_result_path?, analysis_path?, extra_sections?, references?, figures?}` | `{report_html, report_md, model_card_path, figures_used, warnings}` |
| `codegen.model` | `{spec, run_dir}` | `{m_file, function_name, model_card_path}` |
| `simbiology.export` | `{spec, run_dir}` | `{ok, sbproj_path?, model_name, warnings}` |

`options` 通用字段：`time_end`, `n`, `initial_overrides`, `param_overrides`, `params_to_fit`（默认 `estimate:true` 的）、`multistart`（默认 8）、`max_iter`、`weights`、`solver`、`rtol`、`atol`、`seed`。

### 4.5 数据文件约定（拟合）

`data_csv`：首列 `time`，其余列名与 `output_map` 的值对应；可含 `NaN` 表示缺失。例如：

```
time,P_obs
0,0
5,1.2
...
```

`output_map`：`{"P_obs":"P_obs"}`（spec output id → CSV 列名）。

---

## 5. MATLAB 函数契约（按模块）

> 所有函数放在 `matlab/+bma/+<pkg>/`，文件名 = 函数名。参数用 struct/name-value；返回 struct。**不得**依赖当前目录，路径由 `bma.util.projectRoot()` 解析。

### 5.1 `+util`（Lead，先交付）

- `root = bma.util.projectRoot()`：由 `mfilename('fullpath')` 推至项目根。
- `s = bma.util.readJson(path)` / `bma.util.writeJsonAtomic(path, s)`
- `txt = bma.util.readText(path)` / `bma.util.writeTextAtomic(path, txt)`（UTF-8）
- `id = bma.util.newId(prefix)`（时间戳+随机）
- `s = bma.util.nowIso()`；`bma.util.ensureDir(path)`
- `rel = bma.util.relPath(base, absPath)`；`p = bma.util.absPath(workDir, rel)`

### 5.2 `+spec`（core）

- `report = bma.spec.validate(spec, workDir)` → 见 §4.4；`workDir` 可缺省 `pwd`。
- `spec = bma.spec.normalize(spec)`：补默认字段（compartment、initial、bounds、outputs=variables）。
- `spec = bma.spec.load(path)` / `bma.spec.save(spec, path)`
- `m = bma.spec.compile(spec)`：返回编译结构（见 5.3 `bma.model.build`）。

### 5.3 `+model`（core）

- `m = bma.model.build(spec)`：
  ```
  m.spec, m.species (cellstr), m.params (cellstr), m.reactions (struct array)
  m.S (numel(species) x numel(reactions))
  m.rhs = @(t,y,p) ...          % p 为参数向量（按 m.params 顺序）
  m.vfuns = {@(y,p) ...}         % 每个反应的通量函数
  m.outputs = struct array {id, fh(y,p), unit}
  m.paramIndex, m.speciesIndex (containers.Map)
  ```
- `res = bma.model.simulate(m, opts)`：`opts` 见 §4.4；`res = {t, Y, outputs(struct), solver, warnings}`
- `a = bma.model.analyze(m)`：守恒律（S 的左零空间，有理基）、稳态（symbolic solve 失败则 fsolve 多起点）、Jacobian 特征值/稳定性、量纲检查（调用 spec 的单位检查）、warning/notes。
- `ok = bma.model.checkUnits(m)`（供 validate 复用）

### 5.4 `+fit`（fit）

- `fr = bma.fit.estimate(m, data, opts)`：`data` 为 struct `{t, Y, outputs, outputMap, weights}`；返回：
  ```
  fr = struct('params', table/struct array, 'p', param 向量, 'p0', ..., 
              'metrics', struct, 'residuals', ..., 'pred', struct, 
              'fittedSpec', spec, 'warnings', ...)
  ```
  算法：`lsqnonlin`（有界、多起点、固定随机种子），失败退 `fmincon`；默认目标 = 加权残差平方和；指标：R²、RMSE、NRMSE、AICc、BIC、loglik。
- `fr = bma.fit.profile(m, data, fr, paramId, opts)`：剖面似然 + 阈值 CI（chi2）。
- `idx = bma.fit.sensitivity(m, opts)`：局部（中心差分弹性系数）与 Sobol（一阶/总效应，参数范围= bounds，Saltelli 采样自实现，无需工具箱）。
- `r = bma.fit.identifiability(m, data, fr, opts)`：结构可辨识性（符号秩 / 参数-输出灵敏度矩阵秩）与实用可辨识性（Fisher 信息、相关系数矩阵、条件数），给出不可辨识组合。
- `fr = bma.fit.load(path)` / `bma.fit.save(fr, path)`

### 5.5 `+validate`（fit）

- `s = bma.validate.metrics(y, yhat, k, n)`：指标 struct。
- `r = bma.validate.modelSelection(candidates)`：AICc 权重表。
- `r = bma.validate.crossValidation(m, data, opts)`：k 折时间序列交叉验证。
- `r = bma.validate.residuals(fr)`：正态性（Lilliefors/Shapiro 若 stats 工具箱可用，否则偏度/峰度）、滞后 1 自相关、异方差。

### 5.6 `+plot`（fit）

- `p = bma.plot.timeseries(m, res, opts)`、`bma.plot.fit(fr, data, opts)`、`bma.plot.profile(...)`、`bma.plot.sensitivity(...)`、`bma.plot.phase(...)`。统一：写 PNG 到指定目录，返回相对路径；使用 `visible='off'` + `exportgraphics`，无显示器依赖。

### 5.7 `+report`（fit）

- `r = bma.report.build(runDir, spec, fr, analysis, opts)`：生成
  `report.html`（自包含 CSS + 内嵌 PNG base64）、`report.md`、`model_card.json`。
  必须含：模型方程（从 spec 渲染）、参数表（值/单位/CI/证据）、假设清单、参数估计与可辨识性、验证指标、残差、图、参考文献、局限性、可复现命令。

### 5.8 `+io`（io）

- `doc = bma.io.ingest(path, runDir)`：PDF/DOCX/TXT/MD/HTML → 结构化；用 Text Analytics `extractFileText` 读 PDF/DOCX（license 已验证可用）；HTML 用 `htmlTree`/正则；输出 `text.txt`、`sections.json`、`numbers.json`、`tables.json`。
- `secs = bma.io.sectionize(text)`：标题启发式（编号/全大写/短行/常见生物学期刊标题）。
- `nums = bma.io.extractNumbers(text, sections)`：识别 `Km = 12.5 µM`、`kcat 3.4 s−1`、`EC50 of 0.8 nM`、`R0 ≈ 2.5` 等（数值+单位+符号+上下文+位置）。
- `tables = bma.io.extractTables(text)`：Markdown/TSV 表格解析。
- `bma.io.supportedFormats()`。

### 5.9 `+run`（io）

- `r = bma.run.init(workDir, name)`；`r = bma.run.info(runDir)`；`runs = bma.run.list(workDir)`。
- `p = bma.run.artifact(runDir, kind, name)`：返回并创建规范子目录路径。
- 运行目录结构见 §7。

### 5.10 `+kb`（io）

- `idx = bma.kb.index()`：扫描 `kb/` 下 JSON，建内存索引。
- `items = bma.kb.list(tag, limit)`；`hits = bma.kb.search(query, tags, limit)`；`item = bma.kb.get(id)`。
- 检索：小写分词（中英文；中文按 2-gram，英文按词），字段加权（name/summary/keywords/tags），返回分数与命中词。

### 5.11 `+server`（Lead）

- `bma.server.start(workDir, token, opts)`：阻塞命令循环（文件 IPC）；`opts.maxIdleSeconds`、`opts.log`。0.8.3 起 bridge 在最后一次工具调用后按 `BMA_IDLE_SHUTDOWN_SECONDS`（默认 300 s）同时 stop control/worker；下一次调用惰性重启。
- `bma.server.dispatch(method, params, ctx)`：switch 分发到各模块；所有异常转错误码。
- `bma.server.stop()`、`bma.server.status()`。

---

## 6. DSH 工具面（`bridge/lib/tools.js`）

工具名统一 `bma_` 前缀（Agent 内部工具），全部同步阻塞式调用 MATLAB。

| 工具 | 参数 | 返回给模型的内容（渲染） |
|---|---|---|
| `matlab_status` | `{work_dir?}` | MATLAB 版本/工具箱/服务状态/项目路径；首次调用自动启动并预热（~10-20s），提示后续无需重复启动 |
| `bma_kb_list` | `{tag?, limit?}` | 知识库条目列表（id/名称/类型/摘要） |
| `bma_kb_search` | `{query, tags?, limit?}` | 检索结果 + 每条 2-3 行摘要 + 路径 |
| `bma_kb_get` | `{id}` | 完整条目（方程、假设、参数范围、参考） |
| `bma_literature_ingest` | `{path, run_dir?}` | 章节目录、字数、抽取到的数字/单位/上下文（前 N 条）、产物路径；提示 agent 用 `read` 读全文 |
| `bma_model_validate` | `{spec | spec_path, run_dir?}` | valid + 错误/警告列表（含修复提示）+ 摘要 + 归一化 spec 路径 |
| `bma_model_analyze` | `{spec | spec_path, run_dir}` | 守恒律、稳态与稳定性、量纲检查、结构提示 |
| `bma_model_simulate` | `{spec | spec_path, run_dir, options}` | 输出终值/min/max、图路径、CSV 路径、警告 |
| `bma_pde_simulate` | `{spec | spec_path, run_dir, options}` | 原生 2D/3D PDE Toolbox：mesh nodes/elements、probes、field_stats、CSV/PNG、预算/警告 |
| `bma_model_simulate_cases` | `{spec | spec_path, run_dir, cases}` | 每 case 摘要 + 对比图 |
| `bma_model_fit` | `{spec | spec_path, run_dir, data_csv, output_map, options}` | 参数表（值±CI）、拟合指标、图/预测路径、警告 |
| `bma_model_identifiability` | `{spec | spec_path, run_dir, data_csv?, output_map?, param?}` | 结构/实用可辨识性结论、剖面似然图、相关矩阵 |
| `bma_model_sensitivity` | `{spec | spec_path, run_dir, params?, outputs?, method?}` | 排序后的敏感性指数表 |
| `bma_model_selection` | `{spec_paths[], data_csv, output_map, run_dir, options}` | AICc 权重表 + 最佳模型 |
| `bma_model_validate_fit` | `{fit_result_path, data_csv, output_map, run_dir, k?}` | 交叉验证 + 残差诊断 |
| `bma_report_build` | `{run_dir, title, spec_path, fit_result_path?, analysis_path?, references?, extra_sections?}` | 报告 HTML/MD 路径、使用的图、模型卡路径 |
| `bma_codegen` | `{spec | spec_path, run_dir, simbiology?}` | 生成的 .m 路径 + 函数名 +（可选）SimBiology 导出结果 |

通用规则（写进工具描述）：
- `work_dir` 缺省为当前会话工作目录；所有路径支持相对 `work_dir`。
- 返回文本 ≤ ~8KB；大数据只给摘要 + 文件路径，agent 用 `read`（CSV）或 `present` 查看图。
- 工具报错信息必须包含：错误码、出错字段、修复建议（MATLAB 侧提供 `hint`）。
- 单次调用目标 < 60s；`options.multistart` 大时提示分批。

---

## 7. 运行产物布局

```
<work_dir>/.bma/
├─ server/                      # IPC 状态（临时）
└─ runs/<run_id>/
   ├─ run.json
   ├─ literature/<doc_id>/text.txt|sections.json|numbers.json|tables.json
   ├─ models/<name>/spec.json|normalized.json|analysis.json|code/<name>_ode.m
   ├─ data/*.csv
   ├─ fits/<fit_id>/fit.json|params.csv|predictions.csv|residuals.csv|profile_<p>.csv|figures/*.png
   ├─ figures/*.png
   └─ report/report.html|report.md|model_card.json|figures/*
```

`run_id` 形如 `r20261112-153000-a1b2`。报告里所有图用相对路径。

---

## 8. DSH agent preset 组成

`bridge/cordis.patch.yml` 插入：

```yaml
- insert:
    - id: preset-bio-matlab
      name: '@deepseek-ai/dsh-agent-preset'
      config:
        id: bio-matlab
        name: MATLAB 生物系统建模
        description: 读取生物文献，自主构建、拟合与验证数学模型（MATLAB 后端）
        order: 5
        plugins:
          - id: persona ...            # 中文 persona：身份 + 方法论 + 硬性质量门
          - id: bio-matlab-tools ...   # 本项目工具插件（bridge/lib/index.js）
          - id: tool-pwsh / tool-fs / tool-fs-search / tool-todo / tool-ask-user / tool-present
          - id: skill + tool-skill + skill-filesystem（customSkillDirs 指向本项目 skills）
```

Persona 必须包含（详见 `docs/MODELING_METHODOLOGY.md`）：
1. 身份：生物系统建模专家，同时具备数学/物理/化学生物学功底；输出中文报告，spec/代码英文标识符。
2. 强制工作流（质量门）：
   `文献解析 → 证据与实体抽取 → 知识库检索（模态/机制匹配）→ 机制假设与建模假设 → 模型规格 v1 → 校验（必过）→ 仿真 → 参数确定/估计 → 可辨识性 → 验证/证伪 → 模型选择 → 导出与报告`
3. 硬规则：参数必须有来源或显式标 `assumed`；单位必须齐全；先最小机制模型再扩展；每个结论必须可回溯到 section/quote；不得编造文献内容；拟合失败要报告并给替代方案；报告必须列出假设与局限。
4. 工具使用指引：何时用哪个工具；`work_dir` 约定；大输出用 read/CSV；图用 present。

Skills（`bridge/skills/`，按需加载）：
- `bio-modeling-workflow`：完整建模方法论 + 证据表模板 + spec 编写规范 + 常见错误码修复。
- `model-fit-identifiability`：参数估计、多起点、剖面似然、敏感性、可辨识性判读。
- `bio-model-report`：报告结构、断言与局限、医学/生物学表达规范。
- `matlab-modeling-troubleshooting`：校验错误、求解失败、刚性、单位错误的排查路径。

---

## 9. 知识库格式

- `kb/ontology.json`：`{levels:[{id,name,description,examples}], model_classes:[{id,name,when,matlab_impl}], scales:[...]}`
- `kb/units.json`：`{units:{uM:{dim:"concentration",factor:1e-6,base:"M"}, ...}}`（供单位校验）
- `kb/archetypes/<id>.json`：
  ```json
  {"id":"enzyme_michaelis_menten","type":"archetype","name":"米氏酶动力学","name_en":"Michaelis-Menten",
   "domain":"enzyme_kinetics","scale":"molecule","model_class":"ode",
   "summary":"...","when_to_use":["..."],"keywords":["...","..."],
   "equations":[{"name":"...","latex":"...","plain":"...","terms":{...}}],
   "spec_template":{"reactions":[...]},
   "variables":[{"id":"S","name":"底物","unit":"uM","typical_range":[1e-3,1e3]}],
   "parameters":[{"id":"Km","symbol":"K_m","unit":"uM","typical_range":[1e-3,1e3],"notes":"..."}],
   "assumptions":["..."],"evidence_cues":["..."],"fitting_notes":"...","identifiability_notes":"...",
   "references":[{"citation":"...","doi":"..."}],"related":["..."]}
  ```
- `kb/principles/<id>.json`：质量作用定律、守恒律、量纲分析、准稳态近似、Hill 函数、Fick 定律、Nernst 方程、热力学约束、随机性/噪声、网络基序、R0/下一代矩阵、稳定性与振荡条件等。

覆盖目标（≥12 archetype + ≥10 principle）：酶动力学、基因表达（转录翻译+降解）、Hill 调控/开关、双稳态 toggle、repressilator/Goodwin 振荡、信号级联（MAPK）、受体-配体结合、代谢通路（通量/守恒）、种群增长与竞争（logistic/LV）、流行病 SIR/SEIR、药代动力学（一室/二室）、电生理（HH）、趋化、反应-扩散（Turing）。

---

## 10. 测试与验收

1. **MATLAB 单元/集成测试**：`matlab/tests/test_*.m`；`run_all_tests.m` 聚合；必须全绿。
2. **Node bridge 自测**：`bridge/test/*.test.mjs`（node --test），覆盖 IPC、超时、重启、工具渲染。
3. **规格样例**：`spec/examples/` 三个模型（enzyme_mm / goodwin / sir）必须能 validate→build→analyze→simulate→fit（合成数据）→validate→report 全链路通过。
4. **文献解析**：fixtures 的 .md/.txt/.html/.docx/.pdf 各格式抽取校验。
5. **preset 激活**：安装后 `Config.listConfigs` 出现 `preset-bio-matlab` 且为 schema/active；工具 schema 正确。
6. **端到端（E2E）**：
   - **主路径（真实 LLM）**：DSH Web GUI 新建会话选择 preset「MATLAB 生物系统建模」，投喂 `tests/fixtures/literature/enzyme_kinetics/paper.md`，按 `tests/e2e/desktop_preset_acceptance.md` 验收：生成 run 目录、通过校验的 spec、拟合/可辨识性结果、含参数证据表与假设的报告；参数均有 evidence 或 assumed 标注。
   - **自动化路径（需 `DEEPSEEK_API_KEY`）**：`dsh headless --patch tests/e2e/headless.patch.yml` + `run_headless_e2e.ps1`。headless profile 按设计禁用桌面托管凭据，因此**不能复用 GUI 账号登录**；没有 API key 时该路径在 LLM 调用处报 `MISSING_CREDENTIAL`，属预期限制，记录于 ACCEPTANCE.md。
   - **降级路径（无 LLM）**：工具层 E2E `tests/e2e/tool_layer_e2e.ps1` 覆盖原有 15 个 `bma_*` 等价 RPC 方法；0.5.0 新增的 `bma_cancel`/`bma_artifact_import`/`bma_gate_waive` 由 `bridge/test/resilience.test.mjs` 与 `matlab/tests/test_upgrade_050.m` 覆盖。MATLAB 测试全绿 + 工具层 E2E 通过作为无 LLM 环境的验收证据。
   - 插件挂载验证：`dsh --profile headless --patch tests/e2e/headless.mount.patch.yml` 应无 "entry did not activate" 警告（本次已通过；仅剩凭据错误）。
7. **独立 MATLAB 使用**：`matlab/examples/demo_end_to_end.m` 不依赖 DSH，在 MATLAB 中完成一次建模全流程。

---

## 11. 协作边界（写范围）

| 角色 | 写范围 |
|---|---|
| Lead | `bridge/`、`matlab/+bma/+server/`、`matlab/+bma/+util/`、`scripts/`、`docs/`、`README.md`、`tests/e2e/`、`spec/examples/` 初始版 |
| matlab-core | `matlab/+bma/+spec/`、`+model/`、`+codegen/`、`+simbiology/`、`matlab/tests/test_spec_*.m`、`test_model_*.m` |
| matlab-fit | `matlab/+bma/+fit/`、`+validate/`、`+plot/`、`+report/`、`matlab/tests/test_fit_*.m`、`test_validate_*.m`、`test_report_*.m` |
| matlab-io | `matlab/+bma/+io/`、`+run/`、`+kb/`、`matlab/tests/test_io_*.m`、`test_kb_*.m` |
| kb-author | `kb/`、`docs/KB.md` |
| qa-acceptance | `tests/fixtures/`、`tests/e2e/`、`matlab/tests/test_integration_*.m`、`docs/ACCEPTANCE.md` |

共享只读契约：`docs/DESIGN.md`、`spec/examples/`、`matlab/+bma/+util/`。如需修改契约，先通知 Lead。

---

## 12. 里程碑

- M1（基础设施）：util + spec 样例 + DESIGN + 任务分派 ✅
- M2（并行开发）：MATLAB 各模块 + KB 内容 + bridge 骨架
- M3（集成）：server 分发 + bridge 工具 + preset 安装 + 全链路测试绿
- M4（验收）：fixture 文献 E2E + 报告 + 文档 + 演示产物

## 12. v0.3.0 规格扩展（issue 升级）

- **代数变量**：`variables[]` 可写 `{"id":"Km","kind":"algebraic","unit":"uM","expression":"(kr+kcat)/kf"}`；编译期按依赖拓扑展开，不参与状态向量、S 矩阵与守恒律；只允许在 `reactions[].rate.expression` 与 `outputs[].expression` 中引用；循环依赖报 `bma:spec:spec_cycle`；展开长度上限 20000 字符。
- **signed 变量**：`variables[].signed=true` 表示该量可为负（ΔG、化学势等），仿真负值检查跳过该变量。
- **敏感性预算**：`bma.fit.sensitivity` 默认 `method=local`；`sobol_n` 默认 64；`budget_seconds`（默认 120）按一次基准仿真 × `N*(P+2)` 估算，超限默认跳过并返回 `skipped/budget/suggestion`；`force=true` 强制执行；`max_seconds`（默认 300）总墙钟、`max_sample_seconds` 单样本上限、`progress_path` 进度、`cancel.flag` 协作取消；超时返回 `partial`。
- **RPC**：`server.cancel` 写目标 server 的 `cancel.flag`（并镜像到 `<work_dir>/.bma/server/cancel.flag` 供 Sobol/fit 检查）；server 启动清理陈旧 inbox/outbox/claims/done；桥接 `cancel()` 供客户端主动放弃。0.6.0 起 `bma_cancel` 默认只杀 busy heavy worker（不等待新 worker 启动），control 继续可响应。
- **报告**：`extra_sections` 支持 `{title, markdown|body|content|text|file}`，Markdown 正文完整渲染；`evidence` 数组逐条进入报告与模型卡。
- **单位**：新增 energy/power/pressure/molar_energy/specific_power/molality 维度；`mmol/kg`（molality）与 `mM`（concentration）不可互换，除非在 assumptions 声明 kg≈L 近似。


## 13. v0.4.0 文献插图/句子引用（ISS-12）

- `literature.ingest` 额外产物：`sentences.json`（句子 id `section#sN`、绝对 char_start/end）、`figures/` + `figures.json`（index/file/width/height/page/caption/bytes/filter/format/rel_path）。
- `extractPdfFigures` 仅解析 PDF 内嵌位图：DCTDecode→JPG；FlateDecode→PNG（含 Predictor/Indexed 调色板）；跳过空白掩膜；矢量/JPX/CCITT 明确告警不假装成功。
- 每个 number 增加 `sentence_id`；句子切分跳过小数/缩写/标题行；跨行下标符号（ks⏎2）合并为 ks2。
