-- ============================================================
-- Create-InventoryViews.sql
-- The insights layer: "latest snapshot" views plus derived
-- health/insight views over the DBAInventory tables.
-- Both Inventory-Reports.sql and Export-Dashboard.ps1 read from
-- these views, so all consumers agree on the same logic.
-- Safe to re-run (CREATE OR ALTER).
-- Run on the CMS instance after Create-InventoryDB.sql.
-- Requires SQL Server 2016 SP1+ for CREATE OR ALTER.
-- ============================================================

USE DBAInventory;
GO

-- ============================================================
-- dbo.vw_LatestCollection
-- The most recent SUCCESSFUL collection per instance.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LatestCollection
AS
SELECT cl.*
FROM dbo.CollectionLog cl
JOIN (
    SELECT SqlInstance, MAX(CollectionID) AS MaxCollectionID
    FROM dbo.CollectionLog
    WHERE Status = 'Success'
    GROUP BY SqlInstance
) latest
    ON cl.CollectionID = latest.MaxCollectionID;
GO

-- ============================================================
-- dbo.vw_LatestAttempt
-- The most recent collection attempt per instance, ANY status.
-- Use for collection-health reporting (who is unreachable now).
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LatestAttempt
AS
SELECT cl.*
FROM dbo.CollectionLog cl
JOIN (
    SELECT SqlInstance, MAX(CollectionID) AS MaxCollectionID
    FROM dbo.CollectionLog
    GROUP BY SqlInstance
) latest
    ON cl.CollectionID = latest.MaxCollectionID;
GO

-- ============================================================
-- dbo.vw_LatestInstances
-- Current instance-level snapshot, one row per instance,
-- with a friendly version name derived from VersionMajor.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LatestInstances
AS
SELECT
    ip.*,
    CASE ip.VersionMajor
        WHEN 17 THEN 'SQL Server 2025'
        WHEN 16 THEN 'SQL Server 2022'
        WHEN 15 THEN 'SQL Server 2019'
        WHEN 14 THEN 'SQL Server 2017'
        WHEN 13 THEN 'SQL Server 2016'
        WHEN 12 THEN 'SQL Server 2014'
        WHEN 11 THEN 'SQL Server 2012'
        WHEN 10 THEN 'SQL Server 2008/R2'
        ELSE COALESCE('Major v' + CAST(ip.VersionMajor AS VARCHAR(10)), 'Unknown')
    END              AS SqlVersionName,
    lc.CollectionEnd AS LastCollected
FROM dbo.InstanceProperties ip
JOIN dbo.vw_LatestCollection lc
    ON ip.CollectionID = lc.CollectionID;
GO

-- ============================================================
-- dbo.vw_LatestDatabases
-- Current database snapshot, one row per database.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LatestDatabases
AS
SELECT
    d.*,
    lc.CollectionEnd AS LastCollected
FROM dbo.Databases d
JOIN dbo.vw_LatestCollection lc
    ON d.CollectionID = lc.CollectionID;
GO

-- ============================================================
-- dbo.vw_LatestAgentJobs
-- Current Agent job snapshot, one row per job.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LatestAgentJobs
AS
SELECT
    j.*,
    lc.CollectionEnd AS LastCollected
FROM dbo.AgentJobs j
JOIN dbo.vw_LatestCollection lc
    ON j.CollectionID = lc.CollectionID;
GO

-- ============================================================
-- dbo.vw_LatestDisks
-- Current disk snapshot, one row per volume.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LatestDisks
AS
SELECT
    ds.*,
    lc.CollectionEnd AS LastCollected
FROM dbo.DiskSpace ds
JOIN dbo.vw_LatestCollection lc
    ON ds.CollectionID = lc.CollectionID;
GO

-- ============================================================
-- dbo.vw_BackupIssues
-- Databases with backup problems as of the latest snapshot:
--   * no full backup in 7 days (or never)
--   * FULL recovery model with no log backup in 24 hours
-- tempdb is excluded (never backed up); offline/restoring
-- databases are excluded (their backups are managed elsewhere).
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_BackupIssues
AS
SELECT
    d.SqlInstance,
    d.ServerGroup,
    d.DatabaseName,
    d.RecoveryModel,
    d.LastFullBackup,
    d.LastLogBackup,
    DATEDIFF(DAY,  d.LastFullBackup, GETDATE()) AS DaysSinceFullBackup,
    DATEDIFF(HOUR, d.LastLogBackup,  GETDATE()) AS HoursSinceLogBackup,
    CASE
        WHEN d.LastFullBackup IS NULL THEN 'Never backed up'
        WHEN d.LastFullBackup < DATEADD(DAY, -7, GETDATE()) THEN 'Full backup overdue'
        ELSE 'Log backup overdue'
    END AS IssueType
FROM dbo.vw_LatestDatabases d
WHERE d.DatabaseName <> 'tempdb'
  AND d.Status = 'Normal'
  AND (
        d.LastFullBackup IS NULL
        OR d.LastFullBackup < DATEADD(DAY, -7, GETDATE())
        OR (
             d.RecoveryModel = 'FULL'
             AND (d.LastLogBackup IS NULL OR d.LastLogBackup < DATEADD(HOUR, -24, GETDATE()))
           )
      );
GO

-- ============================================================
-- dbo.vw_FailedAgentJobs
-- Enabled jobs whose last run failed, latest snapshot.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_FailedAgentJobs
AS
SELECT
    j.SqlInstance,
    j.ServerGroup,
    j.JobName,
    j.CategoryName,
    j.LastRunDate,
    j.NextRunDate
FROM dbo.vw_LatestAgentJobs j
WHERE j.IsEnabled = 1
  AND j.LastRunOutcome = 'Failed';
GO

-- ============================================================
-- dbo.vw_DatabaseGrowth
-- Size change per database between the latest and the previous
-- successful collection of the same instance.
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_DatabaseGrowth
AS
WITH ranked AS
(
    SELECT
        SqlInstance,
        CollectionID,
        CollectionEnd,
        ROW_NUMBER() OVER (PARTITION BY SqlInstance ORDER BY CollectionID DESC) AS rn
    FROM dbo.CollectionLog
    WHERE Status = 'Success'
)
SELECT
    cur.SqlInstance,
    cur.ServerGroup,
    cur.DatabaseName,
    cur.SizeMB                                          AS CurrentSizeMB,
    prev.SizeMB                                         AS PriorSizeMB,
    CAST(cur.SizeMB - prev.SizeMB AS DECIMAL(18,2))     AS GrowthMB,
    r_prev.CollectionEnd                                AS PriorCollected,
    r_cur.CollectionEnd                                 AS CurrentCollected
FROM dbo.Databases cur
JOIN ranked r_cur
    ON cur.CollectionID = r_cur.CollectionID AND r_cur.rn = 1
JOIN ranked r_prev
    ON r_prev.SqlInstance = r_cur.SqlInstance AND r_prev.rn = 2
JOIN dbo.Databases prev
    ON prev.CollectionID = r_prev.CollectionID
   AND prev.DatabaseName = cur.DatabaseName;
GO

-- ============================================================
-- dbo.vw_LowDiskSpace
-- Volumes below 20% free in the latest snapshot, with a
-- severity band (Critical < 10%, Warning < 20%).
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_LowDiskSpace
AS
SELECT
    ds.SqlInstance,
    ds.ComputerName,
    ds.Volume,
    ds.Label,
    ds.CapacityGB,
    ds.FreeGB,
    ds.PercentFree,
    CASE WHEN ds.PercentFree < 10 THEN 'Critical' ELSE 'Warning' END AS Severity
FROM dbo.vw_LatestDisks ds
WHERE ds.PercentFree < 20;
GO

-- ============================================================
-- dbo.vw_UnregisteredInstances
-- Instances seen in Active Directory (SPNs) within the last 30
-- days that are NOT registered in CMS — i.e. servers that exist
-- but are not being inventoried. Review each one: register it,
-- or record why not in the Notes column (a non-empty Note
-- acknowledges the instance and removes it from this view).
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_UnregisteredInstances
AS
SELECT
    di.SqlInstance,
    di.ComputerName,
    di.InstanceName,
    di.Port,
    di.Source,
    di.FirstSeen,
    di.LastSeen,
    di.Notes
FROM dbo.DiscoveredInstances di
WHERE di.IsRegisteredInCMS = 0
  AND di.LastSeen > DATEADD(DAY, -30, GETDATE())
  AND (di.Notes IS NULL OR di.Notes = '');
GO

-- ============================================================
-- dbo.vw_EstateSummary
-- One-row KPI summary of the whole estate (latest snapshot).
-- ============================================================
CREATE OR ALTER VIEW dbo.vw_EstateSummary
AS
SELECT
    (SELECT COUNT(*) FROM dbo.vw_LatestInstances)                            AS InstanceCount,
    (SELECT COUNT(*) FROM dbo.vw_LatestDatabases)                            AS DatabaseCount,
    (SELECT CAST(SUM(SizeMB) / 1024.0 AS DECIMAL(18,2))
       FROM dbo.vw_LatestDatabases)                                          AS TotalSizeGB,
    (SELECT COUNT(*) FROM dbo.vw_BackupIssues)                               AS BackupIssueCount,
    (SELECT COUNT(*) FROM dbo.vw_FailedAgentJobs)                            AS FailedJobCount,
    (SELECT COUNT(*) FROM dbo.vw_LatestAttempt
      WHERE Status IN ('Unreachable', 'Failed'))                             AS UncollectedCount,
    (SELECT COUNT(*) FROM dbo.vw_UnregisteredInstances)                      AS UnregisteredCount,
    (SELECT MAX(CollectionEnd) FROM dbo.CollectionLog WHERE Status = 'Success') AS LastSuccessfulRun;
GO

PRINT 'DBAInventory views created/updated.';
GO
