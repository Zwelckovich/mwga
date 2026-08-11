<#
.SYNOPSIS
    Prueft, ob die Maschine dem entspricht, was dieses Repo beschreibt.

.DESCRIPTION
    Laeuft am Ende von bootstrap.ps1 automatisch und ist jederzeit einzeln
    aufrufbar. Meldet fehlende Pakete, doppelte Binaries auf dem PATH,
    PATH-Groesse, Nerd Font, die $PROFILE-Weiche und die Profil-Ladezeit.

    Exit-Code 0 = alles gruen, 1 = mindestens ein Fehler.

.EXAMPLE
    .\verify.ps1
#>
[CmdletBinding()]
param()

$repo = $PSScriptRoot
$script:errors = 0
$script:warnings = 0

function Write-Ok { param([string]$Text) Write-Host "  OK  $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text, [string]$Fix)
    Write-Host "  !   $Text" -ForegroundColor Yellow
    if ($Fix) { Write-Host "      -> $Fix" -ForegroundColor DarkGray }
    $script:warnings++
}
function Write-Err { param([string]$Text, [string]$Fix)
    Write-Host "  X   $Text" -ForegroundColor Red
    if ($Fix) { Write-Host "      -> $Fix" -ForegroundColor DarkGray }
    $script:errors++
}

Write-Host ''
Write-Host '-- verify ------------------------------------------' -ForegroundColor DarkGray

# -- PowerShell-Version -------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
} else {
    Write-Err "PowerShell $($PSVersionTable.PSVersion) - dieses Repo setzt 7+ voraus" 'winget install Microsoft.PowerShell'
}

# -- winget-Pakete ------------------------------------------------------------
$manifest = Join-Path $repo 'manifests\winget.json'
if (-not (Test-Path $manifest)) {
    Write-Err 'manifests\winget.json fehlt'
} elseif (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Err 'winget nicht gefunden' 'App Installer aus dem Microsoft Store installieren'
} else {
    $wanted = (Get-Content $manifest -Raw | ConvertFrom-Json).Sources[0].Packages.PackageIdentifier

    # Ein einziger Export statt 30 Einzelabfragen - deutlich schneller und
    # unabhaengig vom lokalisierten Tabellenformat von `winget list`.
    $exportFile = Join-Path ([IO.Path]::GetTempPath()) 'mwga-verify-export.json'
    winget export -o $exportFile --accept-source-agreements 2>&1 | Out-Null

    if (Test-Path $exportFile) {
        $installed = (Get-Content $exportFile -Raw | ConvertFrom-Json).Sources.Packages.PackageIdentifier
        Remove-Item $exportFile -Force -ErrorAction SilentlyContinue

        $missing = @($wanted | Where-Object { $_ -notin $installed })
        if ($missing.Count -eq 0) {
            Write-Ok "winget: alle $($wanted.Count) Pakete installiert"
        } else {
            Write-Err "winget: $($missing.Count) von $($wanted.Count) Paketen fehlen - $($missing -join ', ')" `
                'winget import manifests\winget.json --accept-package-agreements'
        }
    } else {
        Write-Warn 'winget export lieferte keine Datei - Paketpruefung uebersprungen'
    }
}

# -- scoop --------------------------------------------------------------------
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Err 'scoop nicht gefunden' 'irm get.scoop.sh | iex'
} else {
    $scoopManifest = Join-Path $repo 'manifests\scoop.json'
    $wantedScoop = @()
    if (Test-Path $scoopManifest) {
        $wantedScoop = @((Get-Content $scoopManifest -Raw | ConvertFrom-Json).apps.Name)
    }
    $installedScoop = @((scoop export 2>$null | ConvertFrom-Json).apps.Name)
    $missingScoop = @($wantedScoop | Where-Object { $_ -notin $installedScoop })
    if ($missingScoop.Count -eq 0) {
        Write-Ok "scoop: alle $($wantedScoop.Count) Pakete installiert"
    } else {
        Write-Err "scoop: fehlt - $($missingScoop -join ', ')" 'scoop import manifests\scoop.json'
    }
}

# -- Werkzeuge mit eigenem Installer ------------------------------------------
$native = @(
    @{ Name = 'uv'; Version = { uv --version }; Fix = 'irm https://astral.sh/uv/install.ps1 | iex' }
    @{ Name = 'bun'; Version = { bun --version }; Fix = 'irm https://bun.sh/install.ps1 | iex' }
    @{ Name = 'claude'; Version = { claude --version }; Fix = 'irm https://claude.ai/install.ps1 | iex' }
)
foreach ($t in $native) {
    if (Get-Command $t.Name -ErrorAction SilentlyContinue) {
        $v = (& $t.Version 2>&1 | Select-Object -First 1) -replace '\s+', ' '
        Write-Ok "$($t.Name)  $v"
    } else {
        Write-Err "$($t.Name) nicht auf dem PATH" $t.Fix
    }
}

# -- rustup-Komponenten -------------------------------------------------------
if (Get-Command rustup -ErrorAction SilentlyContinue) {
    $rustManifest = Join-Path $repo 'manifests\rust.txt'
    if (Test-Path $rustManifest) {
        $wantedComponents = Get-Content $rustManifest | Where-Object { $_.Trim() -and -not $_.StartsWith('#') }
        $installedComponents = rustup component list --installed 2>$null
        $missingComponents = @($wantedComponents | Where-Object { $c = $_; -not ($installedComponents | Where-Object { $_ -like "$c*" }) })
        if ($missingComponents.Count -eq 0) {
            Write-Ok "rustup: Komponenten vollstaendig ($($wantedComponents -join ', '))"
        } else {
            Write-Warn "rustup: fehlt - $($missingComponents -join ', ')" "rustup component add $($missingComponents -join ' ')"
        }
    }
} else {
    Write-Err 'rustup nicht auf dem PATH' 'winget install Rustlang.Rustup'
}

# -- PowerShell-Module --------------------------------------------------------
$moduleManifest = Join-Path $repo 'manifests\modules.txt'
if (Test-Path $moduleManifest) {
    $wantedModules = Get-Content $moduleManifest | Where-Object { $_.Trim() -and -not $_.StartsWith('#') }
    $missingModules = @($wantedModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
    if ($missingModules.Count -eq 0) {
        Write-Ok "PowerShell-Module: $($wantedModules -join ', ')"
    } else {
        Write-Err "Module fehlen - $($missingModules -join ', ')" `
            "Install-Module $($missingModules -join ', ') -Scope CurrentUser"
    }
}

# -- Doppelte Binaries --------------------------------------------------------
# Der eigentliche Zweck der "eine Quelle pro Werkzeug"-Regel. ffmpeg ist der
# historische Wiederholungstaeter: yt-dlp.FFmpeg und Gyan.FFmpeg gleichzeitig.
$watched = @('ffmpeg', 'ffprobe', 'python', 'node', 'npm', 'git', 'uv', 'bun', 'claude', 'rg', 'fd', 'bat', 'eza', 'fzf', 'jq', 'yazi', 'lazygit', 'zoxide')
$dupes = @()
foreach ($cmd in $watched) {
    $found = @(Get-Command $cmd -All -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' })
    if ($found.Count -gt 1) {
        $dupes += [pscustomobject]@{ Name = $cmd; Paths = $found.Source }
    }
}
if ($dupes.Count -eq 0) {
    Write-Ok 'keine doppelten Binaries auf dem PATH'
} else {
    foreach ($d in $dupes) {
        Write-Warn "$($d.Name) $($d.Paths.Count)x auf dem PATH" ($d.Paths -join "`n         ")
    }
}

# DenoLand.Deno ist kein Fehler: winget erzwingt es als Abhaengigkeit von
# yt-dlp.yt-dlp. Es steht bewusst nicht im Manifest.
if (Get-Command deno -ErrorAction SilentlyContinue) {
    Write-Host '  --  deno vorhanden (erzwungene yt-dlp-Abhaengigkeit, gewollt)' -ForegroundColor DarkGray
}

# -- PATH ---------------------------------------------------------------------
$pathEntries = @($env:PATH -split ';' | Where-Object { $_ })
$wingetEntries = @($pathEntries | Where-Object { $_ -match 'WinGet\\Packages' })
if ($pathEntries.Count -gt 60) {
    Write-Warn "PATH: $($pathEntries.Count) Eintraege / $($env:PATH.Length) Zeichen, davon $($wingetEntries.Count) winget-Paketpfade" `
        'winget-Portables bringen je einen versionierten Ordner mit - bekannter Preis der winget-first-Regel'
} else {
    Write-Ok "PATH: $($pathEntries.Count) Eintraege / $($env:PATH.Length) Zeichen ($($wingetEntries.Count) winget-Paketpfade)"
}

# -- Nerd Font ----------------------------------------------------------------
$fontKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
    'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
)
$hasNerdFont = $false
foreach ($key in $fontKeys) {
    if (-not (Test-Path $key)) { continue }
    $props = (Get-ItemProperty $key).PSObject.Properties.Name
    # Achtung: In der Registry stehen die Schnitte abgekuerzt als "NF", "NFM"
    # und "NFP" ("JetBrainsMono NF Regular"). Nur der Anzeigename im Explorer
    # lautet "JetBrainsMono Nerd Font" - eine Suche nach "Nerd" geht hier leer aus.
    if ($props | Where-Object { $_ -match 'JetBrainsMono.*(Nerd|NF)' }) { $hasNerdFont = $true; break }
}
if ($hasNerdFont) {
    Write-Ok 'JetBrainsMono Nerd Font installiert'
} else {
    Write-Err 'JetBrainsMono Nerd Font fehlt - Prompt und Icons zeigen Kaestchen' `
        'winget install DEVCOM.JetBrainsMonoNerdFont'
}

# -- Profil-Weiche ------------------------------------------------------------
$expected = Join-Path $repo 'profile\profile.ps1'
$profileWired = (Test-Path $PROFILE) -and ((Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($expected))
if ($profileWired) {
    Write-Ok "`$PROFILE zeigt auf $expected"
} else {
    Write-Err '$PROFILE verweist nicht auf dieses Repo' '.\bootstrap.ps1 ausfuehren'
}

# -- Ausgerollte Konfigurationen ----------------------------------------------
$configs = @(
    @{ Label = 'VS Code settings'; Target = "$env:APPDATA\Code\User\settings.json" }
    @{ Label = 'Claude settings'; Target = "$env:USERPROFILE\.claude\settings.json" }
)
$wtPackage = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path (Split-Path $wtPackage)) { $configs += @{ Label = 'Windows Terminal settings'; Target = $wtPackage } }
foreach ($c in $configs) {
    if (Test-Path $c.Target) { Write-Ok "$($c.Label) vorhanden" }
    else { Write-Warn "$($c.Label) nicht ausgerollt" '.\bootstrap.ps1 ausfuehren' }
}

# -- Profil-Ladezeit ----------------------------------------------------------
# Minimum aus drei Laeufen - Virenscanner und Festplatten-Caching lassen
# Einzelmessungen um mehrere hundert Millisekunden schwanken.
function Measure-ShellStart {
    param([string[]]$ExtraArgs)
    $runs = 1..3 | ForEach-Object {
        (Measure-Command { pwsh -NoLogo @ExtraArgs -Command exit }).TotalMilliseconds
    }
    ($runs | Measure-Object -Minimum).Minimum
}
$baseline = Measure-ShellStart -ExtraArgs @('-NoProfile')
$withProfile = Measure-ShellStart -ExtraArgs @()
$cost = [math]::Round($withProfile - $baseline)
if (-not $profileWired) {
    # Gemessen wird immer das aktuell aktive $PROFILE. Solange die Weiche fehlt,
    # sagt der Wert nichts ueber profile.ps1 aus - also nicht als Warnung werten.
    Write-Host ("  --  Profil laedt in {0} ms (noch das alte `$PROFILE, nicht dieses Repo)" -f $cost) -ForegroundColor DarkGray
} elseif ($cost -lt 2000) {
    # Referenz: Fast die gesamten Kosten entfallen auf `oh-my-posh init`.
    # posh-git, PSFzf und Terminal-Icons sind bewusst nicht im Startpfad.
    Write-Ok ("Profil laedt in {0} ms (Shell gesamt {1} ms)" -f $cost, [math]::Round($withProfile))
} else {
    Write-Warn ("Profil laedt in {0} ms - erwartet ist etwa die Zeit von 'oh-my-posh init' allein" -f $cost) `
        'Laedt ein Modul eifrig statt lazy? profile.ps1 pruefen'
}

# -- Fazit --------------------------------------------------------------------
Write-Host '----------------------------------------------------' -ForegroundColor DarkGray
if ($script:errors -eq 0 -and $script:warnings -eq 0) {
    Write-Host '  alles gruen' -ForegroundColor Green
} else {
    Write-Host ("  {0} Fehler, {1} Warnungen" -f $script:errors, $script:warnings) -ForegroundColor $(if ($script:errors) { 'Red' } else { 'Yellow' })
}
Write-Host ''

exit $(if ($script:errors -gt 0) { 1 } else { 0 })
