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

# Verbs whose presence in an expression requires user confirmation
$script:DestructivePattern = '^(Remove|Stop|Kill|Format|Clear|Reset|Disable|Uninstall|Delete|Erase|Purge|Drop|Revoke|Deny)-'

# The single tool definition exposed to all providers
$script:AgentTool = @{
    name        = 'invoke_powershell'
    description = 'Execute a PowerShell expression in a live session. Results are stored in $refs[id] for reuse in later calls. All loaded modules and their claude.md directives are available.'
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
