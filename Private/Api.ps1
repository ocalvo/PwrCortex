# ══════════════════════════════════════════════════════════════════════════════
#  INTERNAL API LAYER
# ══════════════════════════════════════════════════════════════════════════════

function script:Get-ApiKey([string]$Provider) {
    $key = [System.Environment]::GetEnvironmentVariable($script:Providers[$Provider].EnvKeyName)
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Set `$$($script:Providers[$Provider].EnvKeyName) to use $Provider."
    }
    $key
}

function script:Parse-Steps([string]$Content) {
    $steps = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in ($Content -split "`n")) {
        if ($line -match '^\s*(\d+[\.\)]|\-|\*|•)\s+(.+)$') {
            $steps.Add([PSCustomObject]@{
                PSTypeName='LLMStep'; Label=$Matches[2].Trim(); Done=$false; Detail=''
            })
        }
    }
    ,$steps
}

function script:New-ResponseObj {
    param(
        [string]$Provider, [string]$Model, [string]$Content,
        [int]$InputTokens, [int]$OutputTokens, [string]$StopReason,
        [string]$ResponseId, [double]$ElapsedSec, $Raw,
        [PSCustomObject[]]$ToolCalls = @(),
        $Result = $null
    )
    $steps   = script:Parse-Steps $Content
    $summary = if ($Content.Length -gt 200) { $Content.Substring(0,197)+'...' } else { $Content }
    $obj = [PSCustomObject]@{
        PSTypeName   = 'LLMResponse'
        Provider     = $Provider
        Model        = $Model
        Content      = $Content
        Summary      = $summary
        InputTokens  = $InputTokens
        OutputTokens = $OutputTokens
        TotalTokens  = $InputTokens + $OutputTokens
        StopReason   = $StopReason
        ResponseId   = $ResponseId
        ElapsedSec   = $ElapsedSec
        Timestamp    = [datetime]::UtcNow
        Steps        = $steps
        ToolCalls    = $ToolCalls
        Result       = $Result
        Raw          = $Raw
    }
    $dds = [System.Management.Automation.PSPropertySet]::new(
        'DefaultDisplayPropertySet',
        [string[]]@('Provider','Model','TotalTokens','ElapsedSec','Summary'))
    $obj.PSObject.Members.Add(
        [System.Management.Automation.PSMemberSet]::new('PSStandardMembers',[System.Management.Automation.PSMemberInfo[]]@($dds)))
    $obj
}

function script:Invoke-AnthropicRaw {
    param([string]$Model, [string]$SystemPrompt, [array]$Messages,
          [int]$MaxTokens, [double]$Temperature, [array]$Tools = @())
    $key  = script:Get-ApiKey 'Anthropic'
    $body = @{ model=$Model; max_tokens=$MaxTokens; messages=$Messages }
    if ($SystemPrompt)            { $body.system      = $SystemPrompt }
    if ($Tools.Count -gt 0)      { $body.tools        = $Tools }
    if ($PSBoundParameters.ContainsKey('Temperature')) { $body.temperature = $Temperature }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r  = Invoke-RestMethod -Uri $script:Providers.Anthropic.BaseUrl -Method POST `
        -Headers @{
            'x-api-key'         = $key
            'anthropic-version' = '2023-06-01'
            'Content-Type'      = 'application/json'
        } -Body ($body | ConvertTo-Json -Depth 12)
    $sw.Stop()
    @{ Response=$r; ElapsedSec=$sw.Elapsed.TotalSeconds }
}

function script:Invoke-OpenAIRaw {
    param([string]$Model, [string]$SystemPrompt, [array]$Messages,
          [int]$MaxTokens, [double]$Temperature, [array]$Tools = @())
    $key  = script:Get-ApiKey 'OpenAI'
    $msgs = @()
    if ($SystemPrompt) { $msgs += @{role='system';content=$SystemPrompt} }
    $msgs += $Messages
    $body = @{ model=$Model; messages=$msgs; max_tokens=$MaxTokens }
    if ($Tools.Count -gt 0)      { $body.tools = $Tools | ForEach-Object { @{type='function';function=$_} } }
    if ($PSBoundParameters.ContainsKey('Temperature')) { $body.temperature = $Temperature }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r  = Invoke-RestMethod -Uri $script:Providers.OpenAI.BaseUrl -Method POST `
        -Headers @{ 'Authorization'="Bearer $key"; 'Content-Type'='application/json' } `
        -Body ($body | ConvertTo-Json -Depth 12)
    $sw.Stop()
    @{ Response=$r; ElapsedSec=$sw.Elapsed.TotalSeconds }
}

function script:Invoke-ProviderCompletion {
    param([string]$Provider, [string]$Model, [string]$SystemPrompt,
          [array]$Messages, [int]$MaxTokens, [double]$Temperature, [bool]$WithEnv)
    $sys = script:Build-SystemPrompt -UserSystemPrompt $SystemPrompt -IncludeEnv $WithEnv
    $p   = @{ Model=$Model; SystemPrompt=$sys; Messages=$Messages; MaxTokens=$MaxTokens }
    if ($PSBoundParameters.ContainsKey('Temperature')) { $p.Temperature = $Temperature }
    $raw = switch ($Provider) {
        'Anthropic' { script:Invoke-AnthropicRaw @p }
        'OpenAI'    { script:Invoke-OpenAIRaw    @p }
    }
    $r = $raw.Response
    switch ($Provider) {
        'Anthropic' {
            script:New-ResponseObj -Provider 'Anthropic' -Model $r.model `
                -Content $r.content[0].text `
                -InputTokens $r.usage.input_tokens -OutputTokens $r.usage.output_tokens `
                -StopReason $r.stop_reason -ResponseId $r.id -ElapsedSec $raw.ElapsedSec -Raw $r
        }
        'OpenAI' {
            script:New-ResponseObj -Provider 'OpenAI' -Model $r.model `
                -Content $r.choices[0].message.content `
                -InputTokens $r.usage.prompt_tokens -OutputTokens $r.usage.completion_tokens `
                -StopReason $r.choices[0].finish_reason -ResponseId $r.id -ElapsedSec $raw.ElapsedSec -Raw $r
        }
    }
}

function script:Build-SystemPrompt {
    param([string]$UserSystemPrompt='', [bool]$IncludeEnv=$false)

    $sections = [System.Collections.Generic.List[string]]::new()

    if ($IncludeEnv) {
        $e    = Get-LLMEnvironment
        $mods = ($e.LoadedModules | ForEach-Object { "$($_.Name) v$($_.Version)" }) -join ', '

        $sections.Add(@"
<powershell_environment>
  PSVersion        : $($e.PSVersion)
  OS               : $($e.OS)
  Platform         : $($e.Platform) / $($e.Architecture)
  CurrentDirectory : $($e.CurrentDirectory)
  User             : $($e.UserName) @ $($e.MachineName)
  LoadedModules ($($e.ModuleCount)) : $mods
  AvailableCommands: $($e.CommandCount)
</powershell_environment>
"@)

        $directives = Get-LLMModuleDirectives
        if ($directives) {
            $dBlocks = $directives | ForEach-Object {
"<module name=""$($_.Module)"" version=""$($_.Version)"">
$($_.Directive.Trim())
</module>"
            }
            $sections.Add("<module_directives>`n$($dBlocks -join "`n`n")`n</module_directives>")
        }

        $sections.Add(@"
You are an expert PowerShell assistant operating inside the environment described above.
- Prefer modules already loaded; reference real cmdlets.
- When using invoke_powershell, emit precise pipeline expressions.
- Tool results are stored in `$refs[id]`. Chain prior results in later calls: `$refs[1] | Sort-Object CPU`.
- The session is live — variables and state persist across tool calls.
- Stream output (errors, warnings, verbose, debug) is captured and shown separately.
- For destructive operations (Remove-, Stop-, Format- etc.) always warn the user before acting.
- If a module has a claude.md directive, follow its conventions exactly.
"@)
    }

    if ($UserSystemPrompt) { $sections.Add($UserSystemPrompt) }
    ($sections -join "`n`n").Trim()
}
