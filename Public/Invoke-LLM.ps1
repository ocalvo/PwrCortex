function Invoke-LLM {
<#
.SYNOPSIS
    Send one or more prompts to an LLM. Returns rich [LLMResponse] objects.

.PARAMETER Prompt
    User prompt. Accepts pipeline input.
.PARAMETER Provider
    Anthropic or OpenAI. Falls back to $env:LLM_DEFAULT_PROVIDER then Anthropic.
.PARAMETER Model
    Model override.
.PARAMETER SystemPrompt
    Instruction/system prompt.
.PARAMETER MaxTokens
    Max response tokens. Default 1024.
.PARAMETER Temperature
    Sampling temperature 0.0–2.0.
.PARAMETER WithEnvironment
    Inject PS environment snapshot and all claude.md directives into the system prompt.
.PARAMETER Quiet
    Suppress console rendering. Only emit the object.

.EXAMPLE
    Invoke-LLM "What modules do I have for HTTP?" -Provider Anthropic -WithEnvironment
.EXAMPLE
    Get-Content prompts.txt | Invoke-LLM -Provider OpenAI -Quiet | Export-Csv out.csv
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position=0)]
        [string]$Prompt,

        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,
        [string]$SystemPrompt = '',

        [ValidateRange(1,32768)]
        [int]$MaxTokens = 1024,

        [ValidateRange(0.0,2.0)]
        [double]$Temperature,

        [switch]$WithEnvironment,
        [switch]$Quiet
    )
    begin {
        if (-not $Provider) { $Provider = $env:LLM_DEFAULT_PROVIDER ?? 'Anthropic' }
        if (-not $Model)    { $Model    = $script:Providers[$Provider].DefaultModel }
    }
    process {
        script:Push-Preferences
        $script:VerbosePreference = $VerbosePreference
        $script:DebugPreference   = $DebugPreference
        try {
            Write-Verbose "Invoke-LLM: $Provider/$Model, prompt=$($Prompt.Length) chars"
            $completionParams = @{
                Provider=    $Provider; Model=$Model; SystemPrompt=$SystemPrompt
                Messages=    @(@{role='user';content=$Prompt})
                MaxTokens=   $MaxTokens; WithEnv=$WithEnvironment.IsPresent
            }
            if ($PSBoundParameters.ContainsKey('Temperature')) { $completionParams.Temperature = $Temperature }
            $resp = script:Invoke-ProviderCompletion @completionParams

            Write-Verbose "Invoke-LLM completed: $($resp.TotalTokens) tokens, $([math]::Round($resp.ElapsedSec,2))s"
            if (-not $Quiet) {
                script:Write-ResponseBox -Content $resp.Content -Provider $resp.Provider `
                    -Model $resp.Model -InputTokens $resp.InputTokens `
                    -OutputTokens $resp.OutputTokens -StopReason $resp.StopReason `
                    -ElapsedSec $resp.ElapsedSec
                if ($resp.Steps.Count -gt 0) {
                    script:Write-Status "Response has $($resp.Steps.Count) steps — use Expand-LLMProcess for detail" 'info'
                    Write-Host ""
                }
            }
            $resp
        } finally {
            script:Pop-Preferences
        }
    }
}
