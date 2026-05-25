#!/usr/bin/env bash
set -euo pipefail

# Azure Windows VM Software Inventory - Phase 1 (read-only)
# Runs from Azure Cloud Shell Bash or any machine with Azure CLI + jq.
# Produces:
#   ./inventory-output/<timestamp>/windows-vms.csv
#   ./inventory-output/<timestamp>/software-inventory.csv
#   ./inventory-output/<timestamp>/software-inventory.jsonl
#   ./inventory-output/<timestamp>/errors.log
#
# Usage:
#   chmod +x azure-windows-software-inventory.sh
#   ./azure-windows-software-inventory.sh
#
# Default behavior is interactive:
#   1. Lists every accessible subscription with total VM count and Windows VM count.
#   2. Prompts you to choose a subscription by number.
#   3. Lists Windows VMs in that subscription.
#   4. Prompts you to choose all Windows VMs or one specific VM by number.
#
# Optional non-interactive flags:
#   ./azure-windows-software-inventory.sh --subscription <subscription-id-or-name>
#   ./azure-windows-software-inventory.sh --output-dir ./my-report
#   ./azure-windows-software-inventory.sh --parallel 3
#   ./azure-windows-software-inventory.sh --vm-name MyVm --resource-group MyRg
#   ./azure-windows-software-inventory.sh --all-vms
#   ./azure-windows-software-inventory.sh --non-interactive
#   ./azure-windows-software-inventory.sh --blob-account <storageaccount> --blob-container <container>

SUBSCRIPTION=""
OUTPUT_ROOT="./inventory-output"
PARALLEL=3
FILTER_VM_NAME=""
FILTER_RG=""
ALL_VMS=""
NON_INTERACTIVE=""
BLOB_ACCOUNT=""
BLOB_CONTAINER=""
BLOB_PREFIX="azure-windows-software-inventory"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)
      SUBSCRIPTION="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_ROOT="$2"; shift 2 ;;
    --parallel)
      PARALLEL="$2"; shift 2 ;;
    --vm-name)
      FILTER_VM_NAME="$2"; shift 2 ;;
    --resource-group)
      FILTER_RG="$2"; shift 2 ;;
    --all-vms)
      ALL_VMS="1"; shift ;;
    --non-interactive)
      NON_INTERACTIVE="1"; shift ;;
    --blob-account)
      BLOB_ACCOUNT="$2"; shift 2 ;;
    --blob-container)
      BLOB_CONTAINER="$2"; shift 2 ;;
    --blob-prefix)
      BLOB_PREFIX="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,55p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required. Azure Cloud Shell includes jq." >&2; exit 1; }

run_with_spinner() {
  local message="$1"
  local output_file="$2"
  local err_file="$3"
  shift 3

  local spin='|/-\\'
  local i=0
  local elapsed=0
  local pid

  "$@" > "$output_file" 2> "$err_file" &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s %s elapsed: %ss' "$message" "${spin:i++%${#spin}:1}" "$elapsed" >&2
    sleep 1
    elapsed=$((elapsed + 1))
  done

  if wait "$pid"; then
    printf '\r%s done in %ss.                    \n' "$message" "$elapsed" >&2
    return 0
  else
    local rc=$?
    printf '\r%s FAILED after %ss.                \n' "$message" "$elapsed" >&2
    return "$rc"
  fi
}

if { [[ -n "$BLOB_ACCOUNT" ]] && [[ -z "$BLOB_CONTAINER" ]]; } || { [[ -z "$BLOB_ACCOUNT" ]] && [[ -n "$BLOB_CONTAINER" ]]; }; then
  echo "ERROR: --blob-account and --blob-container must be used together." >&2
  exit 2
fi

prompt_number() {
  local prompt="$1"
  local min="$2"
  local max="$3"
  local answer=""

  while true; do
    read -r -p "$prompt" answer
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= min && answer <= max )); then
      printf '%s\n' "$answer"
      return 0
    fi
    echo "Please enter a number from $min to $max." >&2
  done
}

choose_subscription_interactive() {
  local subs_json sub_count subs_table choice selected_id selected_name

  echo "Discovering accessible Azure subscriptions and VM counts..."
  local subs_file subs_err
  subs_file="$TMP_DIR/az-account-list.json"
  subs_err="$TMP_DIR/az-account-list.err"
  if ! run_with_spinner "Querying Azure subscriptions" "$subs_file" "$subs_err" az account list --all -o json; then
    echo "ERROR: Could not list Azure subscriptions: $(tr '\n' ' ' < "$subs_err")" >&2
    exit 1
  fi
  subs_json="$(cat "$subs_file")"
  sub_count="$(jq 'length' <<<"$subs_json")"

  if [[ "$sub_count" == "0" ]]; then
    echo "ERROR: No Azure subscriptions are available to this account." >&2
    exit 1
  fi

  subs_table="$TMP_DIR/subscriptions.jsonl"
  : > "$subs_table"

  for i in $(seq 0 $((sub_count - 1))); do
    local id name state total_vms windows_vms
    id="$(jq -r ".[$i].id" <<<"$subs_json")"
    name="$(jq -r ".[$i].name" <<<"$subs_json")"
    state="$(jq -r ".[$i].state" <<<"$subs_json")"

    total_vms="ERR"
    windows_vms="ERR"
    echo "Checking subscription $((i + 1))/$sub_count: $name"
    if az account set --subscription "$id" >/dev/null 2>&1; then
      local vm_summary vm_summary_file vm_summary_err
      vm_summary_file="$TMP_DIR/subscription-${i}-vm-summary.tsv"
      vm_summary_err="$TMP_DIR/subscription-${i}-vm-summary.err"
      if run_with_spinner "  Querying VM counts for $name" "$vm_summary_file" "$vm_summary_err" bash -c 'az vm list -d -o json | jq -r '\''[length, ([.[] | select((.storageProfile.osDisk.osType // "") == "Windows")] | length)] | @tsv'\'''; then
        vm_summary="$(cat "$vm_summary_file")"
        total_vms="$(awk '{print $1}' <<<"$vm_summary")"
        windows_vms="$(awk '{print $2}' <<<"$vm_summary")"
      else
        echo "  WARN: VM count query failed for $name: $(tr '\n' ' ' < "$vm_summary_err")" >&2
      fi
    fi

    jq -n -c \
      --arg id "$id" \
      --arg name "$name" \
      --arg state "$state" \
      --arg totalVms "$total_vms" \
      --arg windowsVms "$windows_vms" \
      '{id:$id,name:$name,state:$state,totalVms:$totalVms,windowsVms:$windowsVms}' >> "$subs_table"
  done

  echo ""
  echo "Available subscriptions:"
  printf '  %3s  %-42s  %-12s  %9s  %11s\n' "#" "Subscription" "State" "All VMs" "Windows VMs"
  printf '  %3s  %-42s  %-12s  %9s  %11s\n' "---" "------------------------------------------" "------------" "---------" "-----------"

  local idx=1
  while IFS= read -r line; do
    local name state total_vms windows_vms
    name="$(jq -r '.name' <<<"$line")"
    state="$(jq -r '.state' <<<"$line")"
    total_vms="$(jq -r '.totalVms' <<<"$line")"
    windows_vms="$(jq -r '.windowsVms' <<<"$line")"
    printf '  %3d  %-42.42s  %-12.12s  %9s  %11s\n' "$idx" "$name" "$state" "$total_vms" "$windows_vms"
    idx=$((idx + 1))
  done < "$subs_table"

  echo ""
  choice="$(prompt_number "Choose subscription number: " 1 "$sub_count")"
  selected_id="$(sed -n "${choice}p" "$subs_table" | jq -r '.id')"
  selected_name="$(sed -n "${choice}p" "$subs_table" | jq -r '.name')"
  echo "Selected subscription: $selected_name ($selected_id)"
  SUBSCRIPTION="$selected_id"
  az account set --subscription "$SUBSCRIPTION"
}

choose_vm_interactive() {
  local all_vm_json windows_count vm_table choice selected

  echo "Discovering Windows VMs in selected subscription..."
  local all_vm_file all_vm_err
  all_vm_file="$TMP_DIR/selected-subscription-vms.json"
  all_vm_err="$TMP_DIR/selected-subscription-vms.err"
  if ! run_with_spinner "Querying Windows VM list" "$all_vm_file" "$all_vm_err" az vm list -d -o json; then
    echo "ERROR: Could not list VMs in selected subscription: $(tr '\n' ' ' < "$all_vm_err")" >&2
    exit 1
  fi
  all_vm_json="$(cat "$all_vm_file")"
  windows_count="$(jq '[.[] | select((.storageProfile.osDisk.osType // "") == "Windows")] | length' <<<"$all_vm_json")"

  if [[ "$windows_count" == "0" ]]; then
    echo "No Windows VMs found in selected subscription."
    exit 0
  fi

  vm_table="$TMP_DIR/interactive-windows-vms.jsonl"
  jq -c "$VM_QUERY" <<<"$all_vm_json" > "$vm_table"

  echo ""
  echo "Windows VMs:"
  printf '  %3s  %-32s  %-28s  %-16s  %-14s  %-12s\n' "#" "VM Name" "Resource Group" "Power State" "Size" "Location"
  printf '  %3s  %-32s  %-28s  %-16s  %-14s  %-12s\n' "---" "--------------------------------" "----------------------------" "----------------" "--------------" "------------"

  local idx=1
  while IFS= read -r line; do
    local name rg power size loc
    name="$(jq -r '.name' <<<"$line")"
    rg="$(jq -r '.resourceGroup' <<<"$line")"
    power="$(jq -r '.powerState' <<<"$line")"
    size="$(jq -r '.size' <<<"$line")"
    loc="$(jq -r '.location' <<<"$line")"
    printf '  %3d  %-32.32s  %-28.28s  %-16.16s  %-14.14s  %-12.12s\n' "$idx" "$name" "$rg" "$power" "$size" "$loc"
    idx=$((idx + 1))
  done < "$vm_table"

  echo ""
  echo "Choose what to inventory:"
  echo "  0 = all Windows VMs listed above"
  echo "  1-$windows_count = one specific VM"
  choice="$(prompt_number "Choose VM number, or 0 for all: " 0 "$windows_count")"

  if [[ "$choice" == "0" ]]; then
    echo "Selected: all Windows VMs"
    ALL_VMS="1"
    FILTER_VM_NAME=""
    FILTER_RG=""
  else
    selected="$(sed -n "${choice}p" "$vm_table")"
    FILTER_VM_NAME="$(jq -r '.name' <<<"$selected")"
    FILTER_RG="$(jq -r '.resourceGroup' <<<"$selected")"
    echo "Selected VM: $FILTER_RG/$FILTER_VM_NAME"
  fi
}

# For interactive selection we need TMP_DIR before the normal output directory is announced.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OUTPUT_ROOT/$TS"
mkdir -p "$OUT_DIR"
TMP_DIR="$OUT_DIR/tmp"
mkdir -p "$TMP_DIR"

if [[ -z "$SUBSCRIPTION" && -z "$NON_INTERACTIVE" ]]; then
  choose_subscription_interactive
elif [[ -n "$SUBSCRIPTION" ]]; then
  az account set --subscription "$SUBSCRIPTION"
fi

VM_CSV="$OUT_DIR/windows-vms.csv"
SOFTWARE_CSV="$OUT_DIR/software-inventory.csv"
SOFTWARE_JSONL="$OUT_DIR/software-inventory.jsonl"
ERROR_LOG="$OUT_DIR/errors.log"
: > "$ERROR_LOG"
: > "$SOFTWARE_JSONL"

echo "Starting Windows VM/software inventory at $TS UTC"
echo "Output directory: $OUT_DIR"

# PowerShell that runs inside each Windows VM via Azure Run Command.
# Read-only: queries uninstall registry keys only. No package install/update actions.
read -r -d '' GUEST_PS <<'EOF' || true
$ErrorActionPreference = 'Continue'
$paths = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$items = foreach ($path in $paths) {
  Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.DisplayName.Trim().Length -gt 0 } |
    ForEach-Object {
      $installDateRaw = $null
      $installDateIso = $null
      if ($_.InstallDate) {
        $installDateRaw = [string]$_.InstallDate
        if ($installDateRaw -match '^\d{8}$') {
          try {
            $installDateIso = ([datetime]::ParseExact($installDateRaw, 'yyyyMMdd', $null)).ToString('yyyy-MM-dd')
          } catch { $installDateIso = $null }
        }
      }

      [PSCustomObject]@{
        ComputerName      = $env:COMPUTERNAME
        DisplayName       = [string]$_.DisplayName
        DisplayVersion    = [string]$_.DisplayVersion
        Publisher         = [string]$_.Publisher
        InstallDateRaw    = $installDateRaw
        InstallDate       = $installDateIso
        InstallLocation   = [string]$_.InstallLocation
        UninstallString   = [string]$_.UninstallString
        QuietUninstallString = [string]$_.QuietUninstallString
        RegistryKey       = [string]$_.PSChildName
        RegistryPath      = [string]$_.PSPath
        Architecture      = if ($_.PSPath -like '*WOW6432Node*') { 'x86' } else { 'x64' }
      }
    }
}

# Deduplicate common duplicate registry entries.
$items |
  Sort-Object DisplayName, DisplayVersion, Publisher, Architecture -Unique |
  ConvertTo-Json -Depth 4 -Compress
EOF

# Discover Windows VMs. az vm list is used to avoid requiring Resource Graph extension.
VM_QUERY='.[] | select((.storageProfile.osDisk.osType // "") == "Windows") | {
  subscriptionId: .id | split("/")[2],
  resourceGroup: .resourceGroup,
  name: .name,
  location: .location,
  vmId: .vmId,
  powerState: (.powerState // "unknown"),
  size: .hardwareProfile.vmSize,
  osType: .storageProfile.osDisk.osType,
  computerName: (.osProfile.computerName // ""),
  id: .id
}'

if [[ -z "$FILTER_VM_NAME" && -z "$FILTER_RG" && -z "$ALL_VMS" && -z "$NON_INTERACTIVE" ]]; then
  choose_vm_interactive
fi

VM_JSON="$TMP_DIR/windows-vms.jsonl"
: > "$VM_JSON"

if [[ -n "$FILTER_VM_NAME" || -n "$FILTER_RG" ]]; then
  if [[ -z "$FILTER_VM_NAME" || -z "$FILTER_RG" ]]; then
    echo "ERROR: --vm-name and --resource-group must be used together." >&2
    exit 2
  fi
  if ! run_with_spinner "Querying selected VM details" "$VM_JSON.tmp" "$TMP_DIR/selected-vm.err" bash -c 'az vm show -g "$1" -n "$2" -d -o json | jq -c '\''select((.storageProfile.osDisk.osType // "") == "Windows") | {
    subscriptionId: .id | split("/")[2], resourceGroup: .resourceGroup, name: .name, location: .location,
    vmId: .vmId, powerState: (.powerState // "unknown"), size: .hardwareProfile.vmSize,
    osType: .storageProfile.osDisk.osType, computerName: (.osProfile.computerName // ""), id: .id
  }'\''' _ "$FILTER_RG" "$FILTER_VM_NAME"; then
    echo "ERROR: Could not query selected VM details: $(tr '\n' ' ' < "$TMP_DIR/selected-vm.err")" >&2
    exit 1
  fi
  mv "$VM_JSON.tmp" "$VM_JSON"
else
  if ! run_with_spinner "Querying Windows VM list" "$VM_JSON.tmp" "$TMP_DIR/windows-vms.err" bash -c 'az vm list -d -o json | jq -c "$1"' _ "$VM_QUERY"; then
    echo "ERROR: Could not query Windows VM list: $(tr '\n' ' ' < "$TMP_DIR/windows-vms.err")" >&2
    exit 1
  fi
  mv "$VM_JSON.tmp" "$VM_JSON"
fi

VM_COUNT=$(wc -l < "$VM_JSON" | tr -d ' ')
if [[ "$VM_COUNT" == "0" ]]; then
  echo "No Windows VMs found in current subscription/context."
  exit 0
fi

jq -r '["SubscriptionId","ResourceGroup","VMName","Location","PowerState","Size","OSType","ComputerName","ResourceId"],
  ((., inputs) | [.subscriptionId,.resourceGroup,.name,.location,.powerState,.size,.osType,.computerName,.id]) | @csv' < "$VM_JSON" > "$VM_CSV"

echo "Found $VM_COUNT Windows VM(s). VM list written to: $VM_CSV"
echo "Collecting installed software via az vm run-command invoke..."
echo "This can take 1-5 minutes per VM depending on Azure Run Command and VM agent response time."
if [[ "$VM_COUNT" == "1" || "$PARALLEL" == "1" ]]; then
  SHOW_VM_SPINNER="1"
else
  SHOW_VM_SPINNER=""
  echo "Parallel mode is enabled (--parallel $PARALLEL), so VM progress is shown as START/OK lines instead of one shared spinner."
fi

collect_vm() {
  local line="$1"
  local sub rg vm loc power size os computer id safe output_file software_file err_file
  sub=$(jq -r '.subscriptionId' <<<"$line")
  rg=$(jq -r '.resourceGroup' <<<"$line")
  vm=$(jq -r '.name' <<<"$line")
  loc=$(jq -r '.location' <<<"$line")
  power=$(jq -r '.powerState' <<<"$line")
  size=$(jq -r '.size' <<<"$line")
  os=$(jq -r '.osType' <<<"$line")
  computer=$(jq -r '.computerName' <<<"$line")
  id=$(jq -r '.id' <<<"$line")
  safe=$(printf '%s__%s' "$rg" "$vm" | tr -c 'A-Za-z0-9_.-' '_')
  output_file="$TMP_DIR/${safe}.runcommand.json"
  software_file="$TMP_DIR/${safe}.software.json"
  err_file="$TMP_DIR/${safe}.error"

  if [[ "$power" != *"running"* && "$power" != "VM running" ]]; then
    echo "SKIP $rg/$vm - power state: $power" | tee -a "$ERROR_LOG" >&2
    return 0
  fi

  echo "START $rg/$vm - invoking Azure Run Command to read installed software..." >&2
  if [[ "${SHOW_VM_SPINNER:-}" == "1" ]]; then
    if ! run_with_spinner "  Working on $rg/$vm with Azure Run Command" "$output_file" "$err_file" az vm run-command invoke \
        --subscription "$sub" \
        --resource-group "$rg" \
        --name "$vm" \
        --command-id RunPowerShellScript \
        --scripts "$GUEST_PS" \
        -o json; then
      echo "ERROR $rg/$vm - run-command failed: $(tr '\n' ' ' < "$err_file")" | tee -a "$ERROR_LOG" >&2
      return 0
    fi
  elif ! az vm run-command invoke \
      --subscription "$sub" \
      --resource-group "$rg" \
      --name "$vm" \
      --command-id RunPowerShellScript \
      --scripts "$GUEST_PS" \
      -o json > "$output_file" 2> "$err_file"; then
    echo "ERROR $rg/$vm - run-command failed: $(tr '\n' ' ' < "$err_file")" | tee -a "$ERROR_LOG" >&2
    return 0
  fi

  # Azure returns script stdout in value[].message. Extract the JSON array from that message.
  local msg
  msg=$(jq -r '[.value[]?.message] | join("\n")' "$output_file")
  if [[ -z "$msg" || "$msg" == "null" ]]; then
    echo "WARN $rg/$vm - no software output returned" | tee -a "$ERROR_LOG" >&2
    return 0
  fi

  # Keep only the JSON array/object portion in case Run Command adds wrappers such as:
  # [stdout]
  # [...json...]
  # [stderr]
  # The extractor scans for the first valid JSON object/array instead of blindly using the first '['.
  printf '%s\n' "$msg" | python3 -c '
import sys, json
s=sys.stdin.read().strip()
decoder=json.JSONDecoder()
for i, ch in enumerate(s):
    if ch not in "[{":
        continue
    try:
        obj, end = decoder.raw_decode(s[i:])
    except Exception:
        continue
    if isinstance(obj, (list, dict)):
        print(json.dumps(obj, separators=(",",":")))
        raise SystemExit(0)
raise SystemExit("could not parse JSON payload")
' > "$software_file" 2>> "$err_file" || {
    echo "ERROR $rg/$vm - could not parse run-command JSON output: $(tr '\n' ' ' < "$err_file")" | tee -a "$ERROR_LOG" >&2
    return 0
  }

  jq -c --arg sub "$sub" --arg rg "$rg" --arg vm "$vm" --arg loc "$loc" --arg power "$power" --arg size "$size" --arg os "$os" --arg computer "$computer" --arg id "$id" '
    (if type=="array" then . else [.] end)[] |
    {
      SubscriptionId: $sub,
      ResourceGroup: $rg,
      VMName: $vm,
      AzureComputerName: $computer,
      GuestComputerName: (.ComputerName // ""),
      Location: $loc,
      PowerState: $power,
      VMSize: $size,
      OSType: $os,
      ResourceId: $id,
      DisplayName: (.DisplayName // ""),
      DisplayVersion: (.DisplayVersion // ""),
      Publisher: (.Publisher // ""),
      InstallDate: (.InstallDate // ""),
      InstallDateRaw: (.InstallDateRaw // ""),
      Architecture: (.Architecture // ""),
      InstallLocation: (.InstallLocation // ""),
      RegistryKey: (.RegistryKey // ""),
      RegistryPath: (.RegistryPath // ""),
      UninstallString: (.UninstallString // ""),
      QuietUninstallString: (.QuietUninstallString // "")
    }' "$software_file" >> "$SOFTWARE_JSONL"

  echo "OK $rg/$vm"
}
export -f collect_vm
export -f run_with_spinner
export GUEST_PS TMP_DIR ERROR_LOG SOFTWARE_JSONL SHOW_VM_SPINNER

# Run collection with bounded parallelism.
if command -v xargs >/dev/null 2>&1; then
  # -d '\n' keeps each JSONL object intact; without it, xargs may treat quotes inside JSON specially.
  xargs -d '\n' -P "$PARALLEL" -I {} bash -c 'collect_vm "$@"' _ {} < "$VM_JSON"
else
  while IFS= read -r line; do collect_vm "$line"; done < "$VM_JSON"
fi

# Build CSV. If no software rows were collected, still write headers.
if [[ -s "$SOFTWARE_JSONL" ]]; then
  jq -r '["SubscriptionId","ResourceGroup","VMName","AzureComputerName","GuestComputerName","Location","PowerState","VMSize","OSType","DisplayName","DisplayVersion","Publisher","InstallDate","InstallDateRaw","Architecture","InstallLocation","RegistryKey","RegistryPath","UninstallString","QuietUninstallString","ResourceId"],
    ((., inputs) | [.SubscriptionId,.ResourceGroup,.VMName,.AzureComputerName,.GuestComputerName,.Location,.PowerState,.VMSize,.OSType,.DisplayName,.DisplayVersion,.Publisher,.InstallDate,.InstallDateRaw,.Architecture,.InstallLocation,.RegistryKey,.RegistryPath,.UninstallString,.QuietUninstallString,.ResourceId]) | @csv' < "$SOFTWARE_JSONL" > "$SOFTWARE_CSV"
else
  printf '%s\n' '"SubscriptionId","ResourceGroup","VMName","AzureComputerName","GuestComputerName","Location","PowerState","VMSize","OSType","DisplayName","DisplayVersion","Publisher","InstallDate","InstallDateRaw","Architecture","InstallLocation","RegistryKey","RegistryPath","UninstallString","QuietUninstallString","ResourceId"' > "$SOFTWARE_CSV"
fi

TOTAL_SOFTWARE=$(if [[ -s "$SOFTWARE_JSONL" ]]; then wc -l < "$SOFTWARE_JSONL" | tr -d ' '; else echo 0; fi)
ERROR_COUNT=$(if [[ -s "$ERROR_LOG" ]]; then wc -l < "$ERROR_LOG" | tr -d ' '; else echo 0; fi)

if [[ "$TOTAL_SOFTWARE" == "0" ]]; then
  echo ""
  echo "WARN: No installed software rows were collected."
  echo "Check the error log for the exact reason: $ERROR_LOG"
  echo "Common causes: VM is not running, Azure VM Agent is unhealthy, Run Command permission is missing, or Run Command returned no registry output."
fi

REPORT_ZIP="$(pwd)/azure-windows-software-inventory-report-$TS.zip"
echo ""
echo "Creating one-click download zip in the current Cloud Shell folder..."
if command -v zip >/dev/null 2>&1; then
  rm -f "$REPORT_ZIP"
  if (cd "$OUTPUT_ROOT" && zip -qr "$REPORT_ZIP" "$(basename "$OUT_DIR")"); then
    echo "Report zip created: $REPORT_ZIP"
  else
    echo "WARN: Could not create report zip: $REPORT_ZIP" | tee -a "$ERROR_LOG" >&2
    REPORT_ZIP=""
  fi
else
  echo "WARN: zip command was not found, so no zip file was created." | tee -a "$ERROR_LOG" >&2
  REPORT_ZIP=""
fi

BLOB_DESTINATION=""
if [[ -n "$BLOB_ACCOUNT" && -n "$BLOB_CONTAINER" ]]; then
  BLOB_DESTINATION="$BLOB_PREFIX/$TS"
  echo ""
  echo "Uploading report folder to Azure Blob Storage..."
  echo "  Storage account: $BLOB_ACCOUNT"
  echo "  Container:       $BLOB_CONTAINER"
  echo "  Blob prefix:     $BLOB_DESTINATION"

  if az storage container create \
      --account-name "$BLOB_ACCOUNT" \
      --name "$BLOB_CONTAINER" \
      --auth-mode login \
      -o none; then
    az storage blob upload-batch \
      --account-name "$BLOB_ACCOUNT" \
      --auth-mode login \
      --destination "$BLOB_CONTAINER" \
      --destination-path "$BLOB_DESTINATION" \
      --source "$OUT_DIR" \
      --overwrite true \
      -o table
  else
    echo "WARN: Could not create/verify blob container. Skipping blob upload." | tee -a "$ERROR_LOG" >&2
    BLOB_DESTINATION=""
  fi
fi

echo ""
echo "Inventory complete."
echo "Windows VM count: $VM_COUNT"
echo "Software rows: $TOTAL_SOFTWARE"
echo "Warnings/errors: $ERROR_COUNT"
echo "Files:"
echo "  VM inventory CSV:       $VM_CSV"
echo "  Software inventory CSV: $SOFTWARE_CSV"
echo "  Software JSONL:         $SOFTWARE_JSONL"
echo "  Error log:              $ERROR_LOG"
if [[ -n "$REPORT_ZIP" ]]; then
  echo "  Download zip:           $REPORT_ZIP"
fi
if [[ -n "$BLOB_DESTINATION" ]]; then
  echo "  Blob upload path:       https://$BLOB_ACCOUNT.blob.core.windows.net/$BLOB_CONTAINER/$BLOB_DESTINATION/"
fi
echo ""
echo "Next safe phase after validating this report: update availability only (no downloads/installs)."
