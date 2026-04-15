#Requires -Version 7.0
<#
.SYNOPSIS
    PwrCortex — Agentic LLM swarm engine for PowerShell.
    Environment-aware. Pipeline-native. claude.md-driven.

.DESCRIPTION
    PUBLIC CMDLETS
    ──────────────
    Invoke-LLM              Single/batch completions. Pipeline-friendly.
    Invoke-LLMAgent         Agentic loop with dedicated Runspace and $refs object registry.
    Invoke-LLMSwarm         Decompose → dispatch (RunspacePool DAG) → synthesize.
    New-LLMChat             Create a stateful multi-turn chat session.
    Send-LLMMessage         Send one turn inside a chat session.
    Enter-LLMChat           Interactive REPL for a chat session.
    Expand-LLMProcess       Render structured steps from any response.
    Get-LLMProviders        List providers and API key status.
    Get-LLMEnvironment      Snapshot of the current PS environment.
    Get-LLMModuleDirectives Discover claude.md files across loaded/installed modules.

    NATIVE OBJECTS — NOT JSON
    ─────────────────────────
    Tool call results are never serialized to JSON. Each expression runs in
    a dedicated Runspace and its output is stored as a live .NET object in
    a $refs[id] registry. The LLM receives a compact Out-String summary;
    subsequent tool calls can chain via $refs[id] with full type fidelity.

    ENVIRONMENT AWARENESS
    ─────────────────────
    -WithEnvironment injects PS version, OS, loaded modules, command count,
    and all discovered claude.md module directives into every system prompt.
    The LLM knows exactly what it can call and how.

    MODULE DIRECTIVES
    ─────────────────
    Any module can ship a claude.md in its ModuleBase directory.
    Get-LLMModuleDirectives discovers and returns them as objects.
    Build-SystemPrompt automatically injects them when -WithEnvironment is set.

.ENVIRONMENT VARIABLES
    ANTHROPIC_API_KEY     Anthropic / Claude
    OPENAI_API_KEY        OpenAI / GPT
    LLM_DEFAULT_PROVIDER  Default provider name (Anthropic or OpenAI)
    LLM_CONFIRM_DANGEROUS Set to '0' to skip destructive-verb confirmation (not recommended)

.EXAMPLE
    Invoke-LLM "Which of my loaded modules can talk to Azure?" -Provider Anthropic -WithEnvironment

.EXAMPLE
    Invoke-LLMAgent "What process is using the most memory?" -Provider Anthropic

.EXAMPLE
    $chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Ops"
    Enter-LLMChat $chat
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Dot-source private internals (order matters: Config first) ────────────────
. "$PSScriptRoot/Private/Config.ps1"
. "$PSScriptRoot/Private/Rendering.ps1"
. "$PSScriptRoot/Private/Api.ps1"
. "$PSScriptRoot/Private/AgentSession.ps1"
. "$PSScriptRoot/Private/AgentHelpers.ps1"
. "$PSScriptRoot/Private/Swarm.ps1"

# ── Dot-source public cmdlets ────────────────────────────────────────────────
Get-ChildItem "$PSScriptRoot/Public/*.ps1" | ForEach-Object { . $_.FullName }

# ── Exports ──────────────────────────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Invoke-LLM'
    'Invoke-LLMAgent'
    'Invoke-LLMSwarm'
    'New-LLMChat'
    'Send-LLMMessage'
    'Enter-LLMChat'
    'Expand-LLMProcess'
    'Get-LLMProviders'
    'Get-LLMEnvironment'
    'Get-LLMModuleDirectives'
)
