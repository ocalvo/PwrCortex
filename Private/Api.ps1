# ══════════════════════════════════════════════════════════════════════════════
#  INTERNAL API LAYER
# ══════════════════════════════════════════════════════════════════════════════

function script:Get-ApiKey([string]$Provider) {
    $envName = $script:Providers[$Provider].EnvKeyName
    $key = [System.Environment]::GetEnvironmentVariable($envName)
    if ([string]::IsNullOrWhiteSpace($key)) {
        $err = "API key not configured. Set environment variable $envName to use $Provider."
        Write-Error $err -ErrorAction Stop
    }
    Write-Debug "API key resolved for $Provider ($($envName.Substring(0,8))…)"
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
    Write-Verbose "Anthropic API call: $Model, max_tokens=$MaxTokens$(if ($Tools.Count) {", tools=$($Tools.Count)"})"
    Write-Debug "Anthropic request body keys: $($body.Keys -join ', ')"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri $script:Providers.Anthropic.BaseUrl -Method POST `
            -Headers @{
                'x-api-key'         = $key
                'anthropic-version' = '2023-06-01'
                'Content-Type'      = 'application/json'
            } -Body ($body | ConvertTo-Json -Depth 12)
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 429) {
            Write-Warning "Anthropic rate limit hit. Retry after backoff."
        }
        Write-Error "Anthropic API error ($status): $_" -ErrorAction Stop
    }
    $sw.Stop()
    Write-Verbose "Anthropic response: $([math]::Round($sw.Elapsed.TotalSeconds,2))s, stop=$($r.stop_reason)"
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
    Write-Verbose "OpenAI API call: $Model, max_tokens=$MaxTokens$(if ($Tools.Count) {", tools=$($Tools.Count)"})"
    Write-Debug "OpenAI request body keys: $($body.Keys -join ', ')"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri $script:Providers.OpenAI.BaseUrl -Method POST `
            -Headers @{ 'Authorization'="Bearer $key"; 'Content-Type'='application/json' } `
            -Body ($body | ConvertTo-Json -Depth 12)
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 429) {
            Write-Warning "OpenAI rate limit hit. Retry after backoff."
        }
        Write-Error "OpenAI API error ($status): $_" -ErrorAction Stop
    }
    $sw.Stop()
    Write-Verbose "OpenAI response: $([math]::Round($sw.Elapsed.TotalSeconds,2))s, finish=$($r.choices[0].finish_reason)"
    @{ Response=$r; ElapsedSec=$sw.Elapsed.TotalSeconds }
}

function script:Invoke-ProviderCompletion {
    param([string]$Provider, [string]$Model, [string]$SystemPrompt,
          [array]$Messages, [int]$MaxTokens, [double]$Temperature, [bool]$WithEnv)
    Write-Verbose "Provider completion: $Provider/$Model, messages=$($Messages.Count), withEnv=$WithEnv"
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
        Write-Verbose "Building system prompt with environment context"
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
        Write-Verbose "Discovered $(@($directives).Count) module directive(s)"
        if ($directives) {
            $dBlocks = $directives | ForEach-Object {
"<module name=""$($_.Module)"" version=""$($_.Version)"">
$($_.Directive.Trim())
</module>"
            }
            $sections.Add("<module_directives>`n$($dBlocks -join "`n`n")`n</module_directives>")
        }

        # ── Session context: enumerate $llm_* globals ──────────────────
        $llmVars = Get-Variable -Scope Global -Name 'llm_*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'llm_history' }
        $historyVar = Get-Variable -Scope Global -Name 'llm_history' -ErrorAction SilentlyContinue

        if ($llmVars -or ($historyVar -and $historyVar.Value.Count -gt 0)) {
            $ctxLines = [System.Collections.Generic.List[string]]::new()
            if ($historyVar -and $historyVar.Value.Count -gt 0) {
                $ctxLines.Add("  Session history ($($historyVar.Value.Count) prior call(s)):")
                foreach ($h in $historyVar.Value) {
                    $ctxLines.Add("    #$($h.Index) `$$($h.GlobalName) [$($h.Type)] — $($h.Prompt)")
                }
            }
            if ($llmVars) {
                $ctxLines.Add("  Available result variables:")
                foreach ($v in $llmVars) {
                    $typeName = if ($null -ne $v.Value) { $v.Value.GetType().Name } else { 'null' }
                    $preview  = try {
                        $s = ($v.Value | Out-String -Width 120).Trim()
                        if ($s.Length -gt 120) { $s.Substring(0,117) + '...' } else { $s }
                    } catch { '(unable to preview)' }
                    $ctxLines.Add("    `$$($v.Name) [$typeName] — $preview")
                }
            }
            $sections.Add("<session_context>`n$($ctxLines -join "`n")`n</session_context>")
            Write-Verbose "Session context: $(@($llmVars).Count) llm_ var(s), $($historyVar.Value.Count) history entries"
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
- IMPORTANT: Always compute your final answer through invoke_powershell so the result is a live typed .NET object in `$refs`, not just text. For example, if asked "What is 2+2?", call invoke_powershell with `2+2` so the result is [int]4. The caller accesses your answer via .Result — make sure it contains the real object.
- When the user refers to prior results in natural language (e.g. "those processes", "the services from before", "filter those top results"), resolve the reference to the matching `$llm_*` variable from <session_context>. Use the variable names, types, and history prompts to infer which prior result the user means. Do NOT require the user to spell out variable names — that is your job.
- All global variables from the user's PowerShell session are available in your runspace (not just `$llm_*`). When the user references something by description (e.g. "the memory threshold", "the output path"), use `Get-Variable -Scope Global` to discover the matching variable. Always try to resolve references before asking the user for values.
"@)
    }

    if ($UserSystemPrompt) { $sections.Add($UserSystemPrompt) }
    $prompt = ($sections -join "`n`n").Trim()
    Write-Debug "System prompt length: $($prompt.Length) chars, $($sections.Count) section(s)"
    $prompt
}
