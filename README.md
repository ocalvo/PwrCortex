# PwrCortex

**Agentic LLM swarm engine for PowerShell.** Environment-aware, pipeline-native, claude.md-driven.

PwrCortex turns PowerShell into an agentic runtime — your LLM can discover loaded modules, call real cmdlets, and orchestrate parallel worker agents that fan out, execute, and synthesize results back into a single answer.

## Requirements

- PowerShell **7.0+**
- An API key for at least one provider:
  - `ANTHROPIC_API_KEY` — Anthropic / Claude
  - `OPENAI_API_KEY` — OpenAI / GPT

## Installation

```powershell
# Clone and import
git clone https://github.com/ocalvo/PwrCortex.git
Import-Module ./PwrCortex/PwrCortex.psd1
```

## Quick Start

```powershell
# Set your API key
$env:ANTHROPIC_API_KEY = "<your-key>"

# Single completion
Invoke-LLM "Explain PowerShell pipelines" -Provider Anthropic

# Environment-aware completion — injects PS version, OS, loaded modules
Invoke-LLM "Which of my loaded modules can talk to Azure?" -Provider Anthropic -WithEnvironment

# Agentic — the LLM calls real PS commands to answer
Invoke-LLMAgent "What process is using the most memory?" -Provider Anthropic

# Interactive chat REPL
$chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Ops"
Enter-LLMChat $chat

# Swarm — parallel worker agents with DAG orchestration
Invoke-LLMSwarm "Audit this machine: running services, open ports, large processes, and disk usage" -Provider Anthropic
```

## Cmdlets

| Cmdlet | Description |
|---|---|
| `Invoke-LLM` | Single/batch completions. Pipeline-friendly. |
| `Invoke-LLMAgent` | Agentic loop — LLM calls back into PS via tool use. |
| `Invoke-LLMSwarm` | Decompose a goal into parallel sub-tasks, run them concurrently, synthesize results. |
| `New-LLMChat` | Create a stateful multi-turn chat session. |
| `Send-LLMMessage` | Send one turn inside a chat session. |
| `Enter-LLMChat` | Interactive REPL for a chat session. |
| `Expand-LLMProcess` | Render structured steps from any response. |
| `Get-LLMProviders` | List providers and API key status. |
| `Get-LLMEnvironment` | Snapshot of the current PS environment. |
| `Get-LLMModuleDirectives` | Discover `claude.md` files across loaded/installed modules. |

## Environment Variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic / Claude API key |
| `OPENAI_API_KEY` | OpenAI / GPT API key |
| `LLM_DEFAULT_PROVIDER` | Default provider name (`Anthropic` or `OpenAI`) |
| `LLM_CONFIRM_DANGEROUS` | Set to `0` to skip destructive-verb confirmation (not recommended) |

## Key Features

### Environment Awareness

The `-WithEnvironment` switch injects a live snapshot of your PowerShell session into the system prompt — PS version, OS, loaded modules, available commands, and all discovered `claude.md` module directives. The LLM knows exactly what it can call and how.

### Agentic Tool Use

`Invoke-LLMAgent` runs a looped completion where the LLM emits `{ "expression": "<powershell>" }` tool calls. The harness executes each via `Invoke-Expression`, serializes the result with `ConvertTo-Json`, and feeds it back. Destructive verbs (`Remove-`, `Stop-`, `Format-`, `Clear-`, etc.) require interactive confirmation before execution.

### Swarm Orchestration

`Invoke-LLMSwarm` breaks a high-level goal into a DAG of parallel sub-tasks:

1. **Decompose** — An orchestrator LLM call produces a JSON task list with optional `DependsOn` relationships.
2. **Dispatch** — Each task runs as a PS `ThreadJob` in its own runspace. Dependencies are resolved automatically; results from prior tasks are substituted via `{{result::<id>}}` placeholders.
3. **Synthesize** — The orchestrator reassembles all worker results into a single coherent answer.

A live task board renders in the console showing status (`○ pending`, `◔ waiting`, `◕ running`, `✓ done`, `✗ failed`) for every task.

### Module Directives

Any PowerShell module can ship a `claude.md` in its `ModuleBase` directory. PwrCortex automatically discovers and injects these into system prompts when `-WithEnvironment` is set, giving the LLM a precise capability map of every loaded module.

### Chat REPL Commands

Inside `Enter-LLMChat`, these slash commands are available:

| Command | Description |
|---|---|
| `/help` | Show command reference |
| `/exit` `/quit` | Leave the chat session |
| `/history` | Print conversation history |
| `/env` | Show the PS environment snapshot |
| `/directives` | List discovered `claude.md` module directives |
| `/expand` | Expand steps in the last response |
| `/tools` | Show tool calls made in the last response |
| `/stats` | Token usage and session info |
| `/model <name>` | Switch model mid-session |
| `/system <text>` | Replace the system prompt |
| `/agentic on\|off` | Toggle agentic tool-use mode |
| `/swarm <goal>` | Spawn a parallel swarm from this chat |
| `/run <expression>` | Execute a PS expression locally |

## Supported Providers & Models

**Anthropic**: `claude-opus-4-6`, `claude-sonnet-4-6` (default), `claude-haiku-4-5-20251001`

**OpenAI**: `gpt-4o` (default), `gpt-4o-mini`, `gpt-4-turbo`, `o1`, `o3-mini`

## License

[MIT](LICENSE)