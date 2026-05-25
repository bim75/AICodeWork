# AD Active Devices and Login Times

Goal: start simple with an AD-only list of active devices and their most recent login time.

This does not use WinRM, remote registry, software inventory, or Azure. It only queries Active Directory computer objects.

## What this creates

```text
active-devices-logons.csv       # enabled devices active within the selected day window
stale-or-disabled-devices.csv   # disabled devices or devices outside the active window
summary.txt
ad-active-devices-logons-YYYYMMDD-HHMMSS.zip
```

## Important note about login times

By default the script uses AD's replicated `LastLogonTimestamp` / `LastLogonDate` value. That is good for inventory and cleanup planning, but it is approximate and can lag by about 9-14 days.

If you need the most exact computer logon time, run with `-ExactLastLogon`. That queries every domain controller for the non-replicated `lastLogon` value and uses the newest one. It is slower.

## Step 1: open PowerShell as admin

Open Windows PowerShell on a domain-joined machine with the RSAT Active Directory module available.

## Step 2: download the simple script

```powershell
cd $env:USERPROFILE\Desktop
Remove-Item .\ad-active-devices-logons.ps1 -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/bim75/AICodeWork/main/ad-active-devices-logons.ps1" -OutFile ".\ad-active-devices-logons.ps1"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Step 3: run active device report

Default: devices active in the last 90 days.

```powershell
.\ad-active-devices-logons.ps1
```

Only Windows computers:

```powershell
.\ad-active-devices-logons.ps1 -WindowsOnly
```

Change the active window to 30 days:

```powershell
.\ad-active-devices-logons.ps1 -ActiveDays 30
```

Use exact per-domain-controller last logon time:

```powershell
.\ad-active-devices-logons.ps1 -ExactLastLogon
```

Exact login time, Windows only, active in last 30 days:

```powershell
.\ad-active-devices-logons.ps1 -WindowsOnly -ActiveDays 30 -ExactLastLogon
```

## Inventory one OU

```powershell
.\ad-active-devices-logons.ps1 -SearchBase "OU=Computers,DC=example,DC=com"
```

## Columns in the main CSV

`active-devices-logons.csv` includes:

- Name
- DNSHostName
- Enabled
- IsActive
- BestLastLogon
- BestLastLogonSource
- DaysSinceBestLastLogon
- ReplicatedLastLogon
- ExactLastLogon, only populated when `-ExactLastLogon` is used
- ExactLastLogonDomainController, only populated when `-ExactLastLogon` is used
- OperatingSystem
- IPv4Address
- PasswordLastSet
- OU/canonical name
- Description
- ManagedBy

## Recommended first run

Start with this:

```powershell
.\ad-active-devices-logons.ps1 -WindowsOnly -ActiveDays 90
```

If the results look good but you need more exact timestamps, rerun:

```powershell
.\ad-active-devices-logons.ps1 -WindowsOnly -ActiveDays 90 -ExactLastLogon
```
