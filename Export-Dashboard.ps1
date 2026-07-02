#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a self-contained static HTML dashboard from the DBAInventory
    database. Runs as the final step of the inventory Agent job, so the
    dashboard refreshes automatically after every collection.

.DESCRIPTION
    Reads the dbo.vw_* views (created by Create-InventoryViews.sql) and
    writes a single HTML file with:
      - KPI tiles (instances, databases, total size, open issues)
      - Instances by SQL version and by server group
      - Top databases by size and by recent growth
      - Backup issues, failed Agent jobs, low disk space
      - Collection health and unregistered (discovered) instances

    The output is one file with embedded CSS — no JavaScript, no CDN
    dependencies — so it can be dropped on a file share or an IIS folder
    and viewed anywhere on the intranet. It auto-reloads every 15 minutes
    when left open on a screen. Light and dark mode both supported.

.NOTES
    - PowerShell 5.1 compatible; requires dbatools.
    - Point $OutputPath at a UNC share or IIS wwwroot to publish it, e.g.:
        \\fileserver\dba$\dashboard\index.html
        C:\inetpub\wwwroot\sqlestate\index.html
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ─────────────────────────────────────────────────────────────
$CMSInstance = $env:COMPUTERNAME
$InventoryDB = 'DBAInventory'
$OutputPath  = 'C:\DBA\Inventory\Dashboard\index.html'
# ──────────────────────────────────────────────────────────────────────────────

Import-Module dbatools -ErrorAction Stop

function Invoke-InventoryQuery {
    param([string]$Query)
    $result = @(Invoke-DbaQuery -SqlInstance $CMSInstance -Database $InventoryDB -Query $Query -EnableException)
    # Comma operator keeps an empty result an array — otherwise PowerShell
    # unwraps it to $null and .Count breaks under strict mode.
    return , $result
}

function HtmlEncode {
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

# DBNull-safe value fetch with default
function Val {
    param($Value, $Default = 0)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $Default }
    return $Value
}

function Format-Num  { param($n) '{0:N0}' -f [double](Val $n) }

function Format-GB {
    param($gb)
    $gb = [double](Val $gb)
    if ($gb -ge 1024) { return ('{0:N1} TB' -f ($gb / 1024)) }
    return ('{0:N1} GB' -f $gb)
}

function Format-MB {
    param($mb)
    $mb = [double](Val $mb)
    if ($mb -ge 1048576) { return ('{0:N1} TB' -f ($mb / 1048576)) }
    if ($mb -ge 1024)    { return ('{0:N1} GB' -f ($mb / 1024)) }
    return ('{0:N0} MB' -f $mb)
}

function Format-Date {
    param($d, [string]$IfNull = 'Never')
    if ($null -eq $d -or $d -is [System.DBNull]) { return $IfNull }
    return ([datetime]$d).ToString('yyyy-MM-dd HH:mm')
}

# Single-series horizontal bar chart (accent hue; value labeled at the bar tip)
function New-BarChart {
    param(
        [object[]]$Rows,
        [scriptblock]$Label,       # row -> label text
        [scriptblock]$Value,       # row -> numeric value
        [scriptblock]$ValueText,   # row -> formatted value label
        [string]$EmptyText = 'No data yet.'
    )
    if (-not $Rows -or $Rows.Count -eq 0) {
        return "<p class=""empty"">$(HtmlEncode $EmptyText)</p>"
    }
    $max = ($Rows | ForEach-Object { [double](& $Value $_) } | Measure-Object -Maximum).Maximum
    if ($max -le 0) { $max = 1 }

    $html = New-Object System.Text.StringBuilder
    $null = $html.AppendLine('<div class="chart" role="img">')
    foreach ($row in $Rows) {
        # NB: locals must not collide with the scriptblock parameters —
        # PowerShell variable names are case-insensitive.
        $rowLabel = HtmlEncode (& $Label $row)
        $rowNum   = [double](& $Value $row)
        $rowText  = HtmlEncode (& $ValueText $row)
        $pct      = [math]::Max([math]::Round(($rowNum / $max) * 100, 1), 0.5)
        $null = $html.AppendLine(@"
  <div class="bar-row" title="$rowLabel — $rowText">
    <div class="bar-label">$rowLabel</div>
    <div class="bar-track"><div class="bar-fill" style="width:$pct%"></div></div>
    <div class="bar-value">$rowText</div>
  </div>
"@)
    }
    $null = $html.AppendLine('</div>')
    return $html.ToString()
}

# Plain data table. Columns: array of @{ Header = ''; Cell = {scriptblock}; Class = '' }
function New-Table {
    param(
        [object[]]$Rows,
        [object[]]$Columns,
        [string]$EmptyText = 'Nothing to report.'
    )
    if (-not $Rows -or $Rows.Count -eq 0) {
        return "<p class=""empty ok"">&#10003; $(HtmlEncode $EmptyText)</p>"
    }
    $html = New-Object System.Text.StringBuilder
    $null = $html.AppendLine('<div class="table-wrap"><table><thead><tr>')
    foreach ($col in $Columns) {
        $cls = if ($col.ContainsKey('Class')) { " class=""$($col.Class)""" } else { '' }
        $null = $html.Append("<th$cls>$(HtmlEncode $col.Header)</th>")
    }
    $null = $html.AppendLine('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        $null = $html.Append('<tr>')
        foreach ($col in $Columns) {
            $cls = if ($col.ContainsKey('Class')) { " class=""$($col.Class)""" } else { '' }
            # Cell scriptblocks return pre-encoded HTML (they may embed chips)
            $null = $html.Append("<td$cls>$(& $col.Cell $row)</td>")
        }
        $null = $html.AppendLine('</tr>')
    }
    $null = $html.AppendLine('</tbody></table></div>')
    return $html.ToString()
}

# Status chip: colored dot (status palette) + label in text ink — never color-only
function New-Chip {
    param([ValidateSet('good','warning','serious','critical')][string]$Kind, [string]$Text)
    return "<span class=""chip""><span class=""dot dot-$Kind""></span>$(HtmlEncode $Text)</span>"
}

function New-KpiTile {
    param([string]$Label, [string]$Value, [string]$Sub = '', [string]$SubClass = '')
    $subHtml = ''
    if ($Sub) { $subHtml = "<div class=""kpi-sub $SubClass"">$Sub</div>" }
    return @"
  <div class="kpi">
    <div class="kpi-label">$(HtmlEncode $Label)</div>
    <div class="kpi-value">$(HtmlEncode $Value)</div>
    $subHtml
  </div>
"@
}

# ── Query the views ───────────────────────────────────────────────────────────
Write-Output "Querying $InventoryDB on $CMSInstance ..."

$summary      = (Invoke-InventoryQuery 'SELECT * FROM dbo.vw_EstateSummary')[0]
$versionDist  = Invoke-InventoryQuery 'SELECT SqlVersionName, COUNT(*) AS Cnt FROM dbo.vw_LatestInstances GROUP BY SqlVersionName ORDER BY Cnt DESC, SqlVersionName'
$groupDist    = Invoke-InventoryQuery "SELECT ISNULL(ServerGroup, '(ungrouped)') AS ServerGroup, COUNT(*) AS Cnt FROM dbo.vw_LatestInstances GROUP BY ISNULL(ServerGroup, '(ungrouped)') ORDER BY Cnt DESC"
$topDbs       = Invoke-InventoryQuery 'SELECT TOP 10 SqlInstance, DatabaseName, SizeMB FROM dbo.vw_LatestDatabases ORDER BY SizeMB DESC'
$topGrowth    = Invoke-InventoryQuery 'SELECT TOP 10 SqlInstance, DatabaseName, GrowthMB, CurrentSizeMB FROM dbo.vw_DatabaseGrowth WHERE GrowthMB > 0 ORDER BY GrowthMB DESC'
$backupIssues = Invoke-InventoryQuery 'SELECT TOP 50 SqlInstance, DatabaseName, RecoveryModel, IssueType, LastFullBackup, LastLogBackup FROM dbo.vw_BackupIssues ORDER BY CASE WHEN LastFullBackup IS NULL THEN 0 ELSE 1 END, LastFullBackup'
$failedJobs   = Invoke-InventoryQuery 'SELECT TOP 50 SqlInstance, JobName, CategoryName, LastRunDate FROM dbo.vw_FailedAgentJobs ORDER BY LastRunDate DESC'
$lowDisks     = Invoke-InventoryQuery 'SELECT SqlInstance, ComputerName, Volume, Label, CapacityGB, FreeGB, PercentFree, Severity FROM dbo.vw_LowDiskSpace ORDER BY PercentFree'
$collProblems = Invoke-InventoryQuery "SELECT SqlInstance, ServerGroup, Status, ErrorMessage, CollectionEnd FROM dbo.vw_LatestAttempt WHERE Status <> 'Success' ORDER BY SqlInstance"
$unregistered = Invoke-InventoryQuery 'SELECT SqlInstance, Port, FirstSeen, LastSeen FROM dbo.vw_UnregisteredInstances ORDER BY FirstSeen DESC'

# ── KPI row ───────────────────────────────────────────────────────────────────
$backupCount = [int](Val $summary.BackupIssueCount)
$jobCount    = [int](Val $summary.FailedJobCount)
$missCount   = [int](Val $summary.UncollectedCount)
$unregCount  = [int](Val $summary.UnregisteredCount)

function Get-IssueSub {
    param([int]$Count)
    if ($Count -gt 0) { return @{ Sub = (New-Chip 'serious' 'needs attention'); Class = '' } }
    return @{ Sub = '&#10003; all clear'; Class = 'ok' }
}

$kpiTiles = New-Object System.Text.StringBuilder
$null = $kpiTiles.Append((New-KpiTile 'Instances'  (Format-Num $summary.InstanceCount)))
$null = $kpiTiles.Append((New-KpiTile 'Databases'  (Format-Num $summary.DatabaseCount)))
$null = $kpiTiles.Append((New-KpiTile 'Total data' (Format-GB  $summary.TotalSizeGB)))
$s = Get-IssueSub $backupCount; $null = $kpiTiles.Append((New-KpiTile 'Backup issues'    (Format-Num $backupCount) $s.Sub $s.Class))
$s = Get-IssueSub $jobCount;    $null = $kpiTiles.Append((New-KpiTile 'Failed jobs'      (Format-Num $jobCount)    $s.Sub $s.Class))
$s = Get-IssueSub $missCount;   $null = $kpiTiles.Append((New-KpiTile 'Not collected'    (Format-Num $missCount)   $s.Sub $s.Class))
$s = Get-IssueSub $unregCount;  $null = $kpiTiles.Append((New-KpiTile 'Unregistered'     (Format-Num $unregCount)  $s.Sub $s.Class))

# ── Charts ────────────────────────────────────────────────────────────────────
$versionChart = New-BarChart -Rows $versionDist `
    -Label { param($r) $r.SqlVersionName } `
    -Value { param($r) $r.Cnt } `
    -ValueText { param($r) Format-Num $r.Cnt } `
    -EmptyText 'No instances collected yet.'

$groupChart = New-BarChart -Rows $groupDist `
    -Label { param($r) $r.ServerGroup } `
    -Value { param($r) $r.Cnt } `
    -ValueText { param($r) Format-Num $r.Cnt } `
    -EmptyText 'No instances collected yet.'

$topDbChart = New-BarChart -Rows $topDbs `
    -Label { param($r) "$($r.SqlInstance) › $($r.DatabaseName)" } `
    -Value { param($r) Val $r.SizeMB } `
    -ValueText { param($r) Format-MB $r.SizeMB } `
    -EmptyText 'No databases collected yet.'

$growthChart = New-BarChart -Rows $topGrowth `
    -Label { param($r) "$($r.SqlInstance) › $($r.DatabaseName)" } `
    -Value { param($r) Val $r.GrowthMB } `
    -ValueText { param($r) "+$(Format-MB $r.GrowthMB)" } `
    -EmptyText 'Growth appears after two successful collection runs.'

# ── Tables ────────────────────────────────────────────────────────────────────
$backupTable = New-Table -Rows $backupIssues -EmptyText 'All databases have current backups.' -Columns @(
    @{ Header = 'Instance';      Cell = { param($r) HtmlEncode $r.SqlInstance } }
    @{ Header = 'Database';      Cell = { param($r) HtmlEncode $r.DatabaseName } }
    @{ Header = 'Issue';         Cell = { param($r)
            $kind = if ($r.IssueType -eq 'Never backed up') { 'critical' } else { 'serious' }
            New-Chip $kind ([string]$r.IssueType) } }
    @{ Header = 'Recovery';      Cell = { param($r) HtmlEncode $r.RecoveryModel } }
    @{ Header = 'Last full';     Cell = { param($r) HtmlEncode (Format-Date $r.LastFullBackup) }; Class = 'num' }
    @{ Header = 'Last log';      Cell = { param($r) HtmlEncode (Format-Date $r.LastLogBackup 'None') }; Class = 'num' }
)

$jobsTable = New-Table -Rows $failedJobs -EmptyText 'No failed Agent jobs.' -Columns @(
    @{ Header = 'Instance';  Cell = { param($r) HtmlEncode $r.SqlInstance } }
    @{ Header = 'Job';       Cell = { param($r) HtmlEncode $r.JobName } }
    @{ Header = 'Last run';  Cell = { param($r) HtmlEncode (Format-Date $r.LastRunDate) }; Class = 'num' }
)

# Low disk space: meter per volume (fill = % free; severity carries the color)
$diskHtml = ''
if ($lowDisks.Count -eq 0) {
    $diskHtml = '<p class="empty ok">&#10003; All monitored volumes have at least 20% free.</p>'
}
else {
    $sb = New-Object System.Text.StringBuilder
    foreach ($d in $lowDisks) {
        $sev     = ([string]$d.Severity).ToLowerInvariant()   # 'warning' | 'critical'
        $pctFree = [math]::Max([double](Val $d.PercentFree), 1)
        $label   = HtmlEncode "$($d.ComputerName) $($d.Volume)"
        $detail  = HtmlEncode ("{0:N0}% free · {1} free of {2}" -f [double](Val $d.PercentFree), (Format-GB $d.FreeGB), (Format-GB $d.CapacityGB))
        $chip    = New-Chip $sev ([string]$d.Severity)
        $null = $sb.AppendLine(@"
  <div class="disk-row" title="$label — $detail">
    <div class="disk-label">$label</div>
    <div class="meter meter-$sev"><div class="meter-fill" style="width:$pctFree%"></div></div>
    <div class="disk-detail">$chip $detail</div>
  </div>
"@)
    }
    $diskHtml = $sb.ToString()
}

$collTable = New-Table -Rows $collProblems -EmptyText 'Every registered server was collected in the last run.' -Columns @(
    @{ Header = 'Instance'; Cell = { param($r) HtmlEncode $r.SqlInstance } }
    @{ Header = 'Group';    Cell = { param($r) HtmlEncode $r.ServerGroup } }
    @{ Header = 'Status';   Cell = { param($r)
            $kind = if ($r.Status -eq 'Unreachable') { 'critical' } else { 'serious' }
            New-Chip $kind ([string]$r.Status) } }
    @{ Header = 'Last attempt'; Cell = { param($r) HtmlEncode (Format-Date $r.CollectionEnd) }; Class = 'num' }
    @{ Header = 'Error';    Cell = { param($r) HtmlEncode $r.ErrorMessage } }
)

$unregTable = New-Table -Rows $unregistered -EmptyText 'Every instance found in Active Directory is registered in CMS.' -Columns @(
    @{ Header = 'Instance';   Cell = { param($r) HtmlEncode $r.SqlInstance } }
    @{ Header = 'Port';       Cell = { param($r) HtmlEncode $r.Port }; Class = 'num' }
    @{ Header = 'First seen'; Cell = { param($r) HtmlEncode (Format-Date $r.FirstSeen) }; Class = 'num' }
    @{ Header = 'Last seen';  Cell = { param($r) HtmlEncode (Format-Date $r.LastSeen) }; Class = 'num' }
)

# ── Assemble the page ─────────────────────────────────────────────────────────
$dataAsOf     = Format-Date $summary.LastSuccessfulRun 'no successful run yet'
$generatedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm')

$css = @'
:root {
  --page:        #f9f9f7;
  --surface:     #fcfcfb;
  --ink:         #0b0b0b;
  --ink-2:       #52514e;
  --muted:       #898781;
  --border:      rgba(11,11,11,0.10);
  --accent:      #2a78d6;
  --track:       #cde2fb;
  --good:        #0ca30c;
  --good-text:   #006300;
  --warning:     #fab219;
  --warn-track:  #fdeecb;
  --serious:     #ec835a;
  --critical:    #d03b3b;
  --crit-track:  #f6d4d4;
  --hover-wash:  rgba(11,11,11,0.04);
}
@media (prefers-color-scheme: dark) {
  :root {
    --page:        #0d0d0d;
    --surface:     #1a1a19;
    --ink:         #ffffff;
    --ink-2:       #c3c2b7;
    --muted:       #898781;
    --border:      rgba(255,255,255,0.10);
    --accent:      #3987e5;
    --track:       #104281;
    --good:        #0ca30c;
    --good-text:   #0ca30c;
    --warning:     #fab219;
    --warn-track:  #4a3608;
    --serious:     #ec835a;
    --critical:    #d03b3b;
    --crit-track:  #4a1414;
    --hover-wash:  rgba(255,255,255,0.05);
  }
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  background: var(--page);
  color: var(--ink);
  font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size: 14px;
  line-height: 1.45;
  padding: 24px;
}
header { max-width: 1400px; margin: 0 auto 20px; }
h1 { font-size: 22px; font-weight: 600; }
.subtitle { color: var(--ink-2); margin-top: 2px; }
.wrap { max-width: 1400px; margin: 0 auto; }

.kpi-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 12px;
  margin-bottom: 20px;
}
.kpi {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 14px 16px;
}
.kpi-label { color: var(--ink-2); font-size: 13px; }
.kpi-value { font-size: 32px; font-weight: 600; margin-top: 2px; }
.kpi-sub   { font-size: 12px; color: var(--ink-2); margin-top: 4px; }
.kpi-sub.ok { color: var(--good-text); }

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(440px, 1fr));
  gap: 16px;
}
.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 18px;
}
.card.wide { grid-column: 1 / -1; }
.card h2 { font-size: 15px; font-weight: 600; margin-bottom: 2px; }
.card .desc { color: var(--muted); font-size: 12px; margin-bottom: 12px; }

/* Bar chart: thin marks, rounded data-end, square baseline, row-wide hit target */
.chart { display: flex; flex-direction: column; gap: 6px; }
.bar-row {
  display: grid;
  grid-template-columns: minmax(140px, 38%) 1fr auto;
  align-items: center;
  gap: 10px;
  min-height: 24px;
  border-radius: 6px;
  padding: 1px 4px;
}
.bar-row:hover { background: var(--hover-wash); }
.bar-label {
  color: var(--ink-2);
  font-size: 13px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.bar-track { height: 16px; }
.bar-fill {
  height: 16px;
  min-width: 2px;
  background: var(--accent);
  border-radius: 0 4px 4px 0;
}
.bar-value {
  font-size: 13px;
  color: var(--ink);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

/* Disk meters: fill carries severity; track is a light step of the same ramp */
.disk-row {
  display: grid;
  grid-template-columns: minmax(150px, 30%) 1fr minmax(220px, auto);
  align-items: center;
  gap: 10px;
  min-height: 26px;
  border-radius: 6px;
  padding: 1px 4px;
}
.disk-row:hover { background: var(--hover-wash); }
.disk-label { color: var(--ink-2); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.meter { height: 8px; border-radius: 4px; overflow: hidden; }
.meter-fill { height: 8px; border-radius: 4px; }
.meter-warning  { background: var(--warn-track); }
.meter-warning .meter-fill { background: var(--warning); }
.meter-critical { background: var(--crit-track); }
.meter-critical .meter-fill { background: var(--critical); }
.disk-detail { font-size: 12px; color: var(--ink-2); white-space: nowrap; }

/* Tables */
.table-wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th {
  text-align: left;
  font-size: 12px;
  font-weight: 600;
  color: var(--muted);
  padding: 6px 10px;
  border-bottom: 1px solid var(--border);
  white-space: nowrap;
}
td {
  padding: 7px 10px;
  border-bottom: 1px solid var(--border);
  font-size: 13px;
  vertical-align: top;
}
tr:last-child td { border-bottom: none; }
tr:hover td { background: var(--hover-wash); }
td.num, th.num { font-variant-numeric: tabular-nums; white-space: nowrap; }

/* Status chips: colored dot + text ink, never color alone */
.chip { display: inline-flex; align-items: center; gap: 5px; white-space: nowrap; }
.dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
.dot-good     { background: var(--good); }
.dot-warning  { background: var(--warning); }
.dot-serious  { background: var(--serious); }
.dot-critical { background: var(--critical); }

.empty { color: var(--ink-2); font-size: 13px; padding: 6px 0; }
.empty.ok { color: var(--good-text); }

footer {
  max-width: 1400px;
  margin: 24px auto 0;
  color: var(--muted);
  font-size: 12px;
}
'@

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="900">
<title>SQL Server Estate Dashboard</title>
<style>
$css
</style>
</head>
<body>
<header>
  <h1>SQL Server Estate Dashboard</h1>
  <div class="subtitle">Data as of $(HtmlEncode $dataAsOf) &middot; refreshes automatically</div>
</header>
<div class="wrap">

  <div class="kpi-row">
$($kpiTiles.ToString())
  </div>

  <div class="grid">

    <div class="card">
      <h2>Instances by SQL Server version</h2>
      <div class="desc">Latest snapshot per instance</div>
      $versionChart
    </div>

    <div class="card">
      <h2>Instances by server group</h2>
      <div class="desc">CMS registered-server groups</div>
      $groupChart
    </div>

    <div class="card">
      <h2>Largest databases</h2>
      <div class="desc">Top 10 by allocated size</div>
      $topDbChart
    </div>

    <div class="card">
      <h2>Fastest-growing databases</h2>
      <div class="desc">Size change since the previous collection run</div>
      $growthChart
    </div>

    <div class="card wide">
      <h2>Backup issues</h2>
      <div class="desc">No full backup in 7 days, or FULL-recovery databases with no log backup in 24 hours (tempdb excluded)</div>
      $backupTable
    </div>

    <div class="card wide">
      <h2>Low disk space</h2>
      <div class="desc">Volumes under 20% free &mdash; bar shows remaining free space</div>
      $diskHtml
    </div>

    <div class="card">
      <h2>Failed Agent jobs</h2>
      <div class="desc">Enabled jobs whose last run failed</div>
      $jobsTable
    </div>

    <div class="card wide">
      <h2>Collection problems</h2>
      <div class="desc">Registered servers not collected on the latest attempt</div>
      $collTable
    </div>

    <div class="card wide">
      <h2>Discovered but not inventoried</h2>
      <div class="desc">Instances found via Active Directory SPNs (read-only directory lookup) that are not registered in CMS &mdash; review and register them to bring them under inventory</div>
      $unregTable
    </div>

  </div>
</div>
<footer>Generated $(HtmlEncode $generatedAt) by Export-Dashboard.ps1 &middot; source: $(HtmlEncode $InventoryDB) on $(HtmlEncode $CMSInstance)</footer>
</body>
</html>
"@

# ── Write output ──────────────────────────────────────────────────────────────
$outDir = Split-Path -Path $OutputPath -Parent
if (-not (Test-Path -Path $outDir)) {
    $null = New-Item -ItemType Directory -Path $outDir -Force
}

# Write atomically: build alongside, then swap in, so a viewer mid-refresh
# never sees a half-written page.
$tempPath = "$OutputPath.tmp"
Set-Content -Path $tempPath -Value $html -Encoding UTF8
Move-Item -Path $tempPath -Destination $OutputPath -Force

Write-Output "Dashboard written to $OutputPath"
