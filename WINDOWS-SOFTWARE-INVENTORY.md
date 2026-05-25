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

### Step 1: get the script into Cloud Shell

Fresh Cloud Shell starts in `~` and does not already contain this repo. Run one of these first.

Recommended, clone the repo:

```bash
git clone https://github.com/bim75/AICodeWork.git
cd AICodeWork
```

If you already cloned it earlier:

```bash
cd ~/AICodeWork
git pull
```

No git clone option, download just the script:

```bash
curl -fsSL https://raw.githubusercontent.com/bim75/AICodeWork/main/azure-windows-software-inventory.sh -o azure-windows-software-inventory.sh
```

### Step 2: run the inventory

```bash
chmod +x azure-windows-software-inventory.sh
./azure-windows-software-inventory.sh
```

For larger inventories, use Blob-backed output to avoid Azure Run Command stdout truncation:

```bash
./azure-windows-software-inventory.sh --blob-account YOUR_STORAGE_ACCOUNT --blob-container inventory
```

If Blob mode fails because of RBAC/storage permissions, rerun without Blob mode or use Option A over RDP.
