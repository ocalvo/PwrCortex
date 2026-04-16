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

Not a string. Not JSON. An `[int]`. The LLM computed the answer through PowerShell and the actual .NET object came back to you on `.Result`.

This works for anything PowerShell can return:

```powershell
$r = agent "Top 3 processes by memory" -Provider Anthropic
$r.Result | Format-Table ProcessName, Id, @{n='MB';e={[math]::Round($_.WorkingSet64/1MB)}}

# ProcessName     Id    MB
# -----------     --    --
# msedge        8472  2937
# Teams         3340  1241
# explorer      1052   623

$r.Result[0].Kill()   # it's a live [Process] object — methods work
```

Every other LLM agent framework serializes tool results to JSON or text, shoves them into the context window, and hopes the LLM can parse them back. PwrCortex keeps objects alive in memory. The LLM gets a compact summary; you get the real thing.

## Session context compounds automatically

Every result is stored in a semantically-named global variable and tracked in a session history:

```powershell
$r1 = agent "Count .ps1 files in src/"
# → stored as $global:llm_count_ps1_files_src

$r2 = agent "List running services"
# → stored as $global:llm_list_running_services

$r1.GlobalName   # "llm_count_ps1_files_src"

$global:llm_history
# Index GlobalName                    Type  Prompt
# ----- ----------                    ----  ------
#     1 llm_count_ps1_files_src       agent Count .ps1 files in src/
#     2 llm_list_running_services     agent List running services
```

The third call sees everything:

```powershell
agent "Check $llm_history and summarize what we've done"
# → reads both prior results, produces a complete summary
```

This works because PwrCortex injects all `Global:` scope variables into every agent runspace. Your session IS the context window.

## Pipe data in, get objects out

```powershell
Get-Process | feed "Which one uses the most memory?" -Provider Anthropic
# Pipeline objects land in $refs[1] — the agent works with live .NET objects

Get-History | feed "What was I working on? Suggest next steps." -Provider Anthropic
# Session history becomes agent context
```

`feed` (`Push-LLMInput`) pipes any objects into the agent's `$refs[1]` as input, then runs the agentic loop. The agent sees real typed objects, not serialized text.

## One sentence spawns a parallel swarm

```powershell
think "Audit this machine: services, ports, processes, and disk"
```

**Phase 1 — Decompose.** An orchestrator breaks the goal into a DAG of parallel tasks.
**Phase 2 — Dispatch.** Tasks run concurrently in a `RunspacePool` that clones your session.
**Phase 3 — Synthesize.** Results merge into a single coherent answer.

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

The result tracks token breakdown across all phases:

```powershell
$r = think "Audit services and disk" -Provider Anthropic
$r.InputTokens    # 9200
$r.OutputTokens   # 3140
$r.TotalTokens    # 12340
$r.TotalSec       # 8.42
```

## Why this exists

Every LLM agent framework treats shells the same way: run a command, capture stdout as a string, shove it into the context window. Python frameworks (LangChain, CrewAI, AutoGen) serialize to JSON. Bash-based agents get raw text. AI coding tools (Claude Code, Cursor, Copilot) shell out and parse the output.

They all make the same mistake: **they treat PowerShell like bash.**

Bash commands return text. PowerShell commands return **.NET objects** — with properties, methods, types, and pipeline semantics. When you run `Get-Process`, you don't get a string — you get `[System.Diagnostics.Process]` instances with `.WorkingSet64`, `.CPU`, `.Kill()`.

**PwrCortex is the first LLM agent framework that understands PowerShell is not a text shell.** It keeps objects alive in memory, gives the LLM a compact summary, and lets subsequent tool calls operate on the real .NET objects — not a string representation of them.

The shell is not a sandbox. The shell is the runtime.

## The economics

The `$refs` architecture doesn't just improve correctness — it fundamentally changes the cost:

| | PwrCortex | Claude Code / Cursor | LangChain / AutoGen |
|---|---|---|---|
| Tool result storage | Live .NET object in `$refs[id]` | Text in conversation | JSON in context window |
| Token cost to chain | ~5 tokens (`$refs[1]`) | Full text re-sent | Entire blob re-sent |
| Type fidelity | Full — methods, properties, events | Plain text | Strings and numbers |
| Per-agent-call cost (5 steps) | ~$0.025 | ~$2–5+ | ~$1.10 |

**Multi-step agent (5 tool calls):**

| | JSON / text approach | PwrCortex `$refs` | Savings |
|---|---|---|---|
| Total tool data in context | ~50,000–70,000 tokens | ~1,500 tokens | **~97%** |
| 100 Opus calls/day | ~$3,300/mo | ~$75/mo | **$3,200/mo saved** |

## Aliases

Short names for interactive use:

| Alias | Cmdlet | Purpose |
|---|---|---|
| `agent` | `Invoke-LLMAgent` | Agentic tool-use loop, returns typed `.Result` |
| `think` | `Invoke-LLMSwarm` | Parallel swarm orchestration |
| `llm` | `Invoke-LLM` | Single completion |
| `chat` | `Enter-LLMChat` | Interactive REPL |
| `feed` | `Push-LLMInput` | Pipe objects as agent input |
| `swarm` | `Invoke-LLMSwarm` | Alias for `think` |

## Modules document themselves with `claude.md`

Drop a `claude.md` file in any module's directory and PwrCortex discovers it automatically. The LLM gets a curated capability map — not just commands, but *how* to use them:

```
MyModule/
├── MyModule.psm1
├── MyModule.psd1
└── claude.md          ← the LLM reads this
```

Every module in `$env:PSModulePath` with a `claude.md` becomes an AI-callable toolkit. No registration. No schemas. No wrappers.

## Installation

```powershell
# Requires PowerShell 7.0+
Install-Module PwrCortex -Repository PSGallery
```

Set your API keys:

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."   # https://console.anthropic.com
$env:OPENAI_API_KEY    = "sk-..."       # https://platform.openai.com
```

Optionally set a default provider:

```powershell
$env:LLM_DEFAULT_PROVIDER = "Anthropic"
```

## Quick start

```powershell
Import-Module PwrCortex

# Check what's configured
Get-LLMProviders

# Typed results — .Result is a real .NET object
$r = agent "Top 5 processes by CPU" -Provider Anthropic
$r.Result | Format-Table

# Pipe data in
Get-Service | feed "Which services are stopped but set to auto-start?" -Provider Anthropic

# Parallel swarm
think "Security audit: open ports, services, event log errors" -Provider Anthropic

# Interactive chat with tool use
$chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Ops"
Enter-LLMChat $chat
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

## Environment variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic / Claude API key |
| `OPENAI_API_KEY` | OpenAI / GPT API key |
| `LLM_DEFAULT_PROVIDER` | Default provider name (`Anthropic` or `OpenAI`) |
| `LLM_CONFIRM_DANGEROUS` | Set to `0` to skip destructive-verb confirmation |

## License

[MIT](LICENSE)
