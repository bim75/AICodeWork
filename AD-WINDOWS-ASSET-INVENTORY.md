# AD Windows Asset Inventory

Goal: produce a single list of all AD-joined Windows assets across physical machines, VMware VMs, Azure VMs, Hyper-V VMs, and other virtual platforms.

This is the better starting point when all Windows machines are joined to Active Directory. Active Directory becomes the source of truth for the computer list; live remote queries enrich each reachable computer with platform, hardware, OS, and optional installed software data.

## What this collects

The script creates these files:

```text
computers-ad.csv
computers-live.csv
software-inventory.csv      # only when -IncludeSoftware is used
errors.log
summary.txt
ad-windows-asset-inventory-YYYYMMDD-HHMMSS.zip
```

`computers-ad.csv` comes from Active Directory and includes:

- Computer name
- DNS host name
- Enabled/disabled state
- AD operating system fields
- Last logon timestamp
- OU/canonical name
- Distinguished name
- Description/managed-by fields

`computers-live.csv` comes from each reachable machine and includes:

- Manufacturer
- Model
- BIOS serial
- OS name/version/build
- CPU and memory
- Domain membership
- Last boot time
- Platform classification: physical, virtual, cloud virtual, unknown
- Provider/hypervisor guess: VMware, Azure/Hyper-V, VirtualBox, KVM/QEMU, AWS, Google Cloud, physical/unknown

`software-inventory.csv`, if requested, includes installed software from the local uninstall registry keys and optional Appx packages.

## Best architecture

Use a two-pass approach:

1. First pass: asset list only.
   - Fastest and safest.
   - Confirms AD visibility, reachability, and platform classification.

2. Second pass: software inventory.
   - Slower.
   - Requires more remote access rights.
   - Produces the installed software list.

## Requirements

Run this from a domain-joined Windows admin workstation or server.

You need:

1. PowerShell 5.1 or newer.
2. RSAT Active Directory PowerShell module.
3. Network reachability to the target machines.
4. PowerShell Remoting/WinRM enabled on target machines for live enrichment.
5. Local administrator or equivalent rights on target machines for best software visibility.

The script is read-only. It does not install, update, uninstall, or modify software.

## Step 1: open PowerShell as admin

On a domain-joined admin workstation/server, open Windows PowerShell as Administrator.

## Step 2: download the script

Paste this:

```powershell
cd $env:USERPROFILE\Desktop
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/bim75/AICodeWork/main/ad-windows-asset-inventory.ps1" -OutFile ".\ad-windows-asset-inventory.ps1"
```

If PowerShell blocks script execution, run this for the current PowerShell window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Step 3: run the asset-only inventory first

Paste this:

```powershell
.\ad-windows-asset-inventory.ps1
```

This discovers all enabled/disabled Windows computer objects from AD and tries to enrich enabled computers with live platform details.

At the end, look for:

```text
ZIP: .\ad-windows-asset-inventory-YYYYMMDD-HHMMSS.zip
```

During the run you should see visible progress lines like:

```text
Probing 42 enabled AD computer(s) for live platform details...
Progress will print START/WAIT/OK/WARN lines. Timeout per remote batch item: 30 seconds.
BATCH 1 - starting 12 remote query job(s)...
START SERVER01.example.local - launching remote inventory job...
WAIT  SERVER01.example.local - waiting up to 30 second(s)...
OK    SERVER01.example.local - asset rows: 1; software rows: 0
WARN: LAPTOP19.example.local - timeout/offline/unreachable after 30 second(s)
```

Open `computers-ad.csv` and `computers-live.csv` first.

## Step 4: run installed software inventory

After the asset-only pass looks good, run:

```powershell
.\ad-windows-asset-inventory.ps1 -IncludeSoftware
```

For larger environments, increase/decrease parallelism:

```powershell
.\ad-windows-asset-inventory.ps1 -IncludeSoftware -ThrottleLimit 16
```

If Appx inventory is noisy or slow, skip it:

```powershell
.\ad-windows-asset-inventory.ps1 -IncludeSoftware -SkipAppx
```

## Inventory one OU

Use `-SearchBase`:

```powershell
.\ad-windows-asset-inventory.ps1 -SearchBase "OU=Servers,DC=example,DC=com"
```

With software:

```powershell
.\ad-windows-asset-inventory.ps1 -SearchBase "OU=Servers,DC=example,DC=com" -IncludeSoftware
```

## Inventory specific computers

```powershell
.\ad-windows-asset-inventory.ps1 -ComputerName SERVER01,PC042,LAPTOP19
```

With software:

```powershell
.\ad-windows-asset-inventory.ps1 -ComputerName SERVER01,PC042,LAPTOP19 -IncludeSoftware
```

## How platform detection works

The script asks each reachable computer for manufacturer/model/BIOS data using read-only CIM/WMI classes.

Common examples:

```text
VMware, Inc. + VMware Virtual Platform      -> VMware
Microsoft Corporation + Virtual Machine     -> Azure or Hyper-V
Dell/HP/Lenovo/etc. physical model          -> Physical/Unknown
VirtualBox                                  -> VirtualBox
KVM/QEMU                                    -> KVM/QEMU
Amazon EC2                                  -> AWS
Google Compute Engine                       -> Google Cloud
```

Azure and on-prem Hyper-V can look similar from inside the guest. If you want exact Azure confirmation later, combine this AD report with the Azure VM report by computer name/DNS name.

## If many computers show as unreachable

Check these items:

1. Are the machines online?
2. Can you resolve their DNS names?
3. Is WinRM enabled?
4. Does Windows Firewall allow PowerShell Remoting?
5. Does your account have local admin rights?
6. Are laptops off-network or disconnected from VPN/Twingate?

Basic WinRM test for one machine:

```powershell
Test-WSMan SERVER01
```

Basic remote command test:

```powershell
Invoke-Command -ComputerName SERVER01 -ScriptBlock { hostname }
```

If WinRM is not enabled, a domain GPO can enable it for domain machines. Do that carefully and only for trusted admin networks.

## Why this is better than Azure-only for your environment

The Azure Cloud Shell script is useful for Azure VMs when you do not have direct network/WinRM access.

This AD script is better as the primary inventory because your Windows assets are AD joined across:

- VMware
- Azure
- Physical machines
- Other Windows virtual platforms

AD gives one computer list across all of them. The live query then enriches each machine regardless of where it runs.

## Recommended workflow

1. Run asset-only AD inventory.
2. Review `computers-ad.csv` for the full expected asset count.
3. Review `computers-live.csv` for platform/provider guesses.
4. Review `errors.log` for offline/unreachable machines.
5. Fix reachability/WinRM/admin-rights issues if needed.
6. Run `-IncludeSoftware` only after the asset list looks right.

## Safety

This inventory is read-only. It does not install, update, uninstall, or modify software.

The script intentionally does not use `Win32_Product`, because that class can trigger MSI repair/reconfiguration actions.
