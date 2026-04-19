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
    $apiParams = @{ Model=$Model; SystemPrompt=$sys; Messages=$Messages; MaxTokens=$MaxTokens }
    if ($PSBoundParameters.ContainsKey('Temperature')) { $apiParams.Temperature = $Temperature }
    $raw = switch ($Provider) {
        'Anthropic' { script:Invoke-AnthropicRaw @apiParams }
        'OpenAI'    { script:Invoke-OpenAIRaw    @apiParams }
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

        # ── Conversation context: recent entries from $global:context ─────
        $ctxVar = Get-Variable -Scope Global -Name 'context' -ErrorAction SilentlyContinue
        if ($ctxVar -and $ctxVar.Value -and $ctxVar.Value.Count -gt 0) {
            $entries = $ctxVar.Value
            $maxEntries = 20
            $maxPreviewChars = 500
            $recent = if ($entries.Count -gt $maxEntries) {
                $entries | Select-Object -Last $maxEntries
            } else {
                $entries
            }

            $ctxLines = [System.Collections.Generic.List[string]]::new()
            $ctxLines.Add("  $($entries.Count) total entr$(if ($entries.Count -eq 1) {'y'} else {'ies'}); showing last $(@($recent).Count).")
            foreach ($e in $recent) {
                $cmd = if ($e.Command) { $e.Command.Trim() } else { '(no command)' }
                if ($cmd.Length -gt 200) { $cmd = $cmd.Substring(0, 197) + '...' }
                $src = if ($e.PSObject.Properties['Source']) { $e.Source } else { 'Human' }
                $ctxLines.Add("  [$src] #$($e.HistoryId) [$($e.Timestamp.ToString('HH:mm:ss'))] `$ $cmd")

                $preview = try {
                    ($e.Output | Out-String -Width 120).Trim()
                } catch { '(unable to render output)' }
                if ($preview.Length -gt $maxPreviewChars) {
                    $preview = $preview.Substring(0, $maxPreviewChars - 3) + '...'
                }
                foreach ($line in ($preview -split "`n")) {
                    $ctxLines.Add("      $line")
                }
            }
            $sections.Add("<conversation_context>`n$($ctxLines -join "`n")`n</conversation_context>")
            Write-Verbose "Conversation context: $($entries.Count) total entr$(if ($entries.Count -eq 1) {'y'} else {'ies'}), $(@($recent).Count) shown"
        }

        $sections.Add(@'
You are an expert PowerShell assistant operating inside the environment described above.

TOOL SURFACE
- You have ONE tool: `invoke_powershell`. Do NOT refuse work or apologize for missing tools.
- That single tool gives you the entire in-process PowerShell cmdlet surface. Every capability another coding assistant exposes as a named tool has a native PS equivalent that runs in the same .NET runtime (no IPC, no JSON serialization, no subprocess):
    * Read a file → `Get-Content <path>`
    * Write / overwrite a file → `Set-Content -Path <path> -Value <text>` (or `Out-File`)
    * Append to a file → `Add-Content -Path <path> -Value <text>`
    * Edit a file → read with Get-Content, transform in memory, write back with Set-Content
    * Glob / list files → `Get-ChildItem -Path <p> -Filter <pat> -Recurse`
    * Grep / search text → `Select-String -Path <p> -Pattern <regex>`
    * Fetch a URL → `Invoke-WebRequest <url>` (HTML/bytes) or `Invoke-RestMethod <url>` (JSON-parsed)
    * Run a subprocess → `Start-Process`, `& <exe> <args>`, or `$proc = & ... ; $proc.ExitCode`
    * Inspect / manipulate objects → the full object pipeline (Where-Object, Select-Object, ForEach-Object, Sort-Object, Group-Object, Measure-Object, etc.)
- New capabilities are added by installing PowerShell modules (`Install-Module <name>`). Every loaded module's public commands are already available to you; any module that ships a claude.md is surfaced in <module_directives> above. Treat modules as first-class skills.
- Prefer already-loaded modules and real cmdlets over inventing alternatives. When unsure, use `Get-Command`, `Get-Help`, `Get-Member` to discover.

EXECUTION MODEL
- Tool results are stored in `$refs[id]`. Chain prior results in later calls: `$refs[1] | Sort-Object CPU`.
- The session is live — variables and state persist across tool calls.
- Stream output (errors, warnings, verbose, debug) is captured and shown separately.
- For destructive operations (Remove-, Stop-, Format- etc.) always warn the user before acting.
- IMPORTANT: Always compute your final answer through invoke_powershell so the result is a live typed .NET object in `$refs`, not just text. For example, if asked "What is 2+2?", call invoke_powershell with `2+2` so the result is [int]4. The caller accesses your answer via .Result — make sure it contains the real object.

CONVERSATION CONTEXT
- The <conversation_context> block above shows the most recent entries of `$global:context`. Apply the grounding rules from the PwrCortex module directives to interpret them.
- All global variables from the user's PowerShell session are also available. When the user references something by description ("the memory threshold", "the output path"), use `Get-Variable -Scope Global` to discover the matching variable. Always try to resolve references before asking the user for values.
'@)
    }

    if ($UserSystemPrompt) { $sections.Add($UserSystemPrompt) }
    $prompt = ($sections -join "`n`n").Trim()
    Write-Debug "System prompt length: $($prompt.Length) chars, $($sections.Count) section(s)"
    $prompt
}
