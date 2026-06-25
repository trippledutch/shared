# Optimize-VMPlacement

`v0.9` · Windows PowerShell 5.1 / PowerShell 7+ · **read-only unless `-Balance`**

Analyses, and optionally rebalances, VM placement on a Hyper-V failover cluster:

1. **CSV-owner alignment** — does each VM run on the node that owns the CSV holding most of its disk data?
2. **Split disks** — are a VM's disks spread across multiple CSVs?
3. **Identical-function spread** — are same-role VMs spread across nodes (site-aware)?

Remediation prefers moving **CSV ownership** (near-instant, non-disruptive) over moving VMs.

Built on Darryl van der Peijl's original "align VMs with storage" idea
(<https://www.darrylvanderpeijl.com/align-vms-with-storage/>), extended with
CSV-ownership-first remediation, site-aware role spread, spread-aware off-VM
migration, and a measured before/after. Write-up:
<https://cldlbs.com/blog/aligning-vms-with-storage.html>

## Quick start

```powershell
# Analysis only (read-only). Run bare to also see the parameter options.
.\Optimize-VMPlacement.ps1

# Named cluster with site-aware spread
.\Optimize-VMPlacement.ps1 -ClusterName HVCLUSTER -Sites @{ 'A'='hv01','hv02','hv03'; 'B'='hv04','hv05','hv06' }

# Preview every change without touching the cluster (always do this first)
.\Optimize-VMPlacement.ps1 -Balance -WhatIf

# Apply
.\Optimize-VMPlacement.ps1 -Balance
```

Run from a cluster node or a management host with the FailoverClusters and Hyper-V modules and WinRM to the nodes. `-Balance` needs Cluster Full Control; data collection needs local admin on the nodes.

## What it does

### Analysis (always, read-only)
- Maps each VHD to its CSV (strict mount-prefix match), sizes it with `Get-VHD`, picks each VM's **primary CSV** (most bytes), and compares its owner with the node the VM runs on.
- Reports VMs whose disks span multiple CSVs.
- Checks identical-function spread **per site**: a role is *spreadable* when its member count is at most the usable node count of its site(s); a larger group is a *pool* and is reported with its imbalance (not force-spread).
- Lists excluded and non-clustered VMs so nothing is silently dropped.

### Remediation (`-Balance`, honours `-WhatIf`)
- **Phase A — CSV-ownership rebalancing (primary).** For each CSV, move ownership (`Move-ClusterSharedVolume`) to the node already hosting most of its VMs. Re-aligns many VMs at once with **no VM moves** and no change to VM/memory distribution. Disable with `-VMMovesOnly`.
- **Phase B — VM moves (remainder).** Running misaligned VMs are Live Migrated to their CSV owner. Powered-off VMs are quick-migrated (offline cluster move, no downtime) **only where it does not worsen role spread**; otherwise they are held and align by themselves on a later run. A running `-NoLiveMigration` VM is reported as needing a manual shutdown. **The script never powers a VM off.**
- **Phase C — Anti-affinity (idempotent).** Sets a shared `AntiAffinityClassNames` per spreadable role group, only where it is missing.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-ClusterName` | local cluster | Cluster to analyse. |
| `-Sites` | `@{}` (one site) | `site -> node names` for site-aware spread. |
| `-NoLiveMigration` | `@()` | VMs only movable while Off; never powered off by the script. |
| `-ExcludeVMs` | `@()` | Never moved, but still listed in the report. |
| `-RoleGroups` | `@{}` | Explicit role grouping, e.g. `@{ 'DC' = 'DC*','*-DC' }`. |
| `-VMMovesOnly` | off | Skip Phase A; use VM moves only. |
| `-OutputDir` | `C:\Temp` | Folder for the `.txt`, `.csv`, `.html` output. |
| `-Html` | off | Also write a graphical HTML report. |
| `-Balance` | off | Apply the remediation (combine with `-WhatIf`). |
| `-WhatIf` | — | Preview all ownership/VM/anti-affinity changes. |

## Output

A **PRE** and **POST (projected)** situation per node (VM count, assigned memory, **Aligned** and **Misaligned** columns, role collisions) as ASCII bars, with an intermediate "after CSV-ownership" figure, the remediation plan, an execution summary, and recommendations. Files in `-OutputDir`: `<cluster>_VMPlacement_<ts>.txt` (UTF-8 BOM), `.csv` (per-VM model), and `.html` (with `-Html`).

**Colour coding** (readable on a dark console): **white** = info, **green** = aligned / OK / non-disruptive win, **red** = only what needs action. Red is kept narrow so the picture is not worse than it is:
- A **powered-off VM does not count as misaligned** — it can be quick-migrated risk-free, so it is shown on its own neutral line. Only running misaligned VMs are red.
- A **pool already at its best balance (imbalance 0) is green** — there is nothing to act on.

## Why CSV-ownership before VM moves

When VM placement and CSV ownership have drifted apart, moving every VM to its storage concentrates load on the owner nodes and can worsen role spread, while on SAN-backed clusters (direct I/O per node) the alignment payoff is smaller than on Storage Spaces Direct. Moving CSV ownership to where the VMs already run aligns them near-instantly, non-disruptively, and keeps the VM and memory distribution intact.

## Changelog (recent)

- **v0.9** — header prints the configured sites.
- **v0.8** — off-VM quick-migration is spread-aware (held when it would add a collision).
- **v0.7** — off VMs are quick-migrated to their CSV owner under `-Balance`; anti-affinity is idempotent; bare run prints parameter options; full Aligned/Misaligned columns.
- **v0.6** — off VMs no longer counted as misaligned; balanced pools are green, not red.
- **v0.5** — white/green/red colour scheme.
- **v0.3** — CSV-ownership-first remediation; site-aware role spread.

## Safety

Read-only during analysis. The script never sets a VM off, never reboots a guest, and changes nothing unless `-Balance` is supplied. Always run `-Balance -WhatIf` first.

## Licence

MIT, see [LICENSE](LICENSE). Credit to Darryl van der Peijl for the original idea.
