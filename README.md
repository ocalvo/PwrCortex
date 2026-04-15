# PwrCortex

Agentic LLM swarm engine for PowerShell.
Environment-aware. Pipeline-native. claude.md-driven.

```powershell
Install-Module PwrCortex
```

## Why this exists

Every LLM agent framework treats shells the same way: run a command, capture stdout as a string, shove it into the context window. Python frameworks (LangChain, CrewAI, AutoGen) serialize to JSON. Bash-based agents get raw text. AI coding tools (Claude Code, Cursor, Copilot) shell out and parse the output.

They all make the same mistake: **they treat PowerShell like bash.**

Bash commands return text. PowerShell commands return **.NET objects** — with properties, methods, types, and pipeline semantics. When you run `Get-Process`, you don't get a string — you get `[System.Diagnostics.Process]` instances with `.WorkingSet64`, `.CPU`, `.Kill()`. When you run `Get-BuildErrors`, you get `[BuildError]` objects with `.File`, `.Line`, `.Severity`. None of that survives serialization to JSON or text.

Every existing framework throws away this structure, pays to serialize it, pays again to stuff it into the context window, and pays a third time when the LLM hallucinates properties that existed in the original object but got lost in translation.

**PwrCortex is the first LLM agent framework that understands PowerShell is not a text shell.** It keeps objects alive in memory, gives the LLM a compact summary, and lets subsequent tool calls operate on the real .NET objects — not a string representation of them.

The shell is not a sandbox. The shell is the runtime.

## What makes it different

### 1. Native objects, not JSON strings

This is the fundamental difference between PwrCortex and every other LLM agent framework.

When an LLM agent in LangChain or AutoGen calls a tool, it gets back a JSON string. When it needs to process that result further, the entire serialized blob gets shoved back into the context window — burning tokens, losing type information, and breaking anything that doesn't round-trip through JSON cleanly (`DateTime`, `Process`, `ServiceController`, COM objects, nested PSCustomObjects with circular refs).

**PwrCortex never serializes tool results.** Each tool call runs in a dedicated .NET Runspace. The raw output — the actual `[Process]`, `[ServiceController]`, `[FileInfo]`, whatever PowerShell returned — is stored in a live in-memory object registry (`$refs`). The LLM receives a compact `Out-String` summary (the same human-readable table you'd see in your terminal), plus a reference ID:

```
ref:1 -> [Process[]] 5 items
 NPM(K)  PM(M)  WS(M)  CPU(s)    Id  SI ProcessName
 ------  -----  -----  ------    --  -- -----------
    142  2,814  2,937   1,204  8472   1 msedge
     87  1,102  1,241     892  3340   1 Teams
    ...
```

When the LLM needs to drill deeper, it doesn't re-parse JSON — it writes:

```powershell
$refs[1] | Where-Object WorkingSet64 -gt 1GB | Select-Object ProcessName, Id, @{n='MB';e={[math]::Round($_.WorkingSet64/1MB)}}
```

That expression runs against the **real .NET objects** still in memory. Properties, methods, type accelerators, pipeline operators — everything works because nothing was ever flattened to text.

**What this means in practice:**

| | PwrCortex | Claude Code / Cursor | LangChain / AutoGen |
|---|---|---|---|
| Tool result storage | Live .NET object in `$refs[id]` | Text string in conversation | JSON string in context window |
| Token cost of chaining | ~5 tokens (`$refs[1]`) | Full text re-sent every turn | Entire serialized blob re-sent |
| Type fidelity | Full — methods, properties, events | Plain text | Strings and numbers only |
| Pipeline composition | Native `Where-Object`, `Sort-Object` | Regex / string parsing | Parse JSON, rebuild, re-serialize |
| Result available to caller | `.Result` — live objects | Text only | JSON only |
| Per-agent-call cost (Opus, 5 steps) | ~$0.025 | ~$2–5+ | ~$1.10 |

A real example: ask the agent to "find the top 3 memory-heavy processes and kill the one using the most". In a JSON framework, that's serialize → deserialize → find the ID → call another tool. In PwrCortex:

```powershell
# Tool call 1: get processes
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3
# → stored as $refs[1], LLM sees the Out-String table

# Tool call 2: kill the top one (still a live Process object!)
$refs[1][0] | Stop-Process -Force
```

Two tool calls, ~10 tokens of context for the reference. Zero serialization. Full type safety.

**And those objects come back to YOU on `.Result`:**

```powershell
$r = Invoke-LLMAgent "Top 3 processes by memory" -Provider Anthropic -Quiet

$r.Content   # what the LLM said (text)
$r.Result    # the actual [Process] objects it collected — a flat array

# Pipeline them — these are real live .NET objects
$r.Result | Format-Table ProcessName, Id, @{n='MB';e={[math]::Round($_.WorkingSet64/1MB)}}

# Filter, chain, export — just like any other cmdlet output
$r.Result | Where-Object CPU -gt 60 | Stop-Process -WhatIf
$r.Result | Export-Csv top-procs.csv
$r.Result | Select-Object -First 1   # first object
```

The response carries both the LLM's text answer (`.Content`) and every live object it gathered (`.Result`). Your script gets native PowerShell objects — not a string to parse, not JSON to deserialize.

### The cost savings are massive

Every token you don't send is money you don't spend. The `$refs` architecture doesn't just improve correctness — it fundamentally changes the economics of running LLM agents.

**Single tool call** — `Get-Process | Select -First 5`:

| | JSON framework / Claude Code | PwrCortex |
|---|---|---|
| Tool result | ~4,000 tokens (60 properties per object, serialized) | ~250 tokens (Out-String table) |
| Chain to next call | Re-send entire blob | `$refs[1]` — 5 tokens |

**Multi-step agent (5 tool calls)** — each result stays in conversation history:

| | JSON / text approach | PwrCortex `$refs` | Savings |
|---|---|---|---|
| Total tool data in context | ~50,000–70,000 tokens | ~1,500 tokens | **~97%** |
| Claude Sonnet per call | ~$0.22 | ~$0.005 | **~97%** |
| Claude Opus per call | ~$1.10 | ~$0.025 | **~97%** |
| 100 Opus calls/day | ~$3,300/mo | ~$75/mo | **$3,200/mo saved** |

And these savings **multiply with every PowerShell module in the ecosystem**.

Consider [**PwrDev**](https://github.com/ocalvo/PwrDev) — a build and deployment module for C++ and .NET projects. Its `Get-BuildErrors` cmdlet returns structured `[BuildError]` objects with `File`, `Line`, `Column`, `Message`, `Severity` properties. In Claude Code or any text-based agent, a build log is a wall of unstructured text that burns thousands of tokens. In PwrCortex:

```powershell
# Agent calls Get-BuildErrors — returns typed [BuildError] objects
# LLM sees a clean table (~200 tokens), stores as $refs[1]
# Agent then calls: $refs[1] | Where-Object Severity -eq 'Error' | Select -First 3
# → targets exactly the files that need fixing, ~5 tokens for the chain
```

The same principle applies to every module: **Az** (VMs, storage, networking as objects), **dbatools** (SQL results as DataRows), **VMware.PowerCLI** (VM state as objects), **ActiveDirectory** (users, groups, OUs). Each module that returns native PowerShell objects instead of text is an automatic cost multiplier for PwrCortex — the richer your module ecosystem, the less you pay per agent call.

**The implication:** an organization with 50 internal modules and PwrCortex can run an AI-powered ops team at a fraction of the cost of any text-based agent framework. The PowerShell module ecosystem isn't a limitation — it's the competitive advantage.

### 2. PowerShell IS the tool

Every other framework asks you to pre-register tools, write JSON schemas for each function, and maintain a dispatch table. PwrCortex collapses all of that to a single idea:

> The LLM already knows every PowerShell cmdlet. Give it a way to call them.

```powershell
Invoke-LLMAgent "What process is consuming the most memory right now?" -Provider Anthropic
```

The model emits `{ "expression": "Get-Process | Sort-Object WorkingSet -Desc | Select -First 5" }`.
The harness runs it in a dedicated Runspace. Stores the live result. Feeds back a summary. The model answers with real data.

Your entire module library — Az, ActiveDirectory, dbatools, VMware.PowerCLI, anything — is instantly available as agent-callable tooling. No registration. No schemas. No wrappers.

### 3. Dedicated Runspace per agent — isolated, stateful, concurrent

Each `Invoke-LLMAgent` call gets its own .NET `Runspace` with a full clone of your session — modules, environment variables, aliases, everything. Tool calls execute inside this Runspace, so:

- **State persists** across tool calls — variables set in call 1 are available in call 2
- **Isolation is automatic** — the agent can't corrupt your interactive session
- **`$refs` lives in the Runspace** — a shared `@{}` hashtable that accumulates results across all tool calls in the session
- **Timeouts are enforced** — `BeginInvoke()` + `AsyncWaitHandle.WaitOne()` with a configurable `-ToolTimeoutSec`
- **Streams are captured** — `Write-Verbose`, `Write-Warning`, `Write-Debug`, `Write-Error` are all collected and appended to the tool result

### 4. Modules document themselves to the LLM with `claude.md`

Drop a `claude.md` file in any module's directory and PwrCortex discovers it automatically. The LLM gets a curated, prescriptive capability map — not just a list of commands, but *how* to use them, what to avoid, what needs confirmation before execution.

```
MyModule/
├── MyModule.psm1
├── MyModule.psd1
└── claude.md          ← the LLM reads this
```

Example `claude.md` for Az.Compute:

```markdown
# Az.Compute

## Key Cmdlets
- `Get-AzVM [-ResourceGroupName <string>]` — list VMs
- `Start-AzVM -ResourceGroupName <string> -Name <string>` — start a VM

## Conventions
- Always pipeline Get-AzVM rather than calling by name when operating on multiple resources.
- ResourceGroupName is almost always required. Ask the user if not known.

## Caution
- Remove-AzVM is irreversible. Always confirm with the user before emitting this expression.
```

This turns `claude.md` into a first-class PowerShell module convention — the same way modules ship `about_` help topics for humans, they ship `claude.md` for AI consumers.

### 5. One prompt spawns a parallel swarm

```powershell
Invoke-LLMSwarm "Audit this machine: running services, open ports, top processes, disk usage" -Provider Anthropic
```

What happens:

**Phase 1 — Decompose.** An orchestrator LLM call breaks the goal into a task graph with dependency relationships.

**Phase 2 — Dispatch.** Independent tasks launch immediately as parallel workers in a `RunspacePool` that clones your full session. Tasks with `DependsOn` wait only as long as their dependencies take. Worker results stay as in-memory objects — no serialization boundary between runspaces in the same process. A live task board renders in the console:

```
╭── SWARM  ◆  4 tasks ─────────────────────────────────────╮
  Goal: Audit this machine...

  ✓ t1     Scan running services              0.9s
  ✓ t2     Check open ports                   1.4s
  ◕ t3     Analyse top processes              ← running
  ◔ t4     Correlate services + ports         ← t1, t2
```

**Phase 3 — Synthesize.** All results flow back to the orchestrator which produces a single coherent answer.

The LLM generates the DAG. You write one sentence.

### 6. Everything is a PS object

PwrCortex never breaks the pipeline. Every cmdlet returns typed PSCustomObjects with default display sets, so they compose naturally with the rest of PowerShell:

```powershell
# Filter, export, measure — just like any other cmdlet
Invoke-LLMSwarm "..." -Provider Anthropic |
    Select-Object -Expand Tasks |
    Where-Object Status -eq 'failed' |
    Export-Csv audit-failures.csv

# Batch processing
Get-ChildItem *.log | ForEach-Object { Get-Content $_ -Raw } |
    Invoke-LLM -Provider Anthropic -SystemPrompt "Summarise this log for a SOC analyst." |
    Select-Object Summary, TotalTokens |
    Sort-Object TotalTokens -Descending
```

No JSON wrangling. No `ConvertFrom-Json` ceremony. Just the pipe.

### 7. The environment IS the context

```powershell
Invoke-LLM "Which of my loaded modules can manage Azure VMs?" -Provider Anthropic -WithEnvironment
```

`-WithEnvironment` injects a live snapshot of your PS session into every system prompt — PS version, OS, loaded modules with versions, available command count, and all discovered `claude.md` directives. The LLM knows exactly what host it's running inside before it answers a single question.

### 8. Destructive operations require confirmation

The agent will never run `Remove-`, `Stop-`, `Format-`, `Clear-`, or any other destructive verb without showing you first:

```
╭──────────────────────────────────────────────────────────╮
│ ⚠  DESTRUCTIVE OPERATION — CONFIRM BEFORE EXECUTION      │
├──────────────────────────────────────────────────────────┤
│  Remove-Item C:\Logs\* -Recurse -Force                   │
╰──────────────────────────────────────────────────────────╯
Allow execution? [y/N]
```

Set `$env:LLM_CONFIRM_DANGEROUS=0` to disable this in automated pipelines where you've already reviewed the agent's plan.

## Architecture

```
┌──────────────────────────────────────────────────┐
│  User prompt                                      │
├──────────────────────────────────────────────────┤
│  Invoke-LLM        → single completion            │
│  Invoke-LLMAgent   → tool-use loop                │
│  Invoke-LLMSwarm   → decompose → dispatch → synth │
│  New/Send/Enter     → multi-turn chat              │
├──────────────────────────────────────────────────┤
│  Provider layer     Anthropic │ OpenAI             │
├──────────────────────────────────────────────────┤
│  Agent Runspace     $refs registry → .Result        │
│  Swarm RunspacePool DAG scheduler, shared memory   │
└──────────────────────────────────────────────────┘
```

### The Object Registry: `$refs` inside, `.Result` outside

During execution, every tool call stores its output as a live object in `$refs`:

```
$refs[1] = [Process[]]           ← Get-Process output
$refs[2] = [ServiceController[]] ← Get-Service output
$refs[3] = [FileInfo[]]          ← Get-ChildItem output
```

The LLM sees a compact summary and chains with `$refs[1] | Where-Object CPU -gt 100`.
This costs ~5 tokens instead of ~50,000 tokens for serializing 309 process objects to JSON.

After the agent completes, the registry is flattened into a pipeline-native array on `.Result`:

```powershell
$r = Invoke-LLMAgent "Show disk usage and top processes" -Provider Anthropic -Quiet

$r.Result                              # all collected objects as a flat array
$r.Result | Where-Object CPU -gt 100   # filter — works because they're real .NET objects
$r.Result | Export-Csv report.csv      # export — no ConvertFrom-Json needed
```

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

# Ask a question — returns a rich object, renders beautifully
Invoke-LLM "What PS modules do I have for working with Azure?" -Provider Anthropic -WithEnvironment

# Let the agent gather data — .Result gives you live .NET objects
$r = Invoke-LLMAgent "Find the top 5 processes by CPU and tell me what they do" -Provider Anthropic
$r.Result | Format-Table   # real [Process] objects, not text

# Spawn a parallel swarm from one sentence
Invoke-LLMSwarm "Security audit: open ports, running services, recent event log errors" -Provider Anthropic

# Interactive chat session with agentic tool use
$chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Ops"
Enter-LLMChat $chat
```

## Interactive REPL commands

Inside `Enter-LLMChat`, type `/help` for the full list. Highlights:

| Command | What it does |
|---|---|
| `/swarm <goal>` | Spawn a parallel swarm from the current chat |
| `/swarm-results` | Show task breakdown from last swarm |
| `/run <expression>` | Execute a PS expression locally and print result |
| `/expand` | Expand steps in the last response |
| `/expand <N>` | Expand steps in response N (1-based) |
| `/tools` | Show tool calls made in the last response |
| `/model <name>` | Switch model mid-session |
| `/system <text>` | Replace the system prompt |
| `/agentic on\|off` | Toggle agentic tool-use mode |
| `/env` | Show the PS environment snapshot |
| `/directives` | List discovered `claude.md` module directives |
| `/history` | Print conversation history |
| `/stats` | Token usage and session info |
| `/clear` | Clear the screen |
| `/exit` `/quit` | Leave the chat session |

## Cmdlets

| Cmdlet | Description |
|---|---|
| `Invoke-LLM` | Single/batch completions. Pipeline-friendly. |
| `Invoke-LLMAgent` | Agentic loop — dedicated Runspace, native objects returned on `.Result`. |
| `Invoke-LLMSwarm` | Decompose → RunspacePool DAG dispatch → synthesize. Native object passing between workers. |
| `New-LLMChat` | Create a stateful multi-turn chat session. |
| `Send-LLMMessage` | Send one turn inside a chat session. |
| `Enter-LLMChat` | Interactive REPL for a chat session. |
| `Expand-LLMProcess` | Render structured steps from any response. |
| `Get-LLMProviders` | List providers and API key status. |
| `Get-LLMEnvironment` | Snapshot of the current PS environment. |
| `Get-LLMModuleDirectives` | Discover `claude.md` files across loaded/installed modules. |

## Environment variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic / Claude API key |
| `OPENAI_API_KEY` | OpenAI / GPT API key |
| `LLM_DEFAULT_PROVIDER` | Default provider name (`Anthropic` or `OpenAI`) |
| `LLM_CONFIRM_DANGEROUS` | Set to `0` to skip destructive-verb confirmation |

## License

[MIT](LICENSE)
