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

A real session. Each call builds on the last. No variable names to remember — the agent resolves natural language references automatically.

```powershell
# ── Step 1: gather data ──────────────────────────────────────
$r1 = agent "Get the top 5 processes by WorkingSet64"

$r1.Result | ForEach-Object { "$($_.ProcessName) — $([math]::Round($_.WorkingSet64/1MB))MB" }
# vmmemWSL — 7642MB
# Memory Compression — 957MB
# explorer — 623MB
# node — 572MB
# msedge — 426MB
```

The response is an `[LLMResponse]` with `.Result` pointing at a live `[Process[]]` array. Because you rendered it at the prompt, the typed objects also live in `$global:context[-1].Output`.

```powershell
# ── User sets a threshold ────────────────────────────────────
$global:memory_threshold_mb = 1000
```

```powershell
# ── Step 2: just say what you mean ───────────────────────────
$r2 = agent "Filter those top processes to the ones exceeding the memory threshold"

$r2.Result | ForEach-Object { "$($_.ProcessName) — $([math]::Round($_.WorkingSet64/1MB))MB" }
# vmmemWSL — 7642MB
```

No variable names. The agent saw the prior `$r1` render in `<conversation_context>` and discovered `$memory_threshold_mb` from the user's global scope. It connected "those top processes" to the previous context entry and "the memory threshold" to the variable — automatically.

```powershell
# ── User adds context ────────────────────────────────────────
$global:user_note = "vmmemWSL is expected during builds. Flag anything else."
```

```powershell
# ── Step 3: ask for a summary — agent finds everything it needs ──
$r3 = agent "Write a session report. Note anything unexpected."

$r3.Content
# 1. GATHERED: Top 5 processes — vmmemWSL (7,642 MB), Memory Compression (957 MB),
#    explorer (623 MB), node (572 MB), msedge (426 MB).
# 2. FILTERED: Only vmmemWSL exceeds the 1,000 MB threshold.
# 3. USER NOTE: vmmemWSL is expected during builds.
# 4. ASSESSMENT: No anomalies. All high-memory processes are accounted for.
```

The agent found the conversation so far, the user note, and every prior result on its own — without being told where to look.

```powershell
# ── The conversation log tracked everything ───────────────────
$global:context | Select-Object -Last 3 HistoryId, Timestamp, Command

# HistoryId Timestamp           Command
# --------- ---------           -------
#        12 2026-04-19 10:12:41 agent "Get the top 5 processes by WorkingSet64"
#        14 2026-04-19 10:13:02 agent "Filter those top processes to the ones..."
#        15 2026-04-19 10:13:33 agent "Write a session report. Note anything..."
```

**Total: 3 calls, ~20K tokens.** Each call saw the full accumulated context from every prior call, plus any variables the user set in between. Like Claude Code — but at a fraction of the token cost, and without spelling out a single variable name.

## How it works

On import, PwrCortex installs an `Out-Default` proxy and initializes a single
global — `$global:context`. Every command the user runs at the interactive
prompt appends `{ HistoryId, Timestamp, Command, Output }` to `$global:context`,
where `Output` is the list of live typed .NET objects that were displayed.

When you call `agent`, `swarm`, or `chat`:

1. **The conversation log is injected** into the system prompt — the LLM reads
   `$global:context` as the transcript, exactly like a chat history.
2. **Your session is cloned** into a dedicated Runspace — modules, env vars,
   and all `Global:` variables (including `$context` itself) come along.
3. **Tool calls store live .NET objects** in `$refs[id]` — not JSON, not text.
4. **The response is returned** as an `[LLMResponse]` with `.Content`,
   `.Result`, `.ToolCalls`, etc. That response itself flows through Out-Default
   and lands in `$global:context` for the next call to see.

Use `Remove-Context` to scrub or trim entries (e.g. before a tokens-sensitive
call, or after commands whose output you do not want sent to the provider).

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
