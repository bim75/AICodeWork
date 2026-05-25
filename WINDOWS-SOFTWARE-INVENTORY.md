# Azure Windows VM Software Inventory

Goal: produce a list of all installed software on Windows VMs in Azure.

Use Azure Cloud Shell Bash.

## Step 1: open Cloud Shell

Open Azure Portal, start Cloud Shell, choose Bash.

## Step 2: download the inventory script

Paste this into Cloud Shell:

```bash
cd ~
rm -rf AICodeWork
git clone https://github.com/bim75/AICodeWork.git
cd AICodeWork
chmod +x azure-windows-software-inventory.sh
```

## Step 3: run the inventory

Paste this:

```bash
./azure-windows-software-inventory.sh
```

## Step 4: answer the prompts

The script will ask for three things:

1. Subscription number
   - Pick the subscription that contains the VMs.

2. Storage account number
   - Pick the Cloud Shell storage account if you recognize it.
   - If you do not recognize it, pick the first listed storage account.
   - The script will use/create a container named `inventory`.

3. VM selection
   - Enter `0` to inventory all Windows VMs listed.

## Step 5: wait for completion

The script prints progress lines like:

```text
START resource-group/vm-name - invoking Azure Run Command to read installed software...
OK resource-group/vm-name - 235 software row(s)
```

## Step 6: download the result

At the end, look for this line:

```text
Download zip: /home/<you>/AICodeWork/azure-windows-software-inventory-report-YYYYMMDDTHHMMSSZ.zip
```

Download that zip from Cloud Shell.

Inside the zip, the main file is:

```text
software-inventory.csv
```

That CSV is the software list.

## If the script stops with a storage permission error

The account you used does not have permission to create/use blobs in that storage account.

Use this exact fallback command:

```bash
./azure-windows-software-inventory.sh --no-blob
```

This fallback may fail on large inventories because Azure Run Command stdout can truncate output, but it requires fewer storage permissions.

## Safety

This inventory is read-only. It does not install, update, uninstall, or modify software.
