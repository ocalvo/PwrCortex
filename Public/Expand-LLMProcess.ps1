function Expand-LLMProcess {
<#
.SYNOPSIS
    Render the structured steps of an [LLMResponse] in full expanded detail.

.PARAMETER Response
    An [LLMResponse]. Accepts pipeline input.
.PARAMETER Index
    0-based step index to show a single step. Omit to show all.

.EXAMPLE
    $r = Invoke-LLM "Give me 5 steps to audit PS module permissions" -Provider Anthropic -Quiet
    Expand-LLMProcess $r
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Response,
        [int]$Index = -1
    )
    process {
        if ($Response.Steps.Count -eq 0) {
            script:Write-Status 'Response contains no structured steps' 'warn'; return
        }
        $steps = if ($Index -ge 0) { @($Response.Steps[$Index]) } else { $Response.Steps }
        Write-Host ""
        script:Write-Rule -Label "STEPS ($($steps.Count)  ·  $($Response.Model))" -Color $script:C.Slate
        script:Write-StepsBlock -Steps $steps -Expanded $true
    }
}
