# CC-Loop — 自主循环编码引擎

自主推进项目到目标的循环引擎。两种模式：单一工作者（solo，默认）和多角色协作（team）。

## 两种模式

### Solo 模式（默认）

一个 worker 全权处理任务。自己理解项目、自己决策、自己执行、自己验证。

适用场景：
- "审查这个项目，有 bug 就修，你来决定，不用汇报"
- "研究这个算法哪里能提升 XXX"
- "把这个项目的基准往上提 XXX"

特点：省去 planner 调度开销，worker 不被角色框死，自己判断该干什么。

### Team 模式

规划者（planner）每轮读状态、做决策、派角色。角色各司其职：

```
planner（调度）
  → builder（改代码）
  → critic（找问题，强制搜索）
  → tester（写测试）
  → reviewer（评估改动影响）
  → innovator（提方案，强制搜索）
  → searcher（搜外部资料，step-3.7-flash）
gate（机械验证）
```

适用场景：复杂任务、需要多视角深度协作、长迭代。

### 对比

| | solo | team |
|---|---|---|
| 决策 | worker 自己决定 | planner 调度 |
| 每轮 LLM 调用 | 1 次 | 1-2 次（planner + worker） |
| 独立视角 | 无（自己改自己审） | 有（critic/reviewer 独立审查） |
| 适合 | 明确目标、中等复杂度 | 复杂、多维度、需要创新 |

## 用法

```bash
# solo 模式（默认）
bash engine/loop.sh scenarios/ai-memory-solo.conf

# team 模式
bash engine/loop.sh scenarios/ai-memory-fix.conf --mode team

# 也可以在配置文件里指定 MODE="solo" 或 MODE="team"
# 命令行 --mode 覆盖配置文件的 MODE
```

命令行参数：
- `--mode solo|team` — 覆盖模式
- `--rounds N` — 覆盖最大轮数

## 人机协作（暂停/介入）

CC-Loop 运行时，用户随时可以通过创建信号文件介入：

```bash
# 立即停止循环
touch state/stop_signal

# 暂停并注入指令（下一轮 worker/planner 会看到这个指令）
echo "重点检查 _checkDup 方法的边界条件" > state/pause_signal
```

- `stop_signal`：当前轮结束后立即停止，进入最终验证
- `pause_signal`：不停止，但把指令注入下一轮的 prompt（worker/planner 会看到"用户介入指令"）
- 信号文件用完即删（一次性）

这让 CC-Loop 不是黑箱——用户可以随时纠偏、补充指令、或叫停。



1. **动手前先完整理解项目** — 每个角色工作前必须建立全局理解
2. **prompt 描述目标，不描述方法** — 告诉"要什么"和"不能碰什么"，不告诉"怎么做"
3. **完整工具，不阉割** — worker 有 Read/Edit/Write/Bash/Glob/Grep + MCP search（planner 例外：只读+写决策）
4. **机械验证零信任** — 所有产出过 gate，不信自报
5. **不同活用不同模型** — 搜索用 step-3.7-flash，推理用 GLM-5.2[1m]

## 搜索能力（MCP v3）

`search` 工具（cc-loop-search MCP），三种模式：
- **category**：固定角度（latest/papers/projects/articles/pitfalls/comparison/tutorial/spec/general）
- **focus**：自由描述搜索角度
- **follow_up**：基于之前结果追问深入

每次自动注入当前日期（北京时间），避免模型用过期知识冒充"最新"。

挂载策略：
- solo worker：有 MCP search（按需用）
- planner（team）：不挂 MCP（避免初始化卡住，需搜索时派 searcher）
- innovator/critic（team）：强制搜索（先搜再干）
- builder/tester/reviewer（team）：有 MCP search（按需用）

所有角色用 `--strict-mcp-config` 禁用全局 MCP（智谱自带的 4 个 server 会拖慢启动）。

## 模型配置

### GLM-5.2[1m]（worker + planner）

`~/.claude/settings.json`：
```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "<智谱 API Key>",
    "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.7",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
    "API_TIMEOUT_MS": "3000000"
  }
}
```

- `glm-5.2[1m]` 的 `[1m]` 开启 1M 上下文
- 实测：109K token 精准，372K token 轻微衰减，1M 余量充足
- 文档：https://docs.bigmodel.cn → Claude Code
- 配置改后必须杀掉所有 claude 进程

### step-3.7-flash（搜索）

- API: `https://api.stepfun.com/step_plan/v1/chat/completions`
- 256K 上下文，reasoning model（max_tokens 8000+）
- 输入截断保护 100K 字符

## 角色

| 角色 | 模式 | 职责 | 模型 |
|---|---|---|---|
| Solo Worker | solo | 全权处理，自主决策 | GLM-5.2 |
| Planner | team | 循环内调度 | GLM-5.2 |
| Builder | team | 改代码/实现 | GLM-5.2 |
| Critic | team | 找问题（强制搜索） | GLM-5.2 |
| Tester | team | 写测试 | GLM-5.2 |
| Reviewer | team | 评估改动影响 | GLM-5.2 |
| Innovator | team | 提方案（强制搜索） | GLM-5.2 |
| Searcher | team | 搜外部资料 | step-3.7-flash |
| Gate | 两者 | 机械验证 | 无 LLM |

## 目录结构

```
cc-loop/
├── engine/
│   ├── loop.sh           # 主入口（循环驱动 + solo/team 分支 + gate）
│   ├── utils.sh         # 共享函数（log, render_prompt, run_agent, run_search, exec_*）
│   ├── gate.sh          # 机械验证（test/benchmark/custom）
│   ├── search_mcp.py    # 搜索 MCP v3（category/focus/follow_up）
│   └── mcp_config.json  # MCP 挂载配置
├── roles/
│   ├── solo.md          # 单一工作者
│   ├── planner.md       # 规划者
│   ├── builder.md       # 建设者
│   ├── critic.md        # 挑刺者
│   ├── tester.md        # 测试者
│   ├── reviewer.md      # 审查者
│   ├── innovator.md     # 创意者
│   └── coordinator.md   # 统筹者（按需，执行器未实现）
├── scenarios/
│   ├── ai-memory-solo.conf       # solo 模式示例
│   ├── ai-memory-fix.conf        # team 修 bug
│   ├── ai-memory-realbug.conf    # team 真 bug 测试
│   └── ai-memory-innovate.conf   # team 创新优化
├── state/               # 运行时状态（自动生成，不要提交）
└── docs/
    └── ARCHITECTURE.md  # 架构设计文档
```

## 状态文件

| 文件 | 内容 |
|---|---|
| task.json | 任务目标 + 验证标准 |
| progress.json | 当前轮次 + 上轮结果（每轮更新） |
| decision.json | team 模式下 planner 的决策 |
| history.jsonl | 每轮记录（jq 安全转义） |
| result.json | worker 产出 |
| search_result.md | 搜索结果累积 |

## License

MIT
