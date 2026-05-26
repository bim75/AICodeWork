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

create_zip_archive() {
  local source_dir="$1"
  local zip_path="$2"
  local abs_zip_path
  abs_zip_path="$(cd "$(dirname "$zip_path")" && pwd)/$(basename "$zip_path")"
  rm -f "$abs_zip_path"

  if command -v zip >/dev/null 2>&1; then
    (cd "$source_dir" && zip -qr "$abs_zip_path" .)
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$source_dir" "$abs_zip_path" <<'PY'
import os
import sys
import zipfile

source_dir = os.path.abspath(sys.argv[1])
zip_path = os.path.abspath(sys.argv[2])

with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(source_dir):
        for name in files:
            full_path = os.path.join(root, name)
            if os.path.abspath(full_path) == zip_path:
                continue
            arcname = os.path.relpath(full_path, source_dir)
            zf.write(full_path, arcname)
PY
  else
    echo "ERROR: cannot create zip archive; missing both zip and python3" >&2
    return 1
  fi
}

generate_local_html_report() {
  local run_dir="$1"
  local run_utc="$2"
  local days_old="$3"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARN: python3 not found; writing basic index.html instead of rich local report" >&2
    return 1
  fi
  python3 - "$run_dir" "$run_utc" "$days_old" <<'PY'
import collections, html, json, os, sys
run_dir, run_utc, days_old = sys.argv[1:4]
def load(name, default):
    try:
        with open(os.path.join(run_dir, name), encoding='utf-8') as f: return json.load(f)
    except FileNotFoundError: return default
def esc(v):
    if v is None: return ''
    if isinstance(v, (dict, list)): v = json.dumps(v, ensure_ascii=False, sort_keys=True)
    return html.escape(str(v))
def raw(v): return html.escape(json.dumps(v, ensure_ascii=False, indent=2, sort_keys=True))
def counts(items, key): return collections.Counter(str(x.get(key) or '(blank)') for x in items if isinstance(x, dict)).most_common()
def make_table(items, cols, tid):
    if not items: return '<p class="muted">No rows.</p>'
    head=''.join(f'<th>{esc(label)}</th>' for label,_ in cols)
    rows=[]
    for item in items:
        rows.append('<tr>'+''.join(f'<td>{esc(item.get(key, "") if isinstance(item, dict) else "")}</td>' for _,key in cols)+'</tr>')
    return f'<div class="table-wrap"><table id="{esc(tid)}"><thead><tr>{head}</tr></thead><tbody>'+'\n'.join(rows)+'</tbody></table></div>'
resources=load('resources.json',[]); candidates=load('cleanup-candidates.json',[]); advisor=load('advisor-cost-recommendations.json',[])
subs=load('subscriptions.selected.json',[]); all_subs=load('subscriptions.all.json',[])
high=[x for x in candidates if str(x.get('severity','')).lower()=='high']; med=[x for x in candidates if str(x.get('severity','')).lower()=='medium']; low=[x for x in candidates if str(x.get('severity','')).lower()=='low']
reasons=counts(candidates,'reason'); severities=counts(candidates,'severity'); cand_types=counts(candidates,'type'); res_types=counts(resources,'type'); rgs=counts(resources,'resourceGroup')
summary=['Azure abandoned resource inventory summary',f'Run UTC: {run_utc}',f'Subscriptions reviewed: {len(subs)}',f'Resources inventoried: {len(resources)}',f'Cleanup candidate rows: {len(candidates)}',f'High severity candidates: {len(high)}',f'Medium severity candidates: {len(med)}',f'Low severity candidates: {len(low)}',f'Advisor cost recommendations: {len(advisor)}','','Top candidate reasons:']
summary += [f'- {c}: {r}' for r,c in reasons[:20]]
summary_text='\n'.join(summary)
cand_cols=[('Severity','severity'),('Reason','reason'),('Suggested Action','suggestedAction'),('Subscription','subscriptionId'),('Resource Group','resourceGroup'),('Type','type'),('Name','name'),('Location','location'),('Evidence','evidence'),('ID','id')]
res_cols=[('Subscription','subscriptionId'),('Resource Group','resourceGroup'),('Type','type'),('Name','name'),('Location','location'),('Kind','kind'),('SKU Name','skuName'),('SKU Tier','skuTier'),('Owner Tag','tag_owner'),('Environment Tag','tag_env'),('Provisioning State','provisioningState'),('Managed By','managedBy'),('Tags','tags'),('ID','id')]
adv_cols=[('Subscription','subscriptionId'),('Category','category'),('Impact','impact'),('Impacted Field','impactedField'),('Impacted Value','impactedValue'),('Recommendation','shortDescription'),('Details','extendedProperties'),('ID','id')]
sub_list=''.join(f'<li>{esc(s.get("name",""))} — <code>{esc(s.get("id",""))}</code></li>' for s in subs if isinstance(s,dict))
breakdowns=''
for title, rows in [('Candidate severity',severities),('Candidate reasons',reasons),('Candidate resource types',cand_types),('Top resource types',res_types[:30]),('Top resource groups',rgs[:30])]:
    breakdowns += f'<h3>{esc(title)}</h3><table class="compact"><thead><tr><th>Count</th><th>Value</th></tr></thead><tbody>'
    breakdowns += ''.join(f'<tr><td>{c}</td><td>{esc(v)}</td></tr>' for v,c in rows) + '</tbody></table>'
html_doc=f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Azure Abandoned Resource Inventory - Local Report</title><style>
:root {{ --bg:#0f172a; --panel:#111827; --panel2:#1f2937; --text:#e5e7eb; --muted:#9ca3af; --line:#374151; --accent:#60a5fa; --med:#fbbf24; }} *{{box-sizing:border-box}} body{{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;background:var(--bg);color:var(--text);line-height:1.45}} header{{padding:24px;background:linear-gradient(135deg,#111827,#172554);border-bottom:1px solid var(--line)}} main{{padding:20px}} h1{{margin:0 0 8px;font-size:28px}} a{{color:var(--accent)}} .card{{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;margin:0 0 16px}} .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}} .metric{{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:12px}} .num{{font-size:26px;font-weight:750}} .label,.muted{{color:var(--muted)}} .controls{{margin:10px 0 14px}} input,button{{background:#0b1220;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:8px 10px}} .table-wrap{{overflow:auto;max-height:620px;border:1px solid var(--line);border-radius:10px}} table{{border-collapse:collapse;width:100%;font-size:13px}} th,td{{border-bottom:1px solid var(--line);padding:8px;text-align:left;vertical-align:top}} th{{position:sticky;top:0;background:#0b1220;z-index:1}} tr:nth-child(even) td{{background:rgba(255,255,255,.025)}} .compact{{width:auto;min-width:360px}} pre,textarea{{width:100%;background:#020617;color:#d1d5db;border:1px solid var(--line);border-radius:10px;padding:12px;overflow:auto}} textarea{{min-height:320px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}} .warning{{border-left:4px solid var(--med);padding-left:12px}} nav{{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}} nav a{{color:var(--text);text-decoration:none;background:#0b1220;border:1px solid var(--line);border-radius:999px;padding:7px 11px}}
</style></head><body><header><h1>Azure Abandoned Resource Inventory</h1><div class="muted">Self-contained local HTML report generated {esc(run_utc)} UTC. Open this file locally after downloading the ZIP.</div><nav><a href="#summary">Summary</a><a href="#candidates">Cleanup Candidates</a><a href="#inventory">Full Inventory</a><a href="#advisor">Advisor</a><a href="#raw">Raw JSON</a></nav></header><main>
<section id="summary" class="card"><h2>Summary</h2><div class="grid"><div class="metric"><div class="num">{len(subs)}</div><div class="label">Subscriptions reviewed</div></div><div class="metric"><div class="num">{len(resources)}</div><div class="label">Resources inventoried</div></div><div class="metric"><div class="num">{len(candidates)}</div><div class="label">Cleanup candidate rows</div></div><div class="metric"><div class="num">{len(high)}</div><div class="label">High severity</div></div><div class="metric"><div class="num">{len(med)}</div><div class="label">Medium severity</div></div><div class="metric"><div class="num">{len(low)}</div><div class="label">Low severity</div></div><div class="metric"><div class="num">{len(advisor)}</div><div class="label">Advisor cost recommendations</div></div></div><p class="warning">This is a review report only. Do not delete resources until the owner/application impact is confirmed.</p><h3>Selected subscriptions</h3><ul>{sub_list}</ul><h3>Copy/paste summary</h3><button onclick="copyText('summaryText')">Copy summary</button><pre id="summaryText">{esc(summary_text)}</pre>{breakdowns}</section>
<section id="candidates" class="card"><h2>Cleanup candidates</h2><p class="muted">Same rows as cleanup-candidates.json/csv. Use the table search box.</p><div class="controls"><input data-filter="candidateTable" placeholder="Search cleanup candidates..." oninput="filterTable(this)"></div>{make_table(candidates,cand_cols,'candidateTable')}</section>
<section id="inventory" class="card"><h2>Full Azure inventory</h2><p class="muted">Same resource rows as resources.json / azure-inventory.csv, with tags and IDs included.</p><div class="controls"><input data-filter="resourceTable" placeholder="Search full inventory..." oninput="filterTable(this)"></div>{make_table(resources,res_cols,'resourceTable')}</section>
<section id="advisor" class="card"><h2>Azure Advisor cost recommendations</h2><p class="muted">Same rows as advisor-cost-recommendations.json/jsonl where available.</p><div class="controls"><input data-filter="advisorTable" placeholder="Search advisor recommendations..." oninput="filterTable(this)"></div>{make_table(advisor,adv_cols,'advisorTable')}</section>
<section id="raw" class="card"><h2>Raw embedded JSON</h2><p class="muted">These sections preserve the source JSON data inside this local HTML file for copy/paste or audit.</p><details><summary>cleanup-candidates.json</summary><textarea readonly>{raw(candidates)}</textarea></details><details><summary>resources.json</summary><textarea readonly>{raw(resources)}</textarea></details><details><summary>advisor-cost-recommendations.json</summary><textarea readonly>{raw(advisor)}</textarea></details><details><summary>subscriptions.selected.json</summary><textarea readonly>{raw(subs)}</textarea></details><details><summary>subscriptions.all.json</summary><textarea readonly>{raw(all_subs)}</textarea></details></section>
</main><script>function filterTable(input){{const table=document.getElementById(input.dataset.filter);const q=input.value.toLowerCase();if(!table)return;for(const row of table.tBodies[0].rows){{row.style.display=row.innerText.toLowerCase().includes(q)?'':'none';}}}} function copyText(id){{const text=document.getElementById(id).innerText;navigator.clipboard.writeText(text).then(()=>alert('Copied summary to clipboard'));}}</script></body></html>"""
with open(os.path.join(run_dir,'index.html'),'w',encoding='utf-8') as f: f.write(html_doc)
print(os.path.join(run_dir,'index.html'))
PY
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
  local label run_dir zip_path sub_count resource_count candidate_count advisor_count
  label=$(make_run_label "$selected_file")
  run_dir="$SESSION_DIR/$label"
  zip_path="$SESSION_DIR/${label}.zip"
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
Resources
| where type =~ 'microsoft.compute/disks'
| where isempty(tostring(managedBy))
| extend reason='Unattached managed disk', severity='High', suggestedAction='Review, snapshot if needed, then delete', evidence=strcat('diskState=', tostring(properties.diskState))
| project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
| union (
  Resources
  | where type =~ 'microsoft.network/networkinterfaces'
  | where isempty(tostring(properties.virtualMachine.id)) and isempty(tostring(properties.privateEndpoint.id))
  | extend reason='Unattached network interface', severity='High', suggestedAction='Delete if no planned reuse', evidence='No VM/private endpoint association'
  | project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
)
| union (
  Resources
  | where type =~ 'microsoft.network/publicipaddresses'
  | where isempty(tostring(properties.ipConfiguration.id)) and isempty(tostring(properties.natGateway.id))
  | extend reason='Unassociated public IP', severity='High', suggestedAction='Delete if no planned reuse', evidence=strcat('ipAddress=', tostring(properties.ipAddress))
  | project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
)
| union (
  Resources
  | where type =~ 'microsoft.compute/snapshots'
  | extend created=todatetime(properties.timeCreated)
  | where isnotempty(created) and created < ago(${DAYS_OLD}d)
  | extend reason=strcat('Snapshot older than ', '${DAYS_OLD}', ' days'), severity='Medium', suggestedAction='Confirm retention need, then delete', evidence=strcat('created=', tostring(created))
  | project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
)
| union (
  Resources
  | where type =~ 'microsoft.compute/virtualmachines'
  | extend powerState=tostring(properties.extended.instanceView.powerState.displayStatus)
  | where powerState has 'deallocated' or powerState has 'stopped'
  | extend reason='Stopped/deallocated VM', severity='Medium', suggestedAction='Confirm owner; delete or keep stopped intentionally', evidence=strcat('powerState=', powerState)
  | project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
)
| union (
  Resources
  | extend owner=coalesce(tostring(tags.owner), tostring(tags.Owner), tostring(tags['cost-owner']), tostring(tags['CostOwner']))
  | extend env=coalesce(tostring(tags.environment), tostring(tags.Environment), tostring(tags.env), tostring(tags.Env))
  | where isempty(owner) or isempty(env)
  | extend reason='Missing owner/environment tag', severity='Low', suggestedAction='Tag owner/env or review for cleanup', evidence=strcat('owner=', owner, '; env=', env)
  | project subscriptionId, resourceGroup, type, name, location, severity, reason, suggestedAction, evidence, id
)
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

  run_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! generate_local_html_report "$run_dir" "$run_utc" "$DAYS_OLD"; then
    cat > "$run_dir/index.html" <<HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Azure Abandoned Resource Inventory</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:2rem;line-height:1.45}code,pre{background:#f4f4f4;padding:.2rem .35rem;border-radius:4px}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:.35rem .5rem}</style>
</head>
<body>
<h1>Azure Abandoned Resource Inventory</h1>
<p>Run UTC: $run_utc</p>
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
  fi

  echo "$run_dir/index.html" >> "$run_dir/summary.txt"
  echo "ZIP archive: $zip_path" >> "$run_dir/summary.txt"

  log "Creating zip archive for easy download..."
  create_zip_archive "$run_dir" "$zip_path"

  log "Done. Output directory: $run_dir"
  log "Local HTML report: $run_dir/index.html"
  log "ZIP archive: $zip_path"
  cat "$run_dir/summary.txt"
  echo
  echo "Open local HTML report: $run_dir/index.html"
  echo "Download ZIP archive: $zip_path"
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
