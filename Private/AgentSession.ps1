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

# Seeds the conversation log into a runspace. `$context` is the ONLY user-scope
# variable we propagate — the agent reads prior commands/outputs from it, and
# everything else the agent needs it obtains by calling cmdlets. Cloning all
# global variables was legacy behavior from before $context existed; it added
# ~70 vars of noise, collided with read-only PS built-ins, and buried the
# signal the LLM actually cares about.
function script:Add-ContextVariable {
    param([System.Management.Automation.Runspaces.InitialSessionState]$ISS)
    $ctx = Get-Variable -Scope Global -Name 'context' -ErrorAction SilentlyContinue
    if ($ctx) {
        $ISS.Variables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                'context', $ctx.Value, 'PwrCortex conversation log'))
        Write-Verbose "Seeded `$context into ISS ($(@($ctx.Value).Count) entr$(if(@($ctx.Value).Count -eq 1){'y'}else{'ies'}))"
    } else {
        Write-Verbose "`$context not initialized; nothing to seed"
    }
}

function script:New-AgentSession {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    # Only import modules that have a backing file on disk. Dynamic in-memory
    # modules (e.g. script-scoped ones created by Publish-Modules or ad-hoc
    # New-Module) have no .Path and cannot be reloaded by name into a fresh
    # runspace — attempting it aborts ISS.Open() with
    # "The specified module '<name>' was not loaded."
    $mods = @(Get-Module | Where-Object { $_.Path -and (Test-Path $_.Path) })
    $skipped = 0
    foreach ($mod in $mods) {
        try { $iss.ImportPSModule($mod.Name) }
        catch {
            Write-Debug "Skipped module '$($mod.Name)': $_"
            $skipped++
        }
    }
    if ($skipped -gt 0) { Write-Verbose "Skipped $skipped module(s) that failed ImportPSModule" }
    $envCount = 0
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $iss.EnvironmentVariables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                $entry.Key, $entry.Value, ''))
        $envCount++
    }
    script:Add-ContextVariable -ISS $iss
    $refs = @{}
    $iss.Variables.Add(
        [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
            'refs', $refs, 'Agent object registry'))
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    Write-Verbose "Agent session opened: $($mods.Count) modules, $envCount env vars, runspace=$($rs.InstanceId)"
    @{ Runspace = $rs; Refs = $refs; NextId = 0 }
}

function script:Close-AgentSession([hashtable]$Session) {
    if ($Session -and $Session.Runspace) {
        Write-Verbose "Closing agent session: $($Session.Refs.Count) ref(s) collected"
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

    Write-Debug "Guarded expression: $Expression"
    $isDestructive = script:Test-IsDestructive $Expression
    $confirmEnv    = [System.Environment]::GetEnvironmentVariable('LLM_CONFIRM_DANGEROUS')
    $skipConfirm   = $AutoConfirm -or ($confirmEnv -eq '0')

    if ($isDestructive -and -not $skipConfirm) {
        Write-Warning "Destructive expression detected: $($Expression.Substring(0, [math]::Min(80, $Expression.Length)))"
        script:Write-ConfirmBox -Expression $Expression
        $answer = $Host.UI.ReadLine()
        if ($answer -notmatch '^[Yy]$') {
            Write-Verbose "User denied destructive expression"
            return [PSCustomObject]@{
                Output   = 'User denied execution of destructive expression.'
                IsError  = $true
                Denied   = $true
                RefId    = 0
                RefValue = $null
            }
        }
        Write-Verbose "User approved destructive expression"
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $AgentSession.Runspace
    $null = $ps.AddScript($Expression, $false)

    try {
        Write-Verbose "Executing tool call (timeout=${TimeoutSec}s)"
        $async = $ps.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
            Write-Warning "Tool call timed out after ${TimeoutSec}s: $($Expression.Substring(0, [math]::Min(60, $Expression.Length)))"
            $ps.Stop()
            $ps.Dispose()
            return [PSCustomObject]@{
                Output   = "Tool call timed out after ${TimeoutSec}s. Try a simpler approach."
                IsError  = $true
                Denied   = $false
                RefId    = 0
                RefValue = $null
            }
        }
        $result  = $ps.EndInvoke($async)
        $streams = script:Format-Streams $ps
        $ps.Dispose()

        $output = @($result)
        if ($output.Count -eq 0 -and -not $streams) {
            return [PSCustomObject]@{
                Output   = '(no output)'
                IsError  = $false
                Denied   = $false
                RefId    = 0
                RefValue = $null
            }
        }

        $summary = ''
        $refId = 0
        $refValue = $null
        if ($output.Count -gt 0) {
            $AgentSession.NextId++
            $refId = $AgentSession.NextId
            $refValue = if ($output.Count -eq 1) { $output[0] } else { $output }
            $AgentSession.Refs[$refId] = $refValue
            $summary = script:Format-RefSummary -Id $refId -Value $refValue
            Write-Verbose "Tool call stored ref:$refId ($(if ($output.Count -eq 1) { $refValue.GetType().Name } else { "$($output.Count) items" }))"
        }

        [PSCustomObject]@{
            Output   = ($summary + $streams)
            IsError  = $false
            Denied   = $false
            RefId    = $refId
            RefValue = $refValue
        }
    }
    catch {
        Write-Error "Tool call failed: $_" -ErrorAction Continue
        $ps.Dispose()
        [PSCustomObject]@{
            Output   = "Error: $($_.ToString())"
            IsError  = $true
            Denied   = $false
            RefId    = 0
            RefValue = $null
        }
    }
}
