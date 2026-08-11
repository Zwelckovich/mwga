# CLAUDE.local.md

Umgebungsspezifische Erkenntnisse zu diesem Repo. Nicht offensichtliche Dinge,
die beim nächsten Mal Zeit sparen.

## Projekttyp

Dotfiles-/Bootstrap-Repo, kein Softwareprojekt. Kein `CONCEPT.md` — für
Meta-Repos greift die BONSAI-Ausnahme. Kein Python, kein JavaScript: `/pycheck`
und `/reactcheck` sind hier nicht anwendbar. Qualitätssicherung läuft über
den PowerShell-AST-Parser und PSScriptAnalyzer.

## Zielsystem ≠ Entwicklungssystem

Das Repo wird auf einem **privaten Windows-11-PC mit Adminrechten** ausgerollt.
Entwickelt wurde es auf einer **Corporate-Maschine (RSINT)** ohne Adminrechte,
mit Symantec Endpoint Protection. Konsequenzen:

- Zeitmessungen auf der Entwicklungsmaschine sind nach oben verzerrt und
  schwanken stark (Basis-Shellstart zwischen 543 und 1.089 ms gemessen).
  Nur Relationen sind belastbar, keine Absolutwerte.
- `bootstrap.ps1` lässt sich hier nur per `-DryRun` prüfen.
- `verify.ps1` läuft echt, meldet aber erwartbar fehlende Pakete — die
  Entwicklungsmaschine ist nicht das Ziel.

## Fallstricke, die diese Session gekostet haben

**ExecutionPolicy ist ein Henne-Ei-Problem.** `system.ps1` setzt zwar
`RemoteSigned`, aber auf einer frischen Installation kann die Policy auf
`Restricted` stehen — dann startet `bootstrap.ps1` gar nicht erst und kommt nie
bis zu der Zeile, die das Problem behebt. Der erste Aufruf auf einer neuen
Maschine muss deshalb `pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1`
lauten. `Bypass` gilt nur für diesen Prozess. Auf dieser Entwicklungsmaschine
fällt es nicht auf, weil `LocalMachine` bereits auf `RemoteSigned` steht.

**`winget search` taugt nicht zur Existenzprüfung.** Bei einem Nicht-Treffer
liefert es nicht zuverlässig die erwartete Meldung — eine Prüfung per
Textmuster erzeugt Falsch-Positive. Stattdessen `winget show --id X --exact`
und `$LASTEXITCODE` auswerten. So kam heraus, dass `zellij-org.zellij` und
`ez-windows.RSVG` gar nicht existieren; beide kommen jetzt aus scoop.

**Nerd Fonts heißen in der Registry „NF", nicht „Nerd Font".** Unter
`HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` stehen sie als
`JetBrainsMono NF Regular`, `JetBrainsMono NFM Bold`, `JetBrainsMono NFP …`.
Nur der Explorer-Anzeigename (via `Shell.Application`) lautet
„JetBrainsMono Nerd Font". Eine Suche nach „Nerd" in der Registry geht leer aus.

**PSFzf-Tastenhandler sind nicht exportiert.** `Invoke-FzfPsReadlineHandlerHistory`
und `Invoke-FzfPsReadlineHandlerProvider` sind modulintern, aber über den
Modul-SessionState erreichbar: `& (Get-Module PSFzf) { Invoke-… }`. Das macht
echtes Lazy-Loading möglich, bei dem schon der *erste* Tastendruck durchläuft.

**`Get-Command` löst Modul-Autoloading aus.** Um zu prüfen, ob ein Modul
wirklich noch ungeladen ist, `Get-Module` verwenden — `Get-Command` findet
Befehle auch in bloß *verfügbaren* Modulen und täuscht einen Ladevorgang vor.

**`$PID` ist schreibgeschützt.** `$pid = …` wirft
„Cannot overwrite variable PID because it is read-only or constant." In
Port-Kill-Funktionen muss die Variable anders heißen.

**In PowerShell schlägt ein Alias eine Funktion.** Um `ls` auf `eza`
umzubiegen, muss erst `Remove-Item Alias:ls` laufen — eine gleichnamige
Funktion allein greift nicht.

## winget-Eigenheiten

- **`yt-dlp.yt-dlp` erzwingt `DenoLand.Deno` und `yt-dlp.FFmpeg`** als harte
  Paketabhängigkeiten. Beide stehen deshalb bewusst nicht im Manifest, landen
  aber trotzdem auf der Platte. `Gyan.FFmpeg` wurde weggelassen, damit genau
  ein ffmpeg im PATH liegt.
- **Portable-Pakete blähen den PATH auf.** bat, fd, ripgrep, yazi, ffmpeg und
  Poppler landen nicht als Shim in `WinGet\Links`, sondern als kompletter,
  versionierter Ordner im PATH (`ripgrep-15.1.0-x86_64-pc-windows-msvc`).
  Bei jedem Upgrade ändert sich der Pfad. Bekannter Preis der winget-first-Regel;
  `verify.ps1` meldet die PATH-Größe deshalb aktiv.

## Konventionen in diesem Repo

- **Skripte sind reines ASCII.** Keine Box-Zeichen, keine Umlaute, keine
  Gedankenstriche — sonst verlangt PSScriptAnalyzer ein BOM
  (`PSUseBOMForUnicodeEncodedFile`) und die Dateien werden encoding-abhängig.
  Markdown und JSON dürfen Unicode enthalten.
- **Pfade im Profil über `$PSScriptRoot`**, nie hartkodiert. Beim Dot-Sourcing
  wird `$PSScriptRoot` korrekt auf den Repo-Ordner gesetzt, das Profil ist
  damit unabhängig vom Ablageort.
- **Manifeste enthalten Listen, Skripte enthalten Logik.** Ein neues Paket
  bedeutet eine Zeile in `manifests/`, keine Codeänderung.
