#Requires -Version 5.1
<#
.SYNOPSIS
    Collects SQL Server inventory from CMS-registered server groups and
    stores results in the DBAInventory database on the local CMS instance.

.DESCRIPTION
    Per instance, collects:
      - Instance properties (version, edition, patch level, memory, CPU,
        MAXDOP/CTFP, HA settings, service account, authentication mode)
      - Databases (size, recovery model, compat level, backup dates, owner)
      - Agent jobs (enabled, last outcome, next run)
      - Disk space per volume (best effort; requires WMI/CIM access)

    Only touches servers registered in CMS — no network scanning.
    After collection, purges history older than $RetentionDays.

.NOTES
    - PowerShell 5.1 compatible
    - Requires dbatools installed for all users:
        Install-Module dbatools -Scope AllUsers
    - Run via SQL Agent CmdExec step:
        powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\DBA\Inventory\Collect-Inventory.ps1"
    - The SQL Agent service account needs VIEW SERVER STATE on all target
      instances, and local admin (or WMI rights) on hosts for disk data.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Configuration ─────────────────────────────────────────────────────────────
# If the CMS is a named instance use "SERVERNAME\INSTANCENAME"
$CMSInstance   = $env:COMPUTERNAME
$InventoryDB   = 'DBAInventory'
$LogDirectory  = 'C:\DBA\Inventory\Logs'
$RetentionDays = 400   # history older than this is purged after each run

# Groups must match exactly as they appear in SSMS Registered Servers.
# For nested groups use backslash path: "ParentGroup\ChildGroup"
$ServerGroups = @(
    'PROD',
    'DEV',
    'Manufacturing'
)

# Disk collection needs WMI/CIM rights on each host. Set $false to skip.
$CollectDiskSpace = $true
# ──────────────────────────────────────────────────────────────────────────────

Import-Module dbatools -ErrorAction Stop

if (-not (Test-Path -Path $LogDirectory)) {
    $null = New-Item -ItemType Directory -Path $LogDirectory -Force
}

$LogFile = Join-Path $LogDirectory "Inventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Output $entry
}

function Add-CollectionLogEntry {
    param(
        [string]$SqlInstance,
        [string]$ServerGroup,
        [datetime]$CollectionStart,
        [datetime]$CollectionEnd,
        [string]$Status,
        [string]$ErrorMessage
    )

    $query = @"
INSERT INTO dbo.CollectionLog
    (SqlInstance, ServerGroup, CollectionStart, CollectionEnd, Status, ErrorMessage)
OUTPUT INSERTED.CollectionID
VALUES
    (@SqlInstance, @ServerGroup, @CollectionStart, @CollectionEnd, @Status, @ErrorMessage)
"@

    $sqlParams = @{
        SqlInstance     = $SqlInstance
        ServerGroup     = if ([string]::IsNullOrEmpty($ServerGroup)) { [System.DBNull]::Value } else { $ServerGroup }
        CollectionStart = $CollectionStart
        CollectionEnd   = $CollectionEnd
        Status          = $Status
        ErrorMessage    = if ([string]::IsNullOrEmpty($ErrorMessage)) { [System.DBNull]::Value } else { $ErrorMessage }
    }

    try {
        $result = Invoke-DbaQuery -SqlInstance $CMSInstance -Database $InventoryDB `
                                  -Query $query -SqlParameter $sqlParams -EnableException
        return $result.CollectionID
    }
    catch {
        Write-Log "Failed to write CollectionLog entry for $SqlInstance : $_" -Level ERROR
        return $null
    }
}

# Helper: convert SMO DateTime min value to $null for clean inserts
function Convert-SmoDate {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime] -and $Value.Year -le 1900) { return $null }
    return $Value
}

# ── Main Collection Loop ───────────────────────────────────────────────────────
Write-Log '======= Inventory collection started ======='
$totalSuccess = 0
$totalFailed  = 0

foreach ($group in $ServerGroups) {

    Write-Log "Fetching registered servers — Group: '$group'"

    try {
        $registeredServers = Get-DbaRegServer -SqlInstance $CMSInstance -Group $group -EnableException
    }
    catch {
        Write-Log "Could not retrieve server list for group '$group': $_" -Level ERROR
        continue
    }

    if (-not $registeredServers) {
        Write-Log "No servers found in group '$group' — skipping" -Level WARN
        continue
    }

    foreach ($regServer in $registeredServers) {

        $sqlInstance = $regServer.SqlInstance
        $startTime   = Get-Date

        Write-Log "Processing: $sqlInstance"

        # ── Connectivity check ──────────────────────────────────────────────
        if (-not (Test-DbaConnection -SqlInstance $sqlInstance -Quiet)) {
            Write-Log "$sqlInstance is unreachable" -Level WARN
            $null = Add-CollectionLogEntry `
                -SqlInstance     $sqlInstance `
                -ServerGroup     $group `
                -CollectionStart $startTime `
                -CollectionEnd   (Get-Date) `
                -Status          'Unreachable' `
                -ErrorMessage    $null
            $totalFailed++
            continue
        }

        try {
            # ── Instance Properties ─────────────────────────────────────────
            $smo    = Connect-DbaInstance -SqlInstance $sqlInstance -EnableException
            $maxMem = Get-DbaSpConfigure -SqlInstance $sqlInstance -Name MaxServerMemory              -EnableException
            $maxdop = Get-DbaSpConfigure -SqlInstance $sqlInstance -Name MaxDegreeOfParallelism       -EnableException
            $ctfp   = Get-DbaSpConfigure -SqlInstance $sqlInstance -Name CostThresholdForParallelism  -EnableException

            # ProductUpdateLevel (CU info) was added in SQL 2012 SP1 SMO.
            # Older instances will return $null safely here.
            $updateLevel = try { $smo.ProductUpdateLevel } catch { $null }
            $cpuCount    = try { [int]$smo.Processors } catch { $null }
            $physMemMB   = try { [int]$smo.PhysicalMemory } catch { $null }
            $svcAccount  = try { $smo.ServiceAccount } catch { $null }
            $authMode    = try { [string]$smo.LoginMode } catch { $null }

            $instanceRow = [PSCustomObject]@{
                SqlInstance                 = $sqlInstance
                ServerGroup                 = $group
                ComputerName                = $smo.ComputerName
                InstanceName                = $smo.InstanceName
                SQLVersion                  = $smo.Version.ToString()
                VersionMajor                = [int]$smo.VersionMajor
                Edition                     = $smo.Edition
                ProductLevel                = $smo.ProductLevel
                ProductUpdateLevel          = $updateLevel
                Collation                   = $smo.Collation
                MaxServerMemoryMB           = [int]$maxMem.ConfiguredValue
                MAXDOP                      = [int]$maxdop.ConfiguredValue
                CostThresholdForParallelism = [int]$ctfp.ConfiguredValue
                CPUCount                    = $cpuCount
                PhysicalMemoryMB            = $physMemMB
                ServiceAccount              = $svcAccount
                AuthenticationMode          = $authMode
                IsClustered                 = $smo.IsClustered
                IsHadrEnabled               = $smo.IsHadrEnabled
                OSVersion                   = $smo.OSVersion
                CollectedAt                 = Get-Date
            }

            # ── Databases ───────────────────────────────────────────────────
            $databases = Get-DbaDatabase -SqlInstance $sqlInstance -EnableException

            $dbRows = foreach ($db in $databases) {
                [PSCustomObject]@{
                    SqlInstance        = $sqlInstance
                    ServerGroup        = $group
                    DatabaseName       = $db.Name
                    Status             = [string]$db.Status
                    SizeMB             = [math]::Round($db.Size, 2)   # dbatools returns MB
                    RecoveryModel      = [string]$db.RecoveryModel
                    CompatibilityLevel = [int]$db.CompatibilityLevel
                    LastFullBackup     = Convert-SmoDate $db.LastBackupDate
                    LastDiffBackup     = Convert-SmoDate $db.LastDifferentialBackupDate
                    LastLogBackup      = Convert-SmoDate $db.LastLogBackupDate
                    Owner              = $db.Owner
                    IsReadOnly         = $db.IsReadOnly
                    CreateDate         = $db.CreateDate
                    CollationName      = $db.Collation
                    CollectedAt        = Get-Date
                }
            }

            # ── Agent Jobs ──────────────────────────────────────────────────
            $jobs = Get-DbaAgentJob -SqlInstance $sqlInstance -EnableException

            $jobRows = foreach ($job in $jobs) {

                # NextRunScheduleDate is min-value when no future run is scheduled
                $nextRun = $null
                if ($job.HasSchedule) {
                    $nextRun = Convert-SmoDate $job.NextRunScheduleDate
                }

                [PSCustomObject]@{
                    SqlInstance    = $sqlInstance
                    ServerGroup    = $group
                    JobName        = $job.Name
                    IsEnabled      = $job.IsEnabled
                    CategoryName   = $job.Category
                    Description    = $job.Description
                    LastRunDate    = Convert-SmoDate $job.LastRunDate
                    LastRunOutcome = [string]$job.LastRunOutcome
                    NextRunDate    = $nextRun
                    HasSchedule    = $job.HasSchedule
                    CollectedAt    = Get-Date
                }
            }

            # ── Disk Space (best effort — needs WMI/CIM rights on the host) ─
            $diskRows = @()
            if ($CollectDiskSpace) {
                try {
                    $disks = Get-DbaDiskSpace -ComputerName $smo.ComputerName -EnableException

                    $diskRows = foreach ($disk in $disks) {
                        [PSCustomObject]@{
                            SqlInstance  = $sqlInstance
                            ComputerName = $smo.ComputerName
                            Volume       = $disk.Name
                            Label        = $disk.Label
                            CapacityGB   = [math]::Round($disk.Capacity.Gigabyte, 2)
                            FreeGB       = [math]::Round($disk.Free.Gigabyte, 2)
                            PercentFree  = [math]::Round($disk.PercentFree, 2)
                            CollectedAt  = Get-Date
                        }
                    }
                }
                catch {
                    Write-Log "$sqlInstance — disk space unavailable (WMI/CIM): $($_.Exception.Message)" -Level WARN
                }
            }

            # ── Write to DBAInventory ───────────────────────────────────────
            $collectionId = Add-CollectionLogEntry `
                -SqlInstance     $sqlInstance `
                -ServerGroup     $group `
                -CollectionStart $startTime `
                -CollectionEnd   (Get-Date) `
                -Status          'Success' `
                -ErrorMessage    $null

            if ($null -ne $collectionId) {
                # Stamp CollectionID onto each row for FK relationship
                $instanceRow | Add-Member -MemberType NoteProperty -Name CollectionID -Value $collectionId

                $dbRows  | ForEach-Object {
                    $_ | Add-Member -MemberType NoteProperty -Name CollectionID -Value $collectionId
                }
                $jobRows | ForEach-Object {
                    $_ | Add-Member -MemberType NoteProperty -Name CollectionID -Value $collectionId
                }
                $diskRows | ForEach-Object {
                    $_ | Add-Member -MemberType NoteProperty -Name CollectionID -Value $collectionId
                }

                $instanceRow | Write-DbaDbTableData `
                    -SqlInstance $CMSInstance -Database $InventoryDB `
                    -Table InstanceProperties -KeepNulls

                if ($dbRows) {
                    $dbRows | Write-DbaDbTableData `
                        -SqlInstance $CMSInstance -Database $InventoryDB `
                        -Table Databases -KeepNulls
                }

                if ($jobRows) {
                    $jobRows | Write-DbaDbTableData `
                        -SqlInstance $CMSInstance -Database $InventoryDB `
                        -Table AgentJobs -KeepNulls
                }

                if ($diskRows) {
                    $diskRows | Write-DbaDbTableData `
                        -SqlInstance $CMSInstance -Database $InventoryDB `
                        -Table DiskSpace -KeepNulls
                }
            }

            $totalSuccess++
            Write-Log "$sqlInstance — collected successfully"
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Log "$sqlInstance — collection FAILED: $errMsg" -Level ERROR

            $null = Add-CollectionLogEntry `
                -SqlInstance     $sqlInstance `
                -ServerGroup     $group `
                -CollectionStart $startTime `
                -CollectionEnd   (Get-Date) `
                -Status          'Failed' `
                -ErrorMessage    $errMsg

            $totalFailed++
        }
    }
}

# ── Retention purge ────────────────────────────────────────────────────────────
# Children first (FK to CollectionLog), then the log rows themselves.
try {
    $purgeQuery = @"
DECLARE @cutoff DATETIME = DATEADD(DAY, -@Days, GETDATE());

DELETE FROM dbo.InstanceProperties WHERE CollectionID IN (SELECT CollectionID FROM dbo.CollectionLog WHERE CollectionEnd < @cutoff);
DELETE FROM dbo.Databases          WHERE CollectionID IN (SELECT CollectionID FROM dbo.CollectionLog WHERE CollectionEnd < @cutoff);
DELETE FROM dbo.AgentJobs          WHERE CollectionID IN (SELECT CollectionID FROM dbo.CollectionLog WHERE CollectionEnd < @cutoff);
DELETE FROM dbo.DiskSpace          WHERE CollectionID IN (SELECT CollectionID FROM dbo.CollectionLog WHERE CollectionEnd < @cutoff);
DELETE FROM dbo.CollectionLog      WHERE CollectionEnd < @cutoff;

SELECT @@ROWCOUNT AS PurgedLogRows;
"@
    $purged = Invoke-DbaQuery -SqlInstance $CMSInstance -Database $InventoryDB `
                              -Query $purgeQuery -SqlParameter @{ Days = $RetentionDays } -EnableException
    Write-Log "Retention purge complete — $($purged.PurgedLogRows) collection log rows older than $RetentionDays days removed"
}
catch {
    Write-Log "Retention purge failed: $($_.Exception.Message)" -Level ERROR
}

Write-Log "======= Collection complete: $totalSuccess succeeded | $totalFailed failed ======="
