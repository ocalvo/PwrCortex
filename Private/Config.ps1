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

# ── Preference propagation ────────────────────────────────────────────────────
# Public [CmdletBinding()] functions set local $VerbosePreference etc. but
# private module-scope functions don't inherit them. These helpers propagate
# and restore preferences so Write-Verbose/Debug/Warning work in private code.

function script:Push-Preferences {
    $script:_savedVerbose = if (Test-Path variable:script:VerbosePreference) { $script:VerbosePreference } else { 'SilentlyContinue' }
    $script:_savedDebug   = if (Test-Path variable:script:DebugPreference)   { $script:DebugPreference }   else { 'SilentlyContinue' }
    $script:_savedWarning = if (Test-Path variable:script:WarningPreference) { $script:WarningPreference } else { 'Continue' }
}

function script:Pop-Preferences {
    $script:VerbosePreference = $script:_savedVerbose
    $script:DebugPreference   = $script:_savedDebug
    $script:WarningPreference = $script:_savedWarning
}

# ── Global result auto-store ──────────────────────────────────────────────────
# Every agent/swarm response is stored in $global:llm_<type>_<N> so the user's
# session accumulates results that are available to subsequent calls.

# Initialize the session-wide result history stack (persists across calls)
if (-not (Get-Variable -Name 'llm_history' -Scope Global -ErrorAction SilentlyContinue)) {
    $global:llm_history = [System.Collections.Generic.List[PSCustomObject]]::new()
}

function script:Save-GlobalResult {
    param([string]$Type, [string]$Prompt, [object]$Result)
    # Build a slug from the prompt: keep meaningful words, drop noise
    $stopWords = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('the','a','an','is','are','was','were','be','been','being',
                     'in','on','at','to','for','of','with','and','or','but',
                     'not','no','do','does','did','have','has','had','will',
                     'would','could','should','can','may','might','shall',
                     'this','that','these','those','it','its','my','your',
                     'all','each','every','what','which','how','when','where',
                     'who','why','me','i','you','we','they','them','he','she'),
        [System.StringComparer]::OrdinalIgnoreCase)
    $words = ($Prompt -replace '[^\w\s]', '' -split '\s+') |
        Where-Object { $_.Length -gt 1 -and -not $stopWords.Contains($_) } |
        Select-Object -First 4
    $slug = ($words -join '_').ToLower() -replace '[^a-z0-9_]', ''
    if (-not $slug) { $slug = $Type }
    $name = "llm_${slug}"
    # Ensure uniqueness by appending a counter if needed
    if (Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue) {
        $n = 2
        while (Get-Variable -Name "${name}_${n}" -Scope Global -ErrorAction SilentlyContinue) { $n++ }
        $name = "${name}_${n}"
    }
    Set-Variable -Name $name -Value $Result -Scope Global
    $global:llm_history.Add([PSCustomObject]@{
        Index      = $global:llm_history.Count + 1
        GlobalName = $name
        Type       = $Type
        Prompt     = $Prompt
        Timestamp  = [datetime]::UtcNow
    })
    Write-Verbose "Result stored in `$global:$name (history #$($global:llm_history.Count))"
    $name
}

# Verbs whose presence in an expression requires user confirmation
$script:DestructivePattern = '^(Remove|Stop|Kill|Format|Clear|Reset|Disable|Uninstall|Delete|Erase|Purge|Drop|Revoke|Deny)-'

# The single tool definition exposed to all providers
$script:AgentTool = @{
    name        = 'invoke_powershell'
    description = 'Execute a PowerShell expression in a live session. Results are stored as live .NET objects in $refs[id] for reuse in later calls. The caller receives these objects via .Result — always use this tool to produce your final answer so it contains a typed object, not just text. All loaded modules and their claude.md directives are available.'
    input_schema = @{
        type       = 'object'
        required   = @('expression')
        properties = @{
            expression = @{
                type        = 'string'
                description = 'A valid PowerShell expression or pipeline. Output is stored in $refs and a summary returned. Reference previous results via $refs[id].'
            }
        }
    }
}
