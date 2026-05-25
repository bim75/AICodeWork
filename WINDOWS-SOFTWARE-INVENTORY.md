# Azure Windows VM Software Inventory

Goal: produce a list of all installed software on Windows VMs in Azure.

Use Azure Cloud Shell Bash.

## Step 0: create Blob Storage with the right permissions

The inventory script works best when each VM writes its full software JSON to Azure Blob Storage. Create a dedicated storage account/container first so Azure Run Command output does not get truncated.

### Option A: Azure Portal

1. In Azure Portal, open `Storage accounts`.
2. Click `Create`.
3. Choose the same subscription you will inventory.
4. Choose an existing resource group, or create one such as `rg-inventory`.
5. Enter a globally unique storage account name, for example `inventory<yourinitials><date>`.
6. Region: choose the same region as most of the VMs, if practical.
7. Performance: `Standard`.
8. Redundancy: `Locally-redundant storage (LRS)` is fine for this temporary inventory data.
9. Finish creation.
10. Open the new storage account.
11. Go to `Data storage` -> `Containers`.
12. Click `+ Container`.
13. Name it `inventory`.
14. Public access level: `Private (no anonymous access)`.
15. Click `Create`.

Now grant your user permission to create SAS URLs and upload/read blobs:

1. Open the storage account.
2. Go to `Access Control (IAM)`.
3. Click `Add` -> `Add role assignment`.
4. Role: `Storage Blob Data Contributor`.
5. Assign access to: `User, group, or service principal`.
6. Select your signed-in Azure user.
7. Review and assign.
8. Wait 2-5 minutes for the permission to take effect.

Important: the container should stay `Private`. Do not enable anonymous/public blob access.

### Option B: Cloud Shell command

If you prefer commands, replace the values below and paste this into Cloud Shell:

```bash
SUBSCRIPTION_ID="your-subscription-id"
LOCATION="eastus"
RESOURCE_GROUP="rg-inventory"
STORAGE_ACCOUNT="inventory$(date +%m%d%H%M)$RANDOM"
CONTAINER="inventory"

az account set --subscription "$SUBSCRIPTION_ID"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false
SIGNED_IN_USER_ID="$(az ad signed-in-user show --query id -o tsv)"
STORAGE_SCOPE="$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query id -o tsv)"
az role assignment create \
  --assignee "$SIGNED_IN_USER_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_SCOPE"

echo "Waiting 60 seconds for Blob permissions to propagate..."
sleep 60
az storage container create \
  --account-name "$STORAGE_ACCOUNT" \
  --name "$CONTAINER" \
  --public-access off \
  --auth-mode login

echo "Use this storage account when the script asks: $STORAGE_ACCOUNT"
echo "Use this container: $CONTAINER"
```

You may also need permission to run commands on the VMs, such as `Virtual Machine Contributor` on the target VMs/resource group, or another role that includes `Microsoft.Compute/virtualMachines/runCommand/action`.

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
