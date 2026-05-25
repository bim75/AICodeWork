<#
AD Active Devices and Login Times - read-only

Simple AD-only report. No WinRM. No remote registry. No software inventory.

Outputs:
  active-devices-logons.csv
  stale-or-disabled-devices.csv
  summary.txt
  ad-active-devices-logons-<timestamp>.zip

Notes:
  - LastLogonTimestamp is replicated but approximate, usually 9-14 days granularity.
  - For exact per-DC lastLogon, use -ExactLastLogon. It queries every domain controller and is slower.
#>

[CmdletBinding()]
param(
  [string]$SearchBase,
  [int]$ActiveDays = 90,
  [switch]$WindowsOnly,
  [switch]$ServersOnly,
  [switch]$ExactLastLogon,
  [string]$OutputDir = ".\ad-active-devices-logons-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

function Convert-FileTimeSafe {
  param([object]$Value)
  try {
    if ($null -eq $Value) { return $null }
    $i = [Int64]$Value
    if ($i -le 0) { return $null }
    return [DateTime]::FromFileTime($i)
  } catch { return $null }
}

function Convert-DateSafe {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  try { return ([DateTime]$Value) } catch { return $null }
}

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
$dcs = @()
if ($ExactLastLogon) {
  Write-Host "ExactLastLogon requested. Querying domain controllers for non-replicated lastLogon..."
  $dcs = @(Get-ADDomainController -Filter * | Sort-Object HostName)
  Write-Host "Domain controllers: $($dcs.Count)"
}

$properties = @(
  'DNSHostName','OperatingSystem','OperatingSystemVersion','Enabled',
  'LastLogonTimestamp','LastLogonDate','PasswordLastSet','WhenCreated','WhenChanged',
  'IPv4Address','CanonicalName','DistinguishedName','Description','ManagedBy','PrimaryGroupID'
)

$filter = '*'
if ($ServersOnly) {
  $filter = "OperatingSystem -like '*Server*'"
} elseif ($WindowsOnly) {
  $filter = "OperatingSystem -like '*Windows*'"
}
Write-Host "Querying AD computers. Filter: $filter"
if ($SearchBase) {
  $computers = @(Get-ADComputer -Filter $filter -SearchBase $SearchBase -Properties $properties | Sort-Object Name)
} else {
  $computers = @(Get-ADComputer -Filter $filter -Properties $properties | Sort-Object Name)
}

Write-Host "AD computer objects found: $($computers.Count)"
$cutoff = (Get-Date).AddDays(-1 * $ActiveDays)
$rows = New-Object System.Collections.Generic.List[object]
$index = 0

foreach ($c in $computers) {
  $index++
  Write-Progress -Activity 'AD active devices and login times' -Status "$index/$($computers.Count) $($c.Name)" -PercentComplete (($index / [math]::Max($computers.Count,1)) * 100)

  $replicatedLastLogon = Convert-DateSafe $c.LastLogonDate
  if (-not $replicatedLastLogon) { $replicatedLastLogon = Convert-FileTimeSafe $c.LastLogonTimestamp }

  $exactLastLogon = $null
  $exactLastLogonDc = $null
  if ($ExactLastLogon) {
    foreach ($dc in $dcs) {
      try {
        $dcComputer = Get-ADComputer -Identity $c.DistinguishedName -Server $dc.HostName -Properties lastLogon -ErrorAction Stop
        $dcLastLogon = Convert-FileTimeSafe $dcComputer.lastLogon
        if ($dcLastLogon -and ((-not $exactLastLogon) -or $dcLastLogon -gt $exactLastLogon)) {
          $exactLastLogon = $dcLastLogon
          $exactLastLogonDc = $dc.HostName
        }
      } catch {
        Write-Warning "$($c.Name) - could not query lastLogon from $($dc.HostName): $($_.Exception.Message)"
      }
    }
  }

  $bestLastLogon = if ($ExactLastLogon -and $exactLastLogon) { $exactLastLogon } else { $replicatedLastLogon }
  $daysSinceLastLogon = $null
  if ($bestLastLogon) { $daysSinceLastLogon = [math]::Round(((Get-Date) - $bestLastLogon).TotalDays, 1) }

  $isActive = $false
  if ($c.Enabled -and $bestLastLogon -and $bestLastLogon -ge $cutoff) { $isActive = $true }

  $passwordLastSet = Convert-DateSafe $c.PasswordLastSet
  $whenCreated = Convert-DateSafe $c.WhenCreated
  $whenChanged = Convert-DateSafe $c.WhenChanged

  $rows.Add([PSCustomObject]@{
    Name                         = [string]$c.Name
    DNSHostName                  = [string]$c.DNSHostName
    Enabled                      = [bool]$c.Enabled
    ActiveWithinDays             = $ActiveDays
    IsActive                     = [bool]$isActive
    BestLastLogon                = if ($bestLastLogon) { $bestLastLogon.ToString('s') } else { $null }
    BestLastLogonSource          = if ($ExactLastLogon) { 'lastLogon per-DC max' } else { 'LastLogonTimestamp/LastLogonDate replicated' }
    DaysSinceBestLastLogon       = $daysSinceLastLogon
    ReplicatedLastLogon          = if ($replicatedLastLogon) { $replicatedLastLogon.ToString('s') } else { $null }
    ExactLastLogon               = if ($exactLastLogon) { $exactLastLogon.ToString('s') } else { $null }
    ExactLastLogonDomainController = $exactLastLogonDc
    OperatingSystem              = [string]$c.OperatingSystem
    OperatingSystemVersion       = [string]$c.OperatingSystemVersion
    IPv4Address                  = [string]$c.IPv4Address
    PasswordLastSet              = if ($passwordLastSet) { $passwordLastSet.ToString('s') } else { $null }
    WhenCreated                  = if ($whenCreated) { $whenCreated.ToString('s') } else { $null }
    WhenChanged                  = if ($whenChanged) { $whenChanged.ToString('s') } else { $null }
    CanonicalName                = [string]$c.CanonicalName
    DistinguishedName            = [string]$c.DistinguishedName
    Description                  = [string]$c.Description
    ManagedBy                    = [string]$c.ManagedBy
  }) | Out-Null
}
Write-Progress -Activity 'AD active devices and login times' -Completed

$activeRows = @($rows | Where-Object { $_.IsActive } | Sort-Object BestLastLogon -Descending)
$inactiveRows = @($rows | Where-Object { -not $_.IsActive } | Sort-Object Enabled, BestLastLogon)

$activeCsv = Join-Path $OutputDir 'active-devices-logons.csv'
$inactiveCsv = Join-Path $OutputDir 'stale-or-disabled-devices.csv'
$summary = Join-Path $OutputDir 'summary.txt'
$zip = "$OutputDir.zip"

$activeRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $activeCsv
$inactiveRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $inactiveCsv

@(
  "AD Active Devices and Login Times",
  "Generated: $((Get-Date).ToString('s'))",
  "Domain: $($domain.DNSRoot)",
  "SearchBase: $(if ($SearchBase) { $SearchBase } else { 'entire domain' })",
  "WindowsOnly: $WindowsOnly",
  "ServersOnly: $ServersOnly",
  "ActiveDays: $ActiveDays",
  "ExactLastLogon: $ExactLastLogon",
  "Total AD computer objects: $($rows.Count)",
  "Active enabled devices: $($activeRows.Count)",
  "Stale or disabled devices: $($inactiveRows.Count)",
  "Active CSV: $activeCsv",
  "Stale/disabled CSV: $inactiveCsv"
) | Set-Content -Encoding UTF8 -Path $summary

if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip -Force

Write-Host "DONE"
Write-Host "Total AD computer objects: $($rows.Count)"
Write-Host "Active enabled devices: $($activeRows.Count)"
Write-Host "Stale or disabled devices: $($inactiveRows.Count)"
Write-Host "Output folder: $OutputDir"
Write-Host "ZIP: $zip"
Write-Host "Main report: $activeCsv"
