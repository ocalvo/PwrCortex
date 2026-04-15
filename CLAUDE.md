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
| `Invoke-LLMAgent` | The task requires calling real PowerShell commands. Runs in a dedicated Runspace with a `$refs` object registry — results stay as live .NET objects, never serialized to JSON. |
| `Invoke-LLMSwarm` | The goal decomposes into parallel sub-tasks. Workers run in a RunspacePool with DAG-based dependencies and in-memory object passing. |
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

## Branch and PR Policy (release-please)

**Never commit directly to `main`.** All changes must go through a feature branch and pull request. This repo uses [release-please](https://github.com/googleapis/release-please) to automate versioning and changelog generation from merged PR titles.

1. `git checkout -b <short-slug>` — e.g. `feat/llm-timeout`, `fix/swarm-encoding`.
2. Commit on that branch.
3. `gh pr create --title "<type>: <description>" --body "..."` — use `--base main`.
4. Squash-merge; GitHub uses the PR title as the commit subject, which release-please parses.
5. Release-please opens/updates a release PR bumping `PwrCortex.psd1` and `CHANGELOG.md`. Merge that to publish.

**PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/):**

```
<type>[optional scope][!]: <short description>
```

| Type | Version bump | Use for |
|------|--------------|---------|
| `feat` | minor (`1.2.3` → `1.3.0`) | New features, new cmdlets, new parameters |
| `fix` | patch (`1.2.3` → `1.2.4`) | Bug fixes, encoding fixes, parse-error fixes |
| `feat!` / `fix!` / `BREAKING CHANGE:` footer | major (`1.2.3` → `2.0.0`) | Breaking API or behavior changes |
| `perf` | patch | Performance improvements |
| `refactor` | patch | Internal restructuring, no behavior change |
| `docs` | no release | Documentation-only (README, CLAUDE.md, help) |
| `chore` | no release | Housekeeping, deps, formatting |
| `ci` | no release | CI/CD config |
| `test` | no release | Test-only changes |

Examples:

```
feat: add -Timeout parameter to Invoke-LLMAgent
fix: restore box-drawing glyphs lost to double-encoding
docs: expand README with swarm orchestration details
chore: add release-please and PSGallery publish workflows
ci: add Pester test workflow
feat!: rename Get-LLMEnvironment to Get-LLMSessionSnapshot
```

Rules:
- **Imperative mood** ("add", "fix", "remove" — not "added", "fixes").
- Under 72 characters.
- No generic messages ("update files", "misc changes").
- Split unrelated changes into separate PRs.
- If a PR title doesn't match the grammar, release-please silently ignores it.
