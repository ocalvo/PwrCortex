function Get-LLMProviders {
<#
.SYNOPSIS
    List configured providers, default models, and API key status.
#>
    [CmdletBinding()]
    param()
    $c = $script:C; $b = $script:Box
    Write-Host ""; script:Write-Rule -Label 'PROVIDERS' -Color $c.Slate
    foreach ($name in $script:Providers.Keys | Sort-Object) {
        $cfg    = $script:Providers[$name]
        $keySet = -not [string]::IsNullOrWhiteSpace(
            [System.Environment]::GetEnvironmentVariable($cfg.EnvKeyName))
        if (-not $keySet) {
            Write-Warning "$name provider: $($cfg.EnvKeyName) is not set"
        }
        $dot    = if ($keySet) { "$($c.Green)●$($c.Reset)" } else { "$($c.Red)○$($c.Reset)" }
        Write-Host "  $dot $($c.Amber)$($name.PadRight(12))$($c.Reset)$($c.Silver)model:$($c.Reset) $($cfg.DefaultModel.PadRight(34))$($c.Silver)env:$($c.Reset) $($cfg.EnvKeyName)"
        [PSCustomObject]@{
            PSTypeName      = 'LLMProviderInfo'
            Provider        = $name
            DefaultModel    = $cfg.DefaultModel
            EnvVariable     = $cfg.EnvKeyName
            KeyConfigured   = $keySet
            AvailableModels = $cfg.Models -join ', '
        }
    }
    Write-Host ""
}
