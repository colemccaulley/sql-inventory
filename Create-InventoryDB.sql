-- ============================================================
-- Create-InventoryDB.sql
-- Creates the DBAInventory database and all collection tables.
-- Run once on the CMS instance before executing the Agent job.
-- ============================================================

USE master;
GO

IF DB_ID('DBAInventory') IS NULL
    CREATE DATABASE DBAInventory;
GO

USE DBAInventory;
GO

-- ============================================================
-- dbo.CollectionLog
-- One row per server per collection run. Status: Success | Failed | Unreachable
-- ============================================================
IF OBJECT_ID('dbo.CollectionLog', 'U') IS NULL
CREATE TABLE dbo.CollectionLog
(
    CollectionID    INT           IDENTITY(1,1) NOT NULL,
    SqlInstance     NVARCHAR(256) NOT NULL,
    ServerGroup     NVARCHAR(256) NULL,
    CollectionStart DATETIME      NOT NULL,
    CollectionEnd   DATETIME      NULL,
    Status          NVARCHAR(50)  NOT NULL,
    ErrorMessage    NVARCHAR(MAX) NULL,
    CONSTRAINT PK_CollectionLog PRIMARY KEY (CollectionID)
);
GO

-- ============================================================
-- dbo.InstanceProperties
-- Core instance-level metadata per collection run.
-- ============================================================
IF OBJECT_ID('dbo.InstanceProperties', 'U') IS NULL
CREATE TABLE dbo.InstanceProperties
(
    ID                          INT           IDENTITY(1,1) NOT NULL,
    CollectionID                INT           NOT NULL,
    SqlInstance                 NVARCHAR(256) NOT NULL,
    ServerGroup                 NVARCHAR(256) NULL,
    ComputerName                NVARCHAR(256) NULL,
    InstanceName                NVARCHAR(256) NULL,
    SQLVersion                  NVARCHAR(256) NULL,
    Edition                     NVARCHAR(256) NULL,
    ProductLevel                NVARCHAR(256) NULL,
    ProductUpdateLevel          NVARCHAR(256) NULL,
    Collation                   NVARCHAR(256) NULL,
    MaxServerMemoryMB           INT           NULL,
    MAXDOP                      INT           NULL,
    CostThresholdForParallelism INT           NULL,
    IsClustered                 BIT           NULL,
    IsHadrEnabled               BIT           NULL,
    OSVersion                   NVARCHAR(256) NULL,
    CollectedAt                 DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_InstanceProperties PRIMARY KEY (ID),
    CONSTRAINT FK_InstanceProperties_Log
        FOREIGN KEY (CollectionID) REFERENCES dbo.CollectionLog (CollectionID)
);
GO

-- ============================================================
-- dbo.Databases
-- One row per database per collection run.
-- ============================================================
IF OBJECT_ID('dbo.Databases', 'U') IS NULL
CREATE TABLE dbo.Databases
(
    ID                  INT           IDENTITY(1,1) NOT NULL,
    CollectionID        INT           NOT NULL,
    SqlInstance         NVARCHAR(256) NOT NULL,
    ServerGroup         NVARCHAR(256) NULL,
    DatabaseName        NVARCHAR(256) NOT NULL,
    Status              NVARCHAR(50)  NULL,
    SizeMB              DECIMAL(18,2) NULL,
    RecoveryModel       NVARCHAR(20)  NULL,
    CompatibilityLevel  INT           NULL,
    LastFullBackup      DATETIME      NULL,
    LastDiffBackup      DATETIME      NULL,
    LastLogBackup       DATETIME      NULL,
    Owner               NVARCHAR(256) NULL,
    IsReadOnly          BIT           NULL,
    CreateDate          DATETIME      NULL,
    CollationName       NVARCHAR(256) NULL,
    CollectedAt         DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_Databases PRIMARY KEY (ID),
    CONSTRAINT FK_Databases_Log
        FOREIGN KEY (CollectionID) REFERENCES dbo.CollectionLog (CollectionID)
);
GO

-- ============================================================
-- dbo.AgentJobs
-- One row per Agent job per collection run.
-- ============================================================
IF OBJECT_ID('dbo.AgentJobs', 'U') IS NULL
CREATE TABLE dbo.AgentJobs
(
    ID             INT           IDENTITY(1,1) NOT NULL,
    CollectionID   INT           NOT NULL,
    SqlInstance    NVARCHAR(256) NOT NULL,
    ServerGroup    NVARCHAR(256) NULL,
    JobName        NVARCHAR(256) NOT NULL,
    IsEnabled      BIT           NULL,
    CategoryName   NVARCHAR(256) NULL,
    Description    NVARCHAR(MAX) NULL,
    LastRunDate    DATETIME      NULL,
    LastRunOutcome NVARCHAR(50)  NULL,
    NextRunDate    DATETIME      NULL,
    HasSchedule    BIT           NULL,
    CollectedAt    DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_AgentJobs PRIMARY KEY (ID),
    CONSTRAINT FK_AgentJobs_Log
        FOREIGN KEY (CollectionID) REFERENCES dbo.CollectionLog (CollectionID)
);
GO

-- ============================================================
-- Verify
-- ============================================================
SELECT
    t.name           AS TableName,
    p.rows           AS RowCount
FROM sys.tables t
JOIN sys.partitions p
    ON t.object_id = p.object_id
   AND p.index_id IN (0, 1)
WHERE t.schema_id = SCHEMA_ID('dbo')
ORDER BY t.name;
GO
