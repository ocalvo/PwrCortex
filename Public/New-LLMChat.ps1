function New-LLMChat {
<#
.SYNOPSIS
    Create a stateful multi-turn [LLMChat] session object.

.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override.
.PARAMETER SystemPrompt
    Instruction prompt applied to every turn.
.PARAMETER MaxTokens
    Max tokens per reply. Default 1024.
.PARAMETER WithEnvironment
    Inject PS environment and claude.md directives on every turn.
.PARAMETER Name
    Human-readable session name (auto-generated if omitted).
.PARAMETER Agentic
    Enable tool use inside this chat session (LLM can call PS expressions).

.EXAMPLE
    $chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Ops"
    Enter-LLMChat $chat
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,
        [string]$SystemPrompt = '',

        [ValidateRange(1,32768)]
        [int]$MaxTokens = 1024,

        [switch]$WithEnvironment,
        [switch]$Agentic,
        [string]$Name
    )
    if (-not $Model) { $Model = $script:Providers[$Provider].DefaultModel }
    if (-not $Name)  { $Name  = "$Provider-$(Get-Random -Max 9999)" }

    [PSCustomObject]@{
        PSTypeName      = 'LLMChat'
        Id              = $Name
        Provider        = $Provider
        Model           = $Model
        SystemPrompt    = $SystemPrompt
        MaxTokens       = $MaxTokens
        WithEnvironment = $WithEnvironment.IsPresent
        Agentic         = $Agentic.IsPresent
        History         = [System.Collections.Generic.List[PSCustomObject]]::new()
        Responses       = [System.Collections.Generic.List[PSCustomObject]]::new()
        TotalTokensUsed = 0
        TurnCount       = 0
        CreatedAt       = [datetime]::UtcNow
        LastSwarm       = $null
    }
}
