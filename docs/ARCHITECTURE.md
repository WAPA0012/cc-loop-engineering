# CC-Loop 架构设计

> Loop Engine + Agents — 自主推进项目到目标的循环引擎

## 核心理念

1. **动手前先完整理解项目** — 每个角色工作前必须建立全局理解，没有例外
2. **prompt 描述目标，不描述方法** — 告诉角色"要什么"和"不能碰什么"，绝不告诉它"怎么做"
3. **完整工具，不阉割** — worker 拥有完整工具集（Read/Edit/Write/Bash/Glob/Grep），职责边界靠 prompt 约束
4. **机械验证零信任** — 所有产出过 gate（机械、确定性），不信任自报
5. **不同活用不同模型** — 搜索用轻量 API（step-3.7-flash），推理用强模型（GLM-5.2[1m]）

## 角色

### 非循环角色（按需启动）

**统筹者（Coordinator）** — 按需启动，不在循环内
- 模型：GLM-5.2
- 职责：和用户沟通，理解需求，翻译成任务目标 + 验证标准
- 当前状态：prompt 已写（roles/coordinator.md），执行器尚未实现（需手动配置场景文件）

### 循环角色

**规划者（Planner）** — 每轮启动
- 模型：GLM-5.2（1M context）
- 工具：Read, Glob, Grep, Write（只读 + 写决策文件，不挂 MCP）
- 职责：读 progress.json（每轮更新）→ 决定派谁 → 写 decision.json
- 不直接搜索（需要外部资料时派 searcher 角色）
- 上下文管理：每轮独立调用（无状态），读状态文件不累积 session

**搜索者（Searcher）** — 被 planner 派时启动
- 模型：step-3.7-flash（轻量，256K context）
- 调用方式：直接 API（`run_search`），不走 claude -p
- 工具：无（它本身就是工具，被引擎调用）
- 职责：按角度搜索外部资料，结果存入 search_result.md
- 支持三种模式：category（固定角度）/ focus（自由角度）/ follow_up（追问深入）

**创意者（Innovator）** — 被 planner 派时启动
- 模型：GLM-5.2
- 工具：完整（Read/Edit/Write/Bash/Glob/Grep）+ MCP search
- 前置：先让 searcher 搜外部参考（或自己调 MCP search）
- 职责：基于搜索结果 + 项目代码，提有依据的创新方案
- 只提方案不执行（不触发 gate）

**建设者（Builder）** — 被 planner 派时启动
- 模型：GLM-5.2
- 工具：完整 + MCP search
- 职责：改代码/实现/优化，自己跑验证
- 能分析（profile/eval）也能改
- 改完触发 gate

**挑刺者（Critic）** — 被 planner 派时启动
- 模型：GLM-5.2
- 工具：完整 + MCP search
- 职责：审查代码找潜在问题（改之前）
- 强制先搜索已知问题模式
- 不改代码，不触发 gate

**测试者（Tester）** — 被 planner 派时启动
- 模型：GLM-5.2
- 工具：完整 + MCP search
- 职责：写测试用例，自己跑确认能复现
- 不触发 gate

**审查者（Reviewer）** — 被 planner 派时启动
- 模型：GLM-5.2
- 工具：完整 + MCP search
- 职责：评估改动的全局影响（改之后、gate 之前或之后）
- 读 diff（git diff HEAD~1）+ 依赖关系
- 不改代码，不触发 gate

### 机械角色

**Gate** — 每次 builder 改动后触发
- 纯 bash/规则，不调 LLM
- 验证方式由任务配置定义（VERIFY_TYPE + VERIFY_CMD）
- test：跑测试，解析 pass/fail（支持 node --test 和 pytest）
- benchmark：跑 benchmark，判断指标达标
- custom：跑自定义命令
- accept → git commit / reject → git checkout rollback

## 循环流程

```
每轮：
  1. planner 读 progress.json → 决策（写 decision.json）
  2. 按 decision 派角色（search/innovator/builder/critic/tester/reviewer/stop）
  3. 角色干活（各自有完整工具 + 内循环）
  4. builder 改完 → gate 验证 → accept=commit / reject=rollback
  5. 更新 progress.json（round + 上轮结果）
  6. history.jsonl 记录（jq 安全转义）
  7. 连续 5 轮 gate reject → 早停
```

角色派发由 planner 自主决策，不是固定流程。planner 根据当前状态判断什么最该做。

## 搜索 MCP（v3）

`engine/search_mcp.py` — stdio MCP server，对外暴露 `search` 工具：
- **category**：8 个固定角度（latest/papers/projects/articles/pitfalls/comparison/tutorial/spec）
- **focus**：自由描述搜索角度（覆盖 category）
- **follow_up**：基于之前结果的追问深入
- 每次注入当前日期（北京时间）
- 内部调 step-3.7-flash API（OpenAI 兼容格式）

挂载策略：
- Planner 不挂（避免 MCP 初始化卡住）
- Innovator/Critic：强制搜索（prompt 要求先搜再干）
- Builder/Tester/Reviewer：按需搜索

## MCP 配置

`engine/mcp_config.json` 配置 MCP server 路径。当前是 WSL 路径（`/mnt/d/...`），非 WSL 环境需调整。

## 状态文件

| 文件 | 内容 | 谁写 | 谁读 |
|---|---|---|---|
| task.json | 任务目标 + 验证标准 | 引擎初始化 | planner |
| progress.json | 当前轮次 + 上轮结果 | 引擎每轮更新 | planner |
| decision.json | 本轮决策（角色+任务） | planner | 引擎 |
| history.jsonl | 每轮完整记录 | 引擎（jq 转义） | 可选查询 |
| result.json | 角色产出 | 各角色 | 引擎/gate |
| search_result.md | 搜索结果 | searcher | innovator |
| cc-loop.log | 运行日志 | 引擎 | 调试 |

## 设计原则

| 原则 | 具体含义 |
|---|---|
| 完整理解 | 每个角色动手前读项目代码/结构/历史 |
| 目标导向 | prompt 说"要什么"，不说"怎么做" |
| 完整工具 | worker 有 Read/Edit/Write/Bash/Glob/Grep（planner 例外：只读+写决策） |
| 零信任 | gate 机械验证，不信 LLM 自报 |
| 异构模型 | 搜索 step-3.7-flash，推理 GLM-5.2[1m] |
| 状态外置 | planner 读 progress.json，不靠 session 累积（防爆） |
