function Push-LLMInput {
<#
.SYNOPSIS
    Pipe objects into an LLM agent as pre-loaded $refs input.

.DESCRIPTION
    Collects all pipeline objects, stores them as $refs[1] in the agent's
    runspace, and runs the agentic loop with that context. The agent sees
    the data as input (not tool-call output) and can chain from $refs[1]
    in its expressions.

.PARAMETER Prompt
    The task to accomplish against the input data.
.PARAMETER InputObject
    Pipeline objects to pre-load as $refs[1].
.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override.
.PARAMETER MaxTokens
    Max tokens per completion turn. Default 2048.
.PARAMETER MaxTurns
    Maximum tool-call iterations. Default 10.
.PARAMETER ToolTimeoutSec
    Per-tool-call timeout in seconds. Default 30.
.PARAMETER AutoConfirm
    Skip destructive-verb confirmation prompts.
.PARAMETER Quiet
    Suppress console rendering.

.EXAMPLE
    Get-Process | Push-LLMInput "Which process uses the most memory?" -Provider Anthropic

.EXAMPLE
    Import-Csv data.csv | Push-LLMInput "Summarize trends in this dataset" -Provider Anthropic -Quiet
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Prompt,

        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,

        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,

        [ValidateRange(1,32768)]
        [int]$MaxTokens = 2048,

        [ValidateRange(1,50)]
        [int]$MaxTurns = 10,

        [ValidateRange(5,600)]
        [int]$ToolTimeoutSec = 30,

        [switch]$AutoConfirm,
        [switch]$Quiet
    )
    begin {
        $items = [System.Collections.Generic.List[object]]::new()
    }
    process {
        $items.Add($InputObject)
    }
    end {
        $agentParams = @{
            Prompt         = $Prompt
            InputObject    = $items.ToArray()
        }
        if ($Provider)       { $agentParams.Provider       = $Provider }
        if ($Model)          { $agentParams.Model          = $Model }
        if ($MaxTokens)      { $agentParams.MaxTokens      = $MaxTokens }
        if ($MaxTurns)       { $agentParams.MaxTurns       = $MaxTurns }
        if ($ToolTimeoutSec) { $agentParams.ToolTimeoutSec = $ToolTimeoutSec }
        if ($AutoConfirm)    { $agentParams.AutoConfirm    = $true }
        if ($Quiet)          { $agentParams.Quiet          = $true }

        Invoke-LLMAgent @agentParams
    }
}
