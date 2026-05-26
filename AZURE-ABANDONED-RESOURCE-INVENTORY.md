# Azure Abandoned Resource Inventory

Read-only Azure Cloud Shell tooling to inventory Azure resources and flag likely abandoned/orphaned items.

This is intentionally conservative: it creates evidence and review reports only. It does not delete, stop, resize, or modify Azure resources.

## What it finds

The script inventories resources across selected subscriptions and produces cleanup-candidate rows for common issues:

- Unattached managed disks
- Unattached network interfaces
- Unassociated public IP addresses
- Snapshots older than the configured age threshold
- Stopped/deallocated VMs where Resource Graph exposes power state
- Resources missing owner or environment tags
- Azure Advisor cost recommendations, where permissions allow

## Interactive subscription workflow

When you run the script it polls Azure for the subscriptions your account can see, then displays a numbered menu. It refreshes that subscription list each time the menu is displayed, so after each run you can immediately pick another subscription, run all subscriptions, or quit.

You can choose:

- `0` — all enabled subscriptions
- `1` — one subscription by number
- `1,3,4` — multiple subscriptions by number
- `r` — refresh/poll subscriptions again
- `q` — quit

After you choose, the script shows the selected subscription(s) and lets you:

- press Enter to run
- type `b` to back up to the menu
- type `r` to refresh subscriptions
- type `q` to quit

After each inventory run, it returns to the menu so you can run another subscription or run all subscriptions without restarting the script.

## Output files

Each script session creates a timestamped directory under `azure-abandoned-inventory-output/`.

Each selection you run creates its own subdirectory, for example:

- `sub-Production-1234abcd-142500/`
- `sub-DevTest-abcd1234-143100/`
- `multi-3-subscriptions-1234abcd-abcd1234-9876fedc-144000/`

Each run directory contains:

- `azure-inventory.csv` — broad inventory
- `resources.json` — raw inventory JSON
- `cleanup-candidates.csv` — start here for review
- `cleanup-candidates.json` — raw candidate JSON
- `advisor-cost-recommendations.json` — Azure Advisor cost recommendations
- `summary.txt` — terminal-friendly summary
- `index.html` — simple local HTML summary

## Run from Azure Cloud Shell

```bash
curl -L -o azure-abandoned-inventory.sh https://raw.githubusercontent.com/bim75/AICodeWork/main/azure-abandoned-inventory.sh
chmod +x azure-abandoned-inventory.sh
./azure-abandoned-inventory.sh
```

## Optional settings

```bash
# Change old snapshot threshold from the default 90 days
DAYS_OLD=180 ./azure-abandoned-inventory.sh

# Change output directory
OUT_DIR=./my-azure-report ./azure-abandoned-inventory.sh

# Show full az commands while progress spinners run
VERBOSE_COMMANDS=1 ./azure-abandoned-inventory.sh
```

## Progress and Azure CLI extension handling

The script now prints `START`, `WORKING`, `OK`, and `ERROR` lines with elapsed seconds around slow Azure calls, including subscription polling, Resource Graph queries, and Advisor lookups.

It also configures Azure CLI extension installation to be non-interactive and pre-installs the `resource-graph` extension if needed. This prevents the Azure CLI preview-extension warning from sitting at a hidden prompt.

If you already started an older copy and it appears stuck after this warning:

```text
WARNING: Preview version of extension is disabled by default...
```

Press `Ctrl-C`, download the latest script again, and rerun it:

```bash
curl -L -o azure-abandoned-inventory.sh https://raw.githubusercontent.com/bim75/AICodeWork/main/azure-abandoned-inventory.sh
chmod +x azure-abandoned-inventory.sh
./azure-abandoned-inventory.sh
```

## Recommended review process

1. Open `cleanup-candidates.csv`.
2. Sort by `severity`, then `reason`.
3. Fix missing tags first: owner, environment, cost center, keep/delete date.
4. For obvious orphaned objects, tag them before deletion, for example:
   - `cleanup-candidate=true`
   - `cleanup-reviewed-by=<name>`
   - `cleanup-review-date=<date>`
   - `cleanup-action-after=<date>`
5. Wait 7–30 days if there is any uncertainty.
6. Delete only after owner confirmation and backup/snapshot/export where appropriate.

## Important limitations

“Unused” is not always directly knowable from Azure inventory alone.

For stronger evidence, enable and retain:

- Azure Monitor metrics
- Diagnostic settings
- NSG flow logs / Traffic Analytics
- Storage account blob inventory
- Activity Logs exported to Log Analytics
- Cost Management exports

Some resource types, such as Key Vaults, private DNS zones, route tables, managed identities, backup vaults, and Log Analytics workspaces, need human review because they can be dependencies even when they look quiet.

## Safety

This script is read-only. It uses Azure Resource Graph, Azure Advisor, and local report generation.
