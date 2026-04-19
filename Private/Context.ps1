# ══════════════════════════════════════════════════════════════════════════════
#  $global:context — conversation log captured via Out-Default proxy
# ══════════════════════════════════════════════════════════════════════════════
#
# The user's interactive shell pipes the result of every prompt-level command
# through Out-Default. By shadowing Out-Default with a proxy function we can
# append each (command, output) pair to $global:context while still rendering
# normally. Agents, swarms, and Build-SystemPrompt read from $global:context
# so the LLM sees the same conversation the user is living in.
#
# Entries are [PSCustomObject]:
#   HistoryId [int]       — PS command history id (Human only), or -1
#   Timestamp [datetime]  — UTC time the entry was appended
#   Source    [string]    — 'Human' | 'Agent' | 'Swarm'
#   Command   [string]    — for Human: Get-History command line;
#                            for Agent: the expression the agent ran;
#                            for Swarm: the subtask description
#   Output    [List[object]] — the LIVE typed .NET objects

if (-not (Get-Variable -Name 'context' -Scope Global -ErrorAction SilentlyContinue)) {
    $global:context = [System.Collections.Generic.List[PSCustomObject]]::new()
}

# Set by the PSReadLine AddToHistoryHandler (see Install-ContextCapture) the
# instant the user presses Enter, BEFORE the pipeline executes. Out-Default
# reads this during its end{} to tag the captured output with the right
# command line — Get-History doesn't yet contain the current command at that
# point, and $MyInvocation.HistoryId inside the proxy is off by one.
$script:LastHumanCommand = ''
$script:LastHumanHid     = 0
$script:_pwrcortex_prevHistHandler = $null

function script:Add-ContextEntry {
    [CmdletBinding()]
    param(
        [System.Collections.Generic.IList[object]]$Items,

        [ValidateSet('Human','Agent','Swarm')]
        [string]$Source = 'Human',

        [string]$Command = '',

        # Supplied by the Out-Default proxy via $MyInvocation.HistoryId so
        # we attribute output to the CURRENT interactive command (not the
        # previous one, which is what Get-History -Count 1 would return
        # mid-pipeline).
        [int]$HistoryId = -1
    )

    if (-not $Items -or $Items.Count -eq 0) { return }
    if (-not $global:context) {
        $global:context = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    $cmdId   = $HistoryId
    $cmdLine = $Command

    if ($Source -eq 'Human') {
        # A single interactive command may call Out-Default more than once
        # (mixed format blocks, multiple return values). Merge into the tail
        # entry when it's the same Human command so one command == one entry.
        # Never merge across Source boundaries.
        $tail = if ($global:context.Count -gt 0) {
            $global:context[$global:context.Count - 1]
        } else { $null }

        if ($tail -and $tail.Source -eq 'Human' -and $cmdId -gt 0 -and
            $tail.HistoryId -eq $cmdId) {
            foreach ($i in $Items) { $tail.Output.Add($i) }
            # Backfill Command if the earlier entry missed it.
            if (-not $tail.Command -and $cmdLine) { $tail.Command = $cmdLine }
            return
        }
    }

    $entry = [PSCustomObject]@{
        HistoryId = $cmdId
        Timestamp = [datetime]::UtcNow
        Source    = $Source
        Command   = $cmdLine
        Output    = [System.Collections.Generic.List[object]]::new($Items)
    }
    $global:context.Add($entry)
}

function script:Install-ContextCapture {
    [CmdletBinding()]
    param()

    # Resolve the real cmdlet up-front so the proxy can call it without
    # re-entering command resolution (and without recursing into itself).
    $realOutDefault = $ExecutionContext.InvokeCommand.GetCommand(
        'Microsoft.PowerShell.Core\Out-Default',
        [System.Management.Automation.CommandTypes]::Cmdlet)
    if (-not $realOutDefault) {
        Write-Warning "PwrCortex: Out-Default cmdlet not found; context capture disabled."
        return
    }

    # GetNewClosure() binds $realOutDefault into the proxy so later
    # redefinitions of the cmdlet don't affect us.
    $proxyBody = {
        [CmdletBinding()]
        param(
            [switch]$Transcript,
            [Parameter(ValueFromPipeline=$true)]
            [psobject]$InputObject
        )
        begin {
            try {
                $script:__pwrcortex_items = [System.Collections.Generic.List[object]]::new()
                $outBuffer = $null
                if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                    $PSBoundParameters['OutBuffer'] = 1
                }
                $scriptCmd = { & $realOutDefault @PSBoundParameters }
                $script:__pwrcortex_sp = $scriptCmd.GetSteppablePipeline($MyInvocation.CommandOrigin)
                $script:__pwrcortex_sp.Begin($PSCmdlet)
            } catch { throw }
        }
        process {
            try {
                if ($null -ne $_) { $script:__pwrcortex_items.Add($_) }
                $script:__pwrcortex_sp.Process($_)
            } catch { throw }
        }
        end {
            try { $script:__pwrcortex_sp.End() }
            finally {
                try {
                    # Pull the captured command from the PSReadLine
                    # AddToHistoryHandler, which ran before the pipeline
                    # started and has the exact line the user pressed Enter
                    # on. Fall back to Get-History if PSReadLine wasn't loaded
                    # (e.g. piped / non-interactive pwsh), accepting that it
                    # is one command stale in that case.
                    & (Get-Module PwrCortex) {
                        param($i)
                        $cmd = $script:LastHumanCommand
                        $hid = $script:LastHumanHid
                        if (-not $cmd) {
                            $h = Get-History -Count 1 -ErrorAction SilentlyContinue
                            if ($h) {
                                $cmd = [string]$h.CommandLine
                                $hid = [int]$h.Id
                            }
                        }
                        script:Add-ContextEntry -Items $i -HistoryId $hid -Command $cmd
                    } $script:__pwrcortex_items
                } catch {
                    Write-Debug "PwrCortex: failed to append context entry: $_"
                }
            }
        }
    }.GetNewClosure()

    Set-Item -Path function:global:Out-Default -Value $proxyBody -Force

    # Install a PSReadLine AddToHistoryHandler that captures the user's
    # command the instant Enter is pressed — before the pipeline runs.
    # Out-Default's end{} reads $script:LastHumanCommand to tag the buffered
    # output with the right line. Without this hook, neither Get-History nor
    # $MyInvocation.HistoryId give the correct value inside Out-Default: the
    # entry doesn't land in history until after the pipeline (including
    # Out-Default) completes.
    if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
        try {
            $existing = (Get-PSReadLineOption).AddToHistoryHandler
            $script:_pwrcortex_prevHistHandler = $existing
            Set-PSReadLineOption -AddToHistoryHandler {
                param([string]$line)
                & (Get-Module PwrCortex) {
                    param($l)
                    $script:LastHumanCommand = $l
                    $script:LastHumanHid++
                } $line
                if ($script:_pwrcortex_prevHistHandler) {
                    return & $script:_pwrcortex_prevHistHandler $line
                }
                return 'MemoryAndFile'
            }.GetNewClosure()
            Write-Verbose "PwrCortex: PSReadLine AddToHistoryHandler installed for command-line capture."
        } catch {
            Write-Warning "PwrCortex: failed to install PSReadLine handler; context commands may be stale. $_"
        }
    } else {
        Write-Verbose "PwrCortex: PSReadLine not loaded; context will fall back to Get-History (one-command stale)."
    }

    Write-Verbose "PwrCortex: Out-Default proxy installed; `$global:context capture active."
}

function script:Uninstall-ContextCapture {
    [CmdletBinding()]
    param()
    # Remove-Item function:global:Out-Default reports success but silently
    # leaves the function in place (PS 7.x quirk with scoped function: paths).
    # The pipeline form via Get-ChildItem works reliably.
    $removed = 0
    Get-ChildItem function: |
        Where-Object { $_.Name -eq 'Out-Default' } |
        ForEach-Object {
            Remove-Item -LiteralPath "function:$($_.Name)" -Force -ErrorAction SilentlyContinue
            $removed++
        }
    if ($removed -gt 0) {
        Write-Verbose "PwrCortex: Out-Default proxy removed."
    }

    if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
        try {
            if ($script:_pwrcortex_prevHistHandler) {
                Set-PSReadLineOption -AddToHistoryHandler $script:_pwrcortex_prevHistHandler
            } else {
                Set-PSReadLineOption -AddToHistoryHandler $null
            }
            $script:_pwrcortex_prevHistHandler = $null
            Write-Verbose "PwrCortex: PSReadLine AddToHistoryHandler restored."
        } catch {
            Write-Warning "PwrCortex: failed to restore PSReadLine handler. $_"
        }
    }
}
