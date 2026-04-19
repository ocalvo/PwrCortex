# ══════════════════════════════════════════════════════════════════════════════
#  SWARM ORCHESTRATION — Internals
# ══════════════════════════════════════════════════════════════════════════════
#
#  Architecture
#  ────────────
#  Invoke-LLMSwarm runs an ORCHESTRATOR completion that decomposes the goal
#  into a JSON task list. Each task runs in a RunspacePool that clones the
#  user's session. Tasks can declare DependsOn, forming a DAG — the dispatcher
#  releases each task only once all its dependencies have finished successfully.
#
#  Thread communication uses a [ConcurrentDictionary[string,object]] shared
#  across runspaces (same process, no serialization boundary):
#    $script:SwarmShared["result::<taskId>"] = [LLMResponse]  set by workers
#    $script:SwarmShared["status::<taskId>"] = <status>       running|done|failed

$script:SwarmShared = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

# ── Render helpers (swarm-specific) ──────────────────────────────────────────

function script:Write-SwarmHeader {
    param([string]$Goal, [int]$TaskCount)
    $c = $script:C; $b = $script:Box; $w = script:Get-Width
    $label = " SWARM  $($b.Bullet)  $TaskCount tasks "
    $lp = $b.H * 3; $rp = $b.H * [Math]::Max(2, $w - $label.Length - 8)
    Write-Host ""
    Write-Host "$($c.Cyan)$lp$($c.Bold)$label$($c.Reset)$($c.Cyan)$rp$($c.Reset)"
    Write-Host "  $($c.Silver)Goal:$($c.Reset) $($c.White)$Goal$($c.Reset)"
    Write-Host ""
}

function script:Write-SwarmTaskLine {
    param([PSCustomObject]$Task, [string]$Override='')
    $c = $script:C; $b = $script:Box
    $status = if ($Override) { $Override } else { $Task.Status }
    $icon = switch ($status) {
        'pending'  { "$($c.Slate)○$($c.Reset)" }
        'waiting'  { "$($c.Yellow)◔$($c.Reset)" }
        'running'  { "$($c.Cyan)◕$($c.Reset)" }
        'done'     { "$($c.Green)$($b.Tick)$($c.Reset)" }
        'failed'   { "$($c.Red)$($b.X)$($c.Reset)" }
        'skipped'  { "$($c.Silver)—$($c.Reset)" }
        default    { "$($c.Silver)?$($c.Reset)" }
    }
    $depStr = if ($Task.DependsOn.Count -gt 0) { " $($c.Slate)← $($Task.DependsOn -join ', ')$($c.Reset)" } else { '' }
    $elapsed = if ($Task.ElapsedSec -gt 0) { " $($c.Dim)$([math]::Round($Task.ElapsedSec,1))s$($c.Reset)" } else { '' }
    Write-Host "  $icon $($c.Amber)$($Task.Id.PadRight(6))$($c.Reset) $($c.White)$($Task.Name)$($c.Reset)$depStr$elapsed"
}

function script:Write-SwarmSummary {
    param(
        [PSCustomObject]$Result,
        [int]$SynthInputTokens = 0,
        [int]$SynthOutputTokens = 0,
        [double]$SynthElapsedSec = 0
    )
    $c = $script:C; $b = $script:Box; $w = script:Get-Width
    Write-Host ""
    script:Write-Rule -Label "SWARM COMPLETE" -Color $c.Cyan
    $done    = @($Result.Tasks | Where-Object Status -eq 'done').Count
    $failed  = @($Result.Tasks | Where-Object Status -eq 'failed').Count
    $skipped = @($Result.Tasks | Where-Object Status -eq 'skipped').Count
    Write-Host "  $($c.Silver)Tasks      $($c.Reset)$($c.Green)$done done$($c.Reset)  $($c.Red)$failed failed$($c.Reset)  $($c.Slate)$skipped skipped$($c.Reset)"
    Write-Host "  $($c.Silver)Tokens     $($c.Reset)$($Result.TotalTokens)  $($c.Slate)(in: $($Result.InputTokens)  out: $($Result.OutputTokens))$($c.Reset)"
    Write-Host "  $($c.Silver)Wall time  $($c.Reset)$([math]::Round($Result.TotalSec,2))s"
    Write-Host ""
    script:Write-Rule -Label "SYNTHESIS" -Color $c.Amber
    Write-Host ""
    script:Write-ResponseBox -Content $Result.Synthesis -Provider $Result.Provider `
        -Model $Result.Model -InputTokens $SynthInputTokens -OutputTokens $SynthOutputTokens `
        -StopReason 'synthesis' -ElapsedSec $SynthElapsedSec
}

# ── Orchestrator: decompose goal into task list ───────────────────────────────

function script:Invoke-OrchestratorDecompose {
    param([string]$Goal, [string]$Provider, [string]$Model, [string]$Context, [int]$MaxTasks)

    $schema = @"
You are a task orchestrator. Decompose the goal into parallel sub-tasks for specialist LLM agents.

Rules:
- Emit ONLY a raw JSON array, no markdown, no explanation.
- Each element: { "id": "t1", "name": "<short label>", "prompt": "<full task prompt>", "dependsOn": [] }
- "id" must be unique short strings: t1, t2, t3 …
- "dependsOn" is an array of ids that must complete before this task starts. Use [] for tasks that can run immediately.
- Maximum $MaxTasks tasks. Prefer parallelism — only add dependencies when the task genuinely needs prior results.
- Each worker prompt must be fully self-contained. Workers see the same <conversation_context> block you see, but they do NOT see this decomposition prompt — so restate anything they need.
- If a task needs the result of a prior task, say so explicitly in the prompt: "Given the result from task <id>: {{result::<id>}}, ..."
  The harness will substitute {{result::<id>}} with the actual JSON result before dispatching.

The PwrCortex module directives above define how to ground user-activity
questions in `\$global:context`. Apply them when deciding how many tasks to
emit.

Context about the environment:
$Context

Goal: $Goal
"@

    Write-Verbose "Orchestrator decomposing goal into max $MaxTasks tasks ($Provider/$Model)"
    $resp = script:Invoke-ProviderCompletion -Provider $Provider -Model $Model `
        -SystemPrompt $schema -Messages @(@{role='user';content="Decompose this goal into tasks."}) `
        -MaxTokens 2048 -WithEnv $true

    $json = $resp.Content -replace '```json',''-replace '```','' -replace '(?s)^[^[\{]*','' | ForEach-Object { $_.Trim() }
    try {
        $tasks = $json | ConvertFrom-Json
        Write-Verbose "Orchestrator produced $(@($tasks).Count) task(s)"
        return @{ Tasks=$tasks; Tokens=$resp.TotalTokens; InputTokens=$resp.InputTokens; OutputTokens=$resp.OutputTokens }
    } catch {
        Write-Error "Orchestrator produced invalid JSON task list: $_" -ErrorAction Stop
    }
}

# ── Worker scriptblock — runs inside each RunspacePool runspace ───────────────

$script:WorkerBlock = {
    param(
        [string]$TaskId,
        [string]$TaskPrompt,
        [string]$Provider,
        [string]$Model,
        [System.Collections.Concurrent.ConcurrentDictionary[string,object]]$Shared
    )

    try {
        $Shared["status::$TaskId"] = 'running'
        $resp = Invoke-LLMAgent -Prompt $TaskPrompt -Provider $Provider -Model $Model -Quiet
        $Shared["result::$TaskId"] = $resp
        $Shared["status::$TaskId"] = 'done'
    } catch {
        # Preserve position + stack trace so the dispatcher can surface *where*
        # the worker failed. A bare $_.ToString() collapses to just the message
        # and the caller has no hope of diagnosing the real origin.
        $msg  = $_.Exception.Message
        $pos  = if ($_.InvocationInfo) { $_.InvocationInfo.PositionMessage } else { '' }
        $stk  = $_.ScriptStackTrace
        $Shared["result::$TaskId"] = "$msg`n$pos`nScriptStackTrace:`n$stk"
        $Shared["status::$TaskId"] = 'failed'
    }
}

# ── RunspacePool factory — clones the user's session for parallel workers ─────

function script:New-SwarmRunspacePoolInner {
    param([string[]]$ModuleNames)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    foreach ($n in $ModuleNames) {
        try { $iss.ImportPSModule($n) }
        catch { Write-Debug "Swarm: skipped module '$n': $_" }
    }
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if (-not $entry.Key) { continue }
        $val = if ($null -eq $entry.Value) { '' } else { $entry.Value }
        $iss.EnvironmentVariables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                $entry.Key, $val, ''))
    }
    script:Add-ContextVariable -ISS $iss
    $iss
}

function script:New-SwarmRunspacePool {
    param([int]$MaxRunspaces = 4)

    # Try to clone every loaded module with a backing file into the worker
    # runspace. If any one of them throws during the pool's Open() (e.g. a
    # module's load script calls a cmdlet with a null -Path because something
    # it depends on isn't seeded in the isolated runspace), fall back to
    # PwrCortex-only so the swarm still runs.
    $mods = @(Get-Module | Where-Object { $_.Path -and (Test-Path $_.Path) })
    $fullNames = @($mods | ForEach-Object Name)

    $issFull = script:New-SwarmRunspacePoolInner -ModuleNames $fullNames
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $MaxRunspaces, $issFull, $Host)
    try {
        $pool.Open()
        Write-Verbose "RunspacePool opened: max=$MaxRunspaces, $($mods.Count) modules cloned"
        return $pool
    } catch {
        $err   = $_
        $inner = if ($err.Exception.InnerException) { $err.Exception.InnerException.Message } else { $err.Exception.Message }
        $pos   = $err.InvocationInfo.PositionMessage
        $stack = $err.ScriptStackTrace
        Write-Warning "RunspacePool.Open() failed with full module set; falling back to PwrCortex only. Cause: $inner"
        Write-Verbose "Full-module pool open failure position: $pos"
        Write-Verbose "Full-module pool open failure stack:`n$stack"
        try { $pool.Dispose() } catch { }
    }

    $issMin = script:New-SwarmRunspacePoolInner -ModuleNames @('PwrCortex')
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $MaxRunspaces, $issMin, $Host)
    try {
        $pool.Open()
    } catch {
        $err   = $_
        $inner = if ($err.Exception.InnerException) { $err.Exception.InnerException.Message } else { $err.Exception.Message }
        $pos   = $err.InvocationInfo.PositionMessage
        $stack = $err.ScriptStackTrace
        # Using throw (not Write-Error -ErrorAction Stop) so the original
        # ErrorRecord's InvocationInfo propagates — the caller gets a
        # PositionMessage pointing at the throw site with file:line, not a
        # synthetic record pointing at Write-Error itself.
        throw @"
RunspacePool.Open() (fallback, PwrCortex only) failed.
Cause : $inner
$pos
ScriptStackTrace:
$stack
"@
    }
    Write-Verbose "RunspacePool opened (fallback): PwrCortex only"
    $pool
}

# ── DAG dispatcher ────────────────────────────────────────────────────────────

function script:Invoke-SwarmDispatcher {
    param(
        [PSCustomObject[]]$Tasks,
        [string]$Provider,
        [string]$Model,
        [System.Collections.Concurrent.ConcurrentDictionary[string,object]]$Shared,
        [int]$MaxRunspaces = 4,
        [int]$PollMs = 400,
        [int]$TimeoutSec = 300
    )

    Write-Verbose "Swarm dispatcher: $($Tasks.Count) tasks, maxRunspaces=$MaxRunspaces, timeout=${TimeoutSec}s"
    $pool = script:New-SwarmRunspacePool -MaxRunspaces $MaxRunspaces

    $state = @{}
    foreach ($t in $Tasks) {
        $state[$t.id] = [PSCustomObject]@{
            Id         = $t.id
            Name       = $t.name
            Prompt     = $t.prompt
            DependsOn  = @($t.dependsOn)
            Status     = 'pending'
            Pipeline   = $null
            AsyncResult= $null
            StartedAt  = $null
            ElapsedSec = 0.0
            Result     = $null
            Error      = $null
        }
    }

    $startTime = [datetime]::UtcNow
    $allIds    = $state.Keys

    foreach ($t in $state.Values) { script:Write-SwarmTaskLine -Task $t }
    Write-Host ""

    try {
        do {
            $anyProgress = $false

            foreach ($id in $allIds) {
                $t = $state[$id]
                if ($t.Status -notin 'pending','waiting') { continue }

                $depFailed = @($t.DependsOn | Where-Object { $state[$_].Status -eq 'failed' -or $state[$_].Status -eq 'skipped' })
                if ($depFailed.Count -gt 0) {
                    $t.Status = 'skipped'
                    $t.Error  = "Skipped: dependency $($depFailed -join ', ') failed"
                    Write-Warning "Task $id skipped: dependency $($depFailed -join ', ') failed"
                    script:Write-SwarmTaskLine -Task $t
                    $anyProgress = $true
                    continue
                }

                $depsReady = ($t.DependsOn.Count -eq 0) -or
                    ($t.DependsOn | ForEach-Object { $state[$_].Status } | Where-Object { $_ -ne 'done' } | Measure-Object).Count -eq 0

                if (-not $depsReady) {
                    if ($t.Status -ne 'waiting') { $t.Status = 'waiting'; script:Write-SwarmTaskLine -Task $t }
                    continue
                }

                $prompt = $t.Prompt
                foreach ($depId in $t.DependsOn) {
                    $depObj = $Shared["result::$depId"]
                    if ($depObj -and $depObj.Content) {
                        $prompt = $prompt -replace "{{result::$depId}}", $depObj.Content
                    }
                }

                $t.Status    = 'running'
                $t.StartedAt = [datetime]::UtcNow
                Write-Verbose "Task $id dispatching: $($t.Name)"
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                $null = $ps.AddScript($script:WorkerBlock).
                    AddArgument($id).
                    AddArgument($prompt).
                    AddArgument($Provider).
                    AddArgument($Model).
                    AddArgument($Shared)
                $t.Pipeline    = $ps
                $t.AsyncResult = $ps.BeginInvoke()

                script:Write-SwarmTaskLine -Task $t
                $anyProgress = $true
            }

            foreach ($id in $allIds) {
                $t = $state[$id]
                if ($t.Status -ne 'running' -or $null -eq $t.Pipeline) { continue }

                if ($t.AsyncResult.IsCompleted) {
                    try { $t.Pipeline.EndInvoke($t.AsyncResult) } catch {}
                    $t.ElapsedSec = ([datetime]::UtcNow - $t.StartedAt).TotalSeconds
                    $t.Status     = $Shared["status::$id"] ?? 'failed'
                    $t.Result     = $Shared["result::$id"]
                    if ($t.Status -eq 'failed' -and $t.Result -is [string]) {
                        $t.Error = $t.Result
                        Write-Warning "Task $id failed ($([math]::Round($t.ElapsedSec,1))s): $($t.Error.Substring(0, [math]::Min(100, $t.Error.Length)))"
                    } else {
                        Write-Verbose "Task $id completed ($([math]::Round($t.ElapsedSec,1))s)"
                    }

                    $t.Pipeline.Dispose()
                    $t.Pipeline    = $null
                    $t.AsyncResult = $null

                    script:Write-SwarmTaskLine -Task $t
                    $anyProgress = $true
                }
            }

            $allDone = ($state.Values | Where-Object { $_.Status -notin 'done','failed','skipped' } | Measure-Object).Count -eq 0
            if (-not $allDone) { Start-Sleep -Milliseconds $PollMs }

            if (([datetime]::UtcNow - $startTime).TotalSeconds -gt $TimeoutSec) {
                Write-Warning "Swarm timed out after ${TimeoutSec}s — cancelling remaining tasks"
                script:Write-Status "Swarm timed out after ${TimeoutSec}s" 'warn'
                foreach ($id in $allIds) {
                    $t = $state[$id]
                    if ($t.Pipeline) {
                        $t.Pipeline.Stop()
                        $t.Pipeline.Dispose()
                        $t.Pipeline    = $null
                        $t.AsyncResult = $null
                        if ($t.Status -eq 'running') {
                            $t.Status    = 'failed'
                            $t.Error     = "Timed out after ${TimeoutSec}s"
                            $t.ElapsedSec= ([datetime]::UtcNow - $t.StartedAt).TotalSeconds
                            script:Write-SwarmTaskLine -Task $t
                        }
                    }
                    if ($t.Status -eq 'pending' -or $t.Status -eq 'waiting') {
                        $t.Status = 'skipped'
                        $t.Error  = 'Skipped: swarm timed out'
                        script:Write-SwarmTaskLine -Task $t
                    }
                }
                break
            }

        } while (-not $allDone)
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }

    return $state.Values
}

# ── Synthesis: orchestrator reassembles results ───────────────────────────────

function script:Invoke-OrchestratorSynthesize {
    param([string]$Goal, [PSCustomObject[]]$TaskResults, [string]$Provider, [string]$Model)

    $done = @($TaskResults | Where-Object Status -eq 'done').Count
    $failed = @($TaskResults | Where-Object Status -eq 'failed').Count
    Write-Verbose "Synthesizing $done successful / $failed failed task(s)"
    $resultBlocks = $TaskResults | ForEach-Object {
        $content = if ($_.Result -is [PSCustomObject] -and $_.Result.Content) { $_.Result.Content }
                   else { $_.Error ?? 'no result' }
        "<task id=""$($_.Id)"" name=""$($_.Name)"" status=""$($_.Status)"">$content</task>"
    }

    $prompt = @"
Goal: $Goal

Worker results:
$($resultBlocks -join "`n")

Synthesize a single, coherent, well-structured answer to the original goal using all successful worker results.
Acknowledge any failed tasks and explain what impact that has on completeness.
"@

    $resp = script:Invoke-ProviderCompletion -Provider $Provider -Model $Model `
        -SystemPrompt 'You are a synthesis agent. Produce a clear, consolidated answer from the worker results provided. Apply the PwrCortex grounding rules from the module directives above — if worker conclusions conflict with $global:context, trust $global:context.' `
        -Messages @(@{role='user';content=$prompt}) -MaxTokens 2048 -WithEnv $true

    return @{
        Content      = $resp.Content
        Tokens       = $resp.TotalTokens
        InputTokens  = $resp.InputTokens
        OutputTokens = $resp.OutputTokens
        ElapsedSec   = $resp.ElapsedSec
    }
}
