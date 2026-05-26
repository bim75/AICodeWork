#!/usr/bin/env bash
set -Eeuo pipefail

# Azure Abandoned Resource Inventory
# Read-only Azure inventory and cleanup-candidate report.
# Designed for Azure Cloud Shell. Requires: az, jq.
# Interactive workflow:
#   - polls/refreshes subscriptions from Azure
#   - lets you run one subscription, several subscriptions, or all enabled subscriptions
#   - returns to the menu after each run so you can choose another subscription

DAYS_OLD="${DAYS_OLD:-90}"
OUT_DIR="${OUT_DIR:-./azure-abandoned-inventory-output}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SESSION_DIR="$OUT_DIR/$TIMESTAMP"
SUBSCRIPTIONS_FILE="$SESSION_DIR/subscriptions.all.json"

mkdir -p "$SESSION_DIR"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    exit 1
  fi
}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }


run_with_spinner() {
  local label="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3
  local start pid rc elapsed spin i
  spin='|/-\\'
  i=0
  start=$(date +%s)
  printf '[%s] START %s\n' "$(date -u +%H:%M:%S)" "$label" >&2
  if [[ "${VERBOSE_COMMANDS:-0}" == "1" ]]; then
    printf '[%s] Command:' "$(date -u +%H:%M:%S)" >&2
    local arg
    for arg in "$@"; do printf ' %q' "$arg" >&2; done
    printf '\n' >&2
  fi
  ( "$@" >"$stdout_file" 2>"$stderr_file" ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start ))
    printf '\r[%s] WORKING %s elapsed=%ss %s' "$(date -u +%H:%M:%S)" "$label" "$elapsed" "${spin:i++%4:1}" >&2
    sleep 2
  done
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  printf '\r%*s\r' 100 '' >&2
  if [[ "$rc" -eq 0 ]]; then
    printf '[%s] OK %s elapsed=%ss\n' "$(date -u +%H:%M:%S)" "$label" "$elapsed" >&2
  else
    printf '[%s] ERROR %s elapsed=%ss rc=%s\n' "$(date -u +%H:%M:%S)" "$label" "$elapsed" "$rc" >&2
    if [[ -s "$stderr_file" ]]; then
      echo "---- last stderr lines for: $label ----" >&2
      tail -40 "$stderr_file" >&2 || true
      echo "---------------------------------------" >&2
    fi
    return "$rc"
  fi
}

az_json_with_spinner() {
  local label="$1"
  local outfile="$2"
  shift 2
  run_with_spinner "$label" "$outfile" "$outfile.err" "$@"
}

ensure_azure_cli_ready() {
  local tmp
  tmp="$SESSION_DIR/az-extension-preflight.json"
  log "Preparing Azure CLI non-interactive extension behavior..."
  az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>"$SESSION_DIR/az-config-dynamic-install.err" || true
  az config set extension.dynamic_install_allow_preview=true >/dev/null 2>"$SESSION_DIR/az-config-preview.err" || true

  if ! az extension show --name resource-graph >/dev/null 2>&1; then
    run_with_spinner "Installing Azure CLI resource-graph extension" "$tmp" "$tmp.err" az extension add --name resource-graph --yes
  else
    log "Azure CLI resource-graph extension already installed."
  fi
}

safe_name() {
  tr -cs 'A-Za-z0-9._-' '-' <<<"$1" | sed 's/^-//; s/-$//; s/--*/-/g'
}

need az
need jq

if ! az account show >/dev/null 2>&1; then
  echo "You are not logged into Azure. Run: az login" >&2
  exit 1
fi

ensure_azure_cli_ready

fetch_subscriptions() {
  az_json_with_spinner "Polling Azure for subscriptions" "$SUBSCRIPTIONS_FILE" az account list --all -o json
  local total enabled
  total=$(jq length "$SUBSCRIPTIONS_FILE")
  enabled=$(jq '[.[] | select(.state == "Enabled")] | length' "$SUBSCRIPTIONS_FILE")
  log "Found $total subscription(s), $enabled enabled."
}

print_subscription_menu() {
  echo >&2
  echo "Azure subscriptions" >&2
  echo "-------------------" >&2
  jq -r 'to_entries[] | [(.key + 1), .value.name, .value.state, .value.id, (.value.tenantId // "")] | @tsv' "$SUBSCRIPTIONS_FILE" |
    while IFS=$'\t' read -r num name state id tenant; do
      printf '%3s. %-42s %-10s %s tenant=%s\n' "$num" "$name" "$state" "$id" "$tenant" >&2
    done
  echo >&2
  echo "Choose what to inventory:" >&2
  echo "  0          all enabled subscriptions" >&2
  echo "  1          one subscription by number" >&2
  echo "  1,3,4      multiple subscriptions by number" >&2
  echo "  r          refresh/poll subscriptions again" >&2
  echo "  q          quit" >&2
}

select_subscriptions() {
  local selection="$1"
  local selected_file="$2"

  if [[ "$selection" == "0" ]]; then
    jq '[.[] | select(.state == "Enabled")]' "$SUBSCRIPTIONS_FILE" > "$selected_file"
  else
    if ! [[ "$selection" =~ ^[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$ ]]; then
      echo "Invalid selection: $selection" >&2
      return 1
    fi
    jq --arg sel "$selection" '
      ($sel | split(",") | map(gsub(" ";"") | tonumber)) as $idxs |
      [to_entries[] | select((.key + 1) as $n | $idxs | index($n)) | .value]
    ' "$SUBSCRIPTIONS_FILE" > "$selected_file"
  fi

  local count
  count=$(jq length "$selected_file")
  if [[ "$count" -eq 0 ]]; then
    echo "No subscriptions matched that selection." >&2
    return 1
  fi

  if jq -e '[.[] | select(.state != "Enabled")] | length > 0' "$selected_file" >/dev/null; then
    echo "Selection includes non-enabled subscriptions. Choose enabled subscriptions only." >&2
    jq -r '.[] | select(.state != "Enabled") | "  - \(.name) [\(.state)] \(.id)"' "$selected_file" >&2
    return 1
  fi
}

confirm_selection() {
  local selected_file="$1"
  echo >&2
  echo "Selected subscription(s):" >&2
  jq -r '.[] | "  - \(.name)  \(.id)"' "$selected_file" >&2
  echo >&2
  echo "Press Enter to run this selection, or type:" >&2
  echo "  b = back to subscription menu" >&2
  echo "  r = refresh subscriptions" >&2
  echo "  q = quit" >&2
  read -r -p "Run now? [Enter/b/r/q]: " choice
  case "${choice:-run}" in
    run|y|Y|yes|YES) return 0 ;;
    b|B) return 10 ;;
    r|R) return 11 ;;
    q|Q) return 12 ;;
    *) echo "Unknown choice; returning to menu." >&2; return 10 ;;
  esac
}

make_run_label() {
  local selected_file="$1"
  local count first_name first_id run_stamp short_ids
  count=$(jq length "$selected_file")
  run_stamp=$(date -u +%H%M%S)
  if [[ "$count" -eq 1 ]]; then
    first_name=$(jq -r '.[0].name' "$selected_file")
    first_id=$(jq -r '.[0].id[0:8]' "$selected_file")
    safe_name "sub-${first_name}-${first_id}-${run_stamp}"
  else
    short_ids=$(jq -r '.[].id[0:8]' "$selected_file" | paste -sd '-' -)
    safe_name "multi-${count}-subscriptions-${short_ids}-${run_stamp}"
  fi
}

graph_query_paginated() {
  local query="$1"
  local outfile="$2"
  local label="$3"
  shift 3
  local sub_ids=("$@")
  local page_file skip next_file tmp_file

  page_file="$outfile.page1.json"
  next_file="$outfile.next.json"
  tmp_file="$outfile.tmp.json"

  az_json_with_spinner "$label" "$page_file" az graph query --first 1000 --subscriptions "${sub_ids[@]}" -q "$query" -o json
  jq '.data' "$page_file" > "$outfile"

  skip=$(jq -r '.skipToken // empty' "$page_file")
  while [[ -n "$skip" ]]; do
    az_json_with_spinner "Fetching next page for: $label" "$next_file" az graph query --first 1000 --skip-token "$skip" --subscriptions "${sub_ids[@]}" -q "$query" -o json
    jq -s '.[0] + .[1].data' "$outfile" "$next_file" > "$tmp_file"
    mv "$tmp_file" "$outfile"
    skip=$(jq -r '.skipToken // empty' "$next_file")
  done
}

run_inventory() {
  local selected_file="$1"
  local label run_dir sub_count resource_count candidate_count advisor_count
  label=$(make_run_label "$selected_file")
  run_dir="$SESSION_DIR/$label"
  mkdir -p "$run_dir"
  cp "$selected_file" "$run_dir/subscriptions.selected.json"
  cp "$SUBSCRIPTIONS_FILE" "$run_dir/subscriptions.all.json"

  mapfile -t sub_ids < <(jq -r '.[].id' "$selected_file")
  sub_count="${#sub_ids[@]}"

  log "Starting read-only inventory for $sub_count subscription(s)."
  log "Output directory: $run_dir"

  read -r -d '' INVENTORY_QUERY <<'KQL' || true
Resources
| project id, name, type, resourceGroup, subscriptionId, location, kind,
          skuName=tostring(sku.name), skuTier=tostring(sku.tier),
          tags, managedBy=tostring(managedBy), properties
| extend tag_owner=coalesce(tostring(tags.owner), tostring(tags.Owner), tostring(tags.OWNER), tostring(tags['cost-owner']), tostring(tags['CostOwner']))
| extend tag_env=coalesce(tostring(tags.environment), tostring(tags.Environment), tostring(tags.env), tostring(tags.Env))
| extend provisioningState=tostring(properties.provisioningState)
| project-away properties
| order by subscriptionId asc, resourceGroup asc, type asc, name asc
KQL

  graph_query_paginated "$INVENTORY_QUERY" "$run_dir/resources.json" "Running Azure Resource Graph inventory..." "${sub_ids[@]}"

  jq -r '["subscriptionId","resourceGroup","type","name","location","skuName","skuTier","ownerTag","environmentTag","provisioningState","id"],
         (.[] | [.subscriptionId,.resourceGroup,.type,.name,.location,.skuName,.skuTier,.tag_owner,.tag_env,.provisioningState,.id]) | @csv' \
    "$run_dir/resources.json" > "$run_dir/azure-inventory.csv"

  read -r -d '' CANDIDATE_QUERY <<KQL || true
let cutoff = ago(${DAYS_OLD}d);
let allResources = Resources | project id, name, type, resourceGroup, subscriptionId, location, tags, properties, managedBy;
let unattachedDisks = allResources
  | where type =~ 'microsoft.compute/disks'
  | where isempty(tostring(managedBy))
  | extend reason='Unattached managed disk', severity='High', suggestedAction='Review, snapshot if needed, then delete', evidence=strcat('diskState=', tostring(properties.diskState));
let unattachedNics = allResources
  | where type =~ 'microsoft.network/networkinterfaces'
  | where isempty(tostring(properties.virtualMachine.id)) and isempty(tostring(properties.privateEndpoint.id))
  | extend reason='Unattached network interface', severity='High', suggestedAction='Delete if no planned reuse', evidence='No VM/private endpoint association';
let unassociatedPips = allResources
  | where type =~ 'microsoft.network/publicipaddresses'
  | where isempty(tostring(properties.ipConfiguration.id)) and isempty(tostring(properties.natGateway.id))
  | extend reason='Unassociated public IP', severity='High', suggestedAction='Delete if no planned reuse', evidence=strcat('ipAddress=', tostring(properties.ipAddress));
let oldSnapshots = allResources
  | where type =~ 'microsoft.compute/snapshots'
  | extend created=todatetime(properties.timeCreated)
  | where isnotempty(created) and created < cutoff
  | extend reason=strcat('Snapshot older than ', '${DAYS_OLD}', ' days'), severity='Medium', suggestedAction='Confirm retention need, then delete', evidence=strcat('created=', tostring(created));
let deallocatedVms = allResources
  | where type =~ 'microsoft.compute/virtualmachines'
  | extend powerState=tostring(properties.extended.instanceView.powerState.displayStatus)
  | where powerState has 'deallocated' or powerState has 'stopped'
  | extend reason='Stopped/deallocated VM', severity='Medium', suggestedAction='Confirm owner; delete or keep stopped intentionally', evidence=strcat('powerState=', powerState);
let untagged = allResources
  | extend owner=coalesce(tostring(tags.owner), tostring(tags.Owner), tostring(tags['cost-owner']), tostring(tags['CostOwner']))
  | extend env=coalesce(tostring(tags.environment), tostring(tags.Environment), tostring(tags.env), tostring(tags.Env))
  | where isempty(owner) or isempty(env)
  | extend reason='Missing owner/environment tag', severity='Low', suggestedAction='Tag owner/env or review for cleanup', evidence=strcat('owner=', owner, '; env=', env);
union unattachedDisks, unattachedNics, unassociatedPips, oldSnapshots, deallocatedVms, untagged
| project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
| order by severity asc, subscriptionId asc, resourceGroup asc, type asc, name asc
KQL

  graph_query_paginated "$CANDIDATE_QUERY" "$run_dir/cleanup-candidates.json" "Checking common orphan/abandoned patterns..." "${sub_ids[@]}"

  jq -r '["severity","reason","suggestedAction","subscriptionId","resourceGroup","type","name","location","evidence","id"],
         (.[] | [.severity,.reason,.suggestedAction,.subscriptionId,.resourceGroup,.type,.name,.location,.evidence,.id]) | @csv' \
    "$run_dir/cleanup-candidates.json" > "$run_dir/cleanup-candidates.csv"

  log "Pulling Azure Advisor cost recommendations where available..."
  : > "$run_dir/advisor-cost-recommendations.jsonl"
  while read -r sub; do
    run_with_spinner "Setting Azure subscription $sub" "$run_dir/account-set-$sub.out" "$run_dir/account-set-$sub.err" az account set --subscription "$sub"
    if az_json_with_spinner "Advisor cost recommendations for $sub" "$run_dir/advisor-$sub.json" az advisor recommendation list --category Cost -o json; then
      jq -c --arg subscriptionId "$sub" '.[] | . + {subscriptionId:$subscriptionId}' "$run_dir/advisor-$sub.json" >> "$run_dir/advisor-cost-recommendations.jsonl"
    else
      log "WARN: Advisor query failed for subscription $sub; see $run_dir/advisor-$sub.err"
    fi
  done < <(jq -r '.[].id' "$selected_file")

  jq -s '.' "$run_dir/advisor-cost-recommendations.jsonl" > "$run_dir/advisor-cost-recommendations.json"

  resource_count=$(jq length "$run_dir/resources.json")
  candidate_count=$(jq length "$run_dir/cleanup-candidates.json")
  advisor_count=$(jq length "$run_dir/advisor-cost-recommendations.json")

  log "Creating summary..."
  {
    echo "Azure abandoned resource inventory"
    echo "Run UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Session directory: $SESSION_DIR"
    echo "Run directory: $run_dir"
    echo "Subscriptions: $sub_count"
    jq -r '.[] | "  - \(.name)  \(.id)"' "$selected_file"
    echo "Resources inventoried: $resource_count"
    echo "Cleanup candidate rows: $candidate_count"
    echo "Advisor cost recommendations: $advisor_count"
    echo
    echo "Top candidate reasons:"
    jq -r 'sort_by(.reason) | group_by(.reason)[] | [length, .[0].reason] | @tsv' "$run_dir/cleanup-candidates.json" | sort -rn | head -20
    echo
    echo "Files:"
    find "$run_dir" -maxdepth 1 -type f | sort
  } > "$run_dir/summary.txt"

  cat > "$run_dir/index.html" <<HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Azure Abandoned Resource Inventory</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:2rem;line-height:1.45}code,pre{background:#f4f4f4;padding:.2rem .35rem;border-radius:4px}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:.35rem .5rem}</style>
</head>
<body>
<h1>Azure Abandoned Resource Inventory</h1>
<p>Run UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)</p>
<ul>
<li>Subscriptions: $sub_count</li>
<li>Resources inventoried: $resource_count</li>
<li>Cleanup candidate rows: $candidate_count</li>
<li>Advisor cost recommendations: $advisor_count</li>
</ul>
<p>Open <code>cleanup-candidates.csv</code> first. This report is evidence-only; do not delete without owner review.</p>
<h2>Top candidate reasons</h2>
<pre>$(jq -r 'sort_by(.reason) | group_by(.reason)[] | [length, .[0].reason] | @tsv' "$run_dir/cleanup-candidates.json" | sort -rn | head -20)</pre>
</body></html>
HTML

  log "Done. Output directory: $run_dir"
  cat "$run_dir/summary.txt"
  echo >&2
  echo "Returning to subscription menu. You can run another subscription, all subscriptions, refresh, or quit." >&2
}

while true; do
  fetch_subscriptions
  print_subscription_menu
  read -r -p "Selection [0/r/q]: " selection
  selection="${selection:-0}"

  case "$selection" in
    q|Q)
      echo "Session output directory: $SESSION_DIR"
      exit 0
      ;;
    r|R)
      fetch_subscriptions
      continue
      ;;
  esac

  selected_file="$SESSION_DIR/selected.pending.json"
  if ! select_subscriptions "$selection" "$selected_file"; then
    continue
  fi

  if confirm_selection "$selected_file"; then
    run_inventory "$selected_file"
  else
    rc=$?
    case "$rc" in
      10) continue ;;
      11) fetch_subscriptions; continue ;;
      12) echo "Session output directory: $SESSION_DIR"; exit 0 ;;
      *) continue ;;
    esac
  fi
done
