function Get-LLMEnvironment {
<#
.SYNOPSIS
    Returns a live snapshot of the current PowerShell environment as a rich object.
    Automatically injected into system prompts when -WithEnvironment is used.
#>
    [CmdletBinding()]
    param()
    Write-Verbose "Capturing PS environment snapshot"
    $modules = Get-Module | Select-Object Name, Version, ModuleType
    $safeEnv = [System.Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { $_.Key -notmatch '(KEY|TOKEN|SECRET|PASS|CRED|AUTH|API)' } |
        Sort-Object Key | Select-Object Key, Value

    [PSCustomObject]@{
        PSTypeName       = 'LLMEnvironment'
        PSVersion        = $PSVersionTable.PSVersion.ToString()
        OS               = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        Platform         = [System.Environment]::OSVersion.Platform.ToString()
        Architecture     = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        CurrentDirectory = $PWD.Path
        UserName         = [System.Environment]::UserName
        MachineName      = [System.Environment]::MachineName
        LoadedModules    = $modules
        ModuleCount      = ($modules | Measure-Object).Count
        CommandCount     = (Get-Command -ErrorAction SilentlyContinue | Measure-Object).Count
        SafeEnvVars      = $safeEnv
        CapturedAt       = [datetime]::UtcNow
    }
}
