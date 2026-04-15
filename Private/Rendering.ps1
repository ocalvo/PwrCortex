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
