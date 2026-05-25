# Windows Software Inventory

This repo contains two read-only inventory paths.

If Azure Run Command keeps failing or producing empty/header-only reports, use the local RDP path. It avoids Azure Run Command stdout limits and runs directly inside the Windows VM.

## Option A: Local RDP inventory, most reliable for one VM

1. RDP into the Windows VM.
2. Open PowerShell.
3. Run this from the folder containing the script:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\local-windows-software-inventory.ps1
```

Output is written to your Desktop:

- software-inventory.csv
- software-inventory.json
- summary.txt
- errors.log
- software-inventory-YYYYMMDD-HHMMSS.zip

This is read-only. It does not install, update, uninstall, or modify software.

## Option B: Azure Cloud Shell inventory

Use this when you need inventory across Azure Windows VMs without RDP.

```bash
chmod +x azure-windows-software-inventory.sh
./azure-windows-software-inventory.sh
```

For larger inventories, use Blob-backed output to avoid Azure Run Command stdout truncation:

```bash
./azure-windows-software-inventory.sh --blob-account YOUR_STORAGE_ACCOUNT --blob-container inventory
```

If Blob mode fails because of RBAC/storage permissions, rerun without Blob mode or use Option A over RDP.
