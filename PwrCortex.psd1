@{
    RootModule        = 'PwrCortex.psm1'
    ModuleVersion     = '0.10.0' # x-release-please-version
    GUID              = '8d813073-685a-4374-9a02-14bde0b8e9e9'
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
        'Push-LLMInput'
        'Remove-Context'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @('swarm', 'think', 'agent', 'llm', 'chat', 'feed')
    PrivateData       = @{
        PSData = @{
            Tags       = @('LLM', 'AI', 'Agent', 'Swarm', 'Anthropic', 'OpenAI', 'Claude', 'GPT', 'PowerShell')
            LicenseUri = 'https://github.com/ocalvo/PwrCortex/blob/main/LICENSE'
            ProjectUri = 'https://github.com/ocalvo/PwrCortex'
        }
    }
}
