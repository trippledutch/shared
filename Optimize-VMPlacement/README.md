# Optimize-VMPlacement

A read-only-by-default placement balancer for Windows Server Hyper-V failover
clusters. It aligns each VM with the node that owns its Cluster Shared Volume,
checks the site-aware spread of identical-function VMs, and, with `-Balance`,
remediates by moving CSV ownership first and VMs only as the remainder. It
never powers a VM off.

Built on Darryl van der Peijl's original "align VMs with storage" idea
(<https://www.darrylvanderpeijl.com/align-vms-with-storage/>), extended with
CSV-ownership-first remediation, site-aware role spread, and a measured
before/after. Full write-up:
<https://cldlbs.com/blog/aligning-vms-with-storage.html>

## What it does

- **CSV-owner alignment.** Maps each VHD to its CSV and compares the primary
  CSV's owner with the node the VM runs on.
- **Site-aware role spread.** Groups VMs by function and checks the spread per
  site, so site-bound pools (for example RDP hosts) are not mislabelled.
- **Remediation in three phases** (with `-Balance`, honours `-WhatIf`):
  - A. Move CSV ownership to where each CSV's VMs already run.
  - B. Live Migrate the running remainder. Powered-off VMs are named but
    skipped; a running no-LM VM is reported for manual shutdown.
  - C. Set anti-affinity on spreadable role groups.
- **Output.** A per-node PRE/POST view as ASCII bars, plus `.txt` and `.csv`
  (and `.html` with `-Html`).

## Usage

Analysis only (read-only, safe at any time):

```powershell
.\Optimize-VMPlacement.ps1 -ClusterName CLUSTER01
```

Preview the remediation without touching the cluster (run this first):

```powershell
.\Optimize-VMPlacement.ps1 -ClusterName CLUSTER01 -Balance -WhatIf
```

Apply:

```powershell
.\Optimize-VMPlacement.ps1 -ClusterName CLUSTER01 -Balance
```

Site-aware spread needs a site-to-node map:

```powershell
.\Optimize-VMPlacement.ps1 -ClusterName CLUSTER01 `
    -Sites @{ 'SiteA' = @('hv-a1','hv-a2'); 'SiteB' = @('hv-b1','hv-b2') }
```

## Requirements

Windows PowerShell 5.1 or PowerShell 7+, the FailoverClusters and Hyper-V
modules, WinRM and local admin on the nodes, and Cluster Full Control for
`-Balance`. Run from a management host that can reach every node.

## Safety

The analysis is read-only. Remediation only runs with `-Balance`, and you are
expected to preview with `-WhatIf` first. The script never powers a VM off.

## Licence

MIT, see [LICENSE](LICENSE). Credit to Darryl van der Peijl for the original
idea.
