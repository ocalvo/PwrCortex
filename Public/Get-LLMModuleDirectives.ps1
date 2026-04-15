function Get-LLMModuleDirectives {
<#
.SYNOPSIS
    Discovers claude.md directive files across loaded (or all installed) modules.

.DESCRIPTION
    Each module can ship a claude.md in its ModuleBase directory.
    This file is curated documentation written for the LLM — it describes
    what the module does, its key cmdlets, composition conventions, and
    anything that should be treated with caution.

    The harness automatically discovers and injects these into system prompts
    when -WithEnvironment is used, giving the LLM a precise capability map.

.PARAMETER ListAvailable
    Search all installed modules, not just currently loaded ones.

.EXAMPLE
    Get-LLMModuleDirectives | Format-Table Module, Version

.EXAMPLE
    # See full directive for a specific module
    Get-LLMModuleDirectives | Where-Object Module -eq 'Az.Compute' | Select-Object -Expand Directive
#>
    [CmdletBinding()]
    param([switch]$ListAvailable)

    $modules = if ($ListAvailable) { Get-Module -ListAvailable } else { Get-Module }
    Write-Verbose "Scanning $(@($modules).Count) module(s) for claude.md directives"

    foreach ($mod in $modules) {
        $path = Join-Path $mod.ModuleBase 'claude.md'
        if (Test-Path $path) {
            Write-Debug "Found directive: $($mod.Name) v$($mod.Version) at $path"
            [PSCustomObject]@{
                PSTypeName = 'LLMModuleDirective'
                Module     = $mod.Name
                Version    = $mod.Version
                ModuleBase = $mod.ModuleBase
                Path       = $path
                Directive  = Get-Content $path -Raw
            }
        }
    }
}
