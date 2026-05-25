# Local Windows Software Inventory - read-only
# Run inside the Windows VM from an RDP PowerShell window.
# It writes CSV/JSON files plus a ZIP to your Desktop by default.

param(
  [string]$OutputDir = "$([Environment]::GetFolderPath('Desktop'))\software-inventory-$((Get-Date).ToString('yyyyMMdd-HHmmss'))",
  [switch]$SkipAppx
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$ErrorLog = Join-Path $OutputDir 'errors.log'

function Log-Warn {
  param([string]$Message)
  $line = "WARN: $Message"
  Write-Warning $Message
  Add-Content -Path $ErrorLog -Value $line
}

function Convert-InstallDate {
  param([object]$Value)
  $raw = if ($null -ne $Value) { [string]$Value } else { $null }
  $iso = $null
  if ($raw -match '^\d{8}$') {
    try { $iso = ([datetime]::ParseExact($raw, 'yyyyMMdd', $null)).ToString('yyyy-MM-dd') } catch { $iso = $null }
  }
  [PSCustomObject]@{ Raw = $raw; Iso = $iso }
}

function New-Row {
  param(
    [string]$Source,
    [string]$Architecture,
    [string]$DisplayName,
    [string]$DisplayVersion,
    [string]$Publisher,
    [object]$InstallDateRaw,
    [string]$InstallLocation,
    [string]$UninstallString,
    [string]$QuietUninstallString,
    [string]$RegistryKey,
    [string]$RegistryPath
  )
  $installDate = Convert-InstallDate $InstallDateRaw
  [PSCustomObject]@{
    ComputerName         = $env:COMPUTERNAME
    User                 = "$env:USERDOMAIN\$env:USERNAME"
    Source               = $Source
    Architecture         = $Architecture
    DisplayName          = $DisplayName
    DisplayVersion       = $DisplayVersion
    Publisher            = $Publisher
    InstallDate          = $installDate.Iso
    InstallDateRaw       = $installDate.Raw
    InstallLocation      = $InstallLocation
    RegistryKey          = $RegistryKey
    RegistryPath         = $RegistryPath
    UninstallString      = $UninstallString
    QuietUninstallString = $QuietUninstallString
  }
}

function Read-UninstallProviderPath {
  param([string]$Path, [string]$Source, [string]$Architecture)
  try {
    Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -and $_.DisplayName.Trim().Length -gt 0 } |
      ForEach-Object {
        New-Row -Source $Source -Architecture $Architecture -DisplayName ([string]$_.DisplayName) `
          -DisplayVersion ([string]$_.DisplayVersion) -Publisher ([string]$_.Publisher) `
          -InstallDateRaw $_.InstallDate -InstallLocation ([string]$_.InstallLocation) `
          -UninstallString ([string]$_.UninstallString) -QuietUninstallString ([string]$_.QuietUninstallString) `
          -RegistryKey ([string]$_.PSChildName) -RegistryPath ([string]$_.PSPath)
      }
  } catch { Log-Warn "Failed reading $Path : $($_.Exception.Message)" }
}

function Read-LoadedUserUninstallKeys {
  try {
    Get-ChildItem -Path Registry::HKEY_USERS -ErrorAction SilentlyContinue |
      Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' } |
      ForEach-Object {
        $sid = $_.PSChildName
        foreach ($path in @(
          "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
          "Registry::HKEY_USERS\$sid\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )) {
          Read-UninstallProviderPath -Path $path -Source "HKEY_USERS:$sid" -Architecture 'per-user'
        }
      }
  } catch { Log-Warn "Failed reading loaded HKEY_USERS uninstall keys : $($_.Exception.Message)" }
}

function Read-ProgramsProvider {
  try {
    Get-Package -ProviderName Programs -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -and $_.Name.Trim().Length -gt 0 } |
      ForEach-Object {
        New-Row -Source 'Get-Package:Programs' -Architecture 'programs-provider' -DisplayName ([string]$_.Name) `
          -DisplayVersion ([string]$_.Version) -Publisher ([string]$_.ProviderName) `
          -InstallDateRaw $null -InstallLocation $null -UninstallString $null -QuietUninstallString $null `
          -RegistryKey ([string]$_.FastPackageReference) -RegistryPath 'Get-Package:Programs'
      }
  } catch { Log-Warn "Failed reading Get-Package Programs provider : $($_.Exception.Message)" }
}

function Read-AppxAllUsers {
  if ($SkipAppx) { return }
  try {
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -and $_.Name.Trim().Length -gt 0 } |
      ForEach-Object {
        New-Row -Source 'Get-AppxPackage:AllUsers' -Architecture "Appx:$($_.Architecture)" -DisplayName ([string]$_.Name) `
          -DisplayVersion ([string]$_.Version) -Publisher ([string]$_.Publisher) `
          -InstallDateRaw $null -InstallLocation ([string]$_.InstallLocation) -UninstallString $null -QuietUninstallString $null `
          -RegistryKey ([string]$_.PackageFullName) -RegistryPath 'Get-AppxPackage:AllUsers'
      }
  } catch { Log-Warn "Failed reading Appx packages : $($_.Exception.Message)" }
}

Write-Host "Collecting local software inventory from $env:COMPUTERNAME..."
$rows = @()
$rows += @(Read-UninstallProviderPath -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -Source 'HKLM' -Architecture 'x64')
$rows += @(Read-UninstallProviderPath -Path 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -Source 'HKLM' -Architecture 'x86')
$rows += @(Read-UninstallProviderPath -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -Source 'HKCU' -Architecture 'x64')
$rows += @(Read-UninstallProviderPath -Path 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -Source 'HKCU' -Architecture 'x86')
$rows += @(Read-LoadedUserUninstallKeys)
$rows += @(Read-ProgramsProvider)
$rows += @(Read-AppxAllUsers)

$dedup = @($rows | Where-Object { $_ -and $_.DisplayName } | Sort-Object ComputerName, DisplayName, DisplayVersion, Publisher, Source, Architecture -Unique)

$csv = Join-Path $OutputDir 'software-inventory.csv'
$json = Join-Path $OutputDir 'software-inventory.json'
$summary = Join-Path $OutputDir 'summary.txt'
$zip = "$OutputDir.zip"

$dedup | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv
$dedup | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path $json

@(
  "Computer: $env:COMPUTERNAME",
  "User: $env:USERDOMAIN\$env:USERNAME",
  "Generated: $((Get-Date).ToString('s'))",
  "Rows: $($dedup.Count)",
  "CSV: $csv",
  "JSON: $json",
  "Errors: $ErrorLog"
) | Set-Content -Encoding UTF8 -Path $summary

if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip -Force

Write-Host "DONE"
Write-Host "Rows: $($dedup.Count)"
Write-Host "CSV: $csv"
Write-Host "ZIP: $zip"
