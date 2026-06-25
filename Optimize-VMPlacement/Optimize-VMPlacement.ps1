[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Cluster to analyse. Defaults to the local cluster when run on a node.
    [string]$ClusterName = (Get-Cluster -ErrorAction SilentlyContinue).Name,

    # Site -> node mapping for the site-aware spread check. Empty = one site.
    # Example: @{ 'SiteA' = 'hv01','hv02'; 'SiteB' = 'hv03','hv04' }
    [hashtable]$Sites = @{},

    # VMs that cannot Live Migrate: only moved while Off, never powered off.
    [string[]]$NoLiveMigration = @(),

    # VMs never moved, but still listed in the report.
    [string[]]$ExcludeVMs = @(),

    # Explicit role grouping: @{ 'DomainController' = 'DC*','*-DC' }.
    [hashtable]$RoleGroups = @{},

    [string]$OutputDir = 'C:\Temp',

    [switch]$VMMovesOnly,   # skip Phase A (CSV-ownership); VM moves only
    [switch]$Html,          # also write a graphical HTML report
    [switch]$Balance,       # apply remediation (honours -WhatIf)

    [int]$SleepBetweenMigrationsSeconds = 30
)

<#
.SYNOPSIS
    Analyses - and optionally rebalances - VM placement on a Hyper-V
    failover cluster: CSV-owner alignment, disks split across CSVs, and the
    site-aware spread of identical-function VMs. Remediation prefers moving
    CSV OWNERSHIP (near-instant) over moving VMs. Read-only unless -Balance.

.DESCRIPTION
    PART 1 - ANALYSIS (always, read-only)
      1. CSV-owner alignment: each VHD is mapped to its CSV (strict mount
         prefix match), sized with Get-VHD FileSize; the PRIMARY CSV (most
         bytes) and its owner node are compared with the node the VM runs on.
      2. Split disks: VMs whose disks span multiple CSVs are reported.
      3. Identical-function spread: VMs are grouped by role key; the spread
         is checked PER SITE (a role's members can only realistically run on
         the nodes of the site(s) they belong to). A role is 'spreadable'
         when its member count <= the usable node count of those sites; a
         larger group is a 'pool' and is reported with its imbalance.
      4. Excluded / out-of-scope VMs (e.g. -ExcludeVMs, non-clustered VMs)
         are LISTED so nothing is silently dropped, but are never moved.

    PART 2 - REMEDIATION (-Balance only; honours -WhatIf)
      Phase A - CSV-ownership rebalancing (primary, low-disruption):
        For each CSV the script finds the node where most of that CSV's VMs
        already run and, if that is not the current owner, moves the CSV
        ownership there (Move-ClusterSharedVolume). This re-aligns many VMs
        at once WITHOUT moving a single VM, and does not change the VM count
        or memory per node. Skipped with -VMMovesOnly.
      Phase B - VM moves (fallback for the remainder):
        VMs still misaligned after Phase A are moved to their CSV owner.
        Live Migration when supported; offline ownership move when the VM is
        Off; a running -NoLiveMigration VM is reported as 'needs manual
        shutdown'. THE SCRIPT NEVER POWERS A VM OFF.
      Phase C - Anti-affinity:
        For every spreadable role group a shared AntiAffinityClassNames is
        set so the cluster keeps the members apart on future placement.

    OUTPUT
      A PRE and a POST situation per node (VM count, assigned memory,
      aligned/misaligned, role collisions) as ASCII bars, with an
      intermediate 'after CSV-ownership' alignment figure. Files in
      -OutputDir: .txt (full report, UTF-8 BOM), .csv (per-VM model),
      and .html (graphical, with -Html).

.PARAMETER ClusterName       Cluster to analyse. Defaults to the local cluster.
.PARAMETER Sites             Hashtable site -> node names (site-aware spread). Empty = one site.
.PARAMETER NoLiveMigration   VMs only movable while Off; never powered off.
.PARAMETER ExcludeVMs        VMs never moved, but still listed in the report.
.PARAMETER RoleGroups        Explicit role -> name-pattern(s) grouping.
.PARAMETER VMMovesOnly       Skip CSV-ownership rebalancing (Phase A).
.PARAMETER Balance           Apply the remediation. Combine with -WhatIf.
.PARAMETER Html              Also emit a graphical HTML report.
.PARAMETER WhatIf            Preview all moves/ownership/anti-affinity changes.

.EXAMPLE
    .\Optimize-VMPlacement.ps1
    Analysis only; prints findings and the projected Post situation.

.EXAMPLE
    .\Optimize-VMPlacement.ps1 -ClusterName HVCLUSTER -Sites @{ 'A'='hv01','hv02'; 'B'='hv03','hv04' }
    Site-aware analysis of a named cluster.

.EXAMPLE
    .\Optimize-VMPlacement.ps1 -Balance -WhatIf
    Shows the CSV-ownership moves, the remaining VM moves and the
    anti-affinity changes, without touching the cluster. Run this first.

.NOTES
    Script Name : Optimize-VMPlacement.ps1
    Author      : Hans Vredevoort - CloudLabs
    Version     : 0.9
    Run from    : a cluster node or a management host with the FailoverClusters
                  and Hyper-V modules and WinRM to the nodes.
    Requires    : Windows PowerShell 5.1 or PowerShell 7+
                  Cluster Full Control (only for -Balance)
                  Local admin on the nodes (Get-VM / Get-VHD remoting)
    Read-only   : YES, unless -Balance is supplied.

.CHANGELOG
    v0.9 (25 June 2026)
      - Header now prints the configured -Sites (site -> node mapping) so the
        site-aware analysis is transparent about which nodes belong to which site.
    v0.8 (25 June 2026)
      - Off-VM quick-migration is now SPREAD-AWARE: a powered-off VM is moved to
        its CSV owner only when the move does not worsen its role spread (an off
        VM gains nothing from alignment until it runs, so resilience is never
        traded for it). The decision is greedy, so several off VMs of one role
        split across nodes instead of re-colliding on the target. VMs that would
        add a collision are HELD (OffHeld) and align by themselves on a later run.
    v0.7 (25 June 2026)
      - Powered-off, misaligned VMs are now QUICK-MIGRATED to their CSV owner
        under -Balance (offline cluster move, no downtime, no Live Migration)
        instead of being skipped. POST and the execution summary count them as
        aligned (OffMigrated), so the off-VM figure goes to 0.
      - Anti-affinity is now IDEMPOTENT: the current AntiAffinityClassNames is
        read first and the class is only SET where missing. A second run reports
        'already set' instead of re-applying it on every member.
      - RECOMMENDATIONS Phase A line reads correctly when 0 CSV moves are needed
        ('already optimal') instead of 'apply the 0 move(s)'.
      - Running the script with NO parameters prints a parameter-options summary.
      - PRE/POST shows 'Aligned' and 'Misaligned' as two full-title columns.
    v0.6 (20 June 2026)
      - Powered-off VMs no longer count as 'Misaligned'. They split into a
        separate, neutral 'Off, alignable risk-free' line (an off VM can be
        quick/storage-migrated to its CSV owner with no downtime, so it is not
        a live risk). Running misaligned VMs are the only ones flagged red.
      - Per-node PRE/POST rows go red only on RUNNING misaligned VMs.
      - Role spread: a pool already at its best balance (imbalance 0) is now
        Green, not Red - there is nothing to act on. Red is reserved for
        spreadable collisions and pools off their balance.
    v0.5 (18 June 2026)
      - Console/log colours reduced to White (info), Green (aligned / OK /
        non-disruptive win / apply commands) and Red (misaligned /
        collisions / moves needing attention / failures) for readability on
        a blue or black console.
      - Recommendations now NAME the skipped powered-off VMs.
      - Excluded VMs are labelled 'Planned exclusion' in the out-of-scope
        list (instead of 'in -ExcludeVMs').
    v0.4 (18 June 2026)
      - CHANGED Phase B: powered-off VMs are now NAMED but SKIPPED (their
        alignment only matters when running); only running VMs are moved.
      - NEW: the log ends with a RECOMMENDATIONS block plus the exact
        -WhatIf preview and -Balance apply commands.
    v0.3 (18 June 2026)
      - NEW remediation strategy: Phase A rebalances CSV OWNERSHIP
        (Move-ClusterSharedVolume) to where each CSV's VMs already run,
        re-aligning many VMs with no VM moves; VM moves (Phase B) handle
        only the remainder. -VMMovesOnly forces the old VM-only behaviour.
      - CHANGED role spread to be SITE-AWARE: the spreadable threshold and
        anti-affinity now use the usable node count of the role's site(s),
        not the whole cluster, so site-bound pools (e.g. RDP/TS) are no
        longer flagged as fully spreadable.
      - NEW: excluded and non-clustered (out-of-scope) VMs are listed in the
        report instead of being silently dropped.
    v0.2 (18 June 2026)
      - Lint fixes; expanded help.
    v0.1 (18 June 2026)
      - Initial release.
#>

# ----- Encoding + output -----
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $ClusterName) { throw "No cluster found. Run on a cluster node or pass -ClusterName." }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$filePrefix = ($ClusterName -replace '[^A-Za-z0-9._-]', '_')
$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
$logFile   = Join-Path $OutputDir ("{0}_VMPlacement_{1}.txt"  -f $filePrefix, $timestamp)
$htmlFile  = Join-Path $OutputDir ("{0}_VMPlacement_{1}.html" -f $filePrefix, $timestamp)
$csvFile   = Join-Path $OutputDir ("{0}_VMPlacement_{1}.csv"  -f $filePrefix, $timestamp)

$script:sb = New-Object System.Text.StringBuilder
function Write-Log {
    param([AllowEmptyString()][string]$Message = '', [ConsoleColor]$Color = 'White')
    [void]$script:sb.AppendLine($Message)
    Write-Host $Message -ForegroundColor $Color
}
function Get-Bar {
    param([double]$Value, [double]$Max, [int]$Width = 24)
    if ($Max -le 0) { return '' }
    $n = [int][math]::Round(($Value / $Max) * $Width)
    if ($n -lt 0) { $n = 0 } ; if ($n -gt $Width) { $n = $Width }
    return ('#' * $n)
}
function Get-RoleKey {
    param([string]$Name)
    foreach ($role in $RoleGroups.Keys) {
        foreach ($pat in @($RoleGroups[$role])) { if ($Name -like $pat) { return $role } }
    }
    $n = $Name
    $n = $n -replace '(?i)\s*-\s*off\s*$', ''
    $n = $n -replace '\s*\(\d+\)\s*$', ''
    $n = $n -replace '[\s_-]*\d+\s*$', ''
    $n = $n.Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $Name }
    return $n
}

Write-Log ("Optimize-VMPlacement v0.9") -Color White
Write-Log ("Run at {0} on {1}" -f (Get-Date), $env:COMPUTERNAME) -Color White
Write-Log ("Cluster         : {0}" -f $ClusterName) -Color White
Write-Log ("Mode            : {0}" -f $(if ($Balance) { 'BALANCE (remediation)' } else { 'ANALYSIS ONLY (read-only)' })) -Color White
Write-Log ("CSV-owner phase : {0}" -f $(if ($VMMovesOnly) { 'OFF (-VMMovesOnly)' } else { 'ON (primary)' })) -Color White
$siteKeys = @($Sites.Keys | Sort-Object)
for ($si = 0; $si -lt $siteKeys.Count; $si++) {
    $lbl = if ($si -eq 0) { 'Sites           : ' } else { '                  ' }
    Write-Log ("{0}{1,-12}{2}" -f $lbl, $siteKeys[$si], ($Sites[$siteKeys[$si]] -join ', ')) -Color White
}
Write-Log ("No-LiveMigration: {0}" -f ($NoLiveMigration -join ', ')) -Color White
Write-Log ("Excluded        : {0}" -f ($ExcludeVMs -join ', ')) -Color White
if ($PSBoundParameters.Count -eq 0) {
    Write-Log ''
    Write-Log '--- Parameter options (running bare = analysis only; add -Balance to act) ---' -Color White
    Write-Log ("  -ClusterName <name>       cluster to analyse                 (default: {0})" -f $ClusterName)
    Write-Log ("  -ExcludeVMs <names>       never moved, still reported        (default: {0})" -f ($ExcludeVMs -join ', '))
    Write-Log ("  -NoLiveMigration <names>  only moved while off                (default: {0})" -f ($NoLiveMigration -join ', '))
    Write-Log  "  -Sites <hashtable>        site -> node mapping (site-aware spread)"
    Write-Log  "  -RoleGroups <hashtable>   explicit role grouping override"
    Write-Log  "  -VMMovesOnly              skip Phase A (CSV-ownership); use VM moves only"
    Write-Log ("  -OutputDir <path>         .txt/.csv/.html output folder       (default: {0})" -f $OutputDir)
    Write-Log  "  -Html                     also write a graphical HTML report"
    Write-Log  "  -Balance                  APPLY remediation (combine with -WhatIf to preview)"
    Write-Log  "  -WhatIf                   preview every change without touching the cluster"
}
Write-Log ''

# ----- Node + site model -----
$nodeSite = @{}
foreach ($s in $Sites.Keys) { foreach ($n in $Sites[$s]) { $nodeSite[$n.ToLowerInvariant()] = $s } }
$nodeMeta = [ordered]@{}
foreach ($cn in (Get-ClusterNode -Cluster $ClusterName | Sort-Object Name)) {
    $key = $cn.Name.ToLowerInvariant()
    $nodeMeta[$key] = [pscustomobject]@{
        Name   = $cn.Name
        Site   = $(if ($nodeSite.ContainsKey($key)) { $nodeSite[$key] } else { '(unmapped)' })
        State  = $cn.State.ToString()
        Drain  = $cn.DrainStatus.ToString()
        Usable = ($cn.State -eq 'Up' -and $cn.DrainStatus -eq 'NotInitiated')
    }
}
$nodeKeys = @($nodeMeta.Keys)
$usableNodeCount = @($nodeMeta.Values | Where-Object Usable).Count
# usable nodes per site
$siteUsable = @{}
foreach ($nk in $nodeKeys) {
    if (-not $nodeMeta[$nk].Usable) { continue }
    $s = $nodeMeta[$nk].Site
    $siteUsable[$s] = 1 + $(if ($siteUsable.ContainsKey($s)) { $siteUsable[$s] } else { 0 })
}

# ----- CSV snapshot (owner + mount with trailing backslash) -----
$csvTable = @()
foreach ($csv in (Get-ClusterSharedVolume -Cluster $ClusterName)) {
    foreach ($svi in $csv.SharedVolumeInfo) {
        $mount = $svi.FriendlyVolumeName
        if ($mount -and -not $mount.EndsWith('\')) { $mount += '\' }
        $csvTable += [pscustomobject]@{ CsvName = $csv.Name; OwnerNode = $csv.OwnerNode.Name.ToLowerInvariant(); MountPoint = $mount }
    }
}
function Get-CsvForPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    foreach ($c in $csvTable) {
        if ($Path.StartsWith($c.MountPoint, [System.StringComparison]::OrdinalIgnoreCase)) { return $c }
    }
    return $null
}
$csvOwnerNow = @{}
foreach ($c in $csvTable) { $csvOwnerNow[$c.CsvName] = $c.OwnerNode }

# ----- Clustered VM groups -----
$clusterVM = @{}
foreach ($g in (Get-ClusterGroup -Cluster $ClusterName | Where-Object GroupType -eq 'VirtualMachine')) {
    $clusterVM[$g.Name.ToLowerInvariant()] = $g.OwnerNode.Name.ToLowerInvariant()
}

# ----- Per-node VM + disk collection (one remote call per usable node) -----
Write-Log "Collecting VM and disk data per node..." -Color White
$rawVMs = foreach ($nk in ($nodeKeys | Where-Object { $nodeMeta[$_].Usable })) {
    $nodeName = $nodeMeta[$nk].Name
    Write-Host ("  [{0}] reading VMs + VHD sizes..." -f $nodeName.ToUpper()) -ForegroundColor White
    Invoke-Command -ComputerName $nodeName -ErrorAction SilentlyContinue -ScriptBlock {
        foreach ($vm in Get-VM) {
            $disks = foreach ($hd in @($vm.HardDrives)) {
                if ([string]::IsNullOrWhiteSpace($hd.Path)) { continue }
                $size = 0L
                try { $size = [int64](Get-VHD -Path $hd.Path -ErrorAction Stop).FileSize } catch { $size = 0L }
                [pscustomobject]@{ Path = $hd.Path; Bytes = $size }
            }
            [pscustomobject]@{
                Name = $vm.Name; Host = $env:COMPUTERNAME; State = $vm.State.ToString()
                MemoryGB = [math]::Round(($vm.MemoryAssigned / 1GB), 1); Disks = @($disks)
            }
        }
    }
}

# ----- Build the full VM model (incl. excluded + non-clustered, flagged) -----
$model = foreach ($r in $rawVMs) {
    $nameKey = $r.Name.ToLowerInvariant()
    $isClustered = $clusterVM.ContainsKey($nameKey)
    $isExcluded  = ($ExcludeVMs -contains $r.Name)
    $owner = $(if ($isClustered) { $clusterVM[$nameKey] } else { $r.Host.ToLowerInvariant() })

    $perCsv = @{}; $unmatched = 0
    foreach ($d in @($r.Disks)) {
        $hit = Get-CsvForPath -Path $d.Path
        if ($hit) {
            if (-not $perCsv.ContainsKey($hit.CsvName)) { $perCsv[$hit.CsvName] = [pscustomobject]@{ Bytes = 0L; Owner = $hit.OwnerNode } }
            $perCsv[$hit.CsvName].Bytes += [int64]$d.Bytes
        } else { $unmatched++ }
    }
    $distinctCsvs = @($perCsv.Keys)
    $primaryCsv = $null; $primaryOwner = $null; $primaryBytes = -1
    foreach ($cn in $distinctCsvs) {
        if ($perCsv[$cn].Bytes -gt $primaryBytes) { $primaryBytes = $perCsv[$cn].Bytes; $primaryCsv = $cn; $primaryOwner = $perCsv[$cn].Owner }
    }
    if ($primaryBytes -le 0 -and $distinctCsvs.Count -gt 0) {
        $countPerCsv = @{}
        foreach ($d in @($r.Disks)) { $hit = Get-CsvForPath -Path $d.Path; if ($hit) { $countPerCsv[$hit.CsvName] = 1 + $(if ($countPerCsv.ContainsKey($hit.CsvName)) { $countPerCsv[$hit.CsvName] } else { 0 }) } }
        $best = ($countPerCsv.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        if ($best) { $primaryCsv = $best.Key; $primaryOwner = $perCsv[$best.Key].Owner }
    }

    [pscustomobject]@{
        Name = $r.Name; Clustered = $isClustered; Excluded = $isExcluded
        InScope = ($isClustered -and -not $isExcluded)
        OwnerNode = $owner
        Site = $(if ($nodeSite.ContainsKey($owner)) { $nodeSite[$owner] } else { '(unmapped)' })
        State = $r.State; MemoryGB = $r.MemoryGB; RoleKey = (Get-RoleKey -Name $r.Name)
        DiskCsvs = $distinctCsvs
        CsvBreakdown = ($distinctCsvs | ForEach-Object { "{0}={1}GB" -f $_, [math]::Round($perCsv[$_].Bytes / 1GB, 1) }) -join '; '
        SplitCsv = ($distinctCsvs.Count -gt 1); UnmatchedDisks = $unmatched
        PrimaryCsv = $primaryCsv; PrimaryOwner = $primaryOwner
        Aligned = ($null -ne $primaryOwner -and $owner -eq $primaryOwner)
        NoLM = ($NoLiveMigration -contains $r.Name)
        PostPrimaryOwner = $primaryOwner   # updated after Phase A
    }
}
$model    = @($model)
$inScope  = @($model | Where-Object InScope)
$outScope = @($model | Where-Object { -not $_.InScope })

# =====================================================================
# PHASE A planning - CSV-ownership rebalancing
# =====================================================================
$csvVote = @{}
foreach ($vm in $inScope) {
    if (-not $vm.PrimaryCsv) { continue }
    if (-not $csvVote.ContainsKey($vm.PrimaryCsv)) { $csvVote[$vm.PrimaryCsv] = @{} }
    $csvVote[$vm.PrimaryCsv][$vm.OwnerNode] = 1 + $(if ($csvVote[$vm.PrimaryCsv].ContainsKey($vm.OwnerNode)) { $csvVote[$vm.PrimaryCsv][$vm.OwnerNode] } else { 0 })
}
$csvNewOwner = @{}
$csvOwnerPlan = @()
foreach ($csvName in ($csvOwnerNow.Keys | Sort-Object)) {
    $cur = $csvOwnerNow[$csvName]
    $votes = $(if ($csvVote.ContainsKey($csvName)) { $csvVote[$csvName] } else { @{} })
    $best = $cur
    $bestVotes = $(if ($votes.ContainsKey($cur)) { $votes[$cur] } else { 0 })
    foreach ($n in $votes.Keys) {
        if (-not ($nodeMeta.Contains($n) -and $nodeMeta[$n].Usable)) { continue }
        if ($votes[$n] -gt $bestVotes) { $best = $n; $bestVotes = $votes[$n] }
    }
    $csvNewOwner[$csvName] = $best
    if (-not $VMMovesOnly -and $best -ne $cur) {
        $curVotes = $(if ($votes.ContainsKey($cur)) { $votes[$cur] } else { 0 })
        $csvOwnerPlan += [pscustomobject]@{ Csv = $csvName; From = $cur; To = $best; AlignsNow = $curVotes; AlignsAfter = $bestVotes; Gain = ($bestVotes - $curVotes) }
    }
}
# When -VMMovesOnly, keep current owners (no ownership change)
if ($VMMovesOnly) { foreach ($k in @($csvNewOwner.Keys)) { $csvNewOwner[$k] = $csvOwnerNow[$k] } }

# Apply post-ownership to each in-scope VM
foreach ($vm in $inScope) {
    if ($vm.PrimaryCsv -and $csvNewOwner.ContainsKey($vm.PrimaryCsv)) { $vm.PostPrimaryOwner = $csvNewOwner[$vm.PrimaryCsv] }
}

# =====================================================================
# Distribution + site-aware role-spread helpers
# =====================================================================
function Get-Distribution {
    param([hashtable]$Placement, [hashtable]$AlignOwner)
    $dist = [ordered]@{}
    foreach ($nk in $nodeKeys) { $dist[$nk] = [pscustomobject]@{ VMs = 0; Running = 0; MemGB = 0.0; Aligned = 0; Misaligned = 0; MisalignedRunning = 0 } }
    foreach ($vm in $inScope) {
        $node = $(if ($Placement.ContainsKey($vm.Name)) { $Placement[$vm.Name] } else { $vm.OwnerNode })
        if (-not $dist.Contains($node)) { continue }
        $dist[$node].VMs++
        if ($vm.State -eq 'Running') { $dist[$node].Running++ }
        $dist[$node].MemGB += $vm.MemoryGB
        $owner = $(if ($AlignOwner.ContainsKey($vm.Name)) { $AlignOwner[$vm.Name] } else { $null })
        if ($null -ne $owner -and $node -eq $owner) {
            $dist[$node].Aligned++
        } else {
            $dist[$node].Misaligned++
            if ($vm.State -eq 'Running') { $dist[$node].MisalignedRunning++ }
        }
    }
    return $dist
}

function Get-RoleSpread {
    param([hashtable]$Placement)
    $byRole = @{}
    foreach ($vm in $inScope) {
        if (-not $byRole.ContainsKey($vm.RoleKey)) { $byRole[$vm.RoleKey] = @() }
        $byRole[$vm.RoleKey] += $vm.Name
    }
    $total = 0; $poolImb = 0; $detail = @()
    foreach ($role in ($byRole.Keys | Sort-Object)) {
        $members = @($byRole[$role])
        if ($members.Count -lt 2) { continue }
        $perNode = @{}; $sitesUsed = @{}
        foreach ($m in $members) {
            $nd = $(if ($Placement.ContainsKey($m)) { $Placement[$m] } else { ($inScope | Where-Object Name -eq $m).OwnerNode })
            $perNode[$nd] = 1 + $(if ($perNode.ContainsKey($nd)) { $perNode[$nd] } else { 0 })
            $st = $(if ($nodeMeta.Contains($nd)) { $nodeMeta[$nd].Site } else { '(unmapped)' })
            $sitesUsed[$st] = $true
        }
        $avail = 0
        foreach ($st in $sitesUsed.Keys) { $avail += $(if ($siteUsable.ContainsKey($st)) { $siteUsable[$st] } else { 0 }) }
        if ($avail -lt 1) { $avail = $usableNodeCount }
        $spreadable = ($members.Count -le $avail)
        $extras = 0
        foreach ($nd in $perNode.Keys) { if ($perNode[$nd] -gt 1) { $extras += ($perNode[$nd] - 1) } }
        $ceilT = [math]::Ceiling($members.Count / $avail)
        $imb = 0
        foreach ($nd in $perNode.Keys) { if ($perNode[$nd] -gt $ceilT) { $imb += ($perNode[$nd] - $ceilT) } }
        if ($spreadable) { $total += $extras } else { $poolImb += $imb }
        $detail += [pscustomobject]@{
            Role = $role; Count = $members.Count; Avail = $avail; Spreadable = $spreadable
            Collisions = $extras; Imbalance = $imb
            Layout = (($perNode.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}:{1}" -f $_.Key.ToUpper(), $_.Value }) -join '  ')
            Members = $members
        }
    }
    return [pscustomobject]@{ Total = $total; PoolImbalance = $poolImb; Detail = $detail }
}

function Get-RoleBadness {
    # Spread penalty for a role: collisions if spreadable, else pool imbalance.
    param([hashtable]$PerNode, [int]$MemberCount, [int]$Avail)
    if ($Avail -lt 1) { $Avail = 1 }
    if ($MemberCount -le $Avail) {
        $b = 0; foreach ($c in $PerNode.Values) { if ($c -gt 1) { $b += ($c - 1) } }
        return $b
    }
    $ceil = [math]::Ceiling($MemberCount / $Avail)
    $b = 0; foreach ($c in $PerNode.Values) { if ($c -gt $ceil) { $b += ($c - $ceil) } }
    return $b
}

# Alignment-owner maps
$preAlign  = @{}; foreach ($vm in $inScope) { $preAlign[$vm.Name]  = $vm.PrimaryOwner }
$postAlign = @{}; foreach ($vm in $inScope) { $postAlign[$vm.Name] = $vm.PostPrimaryOwner }
$prePlacement = @{}; foreach ($vm in $inScope) { $prePlacement[$vm.Name] = $vm.OwnerNode }

# =====================================================================
# PART 1 - ANALYSIS
# =====================================================================
Write-Log ''
Write-Log '########## ANALYSIS ##########' -Color White
$alignedNow   = @($inScope | Where-Object Aligned).Count
$alignedPhaseA = @($inScope | Where-Object { $null -ne $_.PostPrimaryOwner -and $_.OwnerNode -eq $_.PostPrimaryOwner }).Count
$misaligned    = @($inScope | Where-Object { -not $_.Aligned -and $null -ne $_.PrimaryOwner })
# A powered-off VM is not a live risk: it can be quick/storage-migrated to its CSV
# owner with no downtime. So it does NOT count as "misaligned" - only running VMs do.
$misalignedRun = @($misaligned | Where-Object { $_.State -eq 'Running' })
$misalignedOff = @($misaligned | Where-Object { $_.State -ne 'Running' })
$split        = @($inScope | Where-Object SplitCsv)
$noCsv        = @($inScope | Where-Object { $null -eq $_.PrimaryOwner })

Write-Log ''
Write-Log "--- CSV alignment (VM runs on the owner of its primary CSV) ---" -Color White
Write-Log ("In-scope clustered VMs       : {0}" -f $inScope.Count)
Write-Log ("Aligned now                  : {0}" -f $alignedNow) -Color Green
Write-Log ("Aligned after CSV-owner phase : {0}  (no VM moves)" -f $alignedPhaseA) -Color Green
$runCol = if ($misalignedRun.Count -gt 0) { 'Red' } else { 'Green' }
Write-Log ("Misaligned (running)         : {0}" -f $misalignedRun.Count) -Color $runCol
if ($misalignedOff.Count -gt 0) {
    Write-Log ("Off, alignable risk-free     : {0}  (quick-migrate when convenient)" -f $misalignedOff.Count) -Color White
}
Write-Log ("Disks split over CSVs        : {0}" -f $split.Count)
Write-Log ("No CSV match for disks       : {0}" -f $noCsv.Count)
Write-Log ''
if ($misalignedRun.Count -gt 0) {
    Write-Log "Misaligned and RUNNING (move to CSV owner):" -Color Red
    Write-Log ("{0,-26} {1,-9} {2,-9} {3,-12} {4}" -f 'VM', 'Runs on', 'CSV owner', 'PrimaryCSV', 'Note') -Color White
    foreach ($vm in ($misalignedRun | Sort-Object Name)) {
        $note = @()
        if ($vm.SplitCsv) { $note += ("split: " + $vm.CsvBreakdown) }
        if ($vm.NoLM)     { $note += 'no-LM' }
        Write-Log ("{0,-26} {1,-9} {2,-9} {3,-12} {4}" -f $vm.Name, $vm.OwnerNode.ToUpper(), $vm.PrimaryOwner.ToUpper(), $vm.PrimaryCsv, ($note -join '; ')) -Color Red
    }
    Write-Log ''
}
if ($misalignedOff.Count -gt 0) {
    Write-Log "Powered off, not yet aligned (quick-migrate risk-free; no downtime):" -Color White
    Write-Log ("{0,-26} {1,-9} {2,-9} {3,-12} {4}" -f 'VM', 'Runs on', 'CSV owner', 'PrimaryCSV', 'Note') -Color White
    foreach ($vm in ($misalignedOff | Sort-Object Name)) {
        $note = @('Off')
        if ($vm.SplitCsv) { $note += ("split: " + $vm.CsvBreakdown) }
        if ($vm.NoLM)     { $note += 'no-LM' }
        Write-Log ("{0,-26} {1,-9} {2,-9} {3,-12} {4}" -f $vm.Name, $vm.OwnerNode.ToUpper(), $vm.PrimaryOwner.ToUpper(), $vm.PrimaryCsv, ($note -join '; ')) -Color White
    }
}
if ($split.Count -gt 0) {
    Write-Log ''
    Write-Log "--- VMs with disks split across multiple CSVs (manual review) ---" -Color White
    foreach ($vm in ($split | Sort-Object Name)) { Write-Log ("{0,-26} {1}" -f $vm.Name, $vm.CsvBreakdown) }
}

$preColl = Get-RoleSpread -Placement $prePlacement
Write-Log ''
Write-Log "--- Identical-function VM distribution (site-aware role spread) ---" -Color White
Write-Log ("Role groups with >=2 members : {0}" -f @($preColl.Detail).Count)
Write-Log ("Spreadable collisions        : {0}" -f $preColl.Total)
Write-Log ("Pool imbalance (>site nodes)  : {0}" -f $preColl.PoolImbalance)
Write-Log ''
Write-Log ("{0,-22} {1,-5} {2,-5} {3,-10} {4}" -f 'Role', 'Cnt', 'Site', 'Collisions', 'Per-node layout') -Color White
foreach ($d in ($preColl.Detail | Sort-Object @{E={$_.Collisions};Descending=$true}, Role)) {
    # Red only when actionable: a spreadable collision, or a pool off its balance.
    $actionable = ($d.Spreadable -and $d.Collisions -gt 0) -or ((-not $d.Spreadable) -and $d.Imbalance -gt 0)
    $col = if ($actionable) { 'Red' } else { 'Green' }
    $tag = if (-not $d.Spreadable) { (" (pool > {0} site nodes, imbalance {1}{2})" -f $d.Avail, $d.Imbalance, $(if ($d.Imbalance -eq 0) { ' - optimal' } else { '' })) } else { '' }
    Write-Log ("{0,-22} {1,-5} {2,-5} {3,-10} {4}{5}" -f $d.Role, $d.Count, $d.Avail, $d.Collisions, $d.Layout, $tag) -Color $col
}

# Out-of-scope listing (nothing silently dropped)
if ($outScope.Count -gt 0) {
    Write-Log ''
    Write-Log "--- Excluded / out-of-scope VMs (listed, never moved) ---" -Color White
    Write-Log ("{0,-26} {1,-9} {2,-9} {3,-9} {4}" -f 'VM', 'Runs on', 'State', 'Aligned', 'Reason') -Color White
    foreach ($vm in ($outScope | Sort-Object Name)) {
        $reason = @()
        if ($vm.Excluded)       { $reason += 'Planned exclusion' }
        if (-not $vm.Clustered) { $reason += 'not clustered' }
        Write-Log ("{0,-26} {1,-9} {2,-9} {3,-9} {4}" -f $vm.Name, $vm.OwnerNode.ToUpper(), $vm.State, $vm.Aligned, ($reason -join '; '))
    }
}

# =====================================================================
# PART 2 - REMEDIATION PLAN
# =====================================================================
# Phase B: VMs still misaligned after the CSV-ownership phase.
$planVM = foreach ($vm in ($inScope | Where-Object { $null -ne $_.PostPrimaryOwner -and $_.OwnerNode -ne $_.PostPrimaryOwner } | Sort-Object Name)) {
    $target = $vm.PostPrimaryOwner
    $targetUsable = ($nodeMeta.Contains($target) -and $nodeMeta[$target].Usable)
    $method = $null; $note = ''
    if (-not $targetUsable) { $method = 'Skip'; $note = "target $($target.ToUpper()) not usable" }
    elseif ($vm.State -ne 'Running') { $method = 'OffCandidate'; $note = '' }
    elseif ($vm.NoLM) { $method = 'ManualShutdown'; $note = 'no-LM VM is running; power off manually, then re-run' }
    else { $method = 'Live' }
    [pscustomobject]@{ VM = $vm.Name; From = $vm.OwnerNode; To = $target; Method = $method; Split = $vm.SplitCsv; Note = $note }
}
$planVM = @($planVM)

# An off VM is quick-migrated to its CSV owner only when the move does not worsen its
# role spread (greedy against current owners + Live moves); otherwise it is held.
$roleInfo = @{}; foreach ($d in $preColl.Detail) { $roleInfo[$d.Role] = $d }
$vmRole   = @{}; foreach ($vm in $inScope) { $vmRole[$vm.Name] = $vm.RoleKey }
$proj     = @{}; foreach ($vm in $inScope) { $proj[$vm.Name] = $vm.OwnerNode }
foreach ($p in $planVM) { if ($p.Method -eq 'Live') { $proj[$p.VM] = $p.To } }
foreach ($p in ($planVM | Where-Object Method -eq 'OffCandidate' | Sort-Object VM)) {
    $info = $roleInfo[$vmRole[$p.VM]]
    if ($null -eq $info) { $p.Method = 'OffMigrate'; $p.Note = 'powered off; quick-migrate to CSV owner (no downtime)'; $proj[$p.VM] = $p.To; continue }
    $before = @{}; foreach ($m in $info.Members) { $nd = $proj[$m]; if ($nd) { $before[$nd] = 1 + $(if ($before.ContainsKey($nd)) { $before[$nd] } else { 0 }) } }
    $bBefore = Get-RoleBadness -PerNode $before -MemberCount $info.Count -Avail $info.Avail
    $after = @{}; foreach ($k in $before.Keys) { $after[$k] = $before[$k] }
    $fromN = $proj[$p.VM]; $toN = $p.To
    if ($after.ContainsKey($fromN)) { $after[$fromN]-- ; if ($after[$fromN] -le 0) { $after.Remove($fromN) } }
    $after[$toN] = 1 + $(if ($after.ContainsKey($toN)) { $after[$toN] } else { 0 })
    $bAfter = Get-RoleBadness -PerNode $after -MemberCount $info.Count -Avail $info.Avail
    if ($bAfter -le $bBefore) { $p.Method = 'OffMigrate'; $p.Note = 'powered off; quick-migrate to CSV owner (no downtime)'; $proj[$p.VM] = $p.To }
    else { $p.Method = 'OffHold'; $p.Note = 'powered off; held to protect role spread (move would add a collision)' }
}
$offMove = @($planVM | Where-Object Method -eq 'OffMigrate')
$offHold = @($planVM | Where-Object Method -eq 'OffHold')

# Projected POST placement: running Live moves AND the accepted off-VM quick-migrations
# change placement (Phase A re-owns CSVs without moving VMs; held off VMs stay put).
$postPlacement = @{}
foreach ($vm in $inScope) { $postPlacement[$vm.Name] = $vm.OwnerNode }
foreach ($p in $planVM) { if ($p.Method -in 'Live', 'OffMigrate') { $postPlacement[$p.VM] = $p.To } }

# Anti-affinity for spreadable role groups, idempotent: read current state, set only where missing.
$aaCurrent = @{}
try { foreach ($g in (Get-ClusterGroup -Cluster $ClusterName -ErrorAction Stop)) { $aaCurrent[$g.Name] = @($g.AntiAffinityClassNames) } } catch { }
$aaPlan = foreach ($d in ($preColl.Detail | Where-Object Spreadable)) {
    $class = "Role-" + ($d.Role -replace '[^A-Za-z0-9]', '')
    $toSet = @($d.Members | Where-Object { ($aaCurrent[$_]) -notcontains $class })
    [pscustomobject]@{ Role = $d.Role; Class = $class; Members = $d.Members; Count = $d.Count; ToSet = $toSet; AlreadySet = ($d.Count - $toSet.Count) }
}
$aaPlan = @($aaPlan)
$aaToSetTotal = (@($aaPlan) | ForEach-Object { $_.ToSet.Count } | Measure-Object -Sum).Sum

Write-Log ''
Write-Log '########## REMEDIATION PLAN ##########' -Color White
Write-Log ''
Write-Log ("--- Phase A: CSV-ownership moves ({0}) - non-disruptive, no VM moves ---" -f $csvOwnerPlan.Count) -Color White
if ($csvOwnerPlan.Count -eq 0) { Write-Log $(if ($VMMovesOnly) { '(skipped: -VMMovesOnly)' } else { '(CSV ownership already optimal)' }) }
foreach ($c in ($csvOwnerPlan | Sort-Object Csv)) {
    Write-Log ("{0,-14} {1,-9} -> {2,-9} aligns {3} -> {4} VMs (+{5})" -f $c.Csv, $c.From.ToUpper(), $c.To.ToUpper(), $c.AlignsNow, $c.AlignsAfter, $c.Gain) -Color Green
}
Write-Log ''
$runMoves = @($planVM | Where-Object { $_.Method -in 'Live','ManualShutdown','Skip' })
Write-Log ("--- Phase B: moves for the RUNNING remainder ({0} live) ---" -f @($planVM | Where-Object Method -eq 'Live').Count) -Color White
if ($runMoves.Count -eq 0) { Write-Log '(no running VMs need moving after Phase A)' }
foreach ($p in $runMoves) {
    Write-Log ("{0,-26} {1,-8} -> {2,-8} [{3}] {4}" -f $p.VM, $p.From.ToUpper(), $p.To.ToUpper(), $p.Method, $p.Note) -Color Red
}
Write-Log ''
Write-Log ("--- Phase B: powered-off VMs quick-migrated to their CSV owner ({0}) - no downtime, spread-safe ---" -f $offMove.Count) -Color White
foreach ($p in ($offMove | Sort-Object VM)) {
    Write-Log ("{0,-26} {1,-8} -> {2,-8} (quick-migrate, off)" -f $p.VM, $p.From.ToUpper(), $p.To.ToUpper()) -Color Green
}
if ($offHold.Count -gt 0) {
    Write-Log ''
    Write-Log ("--- Phase B: powered-off VMs HELD in place to protect role spread ({0}) ---" -f $offHold.Count) -Color White
    foreach ($p in ($offHold | Sort-Object VM)) {
        Write-Log ("{0,-26} {1,-8} (CSV owner {2}; moving there would add a role collision - left off, aligns when running)" -f $p.VM, $p.From.ToUpper(), $p.To.ToUpper()) -Color White
    }
}
Write-Log ''
Write-Log ("--- Phase C: anti-affinity for spreadable role groups ({0} group(s); {1} member(s) still to set) ---" -f $aaPlan.Count, $aaToSetTotal) -Color White
foreach ($a in ($aaPlan | Sort-Object Role)) {
    if ($a.ToSet.Count -eq 0) {
        Write-Log ("{0,-22} class '{1}'  (already set on all {2}; no change)" -f $a.Role, $a.Class, $a.Count) -Color Green
    } else {
        Write-Log ("{0,-22} class '{1}'  (set {2} of {3}; {4} already set)" -f $a.Role, $a.Class, $a.ToSet.Count, $a.Count, $a.AlreadySet)
    }
}
$pools = @($preColl.Detail | Where-Object { -not $_.Spreadable })
if ($pools.Count -gt 0) {
    Write-Log ''
    Write-Log "Pools larger than their site node count (reported, not auto-spread):" -Color White
    foreach ($d in ($pools | Sort-Object Role)) { Write-Log ("  {0,-22} {1} members over {2} site nodes  {3}" -f $d.Role, $d.Count, $d.Avail, $d.Layout) }
}

# =====================================================================
# PRE / POST GRAPHICAL (ASCII)
# =====================================================================
$preDist  = Get-Distribution -Placement $prePlacement  -AlignOwner $preAlign
$postDist = Get-Distribution -Placement $postPlacement -AlignOwner $postAlign
$postColl = Get-RoleSpread   -Placement $postPlacement

$maxVMs = 1; $maxMem = 1.0
foreach ($nk in $nodeKeys) {
    if ($preDist[$nk].VMs -gt $maxVMs)  { $maxVMs = $preDist[$nk].VMs }
    if ($postDist[$nk].VMs -gt $maxVMs) { $maxVMs = $postDist[$nk].VMs }
    if ($preDist[$nk].MemGB -gt $maxMem)  { $maxMem = $preDist[$nk].MemGB }
    if ($postDist[$nk].MemGB -gt $maxMem) { $maxMem = $postDist[$nk].MemGB }
}
function Show-DistBlock {
    param([string]$Title, $Dist, [object]$Coll)
    Write-Log ''
    Write-Log ("=== {0} ===" -f $Title) -Color White
    Write-Log ("{0,-10} {1,-5} {2,-26} {3,-7} {4,-9} {5}" -f 'Node', 'VMs', 'VM count', 'Mem GB', 'Aligned', 'Misaligned') -Color White
    foreach ($nk in $nodeKeys) {
        $d = $Dist[$nk]
        $rowCol = if ($d.MisalignedRunning -eq 0) { 'Green' } else { 'Red' }
        Write-Log ("{0,-10} {1,-5} {2,-26} {3,-7} {4,-9} {5}" -f $nodeMeta[$nk].Name.ToUpper(), $d.VMs, (Get-Bar -Value $d.VMs -Max $maxVMs), [math]::Round($d.MemGB, 0), $d.Aligned, $d.Misaligned) -Color $rowCol
    }
    $a = (($Dist.Values | Measure-Object Aligned -Sum).Sum)
    $sumCol = if ($a -eq $inScope.Count -and $Coll.Total -eq 0) { 'Green' } else { 'White' }
    Write-Log ("Aligned: {0} / {1}    Spreadable collisions: {2}    Pool imbalance: {3}" -f $a, $inScope.Count, $Coll.Total, $Coll.PoolImbalance) -Color $sumCol
}
Write-Log ''
Write-Log '########## PRE / POST (projected) ##########' -Color White
Show-DistBlock -Title 'PRE  (current)'   -Dist $preDist  -Coll $preColl
Show-DistBlock -Title 'POST (projected)' -Dist $postDist -Coll $postColl
if ($offMove.Count -gt 0) {
    Write-Log ("Note: {0} powered-off VM(s) are quick-migrated to their CSV owner under -Balance (no downtime, no Live Migration); POST already counts them as aligned." -f $offMove.Count) -Color White
}
if ($offHold.Count -gt 0) {
    Write-Log ("Note: {0} powered-off VM(s) are held in place because the alignment move would worsen role spread; they align by themselves on a later run once running. Role spread is never traded for off-VM alignment." -f $offHold.Count) -Color White
}

# =====================================================================
# EXECUTION (-Balance; honours -WhatIf)
# =====================================================================
$exec = [ordered]@{ CsvOwnerMoved = 0; VMMovedLive = 0; OffMigrated = 0; OffHeld = 0; ManualShutdown = 0; Skipped = 0; Failed = 0; AntiAffinitySet = 0; AntiAffinityAlready = 0 }
if ($Balance) {
    Write-Log ''
    Write-Log '########## APPLYING REMEDIATION ##########' -Color White
    # Phase A
    foreach ($c in ($csvOwnerPlan | Sort-Object Csv)) {
        if ($PSCmdlet.ShouldProcess($c.Csv, ("Move CSV ownership {0} -> {1}" -f $c.From.ToUpper(), $c.To.ToUpper()))) {
            try { Move-ClusterSharedVolume -Cluster $ClusterName -Name $c.Csv -Node $c.To -ErrorAction Stop | Out-Null
                  Write-Log ("CSVOWN {0}: {1} -> {2}" -f $c.Csv, $c.From.ToUpper(), $c.To.ToUpper()) -Color Green; $exec.CsvOwnerMoved++ }
            catch { Write-Log ("FAIL   {0}: {1}" -f $c.Csv, $_.Exception.Message) -Color Red; $exec.Failed++ }
        }
    }
    # Phase B (running VMs only; OFF VMs are named-but-skipped)
    foreach ($p in $planVM) {
        if ($p.Method -eq 'OffHold')        { $exec.OffHeld++; continue }
        if ($p.Method -eq 'ManualShutdown') { Write-Log ("MANUAL {0}: {1}" -f $p.VM, $p.Note) -Color Red; $exec.ManualShutdown++; continue }
        if ($p.Method -eq 'Skip')           { Write-Log ("SKIP   {0}: {1}" -f $p.VM, $p.Note) -Color Red; $exec.Skipped++; continue }
        if ($p.Method -eq 'OffMigrate') {
            if ($PSCmdlet.ShouldProcess($p.VM, ("Quick-migrate (off) {0} -> {1}" -f $p.From.ToUpper(), $p.To.ToUpper()))) {
                try {
                    Move-ClusterVirtualMachineRole -Cluster $ClusterName -Name $p.VM -Node $p.To -ErrorAction Stop | Out-Null; $exec.OffMigrated++
                    Write-Log ("MOVED  {0} -> {1} (off, quick)" -f $p.VM, $p.To.ToUpper()) -Color Green
                } catch { Write-Log ("FAIL   {0}: {1}" -f $p.VM, $_.Exception.Message) -Color Red; $exec.Failed++ }
            }
            continue
        }
        if ($PSCmdlet.ShouldProcess($p.VM, ("Live-migrate {0} -> {1}" -f $p.From.ToUpper(), $p.To.ToUpper()))) {
            try {
                Move-ClusterVirtualMachineRole -Cluster $ClusterName -Name $p.VM -Node $p.To -MigrationType Live -ErrorAction Stop | Out-Null; $exec.VMMovedLive++
                Write-Log ("MOVED  {0} -> {1} (Live)" -f $p.VM, $p.To.ToUpper()) -Color Green
                if ($SleepBetweenMigrationsSeconds -gt 0) { Start-Sleep -Seconds $SleepBetweenMigrationsSeconds }
            } catch { Write-Log ("FAIL   {0}: {1}" -f $p.VM, $_.Exception.Message) -Color Red; $exec.Failed++ }
        }
    }
    # Phase C (idempotent: only set where the class is missing)
    foreach ($a in $aaPlan) {
        $exec.AntiAffinityAlready += $a.AlreadySet
        if ($a.ToSet.Count -eq 0) { continue }
        if ($PSCmdlet.ShouldProcess($a.Role, ("Set AntiAffinityClassNames '{0}' on {1} VM(s)" -f $a.Class, $a.ToSet.Count))) {
            foreach ($m in $a.ToSet) {
                try { $g = Get-ClusterGroup -Cluster $ClusterName -Name $m -ErrorAction Stop; $g.AntiAffinityClassNames = @($a.Class); $exec.AntiAffinitySet++ }
                catch { Write-Log ("FAIL   anti-affinity on {0}: {1}" -f $m, $_.Exception.Message) -Color Red }
            }
            Write-Log ("AA     {0}: class '{1}' set on {2} member(s)" -f $a.Role, $a.Class, $a.ToSet.Count) -Color Green
        }
    }
    Write-Log ''
    Write-Log '--- Execution summary ---' -Color White
    foreach ($k in $exec.Keys) { Write-Log ("  {0,-16} {1}" -f $k, $exec[$k]) }
    if ($WhatIfPreference) { Write-Log "NOTE: -WhatIf active; nothing was actually changed." -Color White }
} else {
    Write-Log ''
    Write-Log "ANALYSIS ONLY: nothing changed. See the recommendations below." -Color White
}

# =====================================================================
# RECOMMENDATIONS - closes the log
# =====================================================================
$scriptName = $(if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'Optimize-VMPlacement.ps1' })
$liveN = @($planVM | Where-Object Method -eq 'Live').Count
$manualN = @($planVM | Where-Object Method -eq 'ManualShutdown').Count
Write-Log ''
Write-Log '########## RECOMMENDATIONS ##########' -Color White
Write-Log ''
if ($csvOwnerPlan.Count -eq 0) {
    Write-Log "1. Phase A (main action): no CSV-ownership moves needed - CSV alignment is already optimal."
} else {
    Write-Log ("1. Phase A (main action): apply the {0} CSV-ownership move(s). This re-aligns {1} -> {2} VMs with NO VM moves and is non-disruptive on a SAN cluster (only the CSV coordinator node changes)." -f $csvOwnerPlan.Count, $alignedNow, $alignedPhaseA)
}
if ($liveN -gt 0 -or $manualN -gt 0) {
    Write-Log ("2. Phase B: {0} running VM(s) need a Live Migration{1}. Verify any appliance or Linux VM (e.g. the Cloud VM) with a single test Live Migration before applying in bulk." -f $liveN, $(if ($manualN -gt 0) { ("; {0} running -NoLiveMigration VM(s) need a MANUAL shutdown first" -f $manualN) } else { '' }))
} else {
    Write-Log "2. Phase B: no running VM needs moving after Phase A."
}
if ($offMove.Count -gt 0) {
    Write-Log ("3. {0} powered-off VM(s) are quick-migrated to their CSV owner under -Balance (risk-free, no downtime, only where it does not worsen role spread): {1}." -f $offMove.Count, (($offMove | Sort-Object VM | ForEach-Object { $_.VM }) -join ', '))
} else {
    Write-Log "3. No powered-off VMs need migrating."
}
if ($offHold.Count -gt 0) {
    Write-Log ("   {0} off VM(s) held to protect role spread (align on a later run when running): {1}." -f $offHold.Count, (($offHold | Sort-Object VM | ForEach-Object { $_.VM }) -join ', '))
}
if ($aaToSetTotal -eq 0) {
    Write-Log ("4. Anti-affinity already covers all {0} spreadable role group(s) - nothing to (re)apply. {1} pool(s) exceed their site node count and cannot be fully separated." -f $aaPlan.Count, $pools.Count)
} else {
    Write-Log ("4. Anti-affinity: {0} member(s) across {1} spreadable role group(s) still need the class set (the rest already have it). {2} pool(s) exceed their site node count and cannot be fully separated - review those manually." -f $aaToSetTotal, $aaPlan.Count, $pools.Count)
}
Write-Log "5. Run order: preview with -WhatIf first, confirm the plan, then apply with -Balance."
Write-Log ''
Write-Log ("   Preview (no changes) :  .\{0} -Balance -WhatIf" -f $scriptName) -Color Green
Write-Log ("   Apply                :  .\{0} -Balance" -f $scriptName) -Color Green
Write-Log ''

# ----- CSV export (full model incl. excluded/out-of-scope) -----
$model | Select-Object Name, Clustered, Excluded, InScope, OwnerNode, Site, State, MemoryGB, RoleKey, PrimaryCsv, PrimaryOwner, PostPrimaryOwner, Aligned, SplitCsv, CsvBreakdown, NoLM, UnmatchedDisks |
    Sort-Object Name | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8

# ----- Text log (UTF-8 BOM) -----
$writer = New-Object System.IO.StreamWriter($logFile, $false, [System.Text.UTF8Encoding]::new($true))
$writer.Write($script:sb.ToString()); $writer.Close(); $writer.Dispose()

# ----- Optional HTML -----
if ($Html) {
    function HtmlBars { param($Dist)
        $rows = ''
        foreach ($nk in $nodeKeys) {
            $d = $Dist[$nk]
            $wVM = [int](($d.VMs / [math]::Max(1, $maxVMs)) * 100); $wMem = [int](($d.MemGB / [math]::Max(1.0, $maxMem)) * 100)
            $rows += "<tr><td class='n'>$($nodeMeta[$nk].Name.ToUpper())</td><td class='b'><div class='bar vm' style='width:$wVM%'>$($d.VMs)</div></td><td class='b'><div class='bar mem' style='width:$wMem%'>$([math]::Round($d.MemGB,0)) GB</div></td><td class='al'>$($d.Aligned)</td><td class='mis'>$($d.Misaligned)</td></tr>"
        }
        return $rows
    }
    $ownRows = ''
    foreach ($c in ($csvOwnerPlan | Sort-Object Csv)) { $ownRows += "<tr><td>$($c.Csv)</td><td>$($c.From.ToUpper())</td><td>$($c.To.ToUpper())</td><td>+$($c.Gain)</td></tr>" }
    if (-not $ownRows) { $ownRows = "<tr><td colspan='4'>CSV ownership already optimal</td></tr>" }
    $roleRows = ''
    foreach ($d in ($preColl.Detail | Sort-Object @{E={$_.Collisions};Descending=$true}, Role)) {
        $actionable = ($d.Spreadable -and $d.Collisions -gt 0) -or ((-not $d.Spreadable) -and $d.Imbalance -gt 0)
        $cls = if ($actionable) { 'warn' } elseif (-not $d.Spreadable) { 'pool' } else { 'ok' }
        $roleRows += "<tr class='$cls'><td>$($d.Role)</td><td>$($d.Count)</td><td>$($d.Avail)</td><td>$($d.Collisions)</td><td>$($d.Layout)</td></tr>"
    }
    $html = @"
<!doctype html><html><head><meta charset='utf-8'><title>$ClusterName VM Placement</title>
<style>body{font-family:Calibri,Segoe UI,sans-serif;color:#3A4255;margin:24px}h1{color:#0A1024;margin:0}.cyan{color:#0A7E9E}
h2{color:#0A1024;border-bottom:2px solid #D3D8E0;padding-bottom:4px;margin-top:26px}.sub{color:#6B7285;font-size:12px;margin:2px 0 18px}
.cols{display:flex;gap:28px}.col{flex:1}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:5px 7px;border:1px solid #E2E6EC;text-align:left}
th{background:#0A1024;color:#fff}td.n{font-weight:bold;color:#0A1024;width:90px}td.b{width:230px}.bar{color:#fff;font-size:11px;font-weight:bold;padding:2px 6px;border-radius:3px;white-space:nowrap}
.bar.vm{background:#2E74B5}.bar.mem{background:#0A7E9E}td.al{color:#548235;font-weight:bold;text-align:center}td.mis{color:#C00000;font-weight:bold;text-align:center}
tr.warn td{background:#FCEBDD}tr.pool td{background:#F2F2F2}.metric{font-size:13px;margin:8px 0}</style></head><body>
<h1>Cloud<span class='cyan'>Labs</span></h1><div class='sub'>Decades of server expertise</div>
<h1>$ClusterName VM Placement - Pre / Post</h1>
<div class='sub'>Cluster $ClusterName &middot; $(Get-Date) &middot; mode: $(if($Balance){'BALANCE'}else{'ANALYSIS ONLY'})</div>
<div class='metric'>Aligned: PRE $alignedNow &rarr; after CSV-owner $alignedPhaseA &rarr; POST $((($postDist.Values|Measure-Object Aligned -Sum).Sum)) / $($inScope.Count) &nbsp;|&nbsp; spreadable collisions PRE $($preColl.Total) &rarr; POST $($postColl.Total)</div>
<h2>CSV-ownership rebalancing (Phase A)</h2><table><tr><th>CSV</th><th>From</th><th>To</th><th>Extra aligned</th></tr>$ownRows</table>
<div class='cols'>
<div class='col'><h2>PRE (current)</h2><table><tr><th>Node</th><th>VM count</th><th>Assigned memory</th><th>Aln</th><th>Mis</th></tr>$(HtmlBars $preDist)</table></div>
<div class='col'><h2>POST (projected)</h2><table><tr><th>Node</th><th>VM count</th><th>Assigned memory</th><th>Aln</th><th>Mis</th></tr>$(HtmlBars $postDist)</table></div>
</div>
<h2>Identical-function distribution (site-aware)</h2><table><tr><th>Role</th><th>Members</th><th>Site nodes</th><th>Collisions</th><th>Per-node layout</th></tr>$roleRows</table>
</body></html>
"@
    $hw = New-Object System.IO.StreamWriter($htmlFile, $false, [System.Text.UTF8Encoding]::new($true)); $hw.Write($html); $hw.Close(); $hw.Dispose()
    Write-Host ("HTML report : {0}" -f $htmlFile) -ForegroundColor White
}

Write-Host ''
Write-Host ("Text log    : {0}" -f $logFile) -ForegroundColor White
Write-Host ("CSV model   : {0}" -f $csvFile) -ForegroundColor White
Write-Host 'Done.' -ForegroundColor Green
