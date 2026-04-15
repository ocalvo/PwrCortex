@{
    RootModule        = 'PwrCortex.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a3e28c45-7b2d-4f8e-9c1a-6d5e4f3b2a10'
    Author            = 'Oscar Calvo'
    CompanyName       = 'PwrCortex'
    Copyright         = '(c) Oscar Calvo. All rights reserved.'
    Description       = 'PwrCortex - Agentic LLM swarm engine for PowerShell. Environment-aware, pipeline-native, claude.md-driven.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Invoke-LLM'
        'Invoke-LLMAgent'
        'Invoke-LLMSwarm'
        'New-LLMChat'
        'Send-LLMMessage'
        'Enter-LLMChat'
        'Expand-LLMProcess'
        'Get-LLMProviders'
        'Get-LLMEnvironment'
        'Get-LLMModuleDirectives'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('LLM', 'AI', 'Agent', 'Swarm', 'Anthropic', 'OpenAI', 'Claude', 'GPT', 'PowerShell')
            LicenseUri = 'https://github.com/ocalvo/PwrCortex/blob/main/LICENSE'
            ProjectUri = 'https://github.com/ocalvo/PwrCortex'
        }
    }
}
