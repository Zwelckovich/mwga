<#
.SYNOPSIS
    Richtet eine frische Windows-Maschine nach diesem Repo ein.

.DESCRIPTION
    Einziger Einstiegspunkt. Idempotent: jeder Schritt prueft erst, ob er
    ueberhaupt noetig ist, und laesst bereits Vorhandenes in Ruhe. Ein zweiter
    Lauf ist damit gefahrlos und dient zugleich als Reparatur.

    Am Ende laeuft verify.ps1 und sagt, was noch fehlt.

.PARAMETER DryRun
    Spielt alles durch, ohne etwas zu installieren oder zu schreiben. Damit
    laesst sich der Ablauf auf einer beliebigen Maschine gefahrlos pruefen.

.PARAMETER SkipVerify
    Laesst den abschliessenden Pruefbericht weg.

.EXAMPLE
    .\bootstrap.ps1 -DryRun
    Zeigt, was passieren wuerde.

.EXAMPLE
    .\bootstrap.ps1
    Richtet die Maschine ein.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

$script:step = 0
$script:total = 13
$script:failures = @()

function Write-Step {
    param([string]$Title)
    $script:step++
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $script:step, $script:total, $Title) -ForegroundColor Cyan
}

function Write-Did { param([string]$Text) Write-Host "    + $Text" -ForegroundColor Green }
function Write-Skip { param([string]$Text) Write-Host "    = $Text" -ForegroundColor DarkGray }
function Write-Would { param([string]$Text) Write-Host "    ~ $Text" -ForegroundColor Yellow }
function Write-Fail {
    param([string]$Text)
    Write-Host "    ! $Text" -ForegroundColor Red
    $script:failures += $Text
}

function Update-SessionPath {
    <#
    .SYNOPSIS
        Liest den PATH aus der Registry neu ein.
    .DESCRIPTION
        Frisch installierte Werkzeuge sind in der laufenden Sitzung sonst
        unsichtbar, und die nachfolgenden Schritte wuerden sie nicht finden.
    #>
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Copy-Config {
    <#
    .SYNOPSIS
        Rollt eine Konfigurationsdatei aus und sichert eine vorhandene vorher.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path $Source)) {
        Write-Fail "$Label - Quelle fehlt: $Source"
        return
    }

    $targetDir = Split-Path $Target -Parent
    if (-not (Test-Path $targetDir)) {
        if ($DryRun) { Write-Would "$Label - Zielordner anlegen: $targetDir"; return }
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    if (Test-Path $Target) {
        $same = (Get-FileHash $Source).Hash -eq (Get-FileHash $Target).Hash
        if ($same) { Write-Skip "$Label bereits aktuell"; return }
        if ($DryRun) { Write-Would "$Label ueberschreiben (Backup wird angelegt)"; return }
        $backup = "$Target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $Target $backup
        Write-Skip "Backup: $backup"
    } elseif ($DryRun) {
        Write-Would "$Label anlegen: $Target"
        return
    }

    Copy-Item $Source $Target -Force
    Write-Did "$Label -> $Target"
}

Write-Host ''
Write-Host '====================================================' -ForegroundColor DarkGray
Write-Host "  mwga bootstrap$(if ($DryRun) { '   [DryRun - es wird nichts veraendert]' })" -ForegroundColor White
Write-Host "  Repo: $repo" -ForegroundColor DarkGray
Write-Host '====================================================' -ForegroundColor DarkGray

# ==============================================================================
Write-Step 'Vorbedingungen'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Dieses Repo setzt PowerShell 7+ voraus (laeuft gerade unter $($PSVersionTable.PSVersion)). " +
          'Erst `winget install Microsoft.PowerShell`, dann in pwsh erneut starten.'
}
Write-Skip "PowerShell $($PSVersionTable.PSVersion)"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget nicht gefunden. App Installer aus dem Microsoft Store installieren und erneut starten.'
}
Write-Skip "winget $(winget --version)"

# ==============================================================================
Write-Step 'Windows-Systemeinstellungen'

$systemScript = Join-Path $repo 'system.ps1'
if (Test-Path $systemScript) {
    & $systemScript -DryRun:$DryRun
} else {
    Write-Fail 'system.ps1 fehlt'
}

# ==============================================================================
Write-Step 'scoop'

if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Skip 'scoop bereits installiert'
} elseif ($DryRun) {
    Write-Would 'scoop installieren (irm get.scoop.sh | iex)'
} else {
    try {
        Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
        Update-SessionPath
        Write-Did 'scoop installiert'
    } catch {
        Write-Fail "scoop-Installation fehlgeschlagen: $($_.Exception.Message)"
    }
}

# ==============================================================================
Write-Step 'winget-Pakete'

$wingetManifest = Join-Path $repo 'manifests\winget.json'
if (-not (Test-Path $wingetManifest)) {
    Write-Fail 'manifests\winget.json fehlt'
} else {
    $wanted = (Get-Content $wingetManifest -Raw | ConvertFrom-Json).Sources[0].Packages.PackageIdentifier
    Write-Skip "$($wanted.Count) Pakete im Manifest"
    if ($DryRun) {
        Write-Would "winget import manifests\winget.json  ($($wanted -join ', '))"
    } else {
        # --ignore-unavailable laesst den Lauf weiterlaufen, wenn eine ID aus dem
        # Katalog verschwindet, statt alles abzubrechen.
        winget import --import-file $wingetManifest `
            --accept-package-agreements --accept-source-agreements `
            --ignore-versions --ignore-unavailable
        # Exit-Code 0x8A15002B = "nichts zu tun", ist kein Fehler.
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            Write-Fail "winget import endete mit Exit-Code $LASTEXITCODE"
        } else {
            Write-Did 'winget-Pakete verarbeitet'
        }
        Update-SessionPath
    }
}

# ==============================================================================
Write-Step 'scoop-Pakete (Luecken, die winget nicht abdeckt)'

$scoopManifest = Join-Path $repo 'manifests\scoop.json'
if (-not (Test-Path $scoopManifest)) {
    Write-Fail 'manifests\scoop.json fehlt'
} elseif (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Skip 'scoop nicht verfuegbar - uebersprungen'
} else {
    $wantedScoop = @((Get-Content $scoopManifest -Raw | ConvertFrom-Json).apps.Name)
    if ($wantedScoop.Count -eq 0) {
        Write-Skip 'scoop-Manifest ist leer'
    } elseif ($DryRun) {
        Write-Would "scoop import manifests\scoop.json  ($($wantedScoop -join ', '))"
    } else {
        scoop import $scoopManifest
        Update-SessionPath
        Write-Did "scoop-Pakete verarbeitet ($($wantedScoop -join ', '))"
    }
}

# ==============================================================================
Write-Step 'Werkzeuge mit eigenem Installer'

# Bewusst nicht ueber winget: uv, bun und Claude Code aktualisieren sich selbst
# (`uv self update`, `bun upgrade`, `claude update`), und das funktioniert nur
# bei einer Installation ueber den jeweils eigenen Installer.
$installers = @(
    @{ Name = 'uv'; Url = 'https://astral.sh/uv/install.ps1' }
    @{ Name = 'bun'; Url = 'https://bun.sh/install.ps1' }
    @{ Name = 'claude'; Url = 'https://claude.ai/install.ps1' }
)
foreach ($i in $installers) {
    if (Get-Command $i.Name -ErrorAction SilentlyContinue) {
        Write-Skip "$($i.Name) bereits installiert"
    } elseif ($DryRun) {
        Write-Would "$($i.Name) installieren (irm $($i.Url) | iex)"
    } else {
        try {
            Invoke-RestMethod -Uri $i.Url | Invoke-Expression
            Update-SessionPath
            Write-Did "$($i.Name) installiert"
        } catch {
            Write-Fail "$($i.Name)-Installation fehlgeschlagen: $($_.Exception.Message)"
        }
    }
}

# ==============================================================================
Write-Step 'PowerShell-Module'

$moduleManifest = Join-Path $repo 'manifests\modules.txt'
if (-not (Test-Path $moduleManifest)) {
    Write-Fail 'manifests\modules.txt fehlt'
} else {
    $modules = Get-Content $moduleManifest | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }
    foreach ($m in $modules) {
        $m = $m.Trim()
        if (Get-Module -ListAvailable -Name $m) {
            Write-Skip "$m bereits vorhanden"
        } elseif ($DryRun) {
            Write-Would "Install-Module $m -Scope CurrentUser"
        } else {
            try {
                Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
                Write-Did "$m installiert"
            } catch {
                Write-Fail "Install-Module $m fehlgeschlagen: $($_.Exception.Message)"
            }
        }
    }
}

# ==============================================================================
Write-Step 'rustup-Komponenten'

$rustManifest = Join-Path $repo 'manifests\rust.txt'
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Write-Skip 'rustup nicht verfuegbar - uebersprungen'
} elseif (-not (Test-Path $rustManifest)) {
    Write-Fail 'manifests\rust.txt fehlt'
} else {
    $components = Get-Content $rustManifest | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }
    $installed = rustup component list --installed 2>$null
    foreach ($c in $components) {
        $c = $c.Trim()
        if ($installed | Where-Object { $_ -like "$c*" }) {
            Write-Skip "$c bereits vorhanden"
        } elseif ($DryRun) {
            Write-Would "rustup component add $c"
        } else {
            rustup component add $c
            Write-Did "$c hinzugefuegt"
        }
    }
}

# ==============================================================================
Write-Step 'Tab-Completion vorgenerieren'

# gh und rustup erzeugen ihre Completion per Unterbefehl. Einmal hier in eine
# Datei geschrieben kostet das Profil spaeter nur noch einen Dateizugriff
# statt zweier Prozessstarts bei jedem Shell-Start.
$completionDir = Join-Path $repo 'profile\completions'
$completions = @(
    @{ Name = 'gh'; Command = { gh completion -s powershell } }
    @{ Name = 'rustup'; Command = { rustup completions powershell } }
)
foreach ($c in $completions) {
    if (-not (Get-Command $c.Name -ErrorAction SilentlyContinue)) {
        Write-Skip "$($c.Name) nicht verfuegbar - uebersprungen"
        continue
    }
    $out = Join-Path $completionDir "$($c.Name).ps1"
    if ($DryRun) { Write-Would "Completion erzeugen: $out"; continue }
    try {
        if (-not (Test-Path $completionDir)) { New-Item -ItemType Directory -Path $completionDir -Force | Out-Null }
        & $c.Command | Out-File -FilePath $out -Encoding utf8
        Write-Did "$($c.Name)-Completion erzeugt"
    } catch {
        Write-Fail "Completion fuer $($c.Name) fehlgeschlagen: $($_.Exception.Message)"
    }
}

# ==============================================================================
Write-Step 'Konfigurationen ausrollen'

Copy-Config -Source (Join-Path $repo 'vscode\settings.json') `
    -Target "$env:APPDATA\Code\User\settings.json" -Label 'VS Code settings'

Copy-Config -Source (Join-Path $repo 'claude\settings.json') `
    -Target "$env:USERPROFILE\.claude\settings.json" -Label 'Claude settings'

# Windows Terminal liegt im Store-Paketpfad; ohne installiertes Terminal
# existiert der Ordner nicht und der Schritt entfaellt.
$wtDir = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
if (Test-Path $wtDir) {
    Copy-Config -Source (Join-Path $repo 'terminal\settings.json') `
        -Target (Join-Path $wtDir 'settings.json') -Label 'Windows Terminal settings'
} else {
    Write-Skip 'Windows Terminal nicht gefunden - settings.json nicht ausgerollt'
}

# VS-Code-Erweiterungen uebernimmt das mitgelieferte Skript.
$extScript = Join-Path $repo 'vscode\install_extensions.ps1'
if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
    Write-Skip 'code-CLI nicht verfuegbar - Erweiterungen uebersprungen'
} elseif ($DryRun) {
    Write-Would 'VS-Code-Erweiterungen installieren (vscode\install_extensions.ps1)'
} elseif (Test-Path $extScript) {
    Push-Location (Join-Path $repo 'vscode')
    try { & $extScript } finally { Pop-Location }
    Write-Did 'VS-Code-Erweiterungen verarbeitet'
}

# ==============================================================================
Write-Step 'PowerShell-Profil verdrahten'

# $PROFILE bekommt nur eine Weiche auf das Repo. Damit wirken Aenderungen am
# Profil sofort, ohne dass irgendetwas kopiert oder synchronisiert werden muss.
$profileTarget = Join-Path $repo 'profile\profile.ps1'
$profileLine = ". `"$profileTarget`""

if (-not (Test-Path $profileTarget)) {
    Write-Fail "profile\profile.ps1 fehlt"
} elseif ((Test-Path $PROFILE) -and ((Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($profileTarget))) {
    Write-Skip '$PROFILE zeigt bereits auf dieses Repo'
} elseif ($DryRun) {
    Write-Would "In `$PROFILE eintragen: $profileLine   ($PROFILE)"
} else {
    $profileDir = Split-Path $PROFILE -Parent
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    if (Test-Path $PROFILE) {
        $backup = "$PROFILE.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $PROFILE $backup
        Write-Skip "Backup: $backup"
    }
    Set-Content -Path $PROFILE -Value @(
        '# Weiche auf das mwga-Repo - Inhalt wird dort gepflegt, nicht hier.',
        $profileLine
    ) -Encoding utf8
    Write-Did "`$PROFILE -> $profileTarget"
}

# ==============================================================================
Write-Step 'git: delta als Diff-Pager'

# Bewusst eng begrenzt: nur die delta-Eintraege. user.name und user.email
# bleiben Handarbeit - dieses Repo schreibt keine Identitaet in deine Config.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Skip 'git nicht verfuegbar - uebersprungen'
} elseif (-not (Get-Command delta -ErrorAction SilentlyContinue)) {
    Write-Skip 'delta nicht verfuegbar - uebersprungen'
} else {
    $gitSettings = [ordered]@{
        'core.pager'              = 'delta'
        'interactive.diffFilter'  = 'delta --color-only'
        'delta.navigate'          = 'true'
        'delta.line-numbers'      = 'true'
        'merge.conflictstyle'     = 'zdiff3'
    }
    foreach ($kv in $gitSettings.GetEnumerator()) {
        $current = git config --global --get $kv.Key 2>$null
        if ($current -eq $kv.Value) {
            Write-Skip "$($kv.Key) bereits gesetzt"
        } elseif ($DryRun) {
            Write-Would "git config --global $($kv.Key) '$($kv.Value)'"
        } else {
            git config --global $kv.Key $kv.Value
            Write-Did "$($kv.Key) = $($kv.Value)"
        }
    }
}

# ==============================================================================
Write-Step 'Pruefbericht'

if ($SkipVerify) {
    Write-Skip 'uebersprungen (-SkipVerify)'
} elseif ($DryRun) {
    Write-Would 'verify.ps1 ausfuehren'
} else {
    $verifyScript = Join-Path $repo 'verify.ps1'
    if (Test-Path $verifyScript) { & $verifyScript } else { Write-Fail 'verify.ps1 fehlt' }
}

# ==============================================================================
Write-Host ''
if ($script:failures.Count -gt 0) {
    Write-Host ("bootstrap mit {0} Problem(en) beendet:" -f $script:failures.Count) -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Red }
} elseif ($DryRun) {
    Write-Host 'DryRun sauber durchgelaufen - es wurde nichts veraendert.' -ForegroundColor Green
} else {
    Write-Host 'bootstrap fertig. Neue Shell oeffnen, damit PATH und Profil greifen.' -ForegroundColor Green
}
Write-Host ''
