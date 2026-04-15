function Send-LLMMessage {
<#
.SYNOPSIS
    Send one message in an [LLMChat] session and receive an [LLMResponse].

.PARAMETER Chat
    An [LLMChat] from New-LLMChat. Accepts pipeline input.
.PARAMETER Message
    The user-turn message.
.PARAMETER Quiet
    Suppress console rendering.

.EXAMPLE
    $chat | Send-LLMMessage "Show me how to parse JSON in PS"
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Chat,

        [Parameter(Mandatory, Position=0)]
        [string]$Message,

        [switch]$Quiet
    )
    process {
        if ($Chat.Agentic) {
            $resp = Invoke-LLMAgent -Prompt $Message -Provider $Chat.Provider -Model $Chat.Model `
                -SystemPrompt $Chat.SystemPrompt -MaxTokens $Chat.MaxTokens -Quiet:$Quiet
        } else {
            $msgs = $Chat.History | ForEach-Object { @{role=$_.Role;content=$_.Content} }
            $msgs += @{role='user';content=$Message}
            $p = @{
                Provider=$Chat.Provider; Model=$Chat.Model; SystemPrompt=$Chat.SystemPrompt
                Messages=$msgs; MaxTokens=$Chat.MaxTokens; WithEnv=$Chat.WithEnvironment
            }
            $resp = script:Invoke-ProviderCompletion @p
            if (-not $Quiet) {
                script:Write-ResponseBox -Content $resp.Content -Provider $resp.Provider `
                    -Model $resp.Model -InputTokens $resp.InputTokens `
                    -OutputTokens $resp.OutputTokens -StopReason $resp.StopReason `
                    -ElapsedSec $resp.ElapsedSec
                if ($resp.Steps.Count -gt 0) {
                    script:Write-Status "Response has $($resp.Steps.Count) steps — use /expand to inspect" 'info'
                    Write-Host ""
                }
            }
        }

        $Chat.History.Add([PSCustomObject]@{Role='user';     Content=$Message})
        $Chat.History.Add([PSCustomObject]@{Role='assistant';Content=$resp.Content})
        $Chat.Responses.Add($resp)
        $Chat.TotalTokensUsed += $resp.TotalTokens
        $Chat.TurnCount++
        $resp
    }
}
