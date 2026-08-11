# PowerShell-Profil - wird aus $PROFILE dot-gesourct.
#
# $PROFILE enthaelt genau eine Zeile:  . <repo>\profile\profile.ps1
# Aenderungen hier wirken damit sofort, ohne Deploy-Schritt.
#
# Startzeit ist ein Entwurfsziel: alles, was ein Modul laedt oder einen Prozess
# startet, laeuft lazy. Sofort geladen wird nur, was den Prompt zeichnet.

# Native Kommandos (winget, git, ...) als UTF-8 dekodieren, sonst wird
# nicht-ASCII zu Mojibake ("verfuegbares" -> "verf?gbares").
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ==============================================================================
# PROMPT
# ==============================================================================

# oh-my-posh liefert Branch, Working-/Staging-Status und Stash-Count selbst -
# posh-git wird dafuer nicht gebraucht (siehe LAZY-Abschnitt unten).
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    $themePath = Join-Path $PSScriptRoot 'theme.omp.json'
    if (Test-Path $themePath) {
        oh-my-posh init pwsh --config $themePath | Invoke-Expression
    }
}

# ==============================================================================
# PSREADLINE
# ==============================================================================

# PredictionSource braucht ein echtes Terminal - in Pipes und CI wuerde es werfen.
if ($Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected) {
    Set-PSReadLineOption -PredictionSource History
    Set-PSReadLineOption -Colors @{ InlinePrediction = '#898c5b' }
}

# Tab bleibt bewusst beim nativen MenuComplete: Tab ist der haeufigste
# Tastendruck und darf nie auf einen Modul-Ladevorgang warten.
# Wer stattdessen fzf-Tab will: Initialize-PSFzf aufrufen und dann
#   Set-PsFzfOption -TabExpansion
Set-PSReadLineKeyHandler -Key 'Tab' -Function MenuComplete
Set-PSReadLineKeyHandler -Key 'UpArrow' -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key 'DownArrow' -Function HistorySearchForward
Set-PSReadLineOption -HistorySearchCursorMovesToEnd

# Pfeil rechts: im Text vorwaerts, am Zeilenende das naechste Vorschlagswort.
Set-PSReadLineKeyHandler -Key 'RightArrow' -ScriptBlock {
    param($key, $arg)
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($cursor -lt $line.Length) {
        [Microsoft.PowerShell.PSConsoleReadLine]::ForwardChar($key, $arg)
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptNextSuggestionWord($key, $arg)
    }
}

# End: ans Zeilenende, am Zeilenende den ganzen Vorschlag uebernehmen.
Set-PSReadLineKeyHandler -Key 'End' -ScriptBlock {
    param($key, $arg)
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($cursor -lt $line.Length) {
        [Microsoft.PowerShell.PSConsoleReadLine]::EndOfLine($key, $arg)
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptSuggestion($key, $arg)
    }
}

# ==============================================================================
# LAZY LOADING
# ==============================================================================
# PSFzf und posh-git kosten zusammen rund 2,7 Sekunden Ladezeit. Beide werden
# erst geladen, wenn man sie tatsaechlich benutzt.

# --- PSFzf: erst beim ersten Ctrl+R / Ctrl+T -------------------------------
function Initialize-PSFzf {
    <#
    .SYNOPSIS
        Laedt PSFzf nach und registriert seine echten Tastenbelegungen.
    .DESCRIPTION
        Ab dem zweiten Tastendruck greift direkt PSFzf, weil Set-PsFzfOption
        die untenstehenden Platzhalter-Handler ueberschreibt.
    #>
    if (Get-Module PSFzf) { return $true }
    try {
        Import-Module PSFzf -Global -ErrorAction Stop
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        return $true
    } catch {
        Write-Warning "PSFzf konnte nicht geladen werden: $($_.Exception.Message)"
        return $false
    }
}

# Die PSFzf-Handler sind modulintern, aber ueber den Modul-SessionState
# erreichbar - so laeuft schon der ERSTE Tastendruck durch, ohne Nachfassen.
Set-PSReadLineKeyHandler -Key 'Ctrl+r' -Description 'Fuzzy-Historie (laedt PSFzf beim ersten Aufruf)' -ScriptBlock {
    if (Initialize-PSFzf) { & (Get-Module PSFzf) { Invoke-FzfPsReadlineHandlerHistory } }
}
Set-PSReadLineKeyHandler -Key 'Ctrl+t' -Description 'Fuzzy-Dateiauswahl (laedt PSFzf beim ersten Aufruf)' -ScriptBlock {
    if (Initialize-PSFzf) { & (Get-Module PSFzf) { Invoke-FzfPsReadlineHandlerProvider } }
}

# --- posh-git: erst beim ersten `git <Tab>` --------------------------------
# Nur noch fuer die Tab-Completion zustaendig; den Prompt zeichnet oh-my-posh.
# Nach dem Import registriert posh-git seinen eigenen Completer und ersetzt
# diesen hier - der erste Aufruf liefert das Ergebnis bereits selbst.
Register-ArgumentCompleter -Native -CommandName git -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Import-Module posh-git -Global -ErrorAction SilentlyContinue
    if (Get-Command Expand-GitCommand -ErrorAction SilentlyContinue) {
        Expand-GitCommand $commandAst.Extent.Text
    }
}

# ==============================================================================
# TAB-COMPLETION FUER CLI-TOOLS
# ==============================================================================

# winget liefert einen statischen Completer - kostet beim Registrieren nichts.
Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.Utf8Encoding]::new()
    $local:word = $wordToComplete.Replace('"', '""')
    $local:ast = $commandAst.ToString().Replace('"', '""')
    winget complete --word "$local:word" --commandline "$local:ast" --position $cursorPosition | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

# gh und rustup erzeugen ihre Completion per Unterbefehl - das kostet einen
# Prozessstart. Deshalb generiert bootstrap.ps1 sie einmalig nach
# profile\completions\ und hier wird nur noch die fertige Datei gelesen.
$completionDir = Join-Path $PSScriptRoot 'completions'
if (Test-Path $completionDir) {
    Get-ChildItem $completionDir -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
        . $_.FullName
    }
}

# ==============================================================================
# ZOXIDE
# ==============================================================================

if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# ==============================================================================
# ALIASE
# ==============================================================================

Set-Alias which Get-Command
Set-Alias lg lazygit
Set-Alias ee yazi
Set-Alias zz zellij

# eza ersetzt Terminal-Icons: dieselben Nerd-Font-Icons, aber ohne Modul-
# Ladezeit. In PowerShell schlaegt ein Alias eine Funktion, deshalb muss der
# eingebaute ls-Alias erst weichen.
if (Get-Command eza -ErrorAction SilentlyContinue) {
    if (Test-Path Alias:ls) { Remove-Item Alias:ls -Force }
    function ls { eza --icons --git @args }
    function ll { eza --long --icons --git @args }
    function la { eza --long --all --icons --git @args }
    function lt { eza --tree --level=2 --icons @args }
}

# Eine bzw. zwei Ebenen nach oben.
function GoUpOneLevel { Set-Location .. }
function GoUpTwoLevels { Set-Location ..\.. }
Set-Alias -Name '..' -Value 'GoUpOneLevel'
Set-Alias -Name '...' -Value 'GoUpTwoLevels'

# ==============================================================================
# FUNKTIONEN
# ==============================================================================

function Invoke-UvVenv {
    <#  .SYNOPSIS  Legt ein Projekt-Environment mit uv an.  #>
    uv venv
}

function Invoke-VenvActivate {
    <#  .SYNOPSIS  Aktiviert .venv im aktuellen Ordner und zeigt, welches Python greift.  #>
    $activate = Join-Path '.venv' 'Scripts\Activate.ps1'
    if (-not (Test-Path $activate)) {
        Write-Error "Kein .venv gefunden. Erst 'pyvenv' ausfuehren."
        return
    }
    & $activate
    Get-Command python | Select-Object -ExpandProperty Source
}

Set-Alias pyvenv Invoke-UvVenv
Set-Alias pyact Invoke-VenvActivate

function Invoke-PyCheck {
    <#  .SYNOPSIS  BONSAI-Qualitaetslauf: formatieren, linten, typpruefen.  #>
    uv run ruff format
    if ($LASTEXITCODE -ne 0) { return }
    uv run ruff check --fix
    if ($LASTEXITCODE -ne 0) { return }
    uv run ty check
}
Set-Alias pycheck Invoke-PyCheck

function Remove-ItemForced {
    <#  .SYNOPSIS  Loescht rekursiv und ohne Rueckfrage.  #>
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Path
    )
    # process-Block ist Pflicht, sobald ValueFromPipeline gesetzt ist: ohne ihn
    # verarbeitet die Funktion bei Pipeline-Eingabe nur das LETZTE Element.
    process { Remove-Item $Path -Recurse -Force }
}
Set-Alias rmf Remove-ItemForced

function Stop-ProcessOnPort {
    <#
    .SYNOPSIS
        Beendet den Prozess, der auf einem Port lauscht.
    .NOTES
        Die Variable heisst bewusst $procId und nicht $pid - $PID ist eine
        schreibgeschuetzte automatische Variable von PowerShell.
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$Port
    )
    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($connections.Count -eq 0) {
        Write-Host "Kein Prozess lauscht auf Port $Port." -ForegroundColor Yellow
        return
    }
    foreach ($procId in ($connections.OwningProcess | Sort-Object -Unique)) {
        $name = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
        Write-Host "Beende PID $procId ($name) auf Port $Port" -ForegroundColor Cyan
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}
Set-Alias kp Stop-ProcessOnPort

function notebook2py {
    <#  .SYNOPSIS  Wandelt ein Jupyter-Notebook in eine aufgeraeumte .py-Datei.  #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$NotebookPath
    )

    if (-not (Test-Path -LiteralPath $NotebookPath)) {
        Write-Error "Not found: $NotebookPath"; return
    }
    $nb = Get-Item -LiteralPath $NotebookPath
    if ($nb.Extension -ne '.ipynb') {
        Write-Error "Not an .ipynb file: $($nb.Name)"; return
    }
    $py = Join-Path $nb.DirectoryName "$($nb.BaseName).py"

    # Fehlende Dev-Abhaengigkeiten im uv-Environment nachziehen.
    $required = @('jupytext', 'ruff')
    $missing = @()
    foreach ($pkg in $required) {
        & uv pip show $pkg 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $missing += $pkg }
    }
    if ($missing.Count -gt 0) {
        Write-Host "-> adding missing dev deps: $($missing -join ', ')" -ForegroundColor Yellow
        uv add --dev @missing
        if ($LASTEXITCODE -ne 0) { Write-Error 'uv add failed'; return }
    }

    function Invoke-Step {
        param([string]$Label, [scriptblock]$Action)
        Write-Host "-> $Label" -ForegroundColor Cyan
        & $Action
        if ($LASTEXITCODE -ne 0) {
            Write-Error "$Label failed (exit $LASTEXITCODE)"
            throw
        }
    }

    try {
        Invoke-Step "converting $($nb.Name)" {
            uv run jupytext --to py:percent $nb.FullName -o $py
        }
        Invoke-Step 'stripping notebook artifacts' {
            $stripper = @'
import ast, pathlib, re, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
src = re.sub(r"\A# ---\n(?:#[^\n]*\n)*?# ---\n+", "", src)
src = re.sub(r"(?m)^# %%[^\n]*\n", "", src)
tree = ast.parse(src)
remove = set()
for node in tree.body:
    if isinstance(node, ast.Expr) and isinstance(node.value, ast.Name):
        for ln in range(node.lineno, node.end_lineno + 1):
            remove.add(ln)
out = [ln for i, ln in enumerate(src.splitlines(keepends=True), 1) if i not in remove]
p.write_text("".join(out), encoding="utf-8")
'@
            uv run python -c $stripper $py
        }
        Invoke-Step 'unused imports + isort (F, I)' {
            uv run ruff check --select F,I --fix $py
        }
        Invoke-Step 'formatting' {
            uv run ruff format $py
        }
        Write-Host "OK $py" -ForegroundColor Green
    } catch {
        # Invoke-Step hat den Fehler bereits gemeldet - hier nur sauber aussteigen.
        return
    }
}

# ==============================================================================
# UPDATES
# ==============================================================================

function Invoke-UpgradeStep {
    <#
    .SYNOPSIS
        Fuehrt einen Update-Schritt aus und klassifiziert seinen Exit-Code.
    .DESCRIPTION
        Die Ausgabe wird eingefangen statt gestreamt - so bleibt winget still
        (kein Spinner) und nur echte Fehler landen auf dem Bildschirm.
    #>
    param([string]$Label, [scriptblock]$Action)
    Write-Host "-> $Label" -ForegroundColor Cyan
    $out = & $Action 2>&1
    $code = $LASTEXITCODE
    # winget: APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE = 0x8A15002B
    if ($code -eq 0) { $status = 'Success' }
    elseif ($code -eq -1978335189) { $status = 'Nichts zu tun' }
    elseif ($null -eq $code) { $status = 'Success' }
    else { $status = "Fehler (exit $code)" }
    if ($status -like 'Fehler*') { $out | Out-Host }
    [pscustomobject]@{ Label = $Label; Status = $status }
}

function Invoke-Up {
    <#
    .SYNOPSIS
        Aktualisiert alles: Paketmanager, Sprach-Toolchains, PowerShell-Module.
    .DESCRIPTION
        Ersetzt das fruehere codeup. Schritte ohne installiertes Werkzeug
        werden uebersprungen statt als Fehler gemeldet.
    #>
    $results = @()

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $results += Invoke-UpgradeStep 'winget' { winget upgrade --all --accept-source-agreements }
    }
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        $results += Invoke-UpgradeStep 'scoop' {
            scoop update
            scoop update *
            scoop cleanup * -k
        }
    }
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $results += Invoke-UpgradeStep 'uv' { uv self update }
    }
    if (Get-Command bun -ErrorAction SilentlyContinue) {
        $results += Invoke-UpgradeStep 'bun' { bun upgrade }
    }
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        $results += Invoke-UpgradeStep 'claude' { claude update }
    }
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        $results += Invoke-UpgradeStep 'rustup' { rustup update }
    }
    $results += Invoke-UpgradeStep 'PS-Module' {
        Update-Module -Scope CurrentUser -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }

    Write-Host ''
    Write-Host '-- up --------------------------' -ForegroundColor DarkGray
    foreach ($r in $results) {
        if ($r.Status -eq 'Success') { $color = 'Green'; $sym = 'OK' }
        elseif ($r.Status -eq 'Nichts zu tun') { $color = 'Yellow'; $sym = '--' }
        else { $color = 'Red'; $sym = 'XX' }
        Write-Host ('  {0} {1,-12} {2}' -f $sym, $r.Label, $r.Status) -ForegroundColor $color
    }
}
Set-Alias up Invoke-Up

# ==============================================================================
# BONSAI
# ==============================================================================

$BONSAI_REPO = 'C:\Git\BONSAI'

function Invoke-BonsaiUpdate {
    & "$BONSAI_REPO\scripts\install.ps1" update
}
Set-Alias bonsai-update Invoke-BonsaiUpdate
