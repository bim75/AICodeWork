<#
AD Windows Asset Inventory - read-only

Discovers Windows computer objects from Active Directory, then optionally enriches
reachable machines with live hardware/platform and installed software data.

Outputs, under .\ad-windows-asset-inventory-<timestamp> by default:
  computers-ad.csv              AD-discovered Windows computer objects
  computers-live.csv            Live reachable machine enrichment
  software-inventory.csv        Optional installed software rows when -IncludeSoftware is used
  errors.log                    Offline/unreachable/permission errors
  summary.txt
  ad-windows-asset-inventory-<timestamp>.zip

Examples:
  .\ad-windows-asset-inventory.ps1
  .\ad-windows-asset-inventory.ps1 -SearchBase "OU=Servers,DC=example,DC=com"
  .\ad-windows-asset-inventory.ps1 -ComputerName SERVER01,PC042 -IncludeSoftware
  .\ad-windows-asset-inventory.ps1 -IncludeSoftware -ThrottleLimit 16

Requirements:
  - Run from a domain-joined Windows admin workstation/server.
  - RSAT Active Directory PowerShell module for AD discovery.
  - PowerShell Remoting/WinRM enabled for live enrichment/software inventory.
  - Local admin or equivalent rights on target machines for full remote registry/software visibility.

Safety:
  - Read-only. Does not install, update, uninstall, or modify software.
  - Does not use Win32_Product because that can trigger MSI repair actions.
#>

[CmdletBinding()]
param(
  [string]$SearchBase,
  [string[]]$ComputerName,
  [string]$OutputDir = ".\ad-windows-asset-inventory-$((Get-Date).ToString('yyyyMMdd-HHmmss'))",
  [switch]$IncludeSoftware,
  [switch]$SkipAppx,
  [int]$ThrottleLimit = 12,
  [int]$RemoteTimeoutSeconds = 30,
  [int]$StopAfterConsecutiveRemoteFailures = 25,
  [switch]$ContinueAfterMassRemoteFailure
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$ErrorLog = Join-Path $OutputDir 'errors.log'

function Write-Log {
  param([string]$Level, [string]$Message)
  $line = "{0} {1}: {2}" -f (Get-Date).ToString('s'), $Level, $Message
  Add-Content -Path $ErrorLog -Value $line
  if ($Level -eq 'WARN') { Write-Warning $Message } else { Write-Host $Message }
}

function Convert-FileTimeSafe {
  param([object]$Value)
  try {
    if ($null -eq $Value) { return $null }
    $i = [Int64]$Value
    if ($i -le 0) { return $null }
    return ([DateTime]::FromFileTime($i)).ToString('s')
  } catch { return $null }
}

function Get-PlatformClassification {
  param([string]$Manufacturer, [string]$Model)
  $mfg = ($Manufacturer | ForEach-Object { [string]$_ }).Trim()
  $mdl = ($Model | ForEach-Object { [string]$_ }).Trim()
  $combo = "$mfg $mdl"

  if ($combo -match '(?i)VMware|VirtualBox|KVM|QEMU|Xen|HVM domU') { return 'Virtual' }
  if ($combo -match '(?i)Microsoft Corporation Virtual Machine|Hyper-V|Virtual Machine') { return 'Virtual' }
  if ($combo -match '(?i)Amazon EC2|Google Compute Engine|OpenStack') { return 'CloudVirtual' }
  if ([string]::IsNullOrWhiteSpace($combo)) { return 'Unknown' }
  return 'Physical'
}

function Get-HypervisorGuess {
  param([string]$Manufacturer, [string]$Model, [string]$BiosSerial)
  $combo = "$Manufacturer $Model $BiosSerial"
  if ($combo -match '(?i)VMware') { return 'VMware' }
  if ($combo -match '(?i)Microsoft Corporation Virtual Machine|Hyper-V') { return 'Hyper-V/Azure' }
  if ($combo -match '(?i)VirtualBox') { return 'VirtualBox' }
  if ($combo -match '(?i)KVM|QEMU') { return 'KVM/QEMU' }
  if ($combo -match '(?i)Xen|HVM domU') { return 'Xen' }
  if ($combo -match '(?i)Amazon EC2') { return 'AWS EC2' }
  if ($combo -match '(?i)Google Compute Engine') { return 'Google Compute Engine' }
  return $null
}

function Get-ProviderGuess {
  param([string]$Manufacturer, [string]$Model, [string]$BiosSerial)
  $combo = "$Manufacturer $Model $BiosSerial"
  if ($combo -match '(?i)VMware') { return 'VMware' }
  if ($combo -match '(?i)Microsoft Corporation Virtual Machine|Hyper-V') { return 'Azure or Hyper-V' }
  if ($combo -match '(?i)Amazon EC2') { return 'AWS' }
  if ($combo -match '(?i)Google Compute Engine') { return 'Google Cloud' }
  if ($combo -match '(?i)VirtualBox') { return 'VirtualBox' }
  if ($combo -match '(?i)KVM|QEMU|OpenStack') { return 'KVM/OpenStack' }
  return 'Physical/Unknown'
}

function Get-AdWindowsComputers {
  Import-Module ActiveDirectory -ErrorAction Stop

  $properties = @(
    'DNSHostName','OperatingSystem','OperatingSystemVersion','OperatingSystemServicePack',
    'Enabled','LastLogonTimestamp','WhenCreated','WhenChanged','CanonicalName','Description',
    'IPv4Address','ManagedBy','DistinguishedName'
  )

  if ($ComputerName -and $ComputerName.Count -gt 0) {
    foreach ($name in $ComputerName) {
      $ldap = "(|(name=$name)(dNSHostName=$name))"
      Get-ADComputer -LDAPFilter $ldap -Properties $properties -ErrorAction Continue
    }
  } else {
    $filter = "OperatingSystem -like '*Windows*'"
    if ($SearchBase) {
      Get-ADComputer -Filter $filter -SearchBase $SearchBase -Properties $properties -ErrorAction Stop
    } else {
      Get-ADComputer -Filter $filter -Properties $properties -ErrorAction Stop
    }
  }
}

function Convert-AdComputerRow {
  param([object]$Computer)
  $whenCreated = $null
  $whenChanged = $null
  if ($Computer.WhenCreated) { $whenCreated = $Computer.WhenCreated.ToString('s') }
  if ($Computer.WhenChanged) { $whenChanged = $Computer.WhenChanged.ToString('s') }
  [PSCustomObject]@{
    Name                       = [string]$Computer.Name
    DNSHostName                = [string]$Computer.DNSHostName
    Enabled                    = [bool]$Computer.Enabled
    OperatingSystem            = [string]$Computer.OperatingSystem
    OperatingSystemVersion     = [string]$Computer.OperatingSystemVersion
    OperatingSystemServicePack = [string]$Computer.OperatingSystemServicePack
    IPv4Address                = [string]$Computer.IPv4Address
    LastLogonTimestamp         = Convert-FileTimeSafe $Computer.LastLogonTimestamp
    WhenCreated                = $whenCreated
    WhenChanged                = $whenChanged
    CanonicalName              = [string]$Computer.CanonicalName
    DistinguishedName          = [string]$Computer.DistinguishedName
    Description                = [string]$Computer.Description
    ManagedBy                  = [string]$Computer.ManagedBy
  }
}

$remoteScript = {
  param([bool]$DoSoftware, [bool]$DoSkipAppx)

  function Convert-InstallDate {
    param([object]$Value)
    $raw = if ($null -ne $Value) { [string]$Value } else { $null }
    $iso = $null
    if ($raw -match '^\d{8}$') {
      try { $iso = ([datetime]::ParseExact($raw, 'yyyyMMdd', $null)).ToString('yyyy-MM-dd') } catch { $iso = $null }
    }
    [PSCustomObject]@{ Raw = $raw; Iso = $iso }
  }

  function New-SoftwareRow {
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
          New-SoftwareRow -Source $Source -Architecture $Architecture -DisplayName ([string]$_.DisplayName) `
            -DisplayVersion ([string]$_.DisplayVersion) -Publisher ([string]$_.Publisher) `
            -InstallDateRaw $_.InstallDate -InstallLocation ([string]$_.InstallLocation) `
            -UninstallString ([string]$_.UninstallString) -QuietUninstallString ([string]$_.QuietUninstallString) `
            -RegistryKey ([string]$_.PSChildName) -RegistryPath ([string]$_.PSPath)
        }
    } catch {}
  }

  $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
  $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
  $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
  $dnsHostName = $env:COMPUTERNAME
  try {
    $dnsHostName = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
  } catch {
    $dnsHostName = $env:COMPUTERNAME
  }

  $totalMemoryGB = $null
  $lastBoot = $null
  $installDate = $null
  if ($cs.TotalPhysicalMemory) { $totalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) }
  if ($os.LastBootUpTime) { $lastBoot = ([datetime]$os.LastBootUpTime).ToString('s') }
  if ($os.InstallDate) { $installDate = ([datetime]$os.InstallDate).ToString('s') }

  $asset = [PSCustomObject]@{
    ComputerName       = $env:COMPUTERNAME
    DNSHostName        = $dnsHostName
    Reachable          = $true
    Manufacturer       = [string]$cs.Manufacturer
    Model              = [string]$cs.Model
    SystemType         = [string]$cs.SystemType
    Domain             = [string]$cs.Domain
    PartOfDomain       = [bool]$cs.PartOfDomain
    TotalMemoryGB      = $totalMemoryGB
    CpuName            = [string]$cpu.Name
    CpuCores           = [int]$cpu.NumberOfCores
    CpuLogical         = [int]$cpu.NumberOfLogicalProcessors
    OSName             = [string]$os.Caption
    OSVersion          = [string]$os.Version
    OSBuild            = [string]$os.BuildNumber
    OSArchitecture     = [string]$os.OSArchitecture
    LastBoot           = $lastBoot
    InstallDate        = $installDate
    BiosSerial         = [string]$bios.SerialNumber
    BiosVersion        = [string]($bios.SMBIOSBIOSVersion)
  }

  $software = @()
  if ($DoSoftware) {
    $software += @(Read-UninstallProviderPath -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -Source 'HKLM' -Architecture 'x64')
    $software += @(Read-UninstallProviderPath -Path 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -Source 'HKLM' -Architecture 'x86')
    if (-not $DoSkipAppx) {
      try {
        $software += @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -and $_.Name.Trim().Length -gt 0 } |
          ForEach-Object {
            New-SoftwareRow -Source 'Get-AppxPackage:AllUsers' -Architecture "Appx:$($_.Architecture)" -DisplayName ([string]$_.Name) `
              -DisplayVersion ([string]$_.Version) -Publisher ([string]$_.Publisher) `
              -InstallDateRaw $null -InstallLocation ([string]$_.InstallLocation) `
              -UninstallString $null -QuietUninstallString $null -RegistryKey ([string]$_.PackageFullName) `
              -RegistryPath 'Get-AppxPackage:AllUsers'
          })
      } catch {}
    }
  }

  [PSCustomObject]@{
    Asset    = $asset
    Software = @($software | Where-Object { $_ -and $_.DisplayName } | Sort-Object ComputerName, DisplayName, DisplayVersion, Publisher, Source, Architecture -Unique)
  }
}

Write-Host "Discovering Windows computer objects from Active Directory..."
try {
  $adComputers = @(Get-AdWindowsComputers | Sort-Object Name -Unique)
} catch {
  Write-Error "Could not query Active Directory. Install RSAT Active Directory module and run from a domain-joined machine. $($_.Exception.Message)"
  exit 1
}

$adRows = @($adComputers | ForEach-Object { Convert-AdComputerRow $_ })
$adCsv = Join-Path $OutputDir 'computers-ad.csv'
$adRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $adCsv
Write-Host "AD Windows computer objects: $($adRows.Count)"

function Test-IsLocalTarget {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  $candidate = $Name.Trim().TrimEnd('.').ToLowerInvariant()
  $localNames = New-Object 'System.Collections.Generic.HashSet[string]'
  [void]$localNames.Add($env:COMPUTERNAME.ToLowerInvariant())
  try { [void]$localNames.Add(([System.Net.Dns]::GetHostName()).TrimEnd('.').ToLowerInvariant()) } catch {}
  try { [void]$localNames.Add(([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName).TrimEnd('.').ToLowerInvariant()) } catch {}
  try { [void]$localNames.Add(([System.Net.Dns]::GetHostEntry('localhost').HostName).TrimEnd('.').ToLowerInvariant()) } catch {}
  if ($localNames.Contains($candidate)) { return $true }
  foreach ($localName in $localNames) {
    if ($localName -and $localName.Contains('.') -and $localName.Split('.')[0] -eq $candidate) { return $true }
    if ($candidate.Contains('.') -and $candidate.Split('.')[0] -eq $localName) { return $true }
  }
  return $false
}

$liveRows = New-Object System.Collections.Generic.List[object]
$softwareRows = New-Object System.Collections.Generic.List[object]
$targets = @($adRows | Where-Object { $_.Enabled -eq $true })
$total = $targets.Count
$index = 0
$reachableSuccessCount = 0
$consecutiveRemoteFailureCount = 0
$stoppedLiveQueryEarly = $false

Write-Host "Probing $total enabled AD computer(s) for live platform details..."
Write-Host "Progress will print START/WAIT/OK/WARN lines. Timeout per remote batch item: $RemoteTimeoutSeconds seconds."
$batchNumber = 0
foreach ($batch in @($targets | ForEach-Object -Begin { $b=@() } -Process { $b += $_; if ($b.Count -ge $ThrottleLimit) { ,$b; $b=@() } } -End { if ($b.Count) { ,$b } })) {
  if ($stoppedLiveQueryEarly) { break }
  $batchNumber++
  Write-Host "BATCH $batchNumber - starting $($batch.Count) remote query job(s)..."
  $jobs = @()
  foreach ($target in $batch) {
    $name = if ($target.DNSHostName) { $target.DNSHostName } else { $target.Name }
    $isLocalTarget = Test-IsLocalTarget $name
    $job = $null
    $localResult = $null
    if ($isLocalTarget) {
      Write-Host "START $name - local computer detected; collecting directly without WinRM..."
      try {
        $localResult = & $remoteScript ([bool]$IncludeSoftware) ([bool]$SkipAppx)
      } catch {
        Write-Log -Level 'WARN' -Message "$name - local inventory failed: $($_.Exception.Message)"
      }
    } else {
      Write-Host "START $name - launching remote inventory job..."
      try {
        $job = Invoke-Command -ComputerName $name -ScriptBlock $remoteScript -ArgumentList ([bool]$IncludeSoftware), ([bool]$SkipAppx) -AsJob -ErrorAction Stop
      } catch {
        Write-Log -Level 'WARN' -Message "$name - could not start remote query: $($_.Exception.Message)"
      }
    }
    $jobs += [PSCustomObject]@{
      Target = $target
      Job = $job
      IsLocal = $isLocalTarget
      LocalResult = $localResult
    }
  }

  foreach ($item in $jobs) {
    $index++
    $target = $item.Target
    $name = if ($target.DNSHostName) { $target.DNSHostName } else { $target.Name }
    Write-Progress -Activity 'AD Windows asset inventory' -Status "$index/$total $name" -PercentComplete (($index / [math]::Max($total,1)) * 100)
    $job = $item.Job
    if ($item.IsLocal) {
      if ($item.LocalResult) {
        $result = $item.LocalResult
      } else {
        $consecutiveRemoteFailureCount++
        Write-Log -Level 'WARN' -Message "$name - local inventory returned no result"
        if ((-not $ContinueAfterMassRemoteFailure) -and $reachableSuccessCount -eq 0 -and $consecutiveRemoteFailureCount -ge $StopAfterConsecutiveRemoteFailures) {
          Write-Log -Level 'WARN' -Message "Stopping live query after $consecutiveRemoteFailureCount consecutive failures and zero successes. AD-only inventory files were still created. Re-run with -ContinueAfterMassRemoteFailure to force attempts against every target."
          $stoppedLiveQueryEarly = $true
        }
        continue
      }
    } elseif (-not $job) {
      $consecutiveRemoteFailureCount++
      Write-Log -Level 'WARN' -Message "$name - could not start remote query"
      if ((-not $ContinueAfterMassRemoteFailure) -and $reachableSuccessCount -eq 0 -and $consecutiveRemoteFailureCount -ge $StopAfterConsecutiveRemoteFailures) {
        Write-Log -Level 'WARN' -Message "Stopping live remote query after $consecutiveRemoteFailureCount consecutive failures and zero successes. AD-only inventory files were still created. This usually means WinRM is disabled/blocked, DNS cannot resolve targets, or this account lacks local admin rights. Re-run with -ContinueAfterMassRemoteFailure to force attempts against every target."
        $stoppedLiveQueryEarly = $true
      }
      continue
    } else {
      Write-Host "WAIT  $name - waiting up to $RemoteTimeoutSeconds second(s)..."
      $finished = Wait-Job -Job $job -Timeout $RemoteTimeoutSeconds
      if (-not $finished) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $consecutiveRemoteFailureCount++
        Write-Log -Level 'WARN' -Message "$name - timeout/offline/unreachable after $RemoteTimeoutSeconds second(s)"
        if ((-not $ContinueAfterMassRemoteFailure) -and $reachableSuccessCount -eq 0 -and $consecutiveRemoteFailureCount -ge $StopAfterConsecutiveRemoteFailures) {
          Write-Log -Level 'WARN' -Message "Stopping live remote query after $consecutiveRemoteFailureCount consecutive failures and zero successes. AD-only inventory files were still created. This usually means WinRM is disabled/blocked, DNS cannot resolve targets, or this account lacks local admin rights. Re-run with -ContinueAfterMassRemoteFailure to force attempts against every target."
          $stoppedLiveQueryEarly = $true
        }
        continue
      }

      $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
      $jobErrors = @($job.ChildJobs | ForEach-Object { $_.Error } | Where-Object { $_ })
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

      if ($jobErrors.Count -gt 0 -or -not $result) {
        $consecutiveRemoteFailureCount++
        Write-Log -Level 'WARN' -Message "$name - remote query failed: $($jobErrors -join '; ')"
        if ((-not $ContinueAfterMassRemoteFailure) -and $reachableSuccessCount -eq 0 -and $consecutiveRemoteFailureCount -ge $StopAfterConsecutiveRemoteFailures) {
          Write-Log -Level 'WARN' -Message "Stopping live remote query after $consecutiveRemoteFailureCount consecutive failures and zero successes. AD-only inventory files were still created. This usually means WinRM is disabled/blocked, DNS cannot resolve targets, or this account lacks local admin rights. Re-run with -ContinueAfterMassRemoteFailure to force attempts against every target."
          $stoppedLiveQueryEarly = $true
        }
        continue
      }
    }

    $assetCountForTarget = 0
    $softwareCountForTarget = 0
    foreach ($r in @($result)) {
      if ($r.Asset) {
        $assetCountForTarget++
        $asset = $r.Asset
        $platform = Get-PlatformClassification -Manufacturer $asset.Manufacturer -Model $asset.Model
        $hypervisor = Get-HypervisorGuess -Manufacturer $asset.Manufacturer -Model $asset.Model -BiosSerial $asset.BiosSerial
        $provider = Get-ProviderGuess -Manufacturer $asset.Manufacturer -Model $asset.Model -BiosSerial $asset.BiosSerial
        $liveRows.Add([PSCustomObject]@{
          Name                       = $target.Name
          DNSHostName                = $target.DNSHostName
          ADEnabled                  = $target.Enabled
          ADOperatingSystem          = $target.OperatingSystem
          ADOperatingSystemVersion   = $target.OperatingSystemVersion
          LastLogonTimestamp         = $target.LastLogonTimestamp
          CanonicalName              = $target.CanonicalName
          DistinguishedName          = $target.DistinguishedName
          Reachable                  = $true
          ComputerName               = $asset.ComputerName
          LiveDNSHostName            = $asset.DNSHostName
          Domain                     = $asset.Domain
          PartOfDomain               = $asset.PartOfDomain
          PlatformClass              = $platform
          ProviderGuess              = $provider
          HypervisorGuess            = $hypervisor
          Manufacturer               = $asset.Manufacturer
          Model                      = $asset.Model
          SystemType                 = $asset.SystemType
          TotalMemoryGB              = $asset.TotalMemoryGB
          CpuName                    = $asset.CpuName
          CpuCores                   = $asset.CpuCores
          CpuLogical                 = $asset.CpuLogical
          OSName                     = $asset.OSName
          OSVersion                  = $asset.OSVersion
          OSBuild                    = $asset.OSBuild
          OSArchitecture             = $asset.OSArchitecture
          LastBoot                   = $asset.LastBoot
          InstallDate                = $asset.InstallDate
          BiosSerial                 = $asset.BiosSerial
          BiosVersion                = $asset.BiosVersion
        }) | Out-Null
      }
      foreach ($sw in @($r.Software)) {
        $softwareCountForTarget++
        $platformProvider = $null
        if ($r.Asset) {
          $platformProvider = Get-ProviderGuess -Manufacturer $r.Asset.Manufacturer -Model $r.Asset.Model -BiosSerial $r.Asset.BiosSerial
        }
        $softwareRows.Add([PSCustomObject]@{
          ComputerName         = $target.Name
          DNSHostName          = $target.DNSHostName
          PlatformProvider     = $platformProvider
          Source               = $sw.Source
          Architecture         = $sw.Architecture
          DisplayName          = $sw.DisplayName
          DisplayVersion       = $sw.DisplayVersion
          Publisher            = $sw.Publisher
          InstallDate          = $sw.InstallDate
          InstallDateRaw       = $sw.InstallDateRaw
          InstallLocation      = $sw.InstallLocation
          RegistryKey          = $sw.RegistryKey
          RegistryPath         = $sw.RegistryPath
          UninstallString      = $sw.UninstallString
          QuietUninstallString = $sw.QuietUninstallString
        }) | Out-Null
      }
    }
    Write-Host "OK    $name - asset rows: $assetCountForTarget; software rows: $softwareCountForTarget"
    if ($assetCountForTarget -gt 0) {
      $reachableSuccessCount++
      $consecutiveRemoteFailureCount = 0
    } else {
      $consecutiveRemoteFailureCount++
    }
  }
}
Write-Progress -Activity 'AD Windows asset inventory' -Completed

$liveCsv = Join-Path $OutputDir 'computers-live.csv'
$liveRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $liveCsv

$softwareCsv = Join-Path $OutputDir 'software-inventory.csv'
if ($IncludeSoftware) {
  $softwareRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $softwareCsv
}

$summary = Join-Path $OutputDir 'summary.txt'
$zip = "$OutputDir.zip"
@(
  "AD Windows Asset Inventory",
  "Generated: $((Get-Date).ToString('s'))",
  "AD Windows computer objects: $($adRows.Count)",
  "Enabled AD targets probed: $total",
  "Reachable/live rows: $($liveRows.Count)",
  "Remote successes: $reachableSuccessCount",
  "Consecutive remote failures at end: $consecutiveRemoteFailureCount",
  "Stopped live query early: $stoppedLiveQueryEarly",
  "Software rows: $($softwareRows.Count)",
  "AD CSV: $adCsv",
  "Live CSV: $liveCsv",
  "Software CSV: $(if ($IncludeSoftware) { $softwareCsv } else { 'not requested; rerun with -IncludeSoftware' })",
  "Errors: $ErrorLog"
) | Set-Content -Encoding UTF8 -Path $summary

if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $OutputDir '*') -DestinationPath $zip -Force

Write-Host "DONE"
Write-Host "AD Windows computer objects: $($adRows.Count)"
Write-Host "Reachable/live rows: $($liveRows.Count)"
Write-Host "Remote successes: $reachableSuccessCount"
if ($stoppedLiveQueryEarly) {
  Write-Warning "Stopped live remote query early after repeated failures. Check errors.log, then test WinRM/admin rights with Test-WSMan and Invoke-Command against one known-online computer."
}
if ($IncludeSoftware) { Write-Host "Software rows: $($softwareRows.Count)" }
Write-Host "Output folder: $OutputDir"
Write-Host "ZIP: $zip"
