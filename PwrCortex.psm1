#Requires -Version 7.0
<#
.SYNOPSIS
    PwrCortex — Agentic LLM swarm engine for PowerShell. Environment-aware, pipeline-native, claude.md-driven.

.DESCRIPTION
    PUBLIC CMDLETS
    ──────────────
    Invoke-LLM              Single/batch completions. Pipeline-friendly.
    Invoke-LLMAgent         Agentic loop — LLM calls back into PS via Invoke-Expression.
    New-LLMChat             Create a stateful multi-turn chat session.
    Send-LLMMessage         Send one turn inside a chat session.
    Enter-LLMChat           Interactive REPL for a chat session.
    Expand-LLMProcess       Render structured steps from any response.
    Get-LLMProviders        List providers and API key status.
    Get-LLMEnvironment      Snapshot of the current PS environment.
    Get-LLMModuleDirectives Discover claude.md files across loaded/installed modules.

    ENVIRONMENT AWARENESS
    ─────────────────────
    -WithEnvironment injects PS version, OS, loaded modules, command count,
    and all discovered claude.md module directives into every system prompt.
    The LLM knows exactly what it can call and how.

    AGENTIC TOOL USE
    ────────────────
    Invoke-LLMAgent runs a looped completion where the LLM emits
    { "expression": "<powershell>" } tool calls. The harness executes each
    via Invoke-Expression, serializes the result with ConvertTo-Json, and
    feeds it back. Destructive verbs (Remove-, Stop-, Format-, Clear- etc.)
    require interactive confirmation before execution.

    MODULE DIRECTIVES
    ─────────────────
    Any module can ship a claude.md in its ModuleBase directory.
    Get-LLMModuleDirectives discovers and returns them as objects.
    Build-SystemPrompt automatically injects them when -WithEnvironment is set.

    LONG-RUNNING STEPS
    ──────────────────
    Numbered/bulleted content is parsed into [LLMStep] objects on every
    response. /expand inside the REPL, or Expand-LLMProcess outside it.

.ENVIRONMENT VARIABLES
    ANTHROPIC_API_KEY     Anthropic / Claude
    OPENAI_API_KEY        OpenAI / GPT
    LLM_DEFAULT_PROVIDER  Default provider name (Anthropic or OpenAI)
    LLM_CONFIRM_DANGEROUS Set to '0' to skip destructive-verb confirmation (not recommended)

.EXAMPLE
    # Environment-aware completion
    Invoke-LLM "Which of my loaded modules can talk to Azure?" -Provider Anthropic -WithEnvironment

.EXAMPLE
    # Agentic — LLM calls real PS commands to answer
    Invoke-LLMAgent "What process is using the most memory and what module owns it?" -Provider Anthropic

.EXAMPLE
    # Interactive chat
    $chat = New-LLMChat -Provider Anthropic -WithEnvironment -Name "Ops"
    Enter-LLMChat $chat
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ══════════════════════════════════════════════════════════════════════════════
#  ANSI PALETTE  &  BOX DRAWING
# ══════════════════════════════════════════════════════════════════════════════

$script:C = @{
    Reset    = "`e[0m"
    Bold     = "`e[1m"
    Dim      = "`e[2m"
    Italic   = "`e[3m"
    Amber    = "`e[38;5;214m"
    Cyan     = "`e[38;5;87m"
    White    = "`e[38;5;255m"
    Silver   = "`e[38;5;248m"
    Slate    = "`e[38;5;238m"
    Green    = "`e[38;5;119m"
    Red      = "`e[38;5;203m"
    Yellow   = "`e[38;5;227m"
    Magenta  = "`e[38;5;213m"
    Blue     = "`e[38;5;75m"
    BgAccent = "`e[48;5;236m"
    BgWarn   = "`e[48;5;52m"
}

$script:Box = @{
    TL='╬'; TR='╮'; BL='╰'; BR='╯'
    H='─';  V='│';  LJ='├'; RJ='┤'
    DH='┄'; DV='┆'
    Arrow='›'; Bullet='◆'; Tick='✓'; X='✗'; Warn='⚠'
    Gear='⚙'; Eye='◉'; Lightning='⚡'
}

# ══════════════════════════════════════════════════════════════════════════════
#  RENDER HELPERS
# ══════════════════════════════════════════════════════════════════════════════

function script:Get-Width { try { $Host.UI.RawUI.WindowSize.Width } catch { 100 } }

function script:Write-Rule {
    param([string]$Label='', [string]$Color=$script:C.Slate, [int]$W=0)
    if ($W -eq 0) { $W = script:Get-Width }
    $c = $script:C; $b = $script:Box
    if ($Label) {
        $l = $b.H * 3
        $r = $b.H * [Math]::Max(2, $W - $Label.Length - 6)
        Write-Host "$Color$l $($c.Amber)$Label $Color$r$($c.Reset)"
    } else {
        Write-Host "$Color$($b.H * $W)$($c.Reset)"
    }
}

function script:Write-Banner {
    $c = $script:C; $b = $script:Box; $w = script:Get-Width
    $t = ' PwrCortex '
    $s = ' agentic llm swarm  ·  environment-aware  ·  pipeline-native '
    $lp = [Math]::Max(0,[int](($w - $t.Length - 2)/2))
    $rp = [Math]::Max(0, $w - 2 - $lp - $t.Length)
    Write-Host ""
    Write-Host "$($c.Amber)$($b.TL)$($b.H*$lp)$($c.Bold)$($c.BgAccent)$t$($c.Reset)$($c.Amber)$($b.H*$rp)$($b.TR)$($c.Reset)"
    $sp = ' ' * [Math]::Max(0,[int](($w - $s.Length)/2))
    Write-Host "$($c.Amber)$($b.V)$($c.Reset)$($c.Silver)$sp$s$($c.Reset)"
    Write-Host "$($c.Amber)$($b.BL)$($b.H*($w-2))$($b.BR)$($c.Reset)"
    Write-Host ""
}

function script:Write-ResponseBox {
    param(
        [string]$Content, [string]$Provider, [string]$Model,
        [int]$InputTokens, [int]$OutputTokens, [string]$StopReason, [double]$ElapsedSec
    )
    $c = $script:C; $b = $script:Box; $w = script:Get-Width; $inn = $w - 4
    $pc = if ($Provider -eq 'Anthropic') { $c.Magenta } else { $c.Blue }
    $nameLen = 4 + $Provider.Length + 3 + $Model.Length
    $metaStr = "in:$InputTokens out:$OutputTokens $([math]::Round($ElapsedSec,2))s $StopReason"
    $gap = [Math]::Max(1, $w - 2 - $nameLen - $metaStr.Length - 4)

    Write-Host "$($c.Amber)$($b.TL)$($b.H*($w-2))$($b.TR)$($c.Reset)"
    Write-Host "$($c.Amber)$($b.V)$($c.Reset) $pc$($c.Bold)$($b.Bullet) $Provider$($c.Reset) $($c.Silver)›$($c.Reset) $($c.Cyan)$Model$($c.Reset)$(' '*$gap)$($c.Silver)in:$($c.Reset)$($c.Cyan)$InputTokens$($c.Reset) $($c.Silver)out:$($c.Reset)$($c.Cyan)$OutputTokens$($c.Reset) $($c.Silver)$([math]::Round($ElapsedSec,2))s$($c.Reset) $($c.Green)$StopReason$($c.Reset) $($c.Amber)$($b.V)$($c.Reset)"
    Write-Host "$($c.Amber)$($b.LJ)$($b.H*($w-2))$($b.RJ)$($c.Reset)"

    foreach ($rawLine in ($Content -split "`n")) {
        if ($rawLine.Trim() -eq '') { Write-Host "$($c.Amber)$($b.V)$($c.Reset)"; continue }
        $cur = '  '
        foreach ($word in ($rawLine -split ' ')) {
            if (($cur + $word).Length -ge $inn) {
                Write-Host "$($c.Amber)$($b.V)$($c.Reset)$($c.White)$cur$($c.Reset)"; $cur = "  $word "
            } else { $cur += "$word " }
        }
        if ($cur.Trim()) { Write-Host "$($c.Amber)$($b.V)$($c.Reset)$($c.White)$cur$($c.Reset)" }
    }
    Write-Host "$($c.Amber)$($b.BL)$($b.H*($w-2))$($b.BR)$($c.Reset)"; Write-Host ""
}

function script:Write-ToolCallBox {
    param([string]$Expression, [string]$Result, [bool]$IsError=$false, [int]$CallNum=1)
    $c = $script:C; $b = $script:Box; $w = [Math]::Min((script:Get-Width), 100)
    $resColor = if ($IsError) { $c.Red } else { $c.Green }
    $label    = " $($b.Gear) TOOL CALL $CallNum "
    $pad      = $b.DH * [Math]::Max(2, $w - $label.Length - 4)

    Write-Host "  $($c.Slate)$($b.TL)$($b.DH*2)$($c.Cyan)$label$($c.Slate)$pad$($b.TR)$($c.Reset)"
    Write-Host "  $($c.Slate)$($b.V)$($c.Reset) $($c.Yellow)$($b.Lightning) $($c.Reset)$($c.White)$Expression$($c.Reset)"
    Write-Host "  $($c.Slate)$($b.LJ)$($b.DH*($w-2))$($b.RJ)$($c.Reset)"
    # Truncate result for display
    $display = if ($Result.Length -gt 300) { $Result.Substring(0,297) + '…' } else { $Result }
    foreach ($rl in ($display -split "`n" | Select-Object -First 8)) {
        Write-Host "  $($c.Slate)$($b.V)$($c.Reset) $resColor$rl$($c.Reset)"
    }
    Write-Host "  $($c.Slate)$($b.BL)$($b.DH*($w-2))$($b.BR)$($c.Reset)"; Write-Host ""
}

function script:Write-ConfirmBox {
    param([string]$Expression)
    $c = $script:C; $b = $script:Box; $w = [Math]::Min((script:Get-Width), 80)
    Write-Host ""
    Write-Host "  $($c.Red)$($b.TL)$($b.H*($w-4))$($b.TR)$($c.Reset)"
    Write-Host "  $($c.Red)$($b.V)$($c.Reset) $($c.BgWarn)$($c.Yellow)$($c.Bold) $($b.Warn)  DESTRUCTIVE OPERATION — CONFIRM BEFORE EXECUTION $($c.Reset)  $($c.Red)$($b.V)$($c.Reset)"
    Write-Host "  $($c.Red)$($b.LJ)$($b.H*($w-4))$($b.RJ)$($c.Reset)"
    Write-Host "  $($c.Red)$($b.V)$($c.Reset)  $($c.White)$Expression$($c.Reset)"
    Write-Host "  $($c.Red)$($b.BL)$($b.H*($w-4))$($b.BR)$($c.Reset)"
    Write-Host -NoNewline "  $($c.Yellow)Allow execution? $($c.Cyan)[y/N]$($c.Reset) "
}

function script:Write-StepsBlock {
    param([PSCustomObject[]]$Steps, [bool]$Expanded)
    $c = $script:C; $b = $script:Box; $w = [Math]::Min(64, (script:Get-Width) - 4)
    Write-Host "  $($c.Slate)$($b.TL)$($b.DH*$w)$($b.TR)$($c.Reset)"
    $i = 1
    foreach ($step in $Steps) {
        $icon = if ($step.Done) { "$($c.Green)$($b.Tick)" } else { "$($c.Silver)$i." }
        Write-Host "  $($c.Slate)$($b.V)$($c.Reset) $icon$($c.Reset) $($c.White)$($step.Label)$($c.Reset)"
        if ($Expanded -and $step.Detail) {
            ($step.Detail -split "`n") | ForEach-Object {
                Write-Host "  $($c.Slate)$($b.V)$($c.Reset)    $($c.Dim)$_$($c.Reset)"
            }
        }
        $i++
    }
    Write-Host "  $($c.Slate)$($b.BL)$($b.DH*$w)$($b.BR)$($c.Reset)"; Write-Host ""
}

function script:Write-DirectivesBlock {
    param([PSCustomObject[]]$Directives)
    $c = $script:C; $b = $script:Box
    Write-Host ""; script:Write-Rule -Label "MODULE DIRECTIVES ($($Directives.Count))" -Color $c.Slate
    foreach ($d in $Directives) {
        Write-Host "  $($c.Amber)$($b.Bullet)$($c.Reset) $($c.Cyan)$($d.Module)$($c.Reset) $($c.Silver)v$($d.Version)$($c.Reset)  $($c.Dim)$($d.ModuleBase)$($c.Reset)"
        $preview = ($d.Directive -split "`n" | Select-Object -First 3) -join ' · '
        if ($preview.Length -gt 100) { $preview = $preview.Substring(0,97) + '…' }
        Write-Host "    $($c.Dim)$preview$($c.Reset)"
    }
    Write-Host ""
}

function script:Write-Status {
    param([string]$Msg, [string]$Kind='info')
    $c = $script:C; $b = $script:Box
    $ic = switch ($Kind) {
        'ok'   { "$($c.Green)$($b.Tick)" }
        'err'  { "$($c.Red)$($b.X)" }
        'warn' { "$($c.Yellow)$($b.Warn)" }
        default{ "$($c.Cyan)$($b.Arrow)" }
    }
    Write-Host "  $ic$($c.Reset) $($c.Silver)$Msg$($c.Reset)"
}

function script:Write-Prompt {
    param([string]$Id, [int]$Turn)
    $c = $script:C; $b = $script:Box
    Write-Host -NoNewline "$($c.Amber)$($b.Bullet)$($c.Reset) $($c.Silver)[$Id · t$Turn]$($c.Reset) $($c.Cyan)$($b.Arrow)$($c.Reset) "
}

# ══════════════════════════════════════════════════════════════════════════════
#  PROVIDER TABLE
# ══════════════════════════════════════════════════════════════════════════════

$script:Providers = @{
    Anthropic = @{
        BaseUrl      = 'https://api.anthropic.com/v1/messages'
        EnvKeyName   = 'ANTHROPIC_API_KEY'
        DefaultModel = 'claude-sonnet-4-6'
        Models       = @('claude-opus-4-6','claude-sonnet-4-6','claude-haiku-4-5-20251001')
    }
    OpenAI = @{
        BaseUrl      = 'https://api.openai.com/v1/chat/completions'
        EnvKeyName   = 'OPENAI_API_KEY'
        DefaultModel = 'gpt-4o'
        Models       = @('gpt-4o','gpt-4o-mini','gpt-4-turbo','o1','o3-mini')
    }
}

# Verbs whose presence in an expression requires user confirmation
$script:DestructivePattern = '^(Remove|Stop|Kill|Format|Clear|Reset|Disable|Uninstall|Delete|Erase|Purge|Drop|Revoke|Deny)-'

# The single tool definition exposed to all providers
$script:AgentTool = @{
    name        = 'invoke_powershell'
    description = 'Execute any PowerShell expression and receive the result as JSON. Use real cmdlets and pipelines. All loaded modules and their claude.md directives are available.'
    input_schema = @{
        type       = 'object'
        required   = @('expression')
        properties = @{
            expression = @{
                type        = 'string'
                description = 'A valid PowerShell expression or pipeline. Output will be serialized with ConvertTo-Json and returned to you.'
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  ENVIRONMENT  &  MODULE DIRECTIVES
# ══════════════════════════════════════════════════════════════════════════════

function Get-LLMEnvironment {
<#
.SYNOPSIS
    Returns a live snapshot of the current PowerShell environment as a rich object.
    Automatically injected into system prompts when -WithEnvironment is used.
#>
    [CmdletBinding()]
    param()
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

    foreach ($mod in $modules) {
        $path = Join-Path $mod.ModuleBase 'claude.md'
        if (Test-Path $path) {
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

        # Inject all discovered claude.md directives
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
- For destructive operations (Remove-, Stop-, Format- etc.) always warn the user before acting.
- If a module has a claude.md directive, follow its conventions exactly.
"@)
    }

    if ($UserSystemPrompt) { $sections.Add($UserSystemPrompt) }
    ($sections -join "`n`n").Trim()
}

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
        [PSCustomObject[]]$ToolCalls = @()
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
    # Raw call — returns the full response object. Used by both completion and agent loops.
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
    # Standard (non-agentic) completion — returns [LLMResponse]
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

# ══════════════════════════════════════════════════════════════════════════════
#  DESTRUCTIVE GUARD
# ══════════════════════════════════════════════════════════════════════════════

function script:Test-IsDestructive([string]$Expression) {
    # Split on pipe and semicolons, check each segment for a destructive verb
    $segments = $Expression -split '[|;]'
    foreach ($seg in $segments) {
        $cmd = $seg.Trim() -replace '^\s*[\(&]*\s*', ''
        if ($cmd -match $script:DestructivePattern) { return $true }
    }
    return $false
}

function script:Invoke-GuardedExpression {
    param([string]$Expression, [bool]$AutoConfirm=$false)

    $isDestructive = script:Test-IsDestructive $Expression
    $confirmEnv    = [System.Environment]::GetEnvironmentVariable('LLM_CONFIRM_DANGEROUS')
    $skipConfirm   = $AutoConfirm -or ($confirmEnv -eq '0')

    if ($isDestructive -and -not $skipConfirm) {
        script:Write-ConfirmBox -Expression $Expression
        $answer = $Host.UI.ReadLine()
        if ($answer -notmatch '^[Yy]$') {
            return [PSCustomObject]@{
                Output  = '{"error":"User denied execution of destructive expression."}'
                IsError = $true
                Denied  = $true
            }
        }
    }

    try {
        $result = Invoke-Expression $Expression 2>&1
        $json   = $result | ConvertTo-Json -Compress -Depth 6 -ErrorAction Stop
        [PSCustomObject]@{ Output=$json; IsError=$false; Denied=$false }
    } catch {
        [PSCustomObject]@{
            Output  = "{`"error`":`"$($_.ToString() -replace '"','\"')`"}"
            IsError = $true
            Denied  = $false
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  AGENTIC LOOP HELPERS
# ══════════════════════════════════════════════════════════════════════════════

function script:Extract-AnthropicToolCalls($RawContent) {
    $RawContent | Where-Object { $_.type -eq 'tool_use' }
}

function script:Extract-AnthropicText($RawContent) {
    ($RawContent | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
}

function script:Build-AnthropicToolResult($ToolUseId, $Output) {
    @{ type='tool_result'; tool_use_id=$ToolUseId; content=$Output }
}

function script:Extract-OpenAIToolCalls($Choice) {
    $Choice.message.tool_calls
}

function script:Build-OpenAIToolResult($ToolCallId, $Output) {
    @{ role='tool'; tool_call_id=$ToolCallId; content=$Output }
}

# ══════════════════════════════════════════════════════════════════════════════
#  PUBLIC CMDLETS
# ══════════════════════════════════════════════════════════════════════════════

function Invoke-LLM {
<#
.SYNOPSIS
    Send one or more prompts to an LLM. Returns rich [LLMResponse] objects.

.PARAMETER Prompt
    User prompt. Accepts pipeline input.
.PARAMETER Provider
    Anthropic or OpenAI. Falls back to $env:LLM_DEFAULT_PROVIDER then Anthropic.
.PARAMETER Model
    Model override.
.PARAMETER SystemPrompt
    Instruction/system prompt.
.PARAMETER MaxTokens
    Max response tokens. Default 1024.
.PARAMETER Temperature
    Sampling temperature 0.0–2.0.
.PARAMETER WithEnvironment
    Inject PS environment snapshot and all claude.md directives into the system prompt.
.PARAMETER Quiet
    Suppress console rendering. Only emit the object.

.EXAMPLE
    Invoke-LLM "What modules do I have for HTTP?" -Provider Anthropic -WithEnvironment
.EXAMPLE
    Get-Content prompts.txt | Invoke-LLM -Provider OpenAI -Quiet | Export-Csv out.csv
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position=0)]
        [string]$Prompt,

        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,
        [string]$SystemPrompt = '',

        [ValidateRange(1,32768)]
        [int]$MaxTokens = 1024,

        [ValidateRange(0.0,2.0)]
        [double]$Temperature,

        [switch]$WithEnvironment,
        [switch]$Quiet
    )
    begin {
        if (-not $Provider) { $Provider = $env:LLM_DEFAULT_PROVIDER ?? 'Anthropic' }
        if (-not $Model)    { $Model    = $script:Providers[$Provider].DefaultModel }
    }
    process {
        $p = @{
            Provider=    $Provider; Model=$Model; SystemPrompt=$SystemPrompt
            Messages=    @(@{role='user';content=$Prompt})
            MaxTokens=   $MaxTokens; WithEnv=$WithEnvironment.IsPresent
        }
        if ($PSBoundParameters.ContainsKey('Temperature')) { $p.Temperature = $Temperature }
        $resp = script:Invoke-ProviderCompletion @p

        if (-not $Quiet) {
            script:Write-ResponseBox -Content $resp.Content -Provider $resp.Provider `
                -Model $resp.Model -InputTokens $resp.InputTokens `
                -OutputTokens $resp.OutputTokens -StopReason $resp.StopReason `
                -ElapsedSec $resp.ElapsedSec
            if ($resp.Steps.Count -gt 0) {
                script:Write-Status "Response has $($resp.Steps.Count) steps — use Expand-LLMProcess for detail" 'info'
                Write-Host ""
            }
        }
        $resp
    }
}

function Invoke-LLMAgent {
<#
.SYNOPSIS
    Run an agentic completion loop where the LLM can call back into PowerShell.

.DESCRIPTION
    The LLM is given one tool: invoke_powershell, which accepts any PS expression.
    The harness executes it via Invoke-Expression, serializes the result with
    ConvertTo-Json, and feeds it back. The loop continues until the LLM stops
    issuing tool calls (stop_reason = end_turn) or MaxTurns is reached.

    Destructive expressions (Remove-, Stop-, Format- etc.) require interactive
    confirmation unless -AutoConfirm is set or LLM_CONFIRM_DANGEROUS=0.

    All loaded module claude.md directives are injected automatically, giving
    the LLM a complete picture of what it can invoke.

.PARAMETER Prompt
    The task to accomplish. Accepts pipeline input.
.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override.
.PARAMETER SystemPrompt
    Additional system instructions appended after environment context.
.PARAMETER MaxTokens
    Max tokens per completion turn. Default 2048.
.PARAMETER MaxTurns
    Maximum tool-call iterations before stopping. Default 10.
.PARAMETER AutoConfirm
    Skip destructive-verb confirmation prompts. Use with caution.
.PARAMETER Quiet
    Suppress per-call console rendering.

.EXAMPLE
    Invoke-LLMAgent "What process is consuming the most memory? Show name and MB." -Provider Anthropic

.EXAMPLE
    Invoke-LLMAgent "List all loaded modules that have a claude.md directive" -Provider Anthropic
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position=0)]
        [string]$Prompt,

        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,
        [string]$SystemPrompt = '',

        [ValidateRange(1,32768)]
        [int]$MaxTokens = 2048,

        [ValidateRange(1,50)]
        [int]$MaxTurns = 10,

        [switch]$AutoConfirm,
        [switch]$Quiet
    )
    begin {
        if (-not $Provider) { $Provider = $env:LLM_DEFAULT_PROVIDER ?? 'Anthropic' }
        if (-not $Model)    { $Model    = $script:Providers[$Provider].DefaultModel }
    }
    process {
        $sys      = script:Build-SystemPrompt -UserSystemPrompt $SystemPrompt -IncludeEnv $true
        $messages = [System.Collections.Generic.List[object]]::new()
        $messages.Add(@{role='user';content=$Prompt})
        $allToolCalls = [System.Collections.Generic.List[PSCustomObject]]::new()
        $totalIn  = 0; $totalOut = 0; $totalSec = 0.0
        $turns    = 0; $finalText = ''

        if (-not $Quiet) {
            Write-Host ""
            script:Write-Rule -Label "AGENT  $($script:Box.Gear)  $Prompt" -Color $script:C.Cyan
            Write-Host ""
        }

        do {
            $p   = @{ Model=$Model; SystemPrompt=$sys; Messages=$messages.ToArray(); MaxTokens=$MaxTokens }
            $raw = switch ($Provider) {
                'Anthropic' { script:Invoke-AnthropicRaw @p -Tools @($script:AgentTool) }
                'OpenAI'    { script:Invoke-OpenAIRaw    @p -Tools @($script:AgentTool) }
            }
            $r        = $raw.Response
            $totalSec += $raw.ElapsedSec
            $turns++

            switch ($Provider) {
                'Anthropic' {
                    $totalIn  += $r.usage.input_tokens
                    $totalOut += $r.usage.output_tokens
                    $stopReason = $r.stop_reason
                    $toolCalls  = script:Extract-AnthropicToolCalls $r.content
                    $textNow    = script:Extract-AnthropicText $r.content
                    # Append full assistant turn
                    $messages.Add(@{role='assistant';content=$r.content})

                    if ($toolCalls) {
                        $toolResults = [System.Collections.Generic.List[object]]::new()
                        foreach ($tc in $toolCalls) {
                            $expr   = $tc.input.expression
                            $guarded = script:Invoke-GuardedExpression -Expression $expr -AutoConfirm $AutoConfirm.IsPresent
                            $tcObj  = [PSCustomObject]@{
                                PSTypeName = 'LLMToolCall'
                                CallNum    = $allToolCalls.Count + 1
                                Expression = $expr
                                Output     = $guarded.Output
                                IsError    = $guarded.IsError
                                Denied     = $guarded.Denied
                            }
                            $allToolCalls.Add($tcObj)
                            if (-not $Quiet) {
                                script:Write-ToolCallBox -Expression $expr -Result $guarded.Output `
                                    -IsError $guarded.IsError -CallNum $tcObj.CallNum
                            }
                            $toolResults.Add((script:Build-AnthropicToolResult $tc.id $guarded.Output))
                        }
                        $messages.Add(@{role='user';content=$toolResults.ToArray()})
                    }
                    if ($textNow) { $finalText = $textNow }
                }

                'OpenAI' {
                    $totalIn  += $r.usage.prompt_tokens
                    $totalOut += $r.usage.completion_tokens
                    $choice     = $r.choices[0]
                    $stopReason = $choice.finish_reason
                    $toolCalls  = script:Extract-OpenAIToolCalls $choice
                    $textNow    = $choice.message.content
                    $messages.Add(@{role='assistant'; content=$choice.message.content; tool_calls=$choice.message.tool_calls})

                    if ($toolCalls) {
                        foreach ($tc in $toolCalls) {
                            $expr    = ($tc.function.arguments | ConvertFrom-Json).expression
                            $guarded = script:Invoke-GuardedExpression -Expression $expr -AutoConfirm $AutoConfirm.IsPresent
                            $tcObj   = [PSCustomObject]@{
                                PSTypeName = 'LLMToolCall'
                                CallNum    = $allToolCalls.Count + 1
                                Expression = $expr
                                Output     = $guarded.Output
                                IsError    = $guarded.IsError
                                Denied     = $guarded.Denied
                            }
                            $allToolCalls.Add($tcObj)
                            if (-not $Quiet) {
                                script:Write-ToolCallBox -Expression $expr -Result $guarded.Output `
                                    -IsError $guarded.IsError -CallNum $tcObj.CallNum
                            }
                            $messages.Add((script:Build-OpenAIToolResult $tc.id $guarded.Output))
                        }
                    }
                    if ($textNow) { $finalText = $textNow }
                }
            }

        } while ($stopReason -eq 'tool_use' -and $turns -lt $MaxTurns)

        $resp = script:New-ResponseObj -Provider $Provider -Model $Model -Content $finalText `
            -InputTokens $totalIn -OutputTokens $totalOut -StopReason $stopReason `
            -ResponseId '' -ElapsedSec $totalSec -Raw $null -ToolCalls $allToolCalls.ToArray()

        if (-not $Quiet) {
            script:Write-ResponseBox -Content $finalText -Provider $Provider -Model $Model `
                -InputTokens $totalIn -OutputTokens $totalOut -StopReason $stopReason `
                -ElapsedSec $totalSec
            script:Write-Status "Agent completed · $turns turn(s) · $($allToolCalls.Count) tool call(s) · $($totalIn+$totalOut) tokens" 'ok'
            Write-Host ""
        }
        $resp
    }
}

function New-LLMChat {
<#
.SYNOPSIS
    Create a stateful multi-turn [LLMChat] session object.

.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override.
.PARAMETER SystemPrompt
    Instruction prompt applied to every turn.
.PARAMETER MaxTokens
    Max tokens per reply. Default 1024.
.PARAMETER WithEnvironment
    Inject PS environment and claude.md directives on every turn.
.PARAMETER Name
    Human-readable session name (auto-generated if omitted).
.PARAMETER Agentic
    Enable tool use inside this chat session (LLM can call PS expressions).

.EXAMPLE
    $chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Ops"
    Enter-LLMChat $chat
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,
        [string]$SystemPrompt = '',

        [ValidateRange(1,32768)]
        [int]$MaxTokens = 1024,

        [switch]$WithEnvironment,
        [switch]$Agentic,
        [string]$Name
    )
    if (-not $Model) { $Model = $script:Providers[$Provider].DefaultModel }
    if (-not $Name)  { $Name  = "$Provider-$(Get-Random -Max 9999)" }

    [PSCustomObject]@{
        PSTypeName      = 'LLMChat'
        Id              = $Name
        Provider        = $Provider
        Model           = $Model
        SystemPrompt    = $SystemPrompt
        MaxTokens       = $MaxTokens
        WithEnvironment = $WithEnvironment.IsPresent
        Agentic         = $Agentic.IsPresent
        History         = [System.Collections.Generic.List[PSCustomObject]]::new()
        Responses       = [System.Collections.Generic.List[PSCustomObject]]::new()
        TotalTokensUsed = 0
        TurnCount       = 0
        CreatedAt       = [datetime]::UtcNow
        LastSwarm       = $null
    }
}

function Send-LLMMessage {
<#
.SYNOPSIS
    Send one message in an [LLMChat] session and receive an [LLMResponse].

.PARAMETER Chat
    An [LLMChat] from New-LLMChat. Accepts pipeline input.
.PARAMETER Message
    The user-turn message.
.PARAMETER Quiet
    Suppress console rendering.

.EXAMPLE
    $chat | Send-LLMMessage "Show me how to parse JSON in PS"
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Chat,

        [Parameter(Mandatory, Position=0)]
        [string]$Message,

        [switch]$Quiet
    )
    process {
        if ($Chat.Agentic) {
            # Route through agent loop for agentic chats
            $resp = Invoke-LLMAgent -Prompt $Message -Provider $Chat.Provider -Model $Chat.Model `
                -SystemPrompt $Chat.SystemPrompt -MaxTokens $Chat.MaxTokens -Quiet:$Quiet
        } else {
            $msgs = $Chat.History | ForEach-Object { @{role=$_.Role;content=$_.Content} }
            $msgs += @{role='user';content=$Message}
            $p = @{
                Provider=$Chat.Provider; Model=$Chat.Model; SystemPrompt=$Chat.SystemPrompt
                Messages=$msgs; MaxTokens=$Chat.MaxTokens; WithEnv=$Chat.WithEnvironment
            }
            $resp = script:Invoke-ProviderCompletion @p
            if (-not $Quiet) {
                script:Write-ResponseBox -Content $resp.Content -Provider $resp.Provider `
                    -Model $resp.Model -InputTokens $resp.InputTokens `
                    -OutputTokens $resp.OutputTokens -StopReason $resp.StopReason `
                    -ElapsedSec $resp.ElapsedSec
                if ($resp.Steps.Count -gt 0) {
                    script:Write-Status "Response has $($resp.Steps.Count) steps — use /expand to inspect" 'info'
                    Write-Host ""
                }
            }
        }

        $Chat.History.Add([PSCustomObject]@{Role='user';     Content=$Message})
        $Chat.History.Add([PSCustomObject]@{Role='assistant';Content=$resp.Content})
        $Chat.Responses.Add($resp)
        $Chat.TotalTokensUsed += $resp.TotalTokens
        $Chat.TurnCount++
        $resp
    }
}

function Enter-LLMChat {
<#
.SYNOPSIS
    Enter an interactive REPL inside an [LLMChat] session.
    Type /help for all commands.  /exit or Ctrl+C to leave.

.PARAMETER Chat
    An [LLMChat] from New-LLMChat. Accepts pipeline input.

.EXAMPLE
    $chat = New-LLMChat -Provider Anthropic -WithEnvironment -Agentic -Name "Dev"
    Enter-LLMChat $chat
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Chat
    )
    process {
        $c = $script:C; $b = $script:Box
        script:Write-Banner
        $agentTag = if ($Chat.Agentic) { "$($c.Green) agentic$($c.Reset)" } else { '' }
        script:Write-Status "Entering  $($Chat.Id)  ·  $($Chat.Provider)  ·  $($Chat.Model)$agentTag" 'ok'
        script:Write-Status "Type /help for commands  ·  /exit to leave" 'info'
        Write-Host ""

        $last = $null

        while ($true) {
            script:Write-Prompt -Id $Chat.Id -Turn ($Chat.TurnCount + 1)
            $line = $Host.UI.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            switch -Regex ($line.Trim()) {

                '^/(exit|quit|bye)$' {
                    Write-Host ""
                    script:Write-Status "Left  $($Chat.Id)  ·  $($Chat.TurnCount) turns  ·  $($Chat.TotalTokensUsed) tokens" 'ok'
                    script:Write-Rule
                    return
                }

                '^/help$' {
                    $rows = @(
                        '/help',                'Show this reference'
                        '/exit  /quit',         'Leave the chat session'
                        '/history',             'Print conversation history'
                        '/env',                 'Show the PS environment snapshot'
                        '/directives',          'List discovered claude.md module directives'
                        '/expand',              'Expand steps in the last response'
                        '/expand <N>',          'Expand steps in response N (1-based)'
                        '/tools',               'Show tool calls made in the last response'
                        '/stats',               'Token usage and session info'
                        '/clear',               'Clear the screen'
                        '/model <name>',        'Switch model mid-session'
                        '/system <text>',       'Replace the system prompt'
                        '/agentic on|off',      'Toggle agentic tool-use mode'
                        '/swarm <goal>',        'Spawn a parallel swarm from this chat'
                        '/swarm-results',       'Show task breakdown from last swarm'
                        '/run <expression>',    'Execute a PS expression locally and print result'
                    )
                    Write-Host ""
                    Write-Host "  $($c.Amber)$($c.Bold)CHAT COMMANDS$($c.Reset)"
                    script:Write-Rule -Color $c.Slate
                    for ($i = 0; $i -lt $rows.Count; $i += 2) {
                        Write-Host "  $($c.Cyan)$($rows[$i].PadRight(22))$($c.Reset)$($c.Silver)$($rows[$i+1])$($c.Reset)"
                    }
                    Write-Host ""
                    continue
                }

                '^/history$' {
                    Write-Host ""; script:Write-Rule -Label 'HISTORY' -Color $c.Slate
                    $n = 1
                    foreach ($t in $Chat.History) {
                        $rc  = if ($t.Role -eq 'user') { $c.Cyan } else { $c.Amber }
                        $pre = if ($t.Content.Length -gt 110) { $t.Content.Substring(0,107)+'...' } else { $t.Content }
                        Write-Host "  $($c.Silver)$($n.ToString().PadLeft(3))$($c.Reset)  $rc$($t.Role.ToUpper().PadRight(10))$($c.Reset)  $($c.White)$pre$($c.Reset)"
                        $n++
                    }
                    Write-Host ""
                    continue
                }

                '^/env$' {
                    $e = Get-LLMEnvironment
                    Write-Host ""; script:Write-Rule -Label 'ENVIRONMENT' -Color $c.Slate
                    Write-Host "  $($c.Silver)PS Version    $($c.Reset)$($e.PSVersion)"
                    Write-Host "  $($c.Silver)OS            $($c.Reset)$($e.OS)"
                    Write-Host "  $($c.Silver)Platform      $($c.Reset)$($e.Platform) / $($e.Architecture)"
                    Write-Host "  $($c.Silver)Directory     $($c.Reset)$($e.CurrentDirectory)"
                    Write-Host "  $($c.Silver)User          $($c.Reset)$($e.UserName) @ $($e.MachineName)"
                    $ml = ($e.LoadedModules | Select-Object -First 10 | ForEach-Object { $_.Name }) -join ', '
                    Write-Host "  $($c.Silver)Modules ($($e.ModuleCount))  $($c.Reset)$ml…"
                    Write-Host "  $($c.Silver)Commands      $($c.Reset)$($e.CommandCount)"
                    Write-Host ""
                    continue
                }

                '^/directives$' {
                    $directives = @(Get-LLMModuleDirectives)
                    if ($directives.Count -eq 0) {
                        script:Write-Status 'No claude.md directives found in loaded modules' 'warn'
                    } else {
                        script:Write-DirectivesBlock -Directives $directives
                    }
                    continue
                }

                '^/expand$' {
                    if ($null -eq $last) { script:Write-Status 'No response yet' 'warn'; continue }
                    if ($last.Steps.Count -eq 0) { script:Write-Status 'No structured steps in last response' 'warn'; continue }
                    Write-Host ""; script:Write-Rule -Label "STEPS — last response ($($last.Steps.Count))" -Color $c.Slate
                    script:Write-StepsBlock -Steps $last.Steps -Expanded $true
                    continue
                }

                '^/expand\s+(\d+)$' {
                    $idx = [int]$Matches[1] - 1
                    if ($idx -lt 0 -or $idx -ge $Chat.Responses.Count) {
                        script:Write-Status "Response $($Matches[1]) not found (session has $($Chat.Responses.Count))" 'warn'; continue
                    }
                    $tgt = $Chat.Responses[$idx]
                    if ($tgt.Steps.Count -eq 0) { script:Write-Status "Response $($Matches[1]) has no steps" 'warn'; continue }
                    Write-Host ""; script:Write-Rule -Label "STEPS — response $($Matches[1]) ($($tgt.Steps.Count))" -Color $c.Slate
                    script:Write-StepsBlock -Steps $tgt.Steps -Expanded $true
                    continue
                }

                '^/tools$' {
                    if ($null -eq $last) { script:Write-Status 'No response yet' 'warn'; continue }
                    if ($last.ToolCalls.Count -eq 0) { script:Write-Status 'Last response made no tool calls' 'info'; continue }
                    Write-Host ""; script:Write-Rule -Label "TOOL CALLS ($($last.ToolCalls.Count))" -Color $c.Slate
                    foreach ($tc in $last.ToolCalls) {
                        script:Write-ToolCallBox -Expression $tc.Expression -Result $tc.Output `
                            -IsError $tc.IsError -CallNum $tc.CallNum
                    }
                    continue
                }

                '^/stats$' {
                    Write-Host ""; script:Write-Rule -Label 'SESSION STATS' -Color $c.Slate
                    Write-Host "  $($c.Silver)Session       $($c.Reset)$($Chat.Id)"
                    Write-Host "  $($c.Silver)Provider      $($c.Reset)$($Chat.Provider)"
                    Write-Host "  $($c.Silver)Model         $($c.Reset)$($Chat.Model)"
                    Write-Host "  $($c.Silver)Agentic       $($c.Reset)$($Chat.Agentic)"
                    Write-Host "  $($c.Silver)Turns         $($c.Reset)$($Chat.TurnCount)"
                    Write-Host "  $($c.Silver)Tokens used   $($c.Reset)$($Chat.TotalTokensUsed)"
                    if ($Chat.Responses.Count -gt 0) {
                        $avg = [math]::Round(($Chat.Responses | Measure-Object ElapsedSec -Average).Average,2)
                        Write-Host "  $($c.Silver)Avg latency   $($c.Reset)${avg}s"
                        $tc = ($Chat.Responses | ForEach-Object { $_.ToolCalls.Count } | Measure-Object -Sum).Sum
                        Write-Host "  $($c.Silver)Tool calls    $($c.Reset)$tc"
                    }
                    Write-Host "  $($c.Silver)Started       $($c.Reset)$($Chat.CreatedAt.ToString('u'))"
                    Write-Host ""
                    continue
                }

                '^/clear$' {
                    Clear-Host; script:Write-Banner
                    continue
                }

                '^/model\s+(.+)$' {
                    $Chat.Model = $Matches[1].Trim()
                    script:Write-Status "Model → $($Chat.Model)" 'ok'
                    continue
                }

                '^/system\s+(.+)$' {
                    $Chat.SystemPrompt = $Matches[1].Trim()
                    script:Write-Status "System prompt updated" 'ok'
                    continue
                }

                '^/agentic\s+(on|off)$' {
                    $Chat.Agentic = ($Matches[1] -eq 'on')
                    $state = if ($Chat.Agentic) { "$($c.Green)enabled$($c.Reset)" } else { "$($c.Silver)disabled$($c.Reset)" }
                    script:Write-Status "Agentic mode $state" 'ok'
                    continue
                }

                '^/swarm\s+(.+)$' {
                    $swarmGoal = $Matches[1].Trim()
                    script:Write-Status "Launching swarm from chat $($Chat.Id)…" 'info'
                    try {
                        $swResult = Invoke-LLMSwarm -Goal $swarmGoal -Provider $Chat.Provider -Model $Chat.Model
                        $Chat.LastSwarm = $swResult
                        $Chat.TotalTokensUsed += $swResult.TotalTokens
                        # Inject synthesis back into chat history so the conversation continues coherently
                        $Chat.History.Add([PSCustomObject]@{Role='user';     Content="[SWARM] $swarmGoal"})
                        $Chat.History.Add([PSCustomObject]@{Role='assistant';Content=$swResult.Synthesis})
                        $Chat.TurnCount++
                    } catch {
                        script:Write-Status "Swarm failed: $_" 'err'
                    }
                    continue
                }

                '^/swarm-results$' {
                    if ($null -eq $Chat.LastSwarm) {
                        script:Write-Status 'No swarm has run in this session yet' 'warn'; continue
                    }
                    Write-Host ""; script:Write-Rule -Label "SWARM TASKS ($($Chat.LastSwarm.Tasks.Count))" -Color $c.Slate
                    foreach ($t in $Chat.LastSwarm.Tasks) { script:Write-SwarmTaskLine -Task $t }
                    Write-Host ""
                    continue
                }

                '^/run\s+(.+)$' {
                    $expr = $Matches[1].Trim()
                    try {
                        Write-Host ""; script:Write-Rule -Label "PS › $expr" -Color $c.Slate
                        Invoke-Expression $expr 2>&1 | ForEach-Object {
                            Write-Host "  $($c.Dim)$_$($c.Reset)"
                        }
                        Write-Host ""
                    } catch {
                        script:Write-Status "Error: $_" 'err'
                    }
                    continue
                }

                default {
                    $last = Send-LLMMessage -Chat $Chat -Message $line
                    if ($last.Steps.Count -gt 0) {
                        script:Write-StepsBlock -Steps $last.Steps -Expanded $false
                    }
                }
            }
        }
    }
}

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

# ══════════════════════════════════════════════════════════════════════════════
#  SWARM ORCHESTRATION
# ══════════════════════════════════════════════════════════════════════════════
#
#  Architecture
#  ────────────
#  Invoke-LLMSwarm runs an ORCHESTRATOR completion that decomposes the goal
#  into a JSON task list. Each task becomes a PS ThreadJob that runs its own
#  Invoke-LLMAgent completion in an isolated runspace. Tasks can declare
#  DependsOn, forming a DAG — the dispatcher releases each task only once all
#  its dependencies have finished successfully.
#
#  Thread communication uses a [ConcurrentDictionary] shared across runspaces:
#    $script:SwarmShared["result::<taskId>"] = <json>    set by workers
#    $script:SwarmShared["status::<taskId>"] = <status>  running|done|failed
#
#  The orchestrator receives all worker results and runs a SYNTHESIS completion
#  to produce a final coherent answer.
#
#  Object graph
#  ────────────
#  [LLMSwarmResult]
#    .Goal          string
#    .Tasks         [LLMSwarmTask[]]
#      .Id, .Name, .Prompt, .DependsOn, .Status, .Result, .Error, .ElapsedSec
#    .Synthesis     string          — orchestrator final answer
#    .TotalTokens   int
#    .TotalSec      double
#    .StartedAt     datetime

$script:SwarmShared = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

# ── Render helpers (swarm-specific) ──────────────────────────────────────────

function script:Write-SwarmHeader {
    param([string]$Goal, [int]$TaskCount)
    $c = $script:C; $b = $script:Box; $w = script:Get-Width
    $label = " SWARM  $($b.Bullet)  $TaskCount tasks "
    $lp = $b.H * 3; $rp = $b.H * [Math]::Max(2, $w - $label.Length - 8)
    Write-Host ""
    Write-Host "$($c.Cyan)$lp$($c.Bold)$label$($c.Reset)$($c.Cyan)$rp$($c.Reset)"
    Write-Host "  $($c.Silver)Goal:$($c.Reset) $($c.White)$Goal$($c.Reset)"
    Write-Host ""
}

function script:Write-SwarmTaskLine {
    param([PSCustomObject]$Task, [string]$Override='')
    $c = $script:C; $b = $script:Box
    $status = if ($Override) { $Override } else { $Task.Status }
    $icon = switch ($status) {
        'pending'  { "$($c.Slate)○$($c.Reset)" }
        'waiting'  { "$($c.Yellow)◔$($c.Reset)" }
        'running'  { "$($c.Cyan)◕$($c.Reset)" }
        'done'     { "$($c.Green)$($b.Tick)$($c.Reset)" }
        'failed'   { "$($c.Red)$($b.X)$($c.Reset)" }
        'skipped'  { "$($c.Silver)—$($c.Reset)" }
        default    { "$($c.Silver)?$($c.Reset)" }
    }
    $depStr = if ($Task.DependsOn.Count -gt 0) { " $($c.Slate)← $($Task.DependsOn -join ', ')$($c.Reset)" } else { '' }
    $elapsed = if ($Task.ElapsedSec -gt 0) { " $($c.Dim)$([math]::Round($Task.ElapsedSec,1))s$($c.Reset)" } else { '' }
    Write-Host "  $icon $($c.Amber)$($Task.Id.PadRight(6))$($c.Reset) $($c.White)$($Task.Name)$($c.Reset)$depStr$elapsed"
}

function script:Write-SwarmSummary {
    param([PSCustomObject]$Result)
    $c = $script:C; $b = $script:Box; $w = script:Get-Width
    Write-Host ""
    script:Write-Rule -Label "SWARM COMPLETE" -Color $c.Cyan
    $done    = @($Result.Tasks | Where-Object Status -eq 'done').Count
    $failed  = @($Result.Tasks | Where-Object Status -eq 'failed').Count
    $skipped = @($Result.Tasks | Where-Object Status -eq 'skipped').Count
    Write-Host "  $($c.Silver)Tasks      $($c.Reset)$($c.Green)$done done$($c.Reset)  $($c.Red)$failed failed$($c.Reset)  $($c.Slate)$skipped skipped$($c.Reset)"
    Write-Host "  $($c.Silver)Tokens     $($c.Reset)$($Result.TotalTokens)"
    Write-Host "  $($c.Silver)Wall time  $($c.Reset)$([math]::Round($Result.TotalSec,2))s"
    Write-Host ""
    script:Write-Rule -Label "SYNTHESIS" -Color $c.Amber
    Write-Host ""
    # Render synthesis through the response box
    script:Write-ResponseBox -Content $Result.Synthesis -Provider $Result.Provider `
        -Model $Result.Model -InputTokens 0 -OutputTokens 0 `
        -StopReason 'synthesis' -ElapsedSec 0
}

# ── Orchestrator: decompose goal into task list ───────────────────────────────

function script:Invoke-OrchestratorDecompose {
    param([string]$Goal, [string]$Provider, [string]$Model, [string]$Context, [int]$MaxTasks)

    $schema = @"
You are a task orchestrator. Decompose the goal into parallel sub-tasks for specialist LLM agents.

Rules:
- Emit ONLY a raw JSON array, no markdown, no explanation.
- Each element: { "id": "t1", "name": "<short label>", "prompt": "<full task prompt>", "dependsOn": [] }
- "id" must be unique short strings: t1, t2, t3 …
- "dependsOn" is an array of ids that must complete before this task starts. Use [] for tasks that can run immediately.
- Maximum $MaxTasks tasks. Prefer parallelism — only add dependencies when the task genuinely needs prior results.
- Each "prompt" must be fully self-contained — the worker agent has no other context.
- If a task needs the result of a prior task, say so explicitly in the prompt: "Given the result from task <id>: {{result::<id>}}, ..."
  The harness will substitute {{result::<id>}} with the actual JSON result before dispatching.

Context about the environment:
$Context

Goal: $Goal
"@

    $resp = script:Invoke-ProviderCompletion -Provider $Provider -Model $Model `
        -SystemPrompt $schema -Messages @(@{role='user';content="Decompose this goal into tasks."}) `
        -MaxTokens 2048 -WithEnv $false

    # Strip any accidental markdown fences
    $json = $resp.Content -replace '```json',''-replace '```','' -replace '(?s)^[^[\{]*','' | ForEach-Object { $_.Trim() }
    try {
        $tasks = $json | ConvertFrom-Json
        return @{ Tasks=$tasks; Tokens=$resp.TotalTokens }
    } catch {
        throw "Orchestrator failed to produce valid JSON task list: $_`nRaw: $($resp.Content)"
    }
}

# ── Worker scriptblock — runs inside each RunspacePool runspace ───────────────

$script:WorkerBlock = {
    param(
        [string]$TaskId,
        [string]$TaskPrompt,
        [string]$Provider,
        [string]$Model,
        [System.Collections.Concurrent.ConcurrentDictionary[string,string]]$Shared
    )

    try {
        $Shared["status::$TaskId"] = 'running'
        $resp = Invoke-LLMAgent -Prompt $TaskPrompt -Provider $Provider -Model $Model -Quiet
        $out  = [PSCustomObject]@{
            TaskId       = $TaskId
            Content      = $resp.Content
            TotalTokens  = $resp.TotalTokens
            ElapsedSec   = $resp.ElapsedSec
            ToolCallCount= @($resp.ToolCalls).Count
        } | ConvertTo-Json -Compress -Depth 4
        $Shared["result::$TaskId"]  = $out
        $Shared["status::$TaskId"]  = 'done'
    } catch {
        $Shared["result::$TaskId"]  = "{`"error`":`"$($_.ToString() -replace '"','\"')`"}"
        $Shared["status::$TaskId"]  = 'failed'
    }
}

# ── RunspacePool factory — clones the user's session for parallel workers ─────

function script:New-SwarmRunspacePool {
    param([int]$MaxRunspaces = 4)

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()

    # Import all currently loaded modules so workers inherit the full session context
    foreach ($mod in (Get-Module)) {
        $iss.ImportPSModule($mod.Name)
    }

    # Propagate environment variables (API keys, LLM config, build vars, etc.)
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $iss.EnvironmentVariables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                $entry.Key, $entry.Value, ''))
    }

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $MaxRunspaces, $iss, $Host)
    $pool.Open()
    $pool
}

# ── DAG dispatcher ────────────────────────────────────────────────────────────

function script:Invoke-SwarmDispatcher {
    param(
        [PSCustomObject[]]$Tasks,
        [string]$Provider,
        [string]$Model,
        [System.Collections.Concurrent.ConcurrentDictionary[string,string]]$Shared,
        [int]$MaxRunspaces = 4,
        [int]$PollMs = 400,
        [int]$TimeoutSec = 300
    )

    # Create RunspacePool from the current session
    $pool = script:New-SwarmRunspacePool -MaxRunspaces $MaxRunspaces

    # Build mutable task state table
    $state = @{}
    foreach ($t in $Tasks) {
        $state[$t.id] = [PSCustomObject]@{
            Id         = $t.id
            Name       = $t.name
            Prompt     = $t.prompt
            DependsOn  = @($t.dependsOn)
            Status     = 'pending'   # pending | waiting | running | done | failed | skipped
            Pipeline   = $null       # [PowerShell] instance
            AsyncResult= $null       # IAsyncResult from BeginInvoke
            StartedAt  = $null
            ElapsedSec = 0.0
            Result     = $null
            Error      = $null
        }
    }

    $startTime = [datetime]::UtcNow
    $allIds    = $state.Keys

    # Render initial task board
    foreach ($t in $state.Values) { script:Write-SwarmTaskLine -Task $t }
    Write-Host ""

    try {
        do {
            $anyProgress = $false

            foreach ($id in $allIds) {
                $t = $state[$id]
                if ($t.Status -notin 'pending','waiting') { continue }

                # Check if any dependency failed → skip this task
                $depFailed = @($t.DependsOn | Where-Object { $state[$_].Status -eq 'failed' -or $state[$_].Status -eq 'skipped' })
                if ($depFailed.Count -gt 0) {
                    $t.Status = 'skipped'
                    $t.Error  = "Skipped: dependency $($depFailed -join ', ') failed"
                    script:Write-SwarmTaskLine -Task $t
                    $anyProgress = $true
                    continue
                }

                # Check all deps done
                $depsReady = ($t.DependsOn.Count -eq 0) -or
                    ($t.DependsOn | ForEach-Object { $state[$_].Status } | Where-Object { $_ -ne 'done' } | Measure-Object).Count -eq 0

                if (-not $depsReady) {
                    if ($t.Status -ne 'waiting') { $t.Status = 'waiting'; script:Write-SwarmTaskLine -Task $t }
                    continue
                }

                # Substitute {{result::<id>}} placeholders from shared results
                $prompt = $t.Prompt
                foreach ($depId in $t.DependsOn) {
                    $depResult = $Shared["result::$depId"]
                    if ($depResult) {
                        $prompt = $prompt -replace "{{result::$depId}}", $depResult
                    }
                }

                # Launch worker on RunspacePool
                $t.Status    = 'running'
                $t.StartedAt = [datetime]::UtcNow
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                $null = $ps.AddScript($script:WorkerBlock).
                    AddArgument($id).
                    AddArgument($prompt).
                    AddArgument($Provider).
                    AddArgument($Model).
                    AddArgument($Shared)
                $t.Pipeline    = $ps
                $t.AsyncResult = $ps.BeginInvoke()

                script:Write-SwarmTaskLine -Task $t
                $anyProgress = $true
            }

            # Harvest completed pipelines
            foreach ($id in $allIds) {
                $t = $state[$id]
                if ($t.Status -ne 'running' -or $null -eq $t.Pipeline) { continue }

                if ($t.AsyncResult.IsCompleted) {
                    try { $t.Pipeline.EndInvoke($t.AsyncResult) } catch {}
                    $t.ElapsedSec = ([datetime]::UtcNow - $t.StartedAt).TotalSeconds
                    $t.Status     = $Shared["status::$id"] ?? 'failed'
                    $rawResult    = $Shared["result::$id"]

                    try {
                        $parsed   = $rawResult | ConvertFrom-Json
                        $t.Result = $parsed
                        if ($parsed.error) { $t.Error = $parsed.error }
                    } catch { $t.Result = $rawResult }

                    $t.Pipeline.Dispose()
                    $t.Pipeline    = $null
                    $t.AsyncResult = $null

                    script:Write-SwarmTaskLine -Task $t
                    $anyProgress = $true
                }
            }

            $allDone = ($state.Values | Where-Object { $_.Status -notin 'done','failed','skipped' } | Measure-Object).Count -eq 0
            if (-not $allDone) { Start-Sleep -Milliseconds $PollMs }

            # Timeout guard
            if (([datetime]::UtcNow - $startTime).TotalSeconds -gt $TimeoutSec) {
                script:Write-Status "Swarm timed out after ${TimeoutSec}s" 'warn'
                # Stop and dispose all running pipelines
                foreach ($id in $allIds) {
                    $t = $state[$id]
                    if ($t.Pipeline) {
                        $t.Pipeline.Stop()
                        $t.Pipeline.Dispose()
                        $t.Pipeline    = $null
                        $t.AsyncResult = $null
                        if ($t.Status -eq 'running') {
                            $t.Status    = 'failed'
                            $t.Error     = "Timed out after ${TimeoutSec}s"
                            $t.ElapsedSec= ([datetime]::UtcNow - $t.StartedAt).TotalSeconds
                            script:Write-SwarmTaskLine -Task $t
                        }
                    }
                    if ($t.Status -eq 'pending' -or $t.Status -eq 'waiting') {
                        $t.Status = 'skipped'
                        $t.Error  = 'Skipped: swarm timed out'
                        script:Write-SwarmTaskLine -Task $t
                    }
                }
                break
            }

        } while (-not $allDone)
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }

    return $state.Values
}

# ── Synthesis: orchestrator reassembles results ───────────────────────────────

function script:Invoke-OrchestratorSynthesize {
    param([string]$Goal, [PSCustomObject[]]$TaskResults, [string]$Provider, [string]$Model)

    $resultBlocks = $TaskResults | ForEach-Object {
        $content = if ($_.Result -and $_.Result.Content) { $_.Result.Content } else { $_.Error ?? 'no result' }
        "<task id=""$($_.Id)"" name=""$($_.Name)"" status=""$($_.Status)"">$content</task>"
    }

    $prompt = @"
Goal: $Goal

Worker results:
$($resultBlocks -join "`n")

Synthesize a single, coherent, well-structured answer to the original goal using all successful worker results.
Acknowledge any failed tasks and explain what impact that has on completeness.
"@

    $resp = script:Invoke-ProviderCompletion -Provider $Provider -Model $Model `
        -SystemPrompt 'You are a synthesis agent. Produce a clear, consolidated answer from the worker results provided.' `
        -Messages @(@{role='user';content=$prompt}) -MaxTokens 2048 -WithEnv $false

    return @{ Content=$resp.Content; Tokens=$resp.TotalTokens }
}

# ── Public: Invoke-LLMSwarm ───────────────────────────────────────────────────

function Invoke-LLMSwarm {
<#
.SYNOPSIS
    Decompose a goal into parallel sub-tasks, run them concurrently as worker
    agents, then synthesize the results — all driven by a single prompt.

.DESCRIPTION
    Phase 1  DECOMPOSE  — An orchestrator LLM call breaks the goal into a JSON
             task list with optional DependsOn relationships (a DAG).

    Phase 2  DISPATCH   — Each task runs as a PS ThreadJob in its own runspace,
             importing PwrCortex and calling Invoke-LLMAgent. Tasks with
             DependsOn wait until their dependencies complete. Results from
             prior tasks are substituted into dependent task prompts via
             {{result::<id>}} placeholders.

    Phase 3  SYNTHESIZE — The orchestrator receives all results and produces a
             single coherent final answer.

    The entire execution is non-blocking from the caller's perspective. A live
    task board renders in the console showing pending/waiting/running/done/failed
    status for every task as they change.

.PARAMETER Goal
    The top-level objective. Accepts pipeline input.
.PARAMETER Provider
    Anthropic or OpenAI.
.PARAMETER Model
    Model override (applies to all phases).
.PARAMETER MaxTasks
    Maximum tasks the orchestrator may create. Default 8.
.PARAMETER TimeoutSec
    Wall-clock timeout across all workers. Default 300s.
.PARAMETER Quiet
    Suppress the live task board and synthesis rendering.

.OUTPUTS
    [LLMSwarmResult] with .Tasks, .Synthesis, .TotalTokens, .TotalSec

.EXAMPLE
    Invoke-LLMSwarm "Audit this machine: running services, open ports, large processes, and disk usage" -Provider Anthropic

.EXAMPLE
    Invoke-LLMSwarm "Research and compare: PS 5.1 vs PS 7 module compatibility" -Provider Anthropic -MaxTasks 4

.EXAMPLE
    # Pipeline
    "Summarise all .log files in C:\Logs" | Invoke-LLMSwarm -Provider Anthropic
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position=0)]
        [string]$Goal,

        [ValidateSet('Anthropic','OpenAI')]
        [string]$Provider,

        [string]$Model,

        [ValidateRange(1,20)]
        [int]$MaxTasks = 8,

        [ValidateRange(30,3600)]
        [int]$TimeoutSec = 300,

        [switch]$Quiet
    )
    begin {
        if (-not $Provider) { $Provider = $env:LLM_DEFAULT_PROVIDER ?? 'Anthropic' }
        if (-not $Model)    { $Model    = $script:Providers[$Provider].DefaultModel }
    }
    process {
        $swStart = [System.Diagnostics.Stopwatch]::StartNew()
        $totalTokens = 0

        # ── Phase 1: Decompose ─────────────────────────────────────────────
        if (-not $Quiet) {
            script:Write-Status "Decomposing goal into tasks…" 'info'
        }
        $envContext = "PSVersion: $($PSVersionTable.PSVersion)  OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)"
        $decomp     = script:Invoke-OrchestratorDecompose -Goal $Goal -Provider $Provider `
            -Model $Model -Context $envContext -MaxTasks $MaxTasks
        $tasks      = $decomp.Tasks
        $totalTokens += $decomp.Tokens

        if (-not $Quiet) { script:Write-SwarmHeader -Goal $Goal -TaskCount $tasks.Count }

        # ── Phase 2: Dispatch DAG ─────────────────────────────────────────
        $script:SwarmShared.Clear()
        $finishedTasks = script:Invoke-SwarmDispatcher `
            -Tasks $tasks -Provider $Provider -Model $Model `
            -Shared $script:SwarmShared -MaxRunspaces ([Math]::Min($tasks.Count, 4)) `
            -TimeoutSec $TimeoutSec

        $finishedTasks | ForEach-Object {
            if ($_.Result -and ($_.Result.PSObject.Properties.Name -contains 'TotalTokens')) {
                $totalTokens += $_.Result.TotalTokens
            }
        }

        # ── Phase 3: Synthesize ───────────────────────────────────────────
        if (-not $Quiet) {
            Write-Host ""
            script:Write-Status "Synthesizing results…" 'info'
        }
        $synth = script:Invoke-OrchestratorSynthesize -Goal $Goal `
            -TaskResults $finishedTasks -Provider $Provider -Model $Model
        $totalTokens += $synth.Tokens
        $swStart.Stop()

        $result = [PSCustomObject]@{
            PSTypeName   = 'LLMSwarmResult'
            Goal         = $Goal
            Provider     = $Provider
            Model        = $Model
            Tasks        = $finishedTasks
            Synthesis    = $synth.Content
            TotalTokens  = $totalTokens
            TotalSec     = $swStart.Elapsed.TotalSeconds
            StartedAt    = [datetime]::UtcNow - $swStart.Elapsed
        }

        $dds = [System.Management.Automation.PSPropertySet]::new(
            'DefaultDisplayPropertySet',
            [string[]]@('Goal','TotalTokens','TotalSec','Synthesis'))
        $result.PSObject.Members.Add(
            [System.Management.Automation.PSMemberSet]::new('PSStandardMembers',[System.Management.Automation.PSMemberInfo[]]@($dds)))

        if (-not $Quiet) { script:Write-SwarmSummary -Result $result }

        return $result
    }
}

# ── Chat method: spawn a swarm from inside a chat ────────────────────────────
# Adds a /swarm command to Enter-LLMChat — handled by patching the REPL switch.
# The swarm result is stored on the chat as .LastSwarm for pipeline use.

# ══════════════════════════════════════════════════════════════════════════════
#  EXPORTS
# ══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
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

