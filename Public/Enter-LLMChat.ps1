function Enter-LLMChat {
<#
.SYNOPSIS
    Enter an interactive REPL inside an [LLMChat] session.
    Type /help for all commands.  /exit or Ctrl+C to leave.

.PARAMETER Chat
    An [LLMChat] from New-LLMChat. Accepts pipeline input.

.EXAMPLE
    $chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Dev"
    Enter-LLMChat $chat
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Chat
    )
    process {
        $c = $script:C; $b = $script:Box
        script:Write-Banner
        $agentTag = if ($Chat.Agentic) { "$($c.Green) agentic$($c.Reset)" } else { '' }
        script:Write-Status "Entering  $($Chat.Id)  ·  $($Chat.Provider)  ·  $($Chat.Model)$agentTag" 'ok'
        script:Write-Status "Type /help for commands  ·  /exit to leave" 'info'
        Write-Host ""

        $last = $null

        while ($true) {
            script:Write-Prompt -Id $Chat.Id -Turn ($Chat.TurnCount + 1)
            $line = $Host.UI.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            switch -Regex ($line.Trim()) {

                '^/(exit|quit|bye)$' {
                    Write-Host ""
                    script:Write-Status "Left  $($Chat.Id)  ·  $($Chat.TurnCount) turns  ·  $($Chat.TotalTokensUsed) tokens" 'ok'
                    script:Write-Rule
                    return
                }

                '^/help$' {
                    $rows = @(
                        '/help',                'Show this reference'
                        '/exit  /quit',         'Leave the chat session'
                        '/history',             'Print conversation history'
                        '/env',                 'Show the PS environment snapshot'
                        '/directives',          'List discovered claude.md module directives'
                        '/expand',              'Expand steps in the last response'
                        '/expand <N>',          'Expand steps in response N (1-based)'
                        '/tools',               'Show tool calls made in the last response'
                        '/stats',               'Token usage and session info'
                        '/clear',               'Clear the screen'
                        '/model <name>',        'Switch model mid-session'
                        '/system <text>',       'Replace the system prompt'
                        '/agentic on|off',      'Toggle agentic tool-use mode'
                        '/swarm <goal>',        'Spawn a parallel swarm from this chat'
                        '/swarm-results',       'Show task breakdown from last swarm'
                        '/run <expression>',    'Execute a PS expression locally and print result'
                    )
                    Write-Host ""
                    Write-Host "  $($c.Amber)$($c.Bold)CHAT COMMANDS$($c.Reset)"
                    script:Write-Rule -Color $c.Slate
                    for ($i = 0; $i -lt $rows.Count; $i += 2) {
                        Write-Host "  $($c.Cyan)$($rows[$i].PadRight(22))$($c.Reset)$($c.Silver)$($rows[$i+1])$($c.Reset)"
                    }
                    Write-Host ""
                    continue
                }

                '^/history$' {
                    Write-Host ""; script:Write-Rule -Label 'HISTORY' -Color $c.Slate
                    $n = 1
                    foreach ($t in $Chat.History) {
                        $rc  = if ($t.Role -eq 'user') { $c.Cyan } else { $c.Amber }
                        $pre = if ($t.Content.Length -gt 110) { $t.Content.Substring(0,107)+'...' } else { $t.Content }
                        Write-Host "  $($c.Silver)$($n.ToString().PadLeft(3))$($c.Reset)  $rc$($t.Role.ToUpper().PadRight(10))$($c.Reset)  $($c.White)$pre$($c.Reset)"
                        $n++
                    }
                    Write-Host ""
                    continue
                }

                '^/env$' {
                    $e = Get-LLMEnvironment
                    Write-Host ""; script:Write-Rule -Label 'ENVIRONMENT' -Color $c.Slate
                    Write-Host "  $($c.Silver)PS Version    $($c.Reset)$($e.PSVersion)"
                    Write-Host "  $($c.Silver)OS            $($c.Reset)$($e.OS)"
                    Write-Host "  $($c.Silver)Platform      $($c.Reset)$($e.Platform) / $($e.Architecture)"
                    Write-Host "  $($c.Silver)Directory     $($c.Reset)$($e.CurrentDirectory)"
                    Write-Host "  $($c.Silver)User          $($c.Reset)$($e.UserName) @ $($e.MachineName)"
                    $ml = ($e.LoadedModules | Select-Object -First 10 | ForEach-Object { $_.Name }) -join ', '
                    Write-Host "  $($c.Silver)Modules ($($e.ModuleCount))  $($c.Reset)$ml…"
                    Write-Host "  $($c.Silver)Commands      $($c.Reset)$($e.CommandCount)"
                    Write-Host ""
                    continue
                }

                '^/directives$' {
                    $directives = @(Get-LLMModuleDirectives)
                    if ($directives.Count -eq 0) {
                        script:Write-Status 'No claude.md directives found in loaded modules' 'warn'
                    } else {
                        script:Write-DirectivesBlock -Directives $directives
                    }
                    continue
                }

                '^/expand$' {
                    if ($null -eq $last) { script:Write-Status 'No response yet' 'warn'; continue }
                    if ($last.Steps.Count -eq 0) { script:Write-Status 'No structured steps in last response' 'warn'; continue }
                    Write-Host ""; script:Write-Rule -Label "STEPS — last response ($($last.Steps.Count))" -Color $c.Slate
                    script:Write-StepsBlock -Steps $last.Steps -Expanded $true
                    continue
                }

                '^/expand\s+(\d+)$' {
                    $idx = [int]$Matches[1] - 1
                    if ($idx -lt 0 -or $idx -ge $Chat.Responses.Count) {
                        script:Write-Status "Response $($Matches[1]) not found (session has $($Chat.Responses.Count))" 'warn'; continue
                    }
                    $tgt = $Chat.Responses[$idx]
                    if ($tgt.Steps.Count -eq 0) { script:Write-Status "Response $($Matches[1]) has no steps" 'warn'; continue }
                    Write-Host ""; script:Write-Rule -Label "STEPS — response $($Matches[1]) ($($tgt.Steps.Count))" -Color $c.Slate
                    script:Write-StepsBlock -Steps $tgt.Steps -Expanded $true
                    continue
                }

                '^/tools$' {
                    if ($null -eq $last) { script:Write-Status 'No response yet' 'warn'; continue }
                    if ($last.ToolCalls.Count -eq 0) { script:Write-Status 'Last response made no tool calls' 'info'; continue }
                    Write-Host ""; script:Write-Rule -Label "TOOL CALLS ($($last.ToolCalls.Count))" -Color $c.Slate
                    foreach ($tc in $last.ToolCalls) {
                        script:Write-ToolCallBox -Expression $tc.Expression -Result $tc.Output `
                            -IsError $tc.IsError -CallNum $tc.CallNum
                    }
                    continue
                }

                '^/stats$' {
                    Write-Host ""; script:Write-Rule -Label 'SESSION STATS' -Color $c.Slate
                    Write-Host "  $($c.Silver)Session       $($c.Reset)$($Chat.Id)"
                    Write-Host "  $($c.Silver)Provider      $($c.Reset)$($Chat.Provider)"
                    Write-Host "  $($c.Silver)Model         $($c.Reset)$($Chat.Model)"
                    Write-Host "  $($c.Silver)Agentic       $($c.Reset)$($Chat.Agentic)"
                    Write-Host "  $($c.Silver)Turns         $($c.Reset)$($Chat.TurnCount)"
                    Write-Host "  $($c.Silver)Tokens used   $($c.Reset)$($Chat.TotalTokensUsed)"
                    if ($Chat.Responses.Count -gt 0) {
                        $avg = [math]::Round(($Chat.Responses | Measure-Object ElapsedSec -Average).Average,2)
                        Write-Host "  $($c.Silver)Avg latency   $($c.Reset)${avg}s"
                        $tc = ($Chat.Responses | ForEach-Object { $_.ToolCalls.Count } | Measure-Object -Sum).Sum
                        Write-Host "  $($c.Silver)Tool calls    $($c.Reset)$tc"
                    }
                    Write-Host "  $($c.Silver)Started       $($c.Reset)$($Chat.CreatedAt.ToString('u'))"
                    Write-Host ""
                    continue
                }

                '^/clear$' {
                    Clear-Host; script:Write-Banner
                    continue
                }

                '^/model\s+(.+)$' {
                    $Chat.Model = $Matches[1].Trim()
                    script:Write-Status "Model → $($Chat.Model)" 'ok'
                    continue
                }

                '^/system\s+(.+)$' {
                    $Chat.SystemPrompt = $Matches[1].Trim()
                    script:Write-Status "System prompt updated" 'ok'
                    continue
                }

                '^/agentic\s+(on|off)$' {
                    $Chat.Agentic = ($Matches[1] -eq 'on')
                    $state = if ($Chat.Agentic) { "$($c.Green)enabled$($c.Reset)" } else { "$($c.Silver)disabled$($c.Reset)" }
                    script:Write-Status "Agentic mode $state" 'ok'
                    continue
                }

                '^/swarm\s+(.+)$' {
                    $swarmGoal = $Matches[1].Trim()
                    script:Write-Status "Launching swarm from chat $($Chat.Id)…" 'info'
                    try {
                        $swResult = Invoke-LLMSwarm -Goal $swarmGoal -Provider $Chat.Provider -Model $Chat.Model
                        $Chat.LastSwarm = $swResult
                        $Chat.TotalTokensUsed += $swResult.TotalTokens
                        $Chat.History.Add([PSCustomObject]@{Role='user';     Content="[SWARM] $swarmGoal"})
                        $Chat.History.Add([PSCustomObject]@{Role='assistant';Content=$swResult.Synthesis})
                        $Chat.TurnCount++
                    } catch {
                        script:Write-Status "Swarm failed: $_" 'err'
                    }
                    continue
                }

                '^/swarm-results$' {
                    if ($null -eq $Chat.LastSwarm) {
                        script:Write-Status 'No swarm has run in this session yet' 'warn'; continue
                    }
                    Write-Host ""; script:Write-Rule -Label "SWARM TASKS ($($Chat.LastSwarm.Tasks.Count))" -Color $c.Slate
                    foreach ($t in $Chat.LastSwarm.Tasks) { script:Write-SwarmTaskLine -Task $t }
                    Write-Host ""
                    continue
                }

                '^/run\s+(.+)$' {
                    $expr = $Matches[1].Trim()
                    try {
                        Write-Host ""; script:Write-Rule -Label "PS › $expr" -Color $c.Slate
                        Invoke-Expression $expr 2>&1 | ForEach-Object {
                            Write-Host "  $($c.Dim)$_$($c.Reset)"
                        }
                        Write-Host ""
                    } catch {
                        script:Write-Status "Error: $_" 'err'
                    }
                    continue
                }

                default {
                    $last = Send-LLMMessage -Chat $Chat -Message $line
                    if ($last.Steps.Count -gt 0) {
                        script:Write-StepsBlock -Steps $last.Steps -Expanded $false
                    }
                }
            }
        }
    }
}
