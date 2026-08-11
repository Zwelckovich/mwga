# mwga

Windows-Arbeitsumgebung als Code. Ein Befehl auf einer frischen Installation,
und die Maschine sieht aus wie die vorherige — Pakete, Shell, Editor, Terminal.

## Frische Maschine

```powershell
# 1. PowerShell 7 und git — alles Weitere erledigt der Bootstrap.
#    winget ist bei Windows 11 bereits dabei.
winget install Microsoft.PowerShell Git.Git

# 2. pwsh ALS ADMINISTRATOR starten (nicht Windows PowerShell).
#    Ohne erhöhte Rechte überspringt system.ps1 LongPathsEnabled und den
#    Developer Mode — dann brauchst du einen zweiten Lauf.
git clone https://github.com/Zwelckovich/mwga.git C:\mwga
cd C:\mwga

# 3. Starten.
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

Vorher gefahrlos anschauen, was passieren würde:

```powershell
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -DryRun
```

**Warum `-ExecutionPolicy Bypass`?** Auf einer frischen Installation kann die
Policy auf `Restricted` stehen. Windows verweigert den Start des Skripts dann,
*bevor* `system.ps1` die Policy setzen könnte — ein Henne-Ei-Problem. `Bypass`
gilt nur für diesen einen Prozess; `system.ps1` setzt anschließend dauerhaft
`RemoteSigned` für deinen Benutzer, danach genügt `.\bootstrap.ps1`.

`bootstrap.ps1` ist idempotent — ein zweiter Lauf installiert nichts doppelt und
dient zugleich als Reparatur. Am Ende läuft `verify.ps1` und sagt, was fehlt.

## Was drin ist

| Bereich | Inhalt |
|---|---|
| **Shell** | PowerShell 7, Windows Terminal, oh-my-posh, JetBrainsMono Nerd Font |
| **Git** | git, GitHub CLI, lazygit, delta als Diff-Pager |
| **CLI** | bat, fd, ripgrep, fzf, zoxide, jq, eza, yazi, btop, make, tealdeer, gsudo, yt-dlp, ImageMagick, Poppler, D2 |
| **Sprachen** | rustup, Node LTS, Python 3.13, uv, bun |
| **Apps** | VS Code, PowerToys, Chrome, Notepad++ |
| **Configs** | PowerShell-Profil, VS Code (Settings + 54 Erweiterungen), Windows Terminal, Claude Code |

Vollständige Liste: `manifests/winget.json` und `manifests/scoop.json`.

## Täglich

```powershell
up          # aktualisiert winget, scoop, uv, bun, claude, rustup, PS-Module
verify      # .\verify.ps1 — prüft, ob die Maschine noch dem Repo entspricht
```

## Pflege

**Neues Paket aufnehmen** — Datei bearbeiten, nicht Code:

| Woher | Datei |
|---|---|
| winget | `manifests/winget.json` |
| scoop | `manifests/scoop.json` |
| PowerShell-Modul | `manifests/modules.txt` |
| rustup-Komponente | `manifests/rust.txt` |

Danach `.\bootstrap.ps1` — der Rest passiert von selbst.

**Profil ändern** — `profile/profile.ps1` bearbeiten. `$PROFILE` enthält nur eine
Weiche auf diese Datei, es gibt also nichts zu synchronisieren; eine neue Shell
genügt.

## Aufbau

```
bootstrap.ps1        einziger Einstiegspunkt, idempotent, -DryRun
verify.ps1           Prüfbericht, auch einzeln aufrufbar
system.ps1           Explorer, LongPaths, Developer Mode, ExecutionPolicy
manifests/           was installiert wird — Listen, kein Code
profile/             PowerShell-Profil und oh-my-posh-Theme
vscode/              settings.json, Erweiterungsliste, Installationsskript
terminal/            Windows-Terminal-Konfiguration
claude/              Claude-Code-Einstellungen
```

## Die Entscheidungen dahinter

**winget zuerst, scoop für die Lücken.** Genau eine Quelle pro Werkzeug — das ist
die Regel gegen doppelte Installationen. In der Praxis deckt winget fast alles ab;
`zellij` und `resvg` fehlen dort und kommen deshalb aus scoop. `verify.ps1` prüft
aktiv auf doppelte Binaries, weil zwei `ffmpeg` im PATH genau der Fehler waren,
der diesen Umbau ausgelöst hat.

**uv, bun und Claude Code kommen über ihre eigenen Installer.** `uv self update`,
`bun upgrade` und `claude update` funktionieren nur so — bei einer Installation
über einen Paketmanager verweigern sie den Dienst.

**Das Profil lädt lazy.** oh-my-posh zeichnet den Prompt sofort; posh-git wird
erst beim ersten `git <Tab>` geladen, PSFzf erst beim ersten Ctrl+R. Terminal-Icons
ist ersatzlos entfallen, weil `eza --icons` dasselbe ohne Ladezeit kann. Das spart
rund zwei Sekunden bei jedem Shell-Start.

**Die Identität bleibt Handarbeit.** Der Bootstrap schreibt nur die delta-Einträge
in die globale `.gitconfig`. `user.name` und `user.email` setzt du selbst — dieses
Repo trägt keine Identität in deine Git-Konfiguration.

**Deno ist Absicht.** `yt-dlp.yt-dlp` erzwingt in winget die Abhängigkeiten
`DenoLand.Deno` und `yt-dlp.FFmpeg`. Beide stehen deshalb nicht im Manifest,
werden aber mitinstalliert. `yt-dlp.FFmpeg` ist zugleich das einzige ffmpeg im
System — `Gyan.FFmpeg` wurde bewusst weggelassen, um das Duplikat zu vermeiden.
