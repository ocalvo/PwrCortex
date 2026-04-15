function Invoke-LLMSwarm {
<#
.SYNOPSIS
    Decompose a goal into parallel sub-tasks, run them concurrently as worker
    agents, then synthesize the results — all driven by a single prompt.

.DESCRIPTION
    Phase 1  DECOMPOSE  — An orchestrator LLM call breaks the goal into a JSON
             task list with optional DependsOn relationships (a DAG).

    Phase 2  DISPATCH   — Each task runs in a RunspacePool that clones the
             user's session. Workers call Invoke-LLMAgent with a dedicated
             runspace and $refs registry. Tasks with DependsOn wait until
             their dependencies complete. Results from prior tasks are
             substituted into dependent task prompts via {{result::<id>}}.

    Phase 3  SYNTHESIZE — The orchestrator receives all results and produces a
             single coherent final answer.

.PARAMETER Goal
    The top-level objective. Accepts pipeline input.
.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override (applies to all phases).
.PARAMETER MaxTasks
    Maximum tasks the orchestrator may create. Default 8.
.PARAMETER TimeoutSec
    Wall-clock timeout across all workers. Default 300s.
.PARAMETER Quiet
    Suppress the live task board and synthesis rendering.

.OUTPUTS
    [LLMSwarmResult] with .Tasks, .Synthesis, .TotalTokens, .TotalSec

.EXAMPLE
    Invoke-LLMSwarm "Audit this machine: running services, open ports, large processes, and disk usage" -Provider Anthropic

.EXAMPLE
    Invoke-LLMSwarm "Research and compare: PS 5.1 vs PS 7 module compatibility" -Provider Anthropic -MaxTasks 4

.EXAMPLE
    # Pipeline
    "Summarise all .log files in C:\Logs" | Invoke-LLMSwarm -Provider Anthropic
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position=0)]
        [string]$Goal,

        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,

        [ValidateRange(1,20)]
        [int]$MaxTasks = 8,

        [ValidateRange(30,3600)]
        [int]$TimeoutSec = 300,

        [switch]$Quiet
    )
    begin {
        if (-not $Provider) { $Provider = $env:LLM_DEFAULT_PROVIDER ?? 'Anthropic' }
        if (-not $Model)    { $Model    = $script:Providers[$Provider].DefaultModel }
    }
    process {
        $swStart = [System.Diagnostics.Stopwatch]::StartNew()
        $totalTokens = 0

        # ── Phase 1: Decompose ─────────────────────────────────────────────
        if (-not $Quiet) {
            script:Write-Status "Decomposing goal into tasks…" 'info'
        }
        $envContext = "PSVersion: $($PSVersionTable.PSVersion)  OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
        $decomp     = script:Invoke-OrchestratorDecompose -Goal $Goal -Provider $Provider `
            -Model $Model -Context $envContext -MaxTasks $MaxTasks
        $tasks      = $decomp.Tasks
        $totalTokens += $decomp.Tokens

        if (-not $Quiet) { script:Write-SwarmHeader -Goal $Goal -TaskCount $tasks.Count }

        # ── Phase 2: Dispatch DAG ─────────────────────────────────────────
        $script:SwarmShared.Clear()
        $finishedTasks = script:Invoke-SwarmDispatcher `
            -Tasks $tasks -Provider $Provider -Model $Model `
            -Shared $script:SwarmShared -MaxRunspaces ([Math]::Min($tasks.Count, 4)) `
            -TimeoutSec $TimeoutSec

        $finishedTasks | ForEach-Object {
            if ($_.Result -is [PSCustomObject] -and $_.Result.TotalTokens) {
                $totalTokens += $_.Result.TotalTokens
            }
        }

        # ── Phase 3: Synthesize ───────────────────────────────────────────
        if (-not $Quiet) {
            Write-Host ""
            script:Write-Status "Synthesizing results…" 'info'
        }
        $synth = script:Invoke-OrchestratorSynthesize -Goal $Goal `
            -TaskResults $finishedTasks -Provider $Provider -Model $Model
        $totalTokens += $synth.Tokens
        $swStart.Stop()

        $result = [PSCustomObject]@{
            PSTypeName   = 'LLMSwarmResult'
            Goal         = $Goal
            Provider     = $Provider
            Model        = $Model
            Tasks        = $finishedTasks
            Synthesis    = $synth.Content
            TotalTokens  = $totalTokens
            TotalSec     = $swStart.Elapsed.TotalSeconds
            StartedAt    = [datetime]::UtcNow - $swStart.Elapsed
        }

        $dds = [System.Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet',
            [string[]]@('Goal','TotalTokens','TotalSec','Synthesis'))
        $result.PSObject.Members.Add(
            [System.Management.Automation.PSMemberSet]::new('PSStandardMembers',[System.Management.Automation.PSMemberInfo[]]@($dds)))

        if (-not $Quiet) { script:Write-SwarmSummary -Result $result }

        return $result
    }
}
