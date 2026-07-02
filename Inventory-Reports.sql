-- ============================================================
-- Inventory-Reports.sql
-- Reporting queries against the DBAInventory database.
-- Run on the CMS instance (DBAInventory must be populated and
-- Create-InventoryViews.sql must have been run first).
--
-- These queries read the dbo.vw_* views, so they always reflect
-- the latest snapshot per instance and match the dashboard.
-- ============================================================

USE DBAInventory;
GO

-- ============================================================
-- SECTION 0: ESTATE AT A GLANCE
-- ============================================================

-- 0a. One-row KPI summary (same numbers as the dashboard tiles)
SELECT * FROM dbo.vw_EstateSummary;
GO

-- ============================================================
-- SECTION 1: INVENTORY & ESTATE OVERVIEW
-- ============================================================

-- 1a. Server count by group and SQL version (latest snapshot)
SELECT
    ServerGroup,
    SqlVersionName,
    Edition,
    COUNT(*)         AS ServerCount
FROM dbo.vw_LatestInstances
GROUP BY ServerGroup, SqlVersionName, Edition
ORDER BY ServerGroup, SqlVersionName;
GO

-- 1b. Full instance inventory — latest successful run per server
SELECT
    ServerGroup,
    SqlInstance,
    ComputerName,
    InstanceName,
    SqlVersionName,
    SQLVersion,
    Edition,
    ProductLevel,
    ProductUpdateLevel,
    Collation,
    CPUCount,
    PhysicalMemoryMB,
    MaxServerMemoryMB,
    MAXDOP,
    CostThresholdForParallelism,
    ServiceAccount,
    AuthenticationMode,
    IsClustered,
    IsHadrEnabled,
    OSVersion,
    LastCollected
FROM dbo.vw_LatestInstances
ORDER BY ServerGroup, SqlInstance;
GO

-- 1c. Database estate by instance — count and total size
SELECT
    SqlInstance,
    ServerGroup,
    COUNT(*)                                        AS DatabaseCount,
    CAST(SUM(SizeMB) / 1024.0 AS DECIMAL(18,2))     AS TotalSizeGB
FROM dbo.vw_LatestDatabases
GROUP BY SqlInstance, ServerGroup
ORDER BY TotalSizeGB DESC;
GO


-- ============================================================
-- SECTION 2: VERSION & PATCH COMPLIANCE
-- ============================================================

-- 2a. Servers not on a target CU — edit the IN list to match your standard
SELECT
    SqlInstance,
    ServerGroup,
    SqlVersionName,
    SQLVersion,
    ProductLevel,
    ProductUpdateLevel
FROM dbo.vw_LatestInstances
WHERE ProductUpdateLevel NOT IN ('CU14', 'CU15')  -- adjust to your target
   OR ProductUpdateLevel IS NULL
ORDER BY ServerGroup, SqlInstance;
GO

-- 2b. Databases running below a target compatibility level
SELECT
    SqlInstance,
    ServerGroup,
    DatabaseName,
    CompatibilityLevel
FROM dbo.vw_LatestDatabases
WHERE CompatibilityLevel < 150  -- adjust: 130=2016, 140=2017, 150=2019, 160=2022
ORDER BY CompatibilityLevel, SqlInstance;
GO

-- 2c. Out-of-support versions still in the estate (2014 and older)
SELECT
    SqlInstance,
    ServerGroup,
    SqlVersionName,
    SQLVersion,
    Edition
FROM dbo.vw_LatestInstances
WHERE VersionMajor <= 12
ORDER BY VersionMajor, SqlInstance;
GO


-- ============================================================
-- SECTION 3: BACKUP HEALTH
-- ============================================================

-- 3a. All current backup issues (missing fulls + overdue log backups),
--     tempdb and offline databases excluded
SELECT
    SqlInstance,
    ServerGroup,
    DatabaseName,
    RecoveryModel,
    IssueType,
    LastFullBackup,
    LastLogBackup,
    DaysSinceFullBackup,
    HoursSinceLogBackup
FROM dbo.vw_BackupIssues
ORDER BY
    CASE WHEN LastFullBackup IS NULL THEN 0 ELSE 1 END,
    DaysSinceFullBackup DESC;
GO


-- ============================================================
-- SECTION 4: CAPACITY & GROWTH
-- ============================================================

-- 4a. Largest databases across the estate (latest snapshot)
SELECT TOP 25
    SqlInstance,
    ServerGroup,
    DatabaseName,
    SizeMB,
    CAST(SizeMB / 1024.0 AS DECIMAL(10,2)) AS SizeGB
FROM dbo.vw_LatestDatabases
ORDER BY SizeMB DESC;
GO

-- 4b. Database size growth — latest run vs previous run, per instance
SELECT
    SqlInstance,
    DatabaseName,
    CurrentSizeMB,
    PriorSizeMB,
    GrowthMB,
    PriorCollected,
    CurrentCollected
FROM dbo.vw_DatabaseGrowth
ORDER BY GrowthMB DESC;
GO

-- 4c. Volumes low on disk space (latest snapshot)
SELECT
    SqlInstance,
    ComputerName,
    Volume,
    Label,
    CapacityGB,
    FreeGB,
    PercentFree,
    Severity
FROM dbo.vw_LowDiskSpace
ORDER BY PercentFree;
GO


-- ============================================================
-- SECTION 5: AGENT JOB HEALTH
-- ============================================================

-- 5a. Enabled jobs that failed on their last run
SELECT
    SqlInstance,
    ServerGroup,
    JobName,
    CategoryName,
    LastRunDate,
    NextRunDate
FROM dbo.vw_FailedAgentJobs
ORDER BY ServerGroup, SqlInstance;
GO

-- 5b. Enabled jobs with no schedule attached
SELECT
    SqlInstance,
    ServerGroup,
    JobName,
    CategoryName
FROM dbo.vw_LatestAgentJobs
WHERE IsEnabled = 1
  AND HasSchedule = 0
ORDER BY SqlInstance;
GO

-- 5c. Jobs that have never run (enabled, has a schedule, but LastRunDate is NULL)
SELECT
    SqlInstance,
    ServerGroup,
    JobName,
    CategoryName,
    NextRunDate
FROM dbo.vw_LatestAgentJobs
WHERE IsEnabled  = 1
  AND HasSchedule = 1
  AND LastRunDate IS NULL
ORDER BY SqlInstance;
GO


-- ============================================================
-- SECTION 6: COLLECTION HEALTH
-- ============================================================

-- 6a. Servers that were unreachable or failed on their most recent attempt
SELECT
    SqlInstance,
    ServerGroup,
    Status,
    ErrorMessage,
    CollectionEnd AS LastAttempt
FROM dbo.vw_LatestAttempt
WHERE Status IN ('Unreachable', 'Failed')
ORDER BY ServerGroup, SqlInstance;
GO

-- 6b. Collection run history — success/failure counts per day
SELECT
    CAST(CollectionEnd AS DATE)          AS RunDate,
    COUNT(*)                             AS TotalServers,
    SUM(CASE WHEN Status = 'Success'     THEN 1 ELSE 0 END) AS Succeeded,
    SUM(CASE WHEN Status = 'Failed'      THEN 1 ELSE 0 END) AS Failed,
    SUM(CASE WHEN Status = 'Unreachable' THEN 1 ELSE 0 END) AS Unreachable
FROM dbo.CollectionLog
GROUP BY CAST(CollectionEnd AS DATE)
ORDER BY RunDate DESC;
GO

-- 6c. Servers that have never had a successful collection
SELECT DISTINCT
    SqlInstance,
    ServerGroup
FROM dbo.CollectionLog
WHERE SqlInstance NOT IN (
    SELECT SqlInstance FROM dbo.CollectionLog WHERE Status = 'Success'
)
ORDER BY ServerGroup, SqlInstance;
GO


-- ============================================================
-- SECTION 7: DISCOVERY (AD SPN)
-- ============================================================

-- 7a. Instances found in Active Directory but NOT registered in CMS —
--     these exist on the domain but are not being inventoried.
--     Review each one: register it in a CMS group, or record why not
--     in the Notes column.
SELECT
    SqlInstance,
    ComputerName,
    InstanceName,
    Port,
    FirstSeen,
    LastSeen
FROM dbo.vw_UnregisteredInstances
ORDER BY FirstSeen DESC;
GO

-- 7b. Everything discovery has ever seen, including stale entries
--     (LastSeen > 30 days ago usually means decommissioned)
SELECT
    SqlInstance,
    IsRegisteredInCMS,
    FirstSeen,
    LastSeen,
    DATEDIFF(DAY, LastSeen, GETDATE()) AS DaysSinceSeen,
    Notes
FROM dbo.DiscoveredInstances
ORDER BY LastSeen DESC;
GO

-- 7c. Record a reason for intentionally not inventorying an instance
--     (it will keep appearing in 7a until registered or noted)
/*
UPDATE dbo.DiscoveredInstances
SET Notes = 'Vendor-managed appliance — no access'
WHERE SqlInstance = 'SOMEHOST\SOMEINSTANCE';
*/
GO
