# CC-Loop — Autonomous Coding Loop Engine

An autonomous loop engine that drives projects toward goals. Two modes: a single worker (solo, default) or multi-agent collaboration (team).

## Two Modes

### Solo Mode (Default)

A single worker handles the entire task — understanding the project, making decisions, executing changes, and verifying results autonomously.

Best for:
- "Review this project, fix any bugs you find — you decide, no need to report"
- "Research how to improve XXX in this algorithm"
- "Raise the benchmark of this project by XXX"

No planner overhead. The worker isn't constrained by role boundaries — it decides what to do.

### Team Mode

A planner reads state each round, makes decisions, and dispatches roles:

```
planner (orchestration)
  → builder (modify code)
  → critic (find issues, mandatory search)
  → tester (write tests)
  → reviewer (assess change impact)
  → innovator (propose solutions, mandatory search)
  → searcher (search external resources, real web search)
gate (mechanical verification)
```

Best for complex tasks requiring multiple perspectives, deep collaboration, or extended iteration.

### Comparison

| | solo | team |
|---|---|---|
| Decision-making | worker decides | planner dispatches |
| LLM calls per round | 1 | 1-2 (planner + worker) |
| Independent review | none (self-review) | yes (critic/reviewer) |
| Best for | clear goals, medium complexity | complex, multi-dimensional, innovation |

## Usage

```bash
# solo mode (default)
bash engine/loop.sh scenarios/ai-memory-solo.conf

# team mode
bash engine/loop.sh scenarios/ai-memory-fix.conf --mode team

# You can also set MODE="solo" or MODE="team" in the config file.
# CLI --mode overrides config file MODE.
```

CLI arguments:
- `--mode solo|team` — override mode
- `--rounds N` — override max rounds

## Human-in-the-Loop (Pause / Intervene)

Users can intervene at any time by creating signal files:

```bash
# Stop the loop immediately
touch state/stop_signal

# Inject a directive into the next round's prompt
echo "Focus on edge cases in _checkDup" > state/pause_signal
```

- `stop_signal`: stops after the current round, runs final verification
- `pause_signal`: doesn't stop, but injects the directive into the next round's prompt
- Signal files are consumed once and deleted

## Core Principles

1. **Fully understand the project before acting** — every role must build a complete understanding before doing anything
2. **Prompts describe goals, not methods** — tell the agent "what" and "what not to touch", never "how"
3. **Full toolset, no handicapping** — workers have Read/Edit/Write/Bash/Glob/Grep + MCP search (planner is the exception: read-only + write decision)
4. **Zero-trust mechanical verification** — all outputs pass through gate, no self-reporting trusted
5. **Heterogeneous models** — search uses real web search (stepfun plan MCP channel) + step-3.7-flash structuring, reasoning uses GLM-5.2[1m] (powerful)

## Search Capability (MCP v4)

The `search` tool (cc-loop-search MCP) supports three modes:
- **category**: fixed angle (latest/papers/projects/articles/pitfalls/comparison/tutorial/spec/general)
- **focus**: free-form search angle description
- **follow_up**: drill deeper based on previous results

Each search performs **real web retrieval** (not model memory) via the stepfun StepSearch MCP (the `step_plan` plan channel, billed to your plan's monthly Credit), then structures the real results with step-3.7-flash. Results carry real URLs and publish times — no fabricated content.

> Note: the stepfun plan search endpoint is `https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp`. Do **not** use the standard `https://api.stepfun.com/v1/search` — that's a separate paid endpoint billed to recharge balance, not plan quota.

Mounting strategy:
- solo worker: has MCP search (use as needed)
- planner (team): no MCP (avoids initialization delay; dispatches searcher role when needed)
- innovator/critic (team): mandatory search (search before acting)
- builder/tester/reviewer (team): has MCP search (use as needed)

All roles use `--strict-mcp-config` to disable global MCP servers.

## Model Configuration

### GLM-5.2[1m] (worker + planner)

Configure `~/.claude/settings.json`:
```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "<Zhipu API Key>",
    "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.2[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-4.7",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "1000000",
    "API_TIMEOUT_MS": "3000000"
  }
}
```

- The `[1m]` suffix enables 1M token context
- Tested: 109K tokens precise, 372K tokens slight degradation, 1M headroom sufficient
- Docs: https://docs.bigmodel.cn → Claude Code
- Must kill all claude processes after changing config

### step-3.7-flash (search structuring) + stepfun StepSearch MCP

- **Real retrieval**: stepfun StepSearch MCP (`web_search` tool) via the `step_plan` plan channel — billed to plan monthly Credit
- **Structuring**: step-3.7-flash reorganizes the real results into a clean list (does NOT fabricate)
- Configurable via env vars in `search_mcp.py`: `SEARCH_API_KEY` / `SEARCH_MCP_URL` / `SEARCH_MODEL` / `SEARCH_LLM_URL`
- Input truncation protection at 100K chars

## Roles

| Role | Mode | Responsibility | Model |
|---|---|---|---|
| Solo Worker | solo | Full autonomy, self-directed | GLM-5.2 |
| Planner | team | In-loop orchestration | GLM-5.2 |
| Builder | team | Modify code / implement | GLM-5.2 |
| Critic | team | Find issues (mandatory search) | GLM-5.2 |
| Tester | team | Write tests | GLM-5.2 |
| Reviewer | team | Assess change impact | GLM-5.2 |
| Innovator | team | Propose solutions (mandatory search) | GLM-5.2 |
| Searcher | team | Search external resources (real web search) | stepfun Search + step-3.7-flash |
| Gate | both | Mechanical verification | none |

## Directory Structure

```
cc-loop/
├── engine/
│   ├── loop.sh           # Main entry (loop driver + solo/team branching + gate)
│   ├── utils.sh          # Shared functions (log, render_prompt, run_agent, run_search, exec_*)
│   ├── gate.sh           # Mechanical verification (test/benchmark/custom)
│   ├── search_mcp.py     # Search MCP v4 (real web search + structuring)
│   └── mcp_config.json   # MCP mount config
├── roles/
│   ├── solo.md           # Solo worker
│   ├── planner.md        # Planner
│   ├── builder.md        # Builder
│   ├── critic.md         # Critic
│   ├── tester.md         # Tester
│   ├── reviewer.md       # Reviewer
│   ├── innovator.md      # Innovator
│   └── coordinator.md    # Coordinator (on-demand, executor not yet implemented)
├── scenarios/
│   ├── ai-memory-solo.conf       # solo mode example
│   ├── ai-memory-fix.conf        # team bug fix
│   ├── ai-memory-realbug.conf    # team real bug test
│   └── ai-memory-innovate.conf   # team innovation
├── state/               # Runtime state (auto-generated, do not commit)
└── docs/
    └── ARCHITECTURE.md  # Architecture design document
```

## State Files

| File | Content |
|---|---|
| task.json | Task goal + verification criteria |
| progress.json | Current round + last round result (updated each round) |
| decision.json | Planner's decision (team mode) |
| history.jsonl | Per-round record (jq-escaped) |
| result.json | Worker output |
| search_result.md | Accumulated search results |

## License

MIT
