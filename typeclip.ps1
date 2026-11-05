<#
.SYNOPSIS
    Types the text on your clipboard into another window, key by key.

.DESCRIPTION
    Useful for lab consoles (VNC / vSphere) that don't support paste.
    1. Copy the text you want (Ctrl + C).
    2. Run this script.
    3. Within the countdown, click inside the lab console window.
    The script then "types" the clipboard for you, slowly, so nothing gets lost.

    Never use it for secrets in a shared screen recording.

.EXAMPLE
    .\typeclip.ps1
    .\typeclip.ps1 -Delay 8 -KeyDelayMs 30
#>

param(
    [int]$Delay      = 5,    # seconds to click into the target window
    [int]$KeyDelayMs = 20    # pause between keys; raise it if characters go missing
)

Add-Type -AssemblyName System.Windows.Forms

$text = Get-Clipboard -Raw
if (-not $text) {
    Write-Host "The clipboard is empty. Copy something first (Ctrl + C)." -ForegroundColor Red
    exit 1
}
$text = $text -replace "`r`n", "`n"

Write-Host "Typing $($text.Length) characters. Click inside the lab window now..." -ForegroundColor Yellow
for ($i = $Delay; $i -gt 0; $i--) {
    Write-Host "  $i"
    Start-Sleep -Seconds 1
}

# Characters that SendKeys treats as special must be wrapped in { }
$special = "+^%~(){}[]".ToCharArray()
foreach ($char in $text.ToCharArray()) {
    if ($char -eq "`n") {
        $key = "{ENTER}"
    } elseif ($special -contains $char) {
        $key = "{" + $char + "}"
    } else {
        $key = [string]$char
    }
    [System.Windows.Forms.SendKeys]::SendWait($key)
    Start-Sleep -Milliseconds $KeyDelayMs
}
Write-Host "Done." -ForegroundColor Green
