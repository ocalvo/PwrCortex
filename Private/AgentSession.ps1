# ══════════════════════════════════════════════════════════════════════════════
#  AGENT SESSION — Dedicated runspace, object registry, guarded execution
# ══════════════════════════════════════════════════════════════════════════════

function script:Test-IsDestructive([string]$Expression) {
    $segments = $Expression -split '[|;]'
    foreach ($seg in $segments) {
        $cmd = $seg.Trim() -replace '^\s*[\(&]*\s*', ''
        if ($cmd -match $script:DestructivePattern) { return $true }
    }
    return $false
}

function script:New-AgentSession {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    foreach ($mod in (Get-Module)) { $iss.ImportPSModule($mod.Name) }
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $iss.EnvironmentVariables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                $entry.Key, $entry.Value, ''))
    }
    $refs = @{}
    $iss.Variables.Add(
        [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
            'refs', $refs, 'Agent object registry'))
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    @{ Runspace = $rs; Refs = $refs; NextId = 0 }
}

function script:Close-AgentSession([hashtable]$Session) {
    if ($Session -and $Session.Runspace) {
        $Session.Runspace.Close()
        $Session.Runspace.Dispose()
        $Session.Runspace = $null
    }
}

function script:Format-RefSummary {
    param([int]$Id, [object]$Value, [int]$MaxLines = 15)

    if ($null -eq $Value) { return "ref:$Id → `$null" }

    $items = @($Value)
    $typeName = if ($items.Count -eq 0) { '[empty]' }
                elseif ($items.Count -gt 1) { "[$($items[0].GetType().Name)[]] $($items.Count) items" }
                else { "[$($items[0].GetType().Name)]" }

    $preview = ($Value | Out-String -Width 120).TrimEnd()
    $lines = $preview -split "`r?`n"
    if ($lines.Count -gt $MaxLines) {
        $preview = ($lines[0..($MaxLines - 1)] -join "`n") + "`n... ($($lines.Count) lines total)"
    }
    "ref:$Id -> $typeName`n$preview"
}

function script:Format-Streams([System.Management.Automation.PowerShell]$PS) {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $PS.Streams.Error)       { $parts.Add("ERROR: $e") }
    foreach ($w in $PS.Streams.Warning)     { $parts.Add("WARNING: $w") }
    foreach ($v in $PS.Streams.Verbose)     { $parts.Add("VERBOSE: $v") }
    foreach ($d in $PS.Streams.Debug)       { $parts.Add("DEBUG: $d") }
    foreach ($i in $PS.Streams.Information) { $parts.Add("INFO: $($i.MessageData)") }
    if ($parts.Count -gt 0) { return "`n--- streams ---`n" + ($parts -join "`n") }
    return ''
}

function script:Invoke-GuardedExpression {
    param(
        [string]$Expression,
        [hashtable]$AgentSession,
        [bool]$AutoConfirm = $false,
        [int]$TimeoutSec = 30
    )

    $isDestructive = script:Test-IsDestructive $Expression
    $confirmEnv    = [System.Environment]::GetEnvironmentVariable('LLM_CONFIRM_DANGEROUS')
    $skipConfirm   = $AutoConfirm -or ($confirmEnv -eq '0')

    if ($isDestructive -and -not $skipConfirm) {
        script:Write-ConfirmBox -Expression $Expression
        $answer = $Host.UI.ReadLine()
        if ($answer -notmatch '^[Yy]$') {
            return [PSCustomObject]@{
                Output  = 'User denied execution of destructive expression.'
                IsError = $true
                Denied  = $true
            }
        }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $AgentSession.Runspace
    $null = $ps.AddScript($Expression, $false)

    try {
        $async = $ps.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
            $ps.Stop()
            $ps.Dispose()
            return [PSCustomObject]@{
                Output  = "Tool call timed out after ${TimeoutSec}s. Try a simpler approach."
                IsError = $true
                Denied  = $false
            }
        }
        $result  = $ps.EndInvoke($async)
        $streams = script:Format-Streams $ps
        $ps.Dispose()

        $output = @($result)
        if ($output.Count -eq 0 -and -not $streams) {
            return [PSCustomObject]@{ Output = '(no output)'; IsError = $false; Denied = $false }
        }

        $summary = ''
        if ($output.Count -gt 0) {
            $AgentSession.NextId++
            $id = $AgentSession.NextId
            $val = if ($output.Count -eq 1) { $output[0] } else { $output }
            $AgentSession.Refs[$id] = $val
            $summary = script:Format-RefSummary -Id $id -Value $val
        }

        [PSCustomObject]@{ Output = ($summary + $streams); IsError = $false; Denied = $false }
    }
    catch {
        $ps.Dispose()
        [PSCustomObject]@{
            Output  = "Error: $($_.ToString())"
            IsError = $true
            Denied  = $false
        }
    }
}
