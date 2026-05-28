#!/usr/bin/env bash
set -u -o pipefail

# Azure Subscription Cost + Utilization Inventory
# Read-only. Intended for Azure Cloud Shell Bash.
# Produces JSON/CSV plus a self-contained HTML report and ZIP.

DAYS="${DAYS:-30}"
OUT_BASE="${OUT_BASE:-$HOME/azure-cost-inventory-reports}"
PARALLEL_METRICS="${PARALLEL_METRICS:-4}"
INCLUDE_VM_METRICS="${INCLUDE_VM_METRICS:-1}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need az
need jq
need python3

TS="$(date +%Y%m%d-%H%M%S)"
SESSION_DIR="$OUT_BASE/session-$TS"
mkdir -p "$SESSION_DIR"
LOG="$SESSION_DIR/run.log"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

run_json() {
  local label="$1" out="$2" err="$3"; shift 3
  say "START $label"
  "$@" >"$out" 2>"$err" &
  local pid=$! start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    local now=$(date +%s)
    echo "WORKING $label elapsed=$((now-start))s"
    sleep 2
  done
  wait "$pid"
  local rc=$? now=$(date +%s)
  if [ "$rc" -eq 0 ]; then
    echo "OK $label elapsed=$((now-start))s"
  else
    echo "ERROR $label elapsed=$((now-start))s rc=$rc"
    tail -40 "$err" || true
    return "$rc"
  fi
}

az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true
az config set extension.dynamic_install_allow_preview=true >/dev/null 2>&1 || true

say "Checking Azure login"
if ! az account show -o json >/dev/null 2>"$SESSION_DIR/account-show.err"; then
  echo "You are not logged in. In Azure Cloud Shell this normally should already be authenticated. Try: az login"
  exit 1
fi

list_subs() {
  run_json "Reading accessible subscriptions" "$SESSION_DIR/subscriptions.raw.json" "$SESSION_DIR/subscriptions.err" az account list --all -o json || exit 1
  jq '[.[] | select(.state == "Enabled") | {name, id, tenantId, state, isDefault}]' "$SESSION_DIR/subscriptions.raw.json" > "$SESSION_DIR/subscriptions.json"
}

print_sub_menu() {
  list_subs
  echo
  echo "Accessible enabled subscriptions:"
  jq -r 'to_entries[] | "\(.key+1)) \(.value.name)  [\(.value.id)]"' "$SESSION_DIR/subscriptions.json"
  echo "0) ALL enabled subscriptions"
  echo "r) refresh"
  echo "q) quit"
}

select_subs() {
  while true; do
    print_sub_menu
    echo
    read -r -p "Select subscription number(s), comma-separated, 0=all, r=refresh, q=quit: " ans
    case "$ans" in
      q|Q) exit 0 ;;
      r|R) continue ;;
      0) jq -c '.' "$SESSION_DIR/subscriptions.json" > "$SESSION_DIR/selected-subscriptions.json" ;;
      *)
        python3 - "$SESSION_DIR/subscriptions.json" "$ans" > "$SESSION_DIR/selected-subscriptions.json" <<'PY'
import json, sys
subs=json.load(open(sys.argv[1])); ans=sys.argv[2]
idx=[]
try:
    for p in ans.split(','):
        p=p.strip()
        if not p: continue
        i=int(p)-1
        if i<0 or i>=len(subs): raise ValueError(p)
        idx.append(i)
except Exception:
    print('[]')
    sys.exit(2)
print(json.dumps([subs[i] for i in dict.fromkeys(idx)]))
PY
        if [ $? -ne 0 ] || [ "$(jq 'length' "$SESSION_DIR/selected-subscriptions.json")" -eq 0 ]; then
          echo "Invalid selection."
          continue
        fi
        ;;
    esac
    echo
    echo "Selected:"
    jq -r '.[] | "- \(.name) [\(.id)]"' "$SESSION_DIR/selected-subscriptions.json"
    read -r -p "Press Enter to run read-only inventory, b=back, q=quit: " confirm
    case "$confirm" in q|Q) exit 0 ;; b|B) continue ;; *) break ;; esac
  done
}

collect_subscription() {
  local sub_id="$1" sub_name="$2" safe_name="$3"
  local dir="$SESSION_DIR/$safe_name"
  mkdir -p "$dir"
  say "Collecting subscription: $sub_name [$sub_id]"
  az account set --subscription "$sub_id" >/dev/null

  # Keep this compatible with Azure Cloud Shell's installed az version. Some
  # versions do not support --include-response-body on az resource list.
  run_json "Resource inventory for $sub_name" "$dir/resources.json" "$dir/resources.err" az resource list --subscription "$sub_id" -o json || echo '[]' > "$dir/resources.json"

  # Resource Graph adds richer fields and relationships when available. Azure
  # Resource Graph caps --first at 1000; the main inventory above still captures
  # all resources for this report, so this is supplemental.
  local kql="Resources | where subscriptionId == '$sub_id' | project id, name, type, resourceGroup, location, subscriptionId, sku, kind, properties, tags"
  run_json "Resource Graph inventory for $sub_name" "$dir/resource-graph.json" "$dir/resource-graph.err" az graph query -q "$kql" --subscriptions "$sub_id" --first 1000 -o json || echo '{"data":[]}' > "$dir/resource-graph.json"

  run_json "Advisor cost recommendations for $sub_name" "$dir/advisor-cost.json" "$dir/advisor-cost.err" az advisor recommendation list --subscription "$sub_id" --category Cost -o json || echo '[]' > "$dir/advisor-cost.json"

  local end start
  end="$(date -u +%Y-%m-%d)"
  start="$(date -u -d "$DAYS days ago" +%Y-%m-%d)"
  cat > "$dir/cost-query-body.json" <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {"from": "$start", "to": "$end"},
  "dataset": {
    "granularity": "None",
    "aggregation": {"Cost": {"name": "Cost", "function": "Sum"}},
    "grouping": [
      {"type":"Dimension", "name":"ResourceId"},
      {"type":"Dimension", "name":"ResourceType"},
      {"type":"Dimension", "name":"ServiceName"},
      {"type":"Dimension", "name":"ResourceGroupName"}
    ]
  }
}
EOF
  run_json "Cost by resource for $sub_name ($DAYS days)" "$dir/cost-by-resource.raw.json" "$dir/cost-by-resource.err" \
    az rest --method post --url "https://management.azure.com/subscriptions/$sub_id/providers/Microsoft.CostManagement/query?api-version=2023-03-01" --body "@$dir/cost-query-body.json" -o json || echo '{}' > "$dir/cost-by-resource.raw.json"

  cat > "$dir/service-cost-query-body.json" <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {"from": "$start", "to": "$end"},
  "dataset": {
    "granularity": "None",
    "aggregation": {"Cost": {"name": "Cost", "function": "Sum"}},
    "grouping": [{"type":"Dimension", "name":"ServiceName"}]
  }
}
EOF
  run_json "Cost by service for $sub_name ($DAYS days)" "$dir/cost-by-service.raw.json" "$dir/cost-by-service.err" \
    az rest --method post --url "https://management.azure.com/subscriptions/$sub_id/providers/Microsoft.CostManagement/query?api-version=2023-03-01" --body "@$dir/service-cost-query-body.json" -o json || echo '{}' > "$dir/cost-by-service.raw.json"

  jq -r '
    def cols: .properties.columns | map(.name);
    if (.properties.rows // []) == [] then empty else
    (cols | @csv),
    (.properties.rows[] | @csv)
    end' "$dir/cost-by-resource.raw.json" > "$dir/cost-by-resource.csv" 2>/dev/null || true

  jq -r '
    def cols: .properties.columns | map(.name);
    if (.properties.rows // []) == [] then empty else
    (cols | @csv),
    (.properties.rows[] | @csv)
    end' "$dir/cost-by-service.raw.json" > "$dir/cost-by-service.csv" 2>/dev/null || true

  # Utilization/idle candidate datasets from inventory.
  jq '[.[] | select(.type|ascii_downcase == "microsoft.compute/disks") | {id,name,resourceGroup,location,sku,managedBy, diskState:.properties.diskState, diskSizeGB:.properties.diskSizeGB, tags}]' "$dir/resources.json" > "$dir/disks.json" || echo '[]' > "$dir/disks.json"
  jq '[.[] | select(.type|ascii_downcase == "microsoft.network/publicipaddresses") | {id,name,resourceGroup,location,sku,ipAddress:.properties.ipAddress, ipConfiguration:.properties.ipConfiguration.id, tags}]' "$dir/resources.json" > "$dir/public-ips.json" || echo '[]' > "$dir/public-ips.json"
  jq '[.[] | select(.type|ascii_downcase == "microsoft.network/networkinterfaces") | {id,name,resourceGroup,location,virtualMachine:.properties.virtualMachine.id, privateEndpoint:.properties.privateEndpoint.id, tags}]' "$dir/resources.json" > "$dir/nics.json" || echo '[]' > "$dir/nics.json"
  jq '[.[] | select(.type|ascii_downcase == "microsoft.compute/virtualmachines") | {id,name,resourceGroup,location,hardwareProfile:.properties.hardwareProfile, storageProfile:.properties.storageProfile, tags}]' "$dir/resources.json" > "$dir/vms-basic.json" || echo '[]' > "$dir/vms-basic.json"

  if [ "$INCLUDE_VM_METRICS" = "1" ]; then
    say "Collecting VM CPU metrics for $sub_name (last $DAYS days, avg/max). This can take a while."
    : > "$dir/vm-metrics.jsonl"
    jq -r '.[].id' "$dir/vms-basic.json" | while IFS= read -r vmid; do
      [ -z "$vmid" ] && continue
      tmp="$dir/metric-$(echo "$vmid" | sha1sum | awk '{print $1}').json"
      err="$tmp.err"
      if az monitor metrics list --resource "$vmid" --metric "Percentage CPU" --interval P1D --aggregation Average Maximum --start-time "${start}T00:00:00Z" --end-time "${end}T00:00:00Z" -o json > "$tmp" 2>"$err"; then
        python3 - "$vmid" "$tmp" >> "$dir/vm-metrics.jsonl" <<'PY'
import json, sys
vmid=sys.argv[1]
data=json.load(open(sys.argv[2]))
vals=[]; maxes=[]
for v in data.get('value',[]):
    for ts in v.get('timeseries',[]):
        for d in ts.get('data',[]):
            if d.get('average') is not None: vals.append(float(d['average']))
            if d.get('maximum') is not None: maxes.append(float(d['maximum']))
out={'id':vmid,'cpuAvg': (sum(vals)/len(vals) if vals else None), 'cpuMax': (max(maxes) if maxes else None), 'points': len(vals)}
print(json.dumps(out))
PY
      else
        echo "WARN metric failed for $vmid: $(tail -1 "$err")"
        printf '{"id":%s,"error":%s}\n' "$(jq -Rn --arg v "$vmid" '$v')" "$(jq -Rn --arg v "$(tail -1 "$err" 2>/dev/null)" '$v')" >> "$dir/vm-metrics.jsonl"
      fi
    done
    jq -s '.' "$dir/vm-metrics.jsonl" > "$dir/vm-metrics.json"
  else
    echo '[]' > "$dir/vm-metrics.json"
  fi
}

make_report() {
  say "Building consolidated report"
  python3 - "$SESSION_DIR" "$DAYS" <<'PY'
import csv, json, os, sys, glob, html, statistics
root=sys.argv[1]; days=sys.argv[2]
subs=json.load(open(os.path.join(root,'selected-subscriptions.json')))

def load(path, default):
    try:
        with open(path) as f: return json.load(f)
    except Exception: return default

def cost_rows(path):
    data=load(path,{})
    props=data.get('properties',{})
    cols=[c.get('name') for c in props.get('columns',[])]
    out=[]
    for row in props.get('rows',[]) or []:
        rec=dict(zip(cols,row))
        try: rec['Cost']=float(rec.get('Cost') or rec.get('PreTaxCost') or 0)
        except Exception: rec['Cost']=0.0
        out.append(rec)
    return out

all_resources=[]; all_cost=[]; all_service=[]; all_advisor=[]; findings=[]
for s in subs:
    safe='sub-'+''.join(c if c.isalnum() else '-' for c in s['id'])
    d=os.path.join(root,safe)
    resources=load(os.path.join(d,'resources.json'),[])
    costs=cost_rows(os.path.join(d,'cost-by-resource.raw.json'))
    svc=cost_rows(os.path.join(d,'cost-by-service.raw.json'))
    advisor=load(os.path.join(d,'advisor-cost.json'),[])
    metrics=load(os.path.join(d,'vm-metrics.json'),[])
    m_by_id={m.get('id','').lower():m for m in metrics}
    c_by_id={str(c.get('ResourceId','')).lower():c for c in costs if c.get('ResourceId')}
    for r in resources:
        rid=r.get('id','').lower(); c=c_by_id.get(rid,{})
        all_resources.append({'subscription':s['name'],'subscriptionId':s['id'],'id':r.get('id'),'name':r.get('name'),'type':r.get('type'),'resourceGroup':r.get('resourceGroup'),'location':r.get('location'),'cost':c.get('Cost',0)})
    for c in costs:
        c['subscription']=s['name']; c['subscriptionId']=s['id']; all_cost.append(c)
    for c in svc:
        c['subscription']=s['name']; c['subscriptionId']=s['id']; all_service.append(c)
    for a in advisor:
        ext=a.get('extendedProperties') or {}
        amt=ext.get('annualSavingsAmount') or ext.get('savingsAmount') or ext.get('monthlySavingsAmount')
        all_advisor.append({'subscription':s['name'],'subscriptionId':s['id'],'category':a.get('category'),'impact':a.get('impact'),'shortDescription':(a.get('shortDescription') or {}).get('problem') or a.get('recommendationTypeId'), 'resourceId':a.get('resourceMetadata',{}).get('resourceId'), 'savings':amt, 'currency':ext.get('savingsCurrency')})
    # Candidate findings
    for r in resources:
        t=(r.get('type') or '').lower(); p=r.get('properties') or {}; rid=r.get('id',''); cost=c_by_id.get(rid.lower(),{}).get('Cost',0)
        base={'subscription':s['name'],'subscriptionId':s['id'],'resource':r.get('name'),'type':r.get('type'),'resourceGroup':r.get('resourceGroup'),'location':r.get('location'),'lastDaysCost':cost,'resourceId':rid}
        if t=='microsoft.compute/disks' and not p.get('managedBy'):
            f=base.copy(); f.update({'severity':'High','finding':'Unattached managed disk','recommendation':'Delete if no longer needed, or snapshot/archive then delete. Verify with owner first.'}); findings.append(f)
        if t=='microsoft.network/publicipaddresses' and not ((p.get('ipConfiguration') or {}).get('id')):
            f=base.copy(); f.update({'severity':'Medium','finding':'Unassociated public IP','recommendation':'Delete if unused. Static public IPs can incur ongoing cost and increase attack surface.'}); findings.append(f)
        if t=='microsoft.network/networkinterfaces' and not ((p.get('virtualMachine') or {}).get('id')) and not ((p.get('privateEndpoint') or {}).get('id')):
            f=base.copy(); f.update({'severity':'Medium','finding':'Unattached network interface','recommendation':'Delete if not required by a planned VM/private endpoint.'}); findings.append(f)
        if t=='microsoft.compute/virtualmachines':
            m=m_by_id.get(rid.lower(),{})
            if m.get('cpuAvg') is not None and m.get('cpuMax') is not None and m['cpuAvg'] < 5 and m['cpuMax'] < 20:
                f=base.copy(); f.update({'severity':'Medium','finding':f"Low VM CPU utilization avg={m['cpuAvg']:.1f}% max={m['cpuMax']:.1f}%",'recommendation':'Consider downsizing, schedule shutdown outside business hours, deallocate if unused, or migrate workload to lower-cost service.'}); findings.append(f)
        if t=='microsoft.compute/snapshots':
            f=base.copy(); f.update({'severity':'Review','finding':'Snapshot present','recommendation':'Confirm retention need. Old snapshots often accumulate storage cost.'}); findings.append(f)

# CSV outputs
def write_csv(path, rows):
    keys=[]
    for r in rows:
        for k in r.keys():
            if k not in keys: keys.append(k)
    with open(path,'w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=keys or ['empty']); w.writeheader(); w.writerows(rows)
write_csv(os.path.join(root,'all-resources.csv'), all_resources)
write_csv(os.path.join(root,'all-cost-by-resource.csv'), all_cost)
write_csv(os.path.join(root,'all-cost-by-service.csv'), all_service)
write_csv(os.path.join(root,'advisor-cost-recommendations.csv'), all_advisor)
write_csv(os.path.join(root,'cost-savings-findings.csv'), findings)

summary={
 'days':days,
 'subscriptions':[{'name':s['name'],'id':s['id']} for s in subs],
 'totalResources':len(all_resources),
 'totalCost':round(sum(float(c.get('Cost') or 0) for c in all_cost),2),
 'topServices':sorted(all_service,key=lambda x:float(x.get('Cost') or 0),reverse=True)[:15],
 'topResources':sorted(all_cost,key=lambda x:float(x.get('Cost') or 0),reverse=True)[:25],
 'findingCount':len(findings),
 'advisorCount':len(all_advisor),
}
with open(os.path.join(root,'summary.json'),'w') as f: json.dump(summary,f,indent=2)
with open(os.path.join(root,'findings.json'),'w') as f: json.dump(findings,f,indent=2)

data={'summary':summary,'findings':findings,'advisor':all_advisor,'resources':all_resources,'costByResource':all_cost,'costByService':all_service}
js=json.dumps(data).replace('</','<\\/')
html_doc=f'''<!doctype html><html><head><meta charset="utf-8"><title>Azure Cost Inventory Report</title>
<style>
body{{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#0f172a;color:#e2e8f0}}a{{color:#93c5fd}}
.card{{background:#111827;border:1px solid #334155;border-radius:12px;padding:16px;margin:12px 0}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}}
.metric{{background:#020617;border:1px solid #334155;border-radius:10px;padding:12px}}.metric b{{display:block;font-size:22px;margin-top:4px}}
table{{border-collapse:collapse;width:100%;font-size:13px}}th,td{{border-bottom:1px solid #334155;padding:6px;text-align:left;vertical-align:top}}th{{position:sticky;top:0;background:#1e293b}}
input,select{{width:100%;padding:10px;background:#020617;color:#e2e8f0;border:1px solid #475569;border-radius:8px;box-sizing:border-box}}
input[type=checkbox]{{width:auto;transform:scale(1.2)}}
.controls{{display:grid;grid-template-columns:2fr 1fr;gap:12px}}.sev-High{{color:#fca5a5;font-weight:bold}}.sev-Medium{{color:#fde68a;font-weight:bold}}.sev-Review{{color:#bfdbfe;font-weight:bold}}.money{{color:#86efac}}
.small{{color:#94a3b8;font-size:12px}}
</style></head><body>
<h1>Azure Cost + Utilization Inventory</h1>
<div class="card"><h2>Executive Summary</h2><p>Period: last {html.escape(days)} days. Subscriptions: {len(subs)}. Resources: {len(all_resources)}. Actual cost captured: <span class="money">{summary['totalCost']}</span>. Findings: {len(findings)}. Advisor cost recommendations: {len(all_advisor)}.</p>
<p><b>How to use this:</b> Review high-cost resources first, filter by subscription when needed, then validate each finding with the workload owner before deleting/stopping. This report is read-only evidence, not an automatic cleanup.</p></div>
<div class="card"><h2>Filters</h2><div class="controls"><div><label>Search all visible tables</label><input id="q" placeholder="VM name, resource group, service, type, subscription..." oninput="render()"></div><div><label>Subscription</label><select id="subFilter" onchange="render()"></select></div></div><p class="small">The subscription dropdown filters every table and recalculates the visible summary cards.</p></div>
<div id="app"></div>
<script>const DATA={js};
let selectedRecs = new Set();
function val(x){{return x===null||x===undefined?'':String(x)}}
function esc(x){{return val(x).replace(/[&<>]/g,s=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}}[s]))}}
function money(x){{let n=Number(x||0); return isNaN(n)?esc(x):n.toFixed(2)}}
function num(x){{let n=Number(String(x||'').replace(/[^0-9.-]/g,'')); return isNaN(n)?0:n}}
function selectedSub(){{return document.getElementById('subFilter').value}}
function rowSub(o){{return val(o.subscriptionId)||val(o.subscription)}}
function matchSub(o,sub){{return !sub || rowSub(o)===sub || val(o.subscription)===sub}}
function filtered(rows){{let q=document.getElementById('q').value.toLowerCase(); let sub=selectedSub(); return rows.filter(o=>matchSub(o,sub)).filter(o=>!q||JSON.stringify(o).toLowerCase().includes(q))}}
function table(title, rows, cols){{let r=filtered(rows); let h='<div class="card"><h2>'+esc(title)+' ('+r.length+')</h2><table><thead><tr>'+cols.map(c=>'<th>'+esc(c)+'</th>').join('')+'</tr></thead><tbody>'; h+=r.slice(0,500).map(o=>'<tr>'+cols.map(c=>'<td class="'+(c=='severity'?'sev-'+esc(o[c]):'')+'">'+(c.toLowerCase().includes('cost')||c=='Cost'?money(o[c]):esc(o[c]))+'</td>').join('')+'</tr>').join(''); return h+'</tbody></table>'+(r.length>500?'<p class="small">Showing first 500 filtered rows. See CSV for full data.</p>':'')+'</div>'}}
function sumCost(rows){{return rows.reduce((a,o)=>a+Number(o.Cost||o.cost||o.lastDaysCost||0),0)}}
function bySubRows(rows, sub){{return rows.filter(o=>matchSub(o,sub))}}
function advisorSavingsRows(sub){{return bySubRows(DATA.advisor,sub).map((o,i)=>Object.assign({{_idx:i,_savings:num(o.savings)}},o))}}
function sumSavings(rows){{return rows.reduce((a,o)=>a+num(o.savings),0)}}
function selectedSavings(){{let sub=selectedSub(); return advisorSavingsRows(sub).filter((o,i)=>selectedRecs.has(recKey(o,i))).reduce((a,o)=>a+o._savings,0)}}
function recKey(o,i){{return rowSub(o)+'|'+val(o.resourceId)+'|'+val(o.shortDescription)+'|'+i}}
function toggleRec(key, checked){{checked?selectedRecs.add(key):selectedRecs.delete(key); render()}}
function summaryCards(){{let sub=selectedSub(); let resources=bySubRows(DATA.resources,sub); let costRows=bySubRows(DATA.costByResource,sub); let advisor=bySubRows(DATA.advisor,sub); let name=sub?((DATA.summary.subscriptions.find(s=>s.id===sub)||{{}}).name||sub):'All subscriptions'; return '<div class="card"><h2>Visible Summary - '+esc(name)+'</h2><div class="grid"><div class="metric">Resources<b>'+resources.length+'</b></div><div class="metric">Cost captured<b class="money">'+money(sumCost(costRows))+'</b></div><div class="metric">Advisor recommendations<b>'+advisor.length+'</b></div><div class="metric">Possible savings if all Advisor recs are done<b class="money">'+money(sumSavings(advisor))+'</b></div><div class="metric">Checked recommendation savings<b class="money">'+money(selectedSavings())+'</b></div></div><p class="small">Savings values come from Azure Advisor when it provides a numeric savings amount. Treat them as estimates and validate before action.</p></div>'}}
function subscriptionBreakdown(){{let rows=DATA.summary.subscriptions.map(s=>{{let r=bySubRows(DATA.resources,s.id); let c=bySubRows(DATA.costByResource,s.id); let a=bySubRows(DATA.advisor,s.id); return {{subscription:s.name,subscriptionId:s.id,resources:r.length,cost:sumCost(c),advisor:a.length,possibleAdvisorSavings:sumSavings(a)}}}}); return table('Subscription breakdown', rows, ['subscription','subscriptionId','resources','cost','advisor','possibleAdvisorSavings'])}}
function top5Spend(){{let sub=selectedSub(); let rows=bySubRows(DATA.costByResource,sub).slice().sort((a,b)=>Number(b.Cost||0)-Number(a.Cost||0)).slice(0,5); let name=sub?((DATA.summary.subscriptions.find(s=>s.id===sub)||{{}}).name||sub):'all selected subscriptions'; return table('Top 5 spend - '+name, rows, ['Cost','ResourceId','ResourceType','ServiceName','ResourceGroupName','subscription'])}}
function advisorTable(){{let rows=filtered(DATA.advisor).map((o,i)=>Object.assign({{_idx:i,_savings:num(o.savings)}},o)); let h='<div class="card"><h2>Advisor cost recommendations ('+rows.length+')</h2><p class="small">Check recommendations to model selected estimated savings. These are not actions; they only update the calculator above.</p><table><thead><tr><th>Use?</th><th>savings</th><th>currency</th><th>impact</th><th>recommendation</th><th>subscription</th><th>resourceId</th></tr></thead><tbody>'; h+=rows.slice(0,500).map((o,i)=>{{let k=recKey(o,i); return '<tr><td><input type="checkbox" data-key="'+esc(k)+'" '+(selectedRecs.has(k)?'checked':'')+' onchange="toggleRec(this.dataset.key,this.checked)"></td><td class="money">'+money(o._savings)+'</td><td>'+esc(o.currency)+'</td><td>'+esc(o.impact)+'</td><td>'+esc(o.shortDescription)+'</td><td>'+esc(o.subscription)+'</td><td>'+esc(o.resourceId)+'</td></tr>'}}).join(''); return h+'</tbody></table>'+(rows.length>500?'<p class="small">Showing first 500 filtered recommendations. See CSV for full data.</p>':'')+'</div>'}}
function cleanupSection(){{return DATA.findings.length ? table('Rule-based cleanup findings', DATA.findings, ['severity','finding','recommendation','subscription','resource','type','resourceGroup','lastDaysCost','resourceId']) : '<div class="card"><h2>Rule-based cleanup findings</h2><p>No obvious abandoned-resource findings were detected. This is separate from Advisor recommendations and high-spend optimization.</p></div>'}}
function initSubFilter(){{let sel=document.getElementById('subFilter'); sel.innerHTML='<option value="">All subscriptions</option>'+DATA.summary.subscriptions.map(s=>'<option value="'+esc(s.id)+'">'+esc(s.name)+' — '+esc(s.id)+'</option>').join('')}}
function render(){{document.getElementById('app').innerHTML = summaryCards() + subscriptionBreakdown() + top5Spend() + advisorTable() + cleanupSection() + table('Top resources by cost', DATA.costByResource.slice().sort((a,b)=>Number(b.Cost||0)-Number(a.Cost||0)), ['Cost','ResourceId','ResourceType','ServiceName','ResourceGroupName','subscription']) + table('Cost by service', DATA.costByService.slice().sort((a,b)=>Number(b.Cost||0)-Number(a.Cost||0)), ['Cost','ServiceName','subscription']) + table('All resources', DATA.resources, ['cost','subscription','name','type','resourceGroup','location','id']);}}
initSubFilter(); render();</script></body></html>'''
with open(os.path.join(root,'index.html'),'w') as f: f.write(html_doc)
PY
}

select_subs

jq -c '.[]' "$SESSION_DIR/selected-subscriptions.json" | while IFS= read -r sub; do
  sub_id="$(jq -r '.id' <<<"$sub")"
  sub_name="$(jq -r '.name' <<<"$sub")"
  # Use printf, not echo: echo adds a newline, and tr would turn that newline into
  # a trailing '-' directory name. The report builder expects the exact same safe
  # directory format, so a trailing '-' makes index.html show zero data.
  safe_name="sub-$(printf '%s' "$sub_id" | tr -c 'A-Za-z0-9' '-')"
  collect_subscription "$sub_id" "$sub_name" "$safe_name"
done

make_report

say "Creating ZIP archive"
if command -v zip >/dev/null 2>&1; then
  (cd "$OUT_BASE" && zip -qr "azure-cost-inventory-$TS.zip" "session-$TS")
  ZIP_PATH="$OUT_BASE/azure-cost-inventory-$TS.zip"
else
  python3 - "$SESSION_DIR" "$OUT_BASE/azure-cost-inventory-$TS.zip" <<'PY'
import os, sys, zipfile
root, out=sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
  for base, _, files in os.walk(root):
    for f in files:
      p=os.path.join(base,f); z.write(p, os.path.relpath(p, os.path.dirname(root)))
PY
  ZIP_PATH="$OUT_BASE/azure-cost-inventory-$TS.zip"
fi

say "DONE"
echo "Report folder: $SESSION_DIR"
echo "Open HTML report: $SESSION_DIR/index.html"
echo "ZIP archive: $ZIP_PATH"
echo
cat <<EOF
Next step:
1. Download/open index.html from the report folder.
2. Send me summary.json, cost-savings-findings.csv, advisor-cost-recommendations.csv, and all-cost-by-resource.csv if you want me to interpret the results and produce a prioritized cleanup plan.
3. Do not delete anything solely from this report; validate owner, backups, dependencies, and business criticality first.
EOF


