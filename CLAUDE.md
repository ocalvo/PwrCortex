# PwrCortex — Module Directives

> This file is automatically discovered by `Get-LLMModuleDirectives` and injected
> into system prompts when `-WithEnvironment` is used.

## What This Module Does

PwrCortex is an agentic LLM swarm engine for PowerShell. It provides cmdlets for
completions, agentic tool-use loops, multi-turn chat, and parallel swarm orchestration
backed by Anthropic (Claude) or OpenAI (GPT) APIs.

## Key Cmdlets

| Cmdlet | Use When |
|---|---|
| `Invoke-LLM` | You need a single completion or want to pipe multiple prompts through. |
| `Invoke-LLMAgent` | The task requires calling real PowerShell commands to gather data or act. The LLM gets an `invoke_powershell` tool. |
| `Invoke-LLMSwarm` | The goal decomposes into parallel sub-tasks. Workers run as ThreadJobs with DAG-based dependencies. |
| `New-LLMChat` | You need a stateful multi-turn conversation. Pair with `Send-LLMMessage` or `Enter-LLMChat`. |
| `Send-LLMMessage` | Send a single turn inside an existing `[LLMChat]` session. |
| `Enter-LLMChat` | Launch an interactive REPL for a chat session. Supports `/help`, `/expand`, `/swarm`, `/run`, and more. |
| `Expand-LLMProcess` | Render numbered/bulleted steps from an `[LLMResponse]` in expanded detail. |
| `Get-LLMProviders` | Check which providers have API keys configured and their default models. |
| `Get-LLMEnvironment` | Capture a live snapshot of the PS session (version, OS, modules, commands). |
| `Get-LLMModuleDirectives` | Discover `claude.md` files across loaded or installed modules. |

## Conventions

- Always use `-Provider Anthropic` or `-Provider OpenAI` (or set `$env:LLM_DEFAULT_PROVIDER`).
- Use `-WithEnvironment` when the LLM needs to know about the current PowerShell session.
- Use `-Quiet` to suppress console rendering and only emit objects to the pipeline.
- Destructive expressions (`Remove-`, `Stop-`, `Format-`, `Clear-`, `Kill-`, etc.) require interactive confirmation unless `-AutoConfirm` is passed or `$env:LLM_CONFIRM_DANGEROUS` is `'0'`.
- All responses are `[LLMResponse]` objects with `.Content`, `.Steps`, `.ToolCalls`, `.TotalTokens`, `.ElapsedSec`.
- Swarm results are `[LLMSwarmResult]` objects with `.Tasks`, `.Synthesis`, `.TotalTokens`, `.TotalSec`.

## Environment Variables

- `ANTHROPIC_API_KEY` — Required for Anthropic/Claude provider.
- `OPENAI_API_KEY` — Required for OpenAI/GPT provider.
- `LLM_DEFAULT_PROVIDER` — Default provider when `-Provider` is omitted.
- `LLM_CONFIRM_DANGEROUS` — Set to `'0'` to skip destructive-verb confirmation.

## Pipeline Patterns

```powershell
# Batch completions
Get-Content prompts.txt | Invoke-LLM -Provider Anthropic -Quiet | Export-Csv results.csv

# Agentic data gathering
Invoke-LLMAgent "Show top 5 processes by memory" -Provider Anthropic

# Swarm with DAG
Invoke-LLMSwarm "Audit services, ports, processes, and disk" -Provider Anthropic -MaxTasks 4

# Chat with tool use
$chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic
$chat | Send-LLMMessage "List loaded modules with a claude.md"
```

## Module Directive Discovery

Any PowerShell module can include a `claude.md` file in its `ModuleBase` directory.
PwrCortex discovers these automatically and injects their content into system prompts,
giving the LLM a precise understanding of what each module does and how to use it.
