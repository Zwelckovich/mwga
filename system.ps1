<#
.SYNOPSIS
    Setzt die Windows-Systemeinstellungen, die man auf jeder frischen Maschine
    ohnehin von Hand klickt.

.DESCRIPTION
    Idempotent: jeder Wert wird gelesen, bevor er geschrieben wird, und schon
    korrekte Werte werden uebersprungen. Der groesste Teil liegt unter HKCU und
    braucht keine erhoehten Rechte; nur LongPaths und der Developer Mode
    schreiben nach HKLM und werden ohne Adminrechte uebersprungen.

.PARAMETER DryRun
    Zeigt nur, was geaendert wuerde, ohne die Registry anzufassen.

.EXAMPLE
    .\system.ps1 -DryRun
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Set-RegistryValue {
    <#
    .SYNOPSIS
        Schreibt einen Registry-Wert, wenn er fehlt oder abweicht.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [string]$Type = 'DWord',
        [string]$Label
    )

    $label = if ($Label) { $Label } else { $Name }

    $current = $null
    if (Test-Path $Path) {
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    }

    if ($current -eq $Value) {
        Write-Host ("    ok      {0}" -f $label) -ForegroundColor DarkGray
        return
    }

    if ($DryRun) {
        Write-Host ("    wuerde  {0}  ({1} -> {2})" -f $label, ($current ?? 'nicht gesetzt'), $Value) -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
    Write-Host ("    gesetzt {0}  ({1} -> {2})" -f $label, ($current ?? 'nicht gesetzt'), $Value) -ForegroundColor Green
}

Write-Host '  Explorer' -ForegroundColor Cyan

$advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
# 0 = Dateiendungen anzeigen (Windows blendet sie standardmaessig aus).
Set-RegistryValue -Path $advanced -Name 'HideFileExt' -Value 0 -Label 'Dateiendungen anzeigen'
# 1 = versteckte Dateien anzeigen.
Set-RegistryValue -Path $advanced -Name 'Hidden' -Value 1 -Label 'versteckte Dateien anzeigen'

$cabinet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'
# Vollen Pfad in die Titelleiste statt nur des Ordnernamens.
Set-RegistryValue -Path $cabinet -Name 'FullPath' -Value 1 -Label 'vollen Pfad in Titelleiste'

Write-Host '  Entwicklung' -ForegroundColor Cyan

if ($isAdmin) {
    # Hebt das 260-Zeichen-Limit auf. Ohne das scheitern tiefe node_modules-
    # und Python-Paketbaeume mit kryptischen Fehlern.
    Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
        -Name 'LongPathsEnabled' -Value 1 -Label 'LongPathsEnabled (260-Zeichen-Limit aus)'

    # Erlaubt Symlinks ohne Adminrechte und das Querladen von Apps.
    Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
        -Name 'AllowDevelopmentWithoutDevLicense' -Value 1 -Label 'Developer Mode'
} else {
    Write-Host '    uebersprungen  LongPathsEnabled + Developer Mode (brauchen Adminrechte)' -ForegroundColor Yellow
    Write-Host '                   -> system.ps1 einmal in einer Admin-Shell nachziehen' -ForegroundColor DarkGray
}

# Ohne RemoteSigned laufen weder dieses Repo noch die `irm | iex`-Installer.
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
    Write-Host ("    ok      ExecutionPolicy ({0})" -f $policy) -ForegroundColor DarkGray
} elseif ($DryRun) {
    Write-Host ("    wuerde  ExecutionPolicy ({0} -> RemoteSigned)" -f $policy) -ForegroundColor Yellow
} else {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-Host ("    gesetzt ExecutionPolicy ({0} -> RemoteSigned)" -f $policy) -ForegroundColor Green
}

Write-Host '  Hinweis: Explorer-Aenderungen greifen nach einem Neustart von explorer.exe' -ForegroundColor DarkGray
