function Remove-Context {
<#
.SYNOPSIS
    Clear or trim entries from $global:context.

.DESCRIPTION
    $global:context is the conversation log maintained by PwrCortex. Every
    command the user runs at the interactive prompt has its (command, output)
    appended via an Out-Default proxy. Use Remove-Context to drop entries
    you do not want the LLM to see on the next call.

    Default behavior clears every entry. Use -Last to drop the N most recent
    entries, or -HistoryId to drop entries matching specific PS history ids.

.PARAMETER Last
    Remove the N most recent entries.

.PARAMETER HistoryId
    Remove entries whose HistoryId matches one of the supplied ids. Accepts
    pipeline input by property name so you can feed entries directly:
        $global:context | Where-Object { ... } | Remove-Context

.EXAMPLE
    Remove-Context
    # Clears every entry in $global:context (prompts for confirmation).

.EXAMPLE
    Remove-Context -Last 3
    # Drops the last three entries.

.EXAMPLE
    $global:context | Where-Object { $_.Command -like '*secret*' } | Remove-Context
    # Scrubs entries matching a pattern before the next agent call.
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium',
        DefaultParameterSetName = 'All')]
    param(
        [Parameter(ParameterSetName = 'Last', Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Last,

        [Parameter(ParameterSetName = 'Id', Mandatory,
            ValueFromPipelineByPropertyName)]
        [int[]]$HistoryId,

        [Parameter(ParameterSetName = 'All')]
        [Parameter(ParameterSetName = 'Last')]
        [Parameter(ParameterSetName = 'Id')]
        [ValidateSet('Human','Agent','Swarm')]
        [string[]]$Source
    )
    begin {
        if (-not $global:context) {
            Write-Verbose "`$global:context is not initialized; nothing to remove."
            return
        }
        $idsToRemove = [System.Collections.Generic.HashSet[int]]::new()
    }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'Id' -and $HistoryId) {
            foreach ($id in $HistoryId) { [void]$idsToRemove.Add($id) }
        }
    }
    end {
        if (-not $global:context) { return }

        $sourceFilter = if ($Source) {
            [System.Collections.Generic.HashSet[string]]::new(
                [string[]]$Source, [System.StringComparer]::OrdinalIgnoreCase)
        } else { $null }
        $filterLabel = if ($sourceFilter) { " with Source in ($($Source -join ','))" } else { '' }

        function Test-SourceMatch([PSCustomObject]$Entry) {
            if (-not $sourceFilter) { return $true }
            $src = if ($Entry.PSObject.Properties['Source']) { [string]$Entry.Source } else { 'Human' }
            return $sourceFilter.Contains($src)
        }

        switch ($PSCmdlet.ParameterSetName) {
            'All' {
                if ($global:context.Count -eq 0) {
                    Write-Verbose "`$global:context already empty."
                    return
                }
                if (-not $sourceFilter) {
                    $n = $global:context.Count
                    if ($PSCmdlet.ShouldProcess("all $n entr$(if($n -eq 1){'y'}else{'ies'}) in `$global:context", 'Clear')) {
                        $global:context.Clear()
                        Write-Verbose "Cleared $n entr$(if($n -eq 1){'y'}else{'ies'}) from `$global:context."
                    }
                    return
                }
                $toRemove = @($global:context | Where-Object { Test-SourceMatch $_ })
                if ($toRemove.Count -eq 0) {
                    Write-Verbose "No entries match$filterLabel."
                    return
                }
                if ($PSCmdlet.ShouldProcess("$($toRemove.Count) entr$(if($toRemove.Count -eq 1){'y'}else{'ies'})$filterLabel", 'Remove')) {
                    foreach ($e in $toRemove) { [void]$global:context.Remove($e) }
                    Write-Verbose "Removed $($toRemove.Count) entr$(if($toRemove.Count -eq 1){'y'}else{'ies'}) from `$global:context."
                }
            }
            'Last' {
                $candidates = @($global:context | Where-Object { Test-SourceMatch $_ })
                $n = [Math]::Min($Last, $candidates.Count)
                if ($n -eq 0) {
                    Write-Verbose "No matching entries to trim$filterLabel."
                    return
                }
                $toRemove = @($candidates | Select-Object -Last $n)
                if ($PSCmdlet.ShouldProcess("last $n matching entr$(if($n -eq 1){'y'}else{'ies'})$filterLabel", 'Remove')) {
                    foreach ($e in $toRemove) { [void]$global:context.Remove($e) }
                    Write-Verbose "Removed last $n entr$(if($n -eq 1){'y'}else{'ies'}) from `$global:context."
                }
            }
            'Id' {
                if ($idsToRemove.Count -eq 0) {
                    Write-Verbose "No HistoryId values supplied."
                    return
                }
                $toRemove = @($global:context | Where-Object {
                    $idsToRemove.Contains($_.HistoryId) -and (Test-SourceMatch $_)
                })
                if ($toRemove.Count -eq 0) {
                    Write-Verbose "No entries matched the supplied HistoryId(s)$filterLabel."
                    return
                }
                if ($PSCmdlet.ShouldProcess("$($toRemove.Count) entr$(if($toRemove.Count -eq 1){'y'}else{'ies'}) matching HistoryId=$($idsToRemove -join ',')$filterLabel", 'Remove')) {
                    foreach ($e in $toRemove) { [void]$global:context.Remove($e) }
                    Write-Verbose "Removed $($toRemove.Count) entr$(if($toRemove.Count -eq 1){'y'}else{'ies'}) from `$global:context."
                }
            }
        }
    }
}
