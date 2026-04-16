# PwrCortex

Agentic LLM swarm engine for PowerShell.
Environment-aware. Pipeline-native. claude.md-driven.

```powershell
Install-Module PwrCortex
```

## The result is a real object

```powershell
$r = agent "What is 2 + 2?"

$r.Result
# 4

$r.Result.GetType()
# System.Int32
```

Not a string. Not JSON. An `[int]`. The LLM computed the answer through PowerShell and the actual .NET object came back on `.Result`.

```powershell
$r = agent "Top 3 processes by memory"

$r.Result | Format-Table ProcessName, Id, @{n='MB';e={[math]::Round($_.WorkingSet64/1MB)}}
# ProcessName     Id    MB
# -----------     --    --
# vmmemWSL      2411  7642
# MemCompression 3340   957
# explorer       1052   623

$r.Result[0].Kill()   # live [Process] object — methods work
```

## Demo: context carries across calls

A real session. Each call builds on the last. No wiring — globals and history propagate automatically.

```powershell
# ── Step 1: gather data ──────────────────────────────────────
$r1 = agent "Get the top 5 processes by WorkingSet64"

$r1.GlobalName
# llm_get_top_processes_by

$r1.Result | ForEach-Object { "$($_.ProcessName) — $([math]::Round($_.WorkingSet64/1MB))MB" }
# vmmemWSL — 7642MB
# Memory Compression — 957MB
# explorer — 623MB
# node — 572MB
# msedge — 426MB
```

The result is stored as `$global:llm_get_top_processes_by` — a live `[Process[]]` array, not a response wrapper.

```powershell
# ── User sets a threshold ────────────────────────────────────
$global:memory_threshold_mb = 1000
```

```powershell
# ── Step 2: agent sees BOTH the prior result AND the threshold ──
$r2 = agent 'Filter $llm_get_top_processes_by to processes exceeding $memory_threshold_mb MB'

$r2.Result | ForEach-Object { "$($_.ProcessName) — $([math]::Round($_.WorkingSet64/1MB))MB" }
# vmmemWSL — 7642MB
```

The agent read `$llm_get_top_processes_by` (prior result) and `$memory_threshold_mb` (user variable) from `Global:` scope. No piping, no parameters — it's just there.

```powershell
# ── User adds context ────────────────────────────────────────
$global:user_note = "vmmemWSL is expected during builds. Flag anything else."
```

```powershell
# ── Step 3: agent reads full history + user note ─────────────
$r3 = agent 'Read $llm_history and $user_note. Write a session report.'

$r3.Content
# 1. GATHERED: Top 5 processes — vmmemWSL (7,642 MB), Memory Compression (957 MB),
#    explorer (623 MB), node (572 MB), msedge (426 MB).
# 2. FILTERED: Only vmmemWSL exceeds the 1,000 MB threshold.
# 3. USER NOTE: vmmemWSL is expected during builds.
# 4. ASSESSMENT: No anomalies. All high-memory processes are accounted for.
```

```powershell
# ── The session history tracked everything ────────────────────
$global:llm_history

# Index GlobalName                    Type  Prompt
# ----- ----------                    ----  ------
#     1 llm_get_top_processes_by      agent Get the top 5 processes by WorkingSet64
#     2 llm_filter_processes          agent Filter $llm_get_top_processes_by to...
#     3 llm_read_llm_history          agent Read $llm_history and $user_note...
```

**Total: 3 calls, ~31K tokens.** Each call saw the full accumulated context from every prior call, plus any variables the user set in between. Like Claude Code — but at a fraction of the token cost.

## How it works

Every agent and swarm call:

1. **Clones your session** into a dedicated Runspace — modules, env vars, and all `Global:` variables
2. **Runs tool calls** that store live .NET objects in `$refs[id]` (not JSON, not text)
3. **Stores `.Result`** in a semantically-named global: `$global:llm_<slug_from_prompt>`
4. **Appends to `$global:llm_history`** — an ordered list of all calls with timestamps

So the next call automatically sees everything. Your session is the context window.

## Pipe data in

```powershell
Get-Process | feed "Which one uses the most memory?"

Get-History | feed "What was I working on? Suggest next steps."

Import-Csv sales.csv | feed "Summarize trends in this data"
```

`feed` pipes any objects into `$refs[1]` as input, then runs the agent. The LLM works with real typed objects, not serialized text.

## Parallel swarm

```powershell
think "Audit this machine: services, ports, processes, and disk"
```

One sentence decomposes into parallel tasks:

```
── SWARM  ◆  4 tasks ──────────────────────────────────
  Goal: Audit this machine...

  ✓ t1     Scan running services              0.9s
  ✓ t2     Check open ports                   1.4s
  ◕ t3     Analyse top processes              ← running
  ◔ t4     Correlate services + ports         ← t1, t2

── SWARM COMPLETE ──────────────────────────────────────
  Tasks      4 done  0 failed  0 skipped
  Tokens     12,340  (in: 9,200  out: 3,140)
  Wall time  8.42s
```

The result tracks tokens across all phases:

```powershell
$r = think "Audit services and disk"
$r.InputTokens    # 9200
$r.OutputTokens   # 3140
$r.TotalTokens    # 12340
$r.TotalSec       # 8.42
```

## Why this exists

Every LLM agent framework treats PowerShell like bash — run a command, capture stdout as text, shove it into the context window.

PowerShell commands return **.NET objects** — with properties, methods, types, and pipeline semantics. `Get-Process` returns `[System.Diagnostics.Process]` instances with `.WorkingSet64`, `.CPU`, `.Kill()`. None of that survives serialization to JSON or text.

**PwrCortex keeps objects alive in memory.** The LLM gets a compact summary; you get the real thing on `.Result`. Subsequent tool calls reference `$refs[1]` (~5 tokens) instead of re-sending the entire serialized blob (~50,000 tokens).

| | PwrCortex | Claude Code / Cursor | LangChain / AutoGen |
|---|---|---|---|
| Tool result storage | Live .NET object | Text in conversation | JSON in context |
| Token cost to chain | ~5 tokens | Full text re-sent | Entire blob re-sent |
| Type fidelity | Full | Plain text | Strings and numbers |
| Per 5-step agent call | ~$0.025 | ~$2–5+ | ~$1.10 |

## Aliases

| Alias | Cmdlet | Purpose |
|---|---|---|
| `agent` | `Invoke-LLMAgent` | Agentic tool-use loop, typed `.Result` |
| `think` | `Invoke-LLMSwarm` | Parallel swarm orchestration |
| `feed` | `Push-LLMInput` | Pipe objects as agent input |
| `llm` | `Invoke-LLM` | Single completion |
| `chat` | `Enter-LLMChat` | Interactive REPL |

## Modules document themselves with `claude.md`

Drop a `claude.md` in any module's directory — PwrCortex discovers it automatically:

```
MyModule/
├── MyModule.psm1
├── MyModule.psd1
└── claude.md          ← the LLM reads this
```

Every module in `$env:PSModulePath` with a `claude.md` becomes an AI-callable toolkit. No registration. No schemas.

## Installation

```powershell
Install-Module PwrCortex
```

```powershell
$env:ANTHROPIC_API_KEY    = "sk-ant-..."
$env:LLM_DEFAULT_PROVIDER = "Anthropic"
```

## Cmdlets

| Cmdlet | Description |
|---|---|
| `Invoke-LLM` | Single/batch completions. Pipeline-friendly. |
| `Invoke-LLMAgent` | Agentic loop — dedicated Runspace, native objects on `.Result`. |
| `Invoke-LLMSwarm` | Decompose → RunspacePool DAG dispatch → synthesize. |
| `Push-LLMInput` | Pipe objects into agent as pre-loaded `$refs` input. |
| `New-LLMChat` | Create a stateful multi-turn chat session. |
| `Send-LLMMessage` | Send one turn inside a chat session. |
| `Enter-LLMChat` | Interactive REPL for a chat session. |
| `Expand-LLMProcess` | Render structured steps from any response. |
| `Get-LLMProviders` | List providers and API key status. |
| `Get-LLMEnvironment` | Snapshot of the current PS environment. |
| `Get-LLMModuleDirectives` | Discover `claude.md` files across modules. |

## License

[MIT](LICENSE)
