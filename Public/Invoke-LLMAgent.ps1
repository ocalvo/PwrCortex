function Invoke-LLMAgent {
<#
.SYNOPSIS
    Run an agentic completion loop where the LLM can call back into PowerShell.

.DESCRIPTION
    The LLM is given one tool: invoke_powershell, which accepts any PS expression.
    Expressions execute in a dedicated Runspace with a live $refs object registry.
    Results are stored as in-memory objects; the LLM receives a compact summary and
    can chain previous results via $refs[id]. The loop continues until the LLM stops
    issuing tool calls (stop_reason = end_turn) or MaxTurns is reached.

    After the agent completes, all collected objects are returned on the response's
    .Result property as a flat array of live .NET objects. Pipeline them directly:

        $r = Invoke-LLMAgent "top 3 processes by memory" -Provider Anthropic -Quiet
        $r.Result | Select-Object -First 1 | Stop-Process -WhatIf

    Destructive expressions (Remove-, Stop-, Format- etc.) require interactive
    confirmation unless -AutoConfirm is set or LLM_CONFIRM_DANGEROUS=0.

    All loaded module claude.md directives are injected automatically, giving
    the LLM a complete picture of what it can invoke.

.PARAMETER Prompt
    The task to accomplish. Accepts pipeline input.
.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override.
.PARAMETER SystemPrompt
    Additional system instructions appended after environment context.
.PARAMETER MaxTokens
    Max tokens per completion turn. Default 2048.
.PARAMETER MaxTurns
    Maximum tool-call iterations before stopping. Default 10.
.PARAMETER ToolTimeoutSec
    Per-tool-call timeout in seconds. Default 30.
.PARAMETER AutoConfirm
    Skip destructive-verb confirmation prompts. Use with caution.
.PARAMETER Quiet
    Suppress per-call console rendering.

.EXAMPLE
    Invoke-LLMAgent "What process is consuming the most memory? Show name and MB." -Provider Anthropic

.EXAMPLE
    Invoke-LLMAgent "List all loaded modules that have a claude.md directive" -Provider Anthropic
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
        [int]$MaxTokens = 2048,

        [ValidateRange(1,50)]
        [int]$MaxTurns = 10,

        [ValidateRange(5,600)]
        [int]$ToolTimeoutSec = 30,

        [switch]$AutoConfirm,
        [switch]$Quiet,

        [Parameter()]
        [object[]]$InputObject
    )
    begin {
        if (-not $Provider) { $Provider = $env:LLM_DEFAULT_PROVIDER ?? 'Anthropic' }
        if (-not $Model)    { $Model    = $script:Providers[$Provider].DefaultModel }
    }
    process {
        script:Push-Preferences
        $script:VerbosePreference = $VerbosePreference
        $script:DebugPreference   = $DebugPreference
        $agentSession = script:New-AgentSession
        try {

        # ── Pre-seed $refs with pipeline input if provided ──────────────────
        if ($InputObject -and $InputObject.Count -gt 0) {
            $agentSession.NextId++
            $refId = $agentSession.NextId
            $refVal = if ($InputObject.Count -eq 1) { $InputObject[0] } else { $InputObject }
            $agentSession.Refs[$refId] = $refVal
            $inputSummary = script:Format-RefSummary -Id $refId -Value $refVal
            $Prompt = "Input data pre-loaded as `$refs[$refId]:`n$inputSummary`n`nTask: $Prompt"
            Write-Verbose "Pre-seeded `$refs[$refId] with $($InputObject.Count) input object(s)"
        }

        Write-Verbose "Invoke-LLMAgent: $Provider/$Model, maxTurns=$MaxTurns, toolTimeout=${ToolTimeoutSec}s"
        $sys      = script:Build-SystemPrompt -UserSystemPrompt $SystemPrompt -IncludeEnv $true
        $messages = [System.Collections.Generic.List[object]]::new()
        $messages.Add(@{role='user';content=$Prompt})
        $allToolCalls = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalIn  = 0; $totalOut = 0; $totalSec = 0.0
        $turns    = 0; $finalText = ''

        if (-not $Quiet) {
            Write-Host ""
            script:Write-Rule -Label "AGENT  $($script:Box.Gear)  $Prompt" -Color $script:C.Cyan
            Write-Host ""
        }

        do {
            $apiParams = @{ Model=$Model; SystemPrompt=$sys; Messages=$messages.ToArray(); MaxTokens=$MaxTokens }
            $raw = switch ($Provider) {
                'Anthropic' { script:Invoke-AnthropicRaw @apiParams -Tools @($script:AgentTool) }
                'OpenAI'    { script:Invoke-OpenAIRaw    @apiParams -Tools @($script:AgentTool) }
            }
            $r        = $raw.Response
            $totalSec += $raw.ElapsedSec
            $turns++
            Write-Verbose "Agent turn ${turns}: $([math]::Round($raw.ElapsedSec,2))s"

            switch ($Provider) {
                'Anthropic' {
                    $totalIn  += $r.usage.input_tokens
                    $totalOut += $r.usage.output_tokens
                    $stopReason = $r.stop_reason
                    $toolCalls  = script:Extract-AnthropicToolCalls $r.content
                    $textNow    = script:Extract-AnthropicText $r.content
                    $messages.Add(@{role='assistant';content=$r.content})

                    if ($toolCalls) {
                        $toolResults = [System.Collections.Generic.List[object]]::new()
                        foreach ($tc in $toolCalls) {
                            $expr   = $tc.input.expression
                            $guarded = script:Invoke-GuardedExpression -Expression $expr -AgentSession $agentSession -AutoConfirm $AutoConfirm.IsPresent -TimeoutSec $ToolTimeoutSec
                            $tcObj  = [PSCustomObject]@{
                                PSTypeName = 'LLMToolCall'
                                CallNum    = $allToolCalls.Count + 1
                                Expression = $expr
                                Output     = $guarded.Output
                                IsError    = $guarded.IsError
                                Denied     = $guarded.Denied
                            }
                            $allToolCalls.Add($tcObj)
                            if (-not $Quiet) {
                                script:Write-ToolCallBox -Expression $expr -Result $guarded.Output `
                                    -IsError $guarded.IsError -CallNum $tcObj.CallNum
                            }
                            if (-not $guarded.IsError -and -not $guarded.Denied -and $guarded.RefId -gt 0) {
                                script:Add-ContextEntry -Source 'Agent' -Command $expr -Items @($guarded.RefValue)
                            }
                            $toolResults.Add((script:Build-AnthropicToolResult $tc.id $guarded.Output))
                        }
                        $messages.Add(@{role='user';content=$toolResults.ToArray()})
                    }
                    if ($textNow) { $finalText = $textNow }
                }

                'OpenAI' {
                    $totalIn  += $r.usage.prompt_tokens
                    $totalOut += $r.usage.completion_tokens
                    $choice     = $r.choices[0]
                    $stopReason = $choice.finish_reason
                    $toolCalls  = script:Extract-OpenAIToolCalls $choice
                    $textNow    = $choice.message.content
                    $messages.Add(@{role='assistant'; content=$choice.message.content; tool_calls=$choice.message.tool_calls})

                    if ($toolCalls) {
                        foreach ($tc in $toolCalls) {
                            $expr    = ($tc.function.arguments | ConvertFrom-Json).expression
                            $guarded = script:Invoke-GuardedExpression -Expression $expr -AgentSession $agentSession -AutoConfirm $AutoConfirm.IsPresent -TimeoutSec $ToolTimeoutSec
                            $tcObj   = [PSCustomObject]@{
                                PSTypeName = 'LLMToolCall'
                                CallNum    = $allToolCalls.Count + 1
                                Expression = $expr
                                Output     = $guarded.Output
                                IsError    = $guarded.IsError
                                Denied     = $guarded.Denied
                            }
                            $allToolCalls.Add($tcObj)
                            if (-not $Quiet) {
                                script:Write-ToolCallBox -Expression $expr -Result $guarded.Output `
                                    -IsError $guarded.IsError -CallNum $tcObj.CallNum
                            }
                            if (-not $guarded.IsError -and -not $guarded.Denied -and $guarded.RefId -gt 0) {
                                script:Add-ContextEntry -Source 'Agent' -Command $expr -Items @($guarded.RefValue)
                            }
                            $messages.Add((script:Build-OpenAIToolResult $tc.id $guarded.Output))
                        }
                    }
                    if ($textNow) { $finalText = $textNow }
                }
            }

        } while ($stopReason -eq 'tool_use' -and $turns -lt $MaxTurns)

        if ($stopReason -eq 'tool_use' -and $turns -ge $MaxTurns) {
            Write-Warning "Agent reached MaxTurns limit ($MaxTurns) — stopping with pending tool calls"
        }

        $result = $null
        if ($agentSession.Refs.Count -gt 0) {
            $all = @(foreach ($key in ($agentSession.Refs.Keys | Sort-Object)) {
                $agentSession.Refs[$key]
            })
            $result = if ($all.Count -eq 1) { $all[0] } else { $all }
        }
        $resp = script:New-ResponseObj -Provider $Provider -Model $Model -Content $finalText `
            -InputTokens $totalIn -OutputTokens $totalOut -StopReason $stopReason `
            -ResponseId '' -ElapsedSec $totalSec -Raw $null -ToolCalls $allToolCalls.ToArray() `
            -Result $result

        if (-not $Quiet) {
            script:Write-ResponseBox -Content $finalText -Provider $Provider -Model $Model `
                -InputTokens $totalIn -OutputTokens $totalOut -StopReason $stopReason `
                -ElapsedSec $totalSec
            script:Write-Status "Agent completed · $turns turn(s) · $($allToolCalls.Count) tool call(s) · $($totalIn+$totalOut) tokens" 'ok'
            Write-Host ""
        }
        Write-Verbose "Agent done: $turns turn(s), $($allToolCalls.Count) tool call(s), $($totalIn+$totalOut) tokens, $($agentSession.Refs.Count) ref(s)"
        $resp

        } finally {
            script:Close-AgentSession $agentSession
            script:Pop-Preferences
        }
    }
}
