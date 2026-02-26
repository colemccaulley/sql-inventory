-- ============================================================
-- Inventory-Reports.sql
-- Reporting queries against the DBAInventory database.
-- Run on the CMS instance (DBAInventory must be populated first).
-- ============================================================

USE DBAInventory;
GO

-- ============================================================
-- SECTION 1: INVENTORY & ESTATE OVERVIEW
-- ============================================================

-- 1a. Server count by group and SQL version
SELECT
    ServerGroup,
    SQLVersion,
    Edition,
    COUNT(*)         AS ServerCount
FROM dbo.InstanceProperties
WHERE CollectedAt = (SELECT MAX(CollectedAt) FROM dbo.InstanceProperties)
GROUP BY ServerGroup, SQLVersion, Edition
ORDER BY ServerGroup, SQLVersion;
GO

-- 1b. Full instance inventory — latest successful run per server
SELECT
    ip.ServerGroup,
    ip.SqlInstance,
    ip.ComputerName,
    ip.InstanceName,
    ip.SQLVersion,
    ip.Edition,
    ip.ProductLevel,
    ip.ProductUpdateLevel,
    ip.Collation,
    ip.MaxServerMemoryMB,
    ip.MAXDOP,
    ip.CostThresholdForParallelism,
    ip.IsClustered,
    ip.IsHadrEnabled,
    ip.OSVersion,
    cl.Status        AS CollectionStatus,
    cl.CollectionEnd AS LastCollected
FROM dbo.InstanceProperties ip
JOIN dbo.CollectionLog cl ON ip.CollectionID = cl.CollectionID
WHERE cl.CollectionEnd = (
    SELECT MAX(cl2.CollectionEnd)
    FROM dbo.CollectionLog cl2
    WHERE cl2.SqlInstance = cl.SqlInstance
      AND cl2.Status = 'Success'
)
ORDER BY ip.ServerGroup, ip.SqlInstance;
GO


-- ============================================================
-- SECTION 2: VERSION & PATCH COMPLIANCE
-- ============================================================

-- 2a. Servers not on a target CU — edit the IN list to match your standard
SELECT
    SqlInstance,
    ServerGroup,
    SQLVersion,
    ProductLevel,
    ProductUpdateLevel
FROM dbo.InstanceProperties
WHERE ProductUpdateLevel NOT IN ('CU14', 'CU15')  -- adjust to your target
   OR ProductUpdateLevel IS NULL
ORDER BY ServerGroup, SqlInstance;
GO

-- 2b. Databases running below a target compatibility level
SELECT
    ip.SqlInstance,
    ip.ServerGroup,
    d.DatabaseName,
    d.CompatibilityLevel
FROM dbo.Databases d
JOIN dbo.CollectionLog cl         ON d.CollectionID  = cl.CollectionID
JOIN dbo.InstanceProperties ip    ON ip.CollectionID = cl.CollectionID
WHERE d.CompatibilityLevel < 150  -- adjust: 130=2016, 140=2017, 150=2019, 160=2022
ORDER BY d.CompatibilityLevel, ip.SqlInstance;
GO


-- ============================================================
-- SECTION 3: BACKUP HEALTH
-- ============================================================

-- 3a. Databases with no full backup in the last 7 days (or never backed up)
SELECT
    cl.SqlInstance,
    cl.ServerGroup,
    d.DatabaseName,
    d.RecoveryModel,
    d.LastFullBackup,
    DATEDIFF(DAY, d.LastFullBackup, GETDATE()) AS DaysSinceFullBackup
FROM dbo.Databases d
JOIN dbo.CollectionLog cl ON d.CollectionID = cl.CollectionID
WHERE (d.LastFullBackup IS NULL OR d.LastFullBackup < DATEADD(DAY, -7, GETDATE()))
  AND d.Status = 'Normal'
ORDER BY DaysSinceFullBackup DESC;
GO

-- 3b. FULL recovery model databases with no log backup in 24 hours
SELECT
    cl.SqlInstance,
    cl.ServerGroup,
    d.DatabaseName,
    d.LastLogBackup,
    DATEDIFF(HOUR, d.LastLogBackup, GETDATE()) AS HoursSinceLogBackup
FROM dbo.Databases d
JOIN dbo.CollectionLog cl ON d.CollectionID = cl.CollectionID
WHERE d.RecoveryModel = 'FULL'
  AND (d.LastLogBackup IS NULL OR d.LastLogBackup < DATEADD(HOUR, -24, GETDATE()))
  AND d.Status = 'Normal'
ORDER BY HoursSinceLogBackup DESC;
GO


-- ============================================================
-- SECTION 4: CAPACITY & GROWTH
-- ============================================================

-- 4a. Largest databases across the estate
SELECT
    cl.SqlInstance,
    cl.ServerGroup,
    d.DatabaseName,
    d.SizeMB,
    CAST(d.SizeMB / 1024.0 AS DECIMAL(10,2)) AS SizeGB
FROM dbo.Databases d
JOIN dbo.CollectionLog cl ON d.CollectionID = cl.CollectionID
WHERE cl.Status = 'Success'
ORDER BY d.SizeMB DESC;
GO

-- 4b. Database size growth — current run vs previous run
SELECT
    d.SqlInstance,
    d.DatabaseName,
    d.SizeMB                                        AS CurrentSizeMB,
    prev.SizeMB                                     AS PriorSizeMB,
    CAST(d.SizeMB - prev.SizeMB AS DECIMAL(10,2))  AS GrowthMB
FROM dbo.Databases d
JOIN dbo.CollectionLog cl      ON d.CollectionID    = cl.CollectionID
JOIN dbo.Databases prev        ON prev.SqlInstance  = d.SqlInstance
                               AND prev.DatabaseName = d.DatabaseName
JOIN dbo.CollectionLog cl_prev ON prev.CollectionID = cl_prev.CollectionID
WHERE cl.CollectionEnd = (
        SELECT MAX(CollectionEnd) FROM dbo.CollectionLog WHERE Status = 'Success'
      )
  AND cl_prev.CollectionEnd = (
        SELECT MAX(CollectionEnd)
        FROM dbo.CollectionLog
        WHERE Status = 'Success'
          AND CollectionEnd < (
                SELECT MAX(CollectionEnd) FROM dbo.CollectionLog WHERE Status = 'Success'
              )
      )
ORDER BY GrowthMB DESC;
GO


-- ============================================================
-- SECTION 5: AGENT JOB HEALTH
-- ============================================================

-- 5a. Jobs that failed on their last run
SELECT
    cl.SqlInstance,
    cl.ServerGroup,
    j.JobName,
    j.LastRunDate,
    j.LastRunOutcome
FROM dbo.AgentJobs j
JOIN dbo.CollectionLog cl ON j.CollectionID = cl.CollectionID
WHERE j.LastRunOutcome = 'Failed'
  AND cl.Status = 'Success'
ORDER BY cl.ServerGroup, cl.SqlInstance;
GO

-- 5b. Enabled jobs with no schedule attached
SELECT
    cl.SqlInstance,
    cl.ServerGroup,
    j.JobName,
    j.CategoryName
FROM dbo.AgentJobs j
JOIN dbo.CollectionLog cl ON j.CollectionID = cl.CollectionID
WHERE j.IsEnabled = 1
  AND j.HasSchedule = 0
ORDER BY cl.SqlInstance;
GO

-- 5c. Jobs that have never run (enabled, has a schedule, but LastRunDate is NULL)
SELECT
    cl.SqlInstance,
    cl.ServerGroup,
    j.JobName,
    j.CategoryName,
    j.NextRunDate
FROM dbo.AgentJobs j
JOIN dbo.CollectionLog cl ON j.CollectionID = cl.CollectionID
WHERE j.IsEnabled  = 1
  AND j.HasSchedule = 1
  AND j.LastRunDate IS NULL
ORDER BY cl.SqlInstance;
GO


-- ============================================================
-- SECTION 6: COLLECTION HEALTH
-- ============================================================

-- 6a. Servers that were unreachable or failed in the most recent run
SELECT
    SqlInstance,
    ServerGroup,
    Status,
    ErrorMessage,
    CollectionEnd AS LastAttempt
FROM dbo.CollectionLog
WHERE CollectionEnd = (SELECT MAX(CollectionEnd) FROM dbo.CollectionLog)
  AND Status IN ('Unreachable', 'Failed')
ORDER BY ServerGroup, SqlInstance;
GO

-- 6b. Collection run history — success/failure counts per run
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
