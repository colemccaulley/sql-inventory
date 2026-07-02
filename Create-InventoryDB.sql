-- ============================================================
-- Create-InventoryDB.sql
-- Creates (or upgrades) the DBAInventory database and all
-- collection tables. Safe to re-run: existing tables are kept
-- and missing columns/tables/indexes are added in place.
-- Run on the CMS instance before executing the Agent job.
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CollectionLog_Instance' AND object_id = OBJECT_ID('dbo.CollectionLog'))
    CREATE INDEX IX_CollectionLog_Instance ON dbo.CollectionLog (SqlInstance, Status) INCLUDE (CollectionEnd);
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

-- v2 columns (added in place when upgrading an existing install)
IF COL_LENGTH('dbo.InstanceProperties', 'VersionMajor') IS NULL
    ALTER TABLE dbo.InstanceProperties ADD VersionMajor INT NULL;
IF COL_LENGTH('dbo.InstanceProperties', 'CPUCount') IS NULL
    ALTER TABLE dbo.InstanceProperties ADD CPUCount INT NULL;
IF COL_LENGTH('dbo.InstanceProperties', 'PhysicalMemoryMB') IS NULL
    ALTER TABLE dbo.InstanceProperties ADD PhysicalMemoryMB INT NULL;
IF COL_LENGTH('dbo.InstanceProperties', 'ServiceAccount') IS NULL
    ALTER TABLE dbo.InstanceProperties ADD ServiceAccount NVARCHAR(256) NULL;
IF COL_LENGTH('dbo.InstanceProperties', 'AuthenticationMode') IS NULL
    ALTER TABLE dbo.InstanceProperties ADD AuthenticationMode NVARCHAR(50) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_InstanceProperties_Collection' AND object_id = OBJECT_ID('dbo.InstanceProperties'))
    CREATE INDEX IX_InstanceProperties_Collection ON dbo.InstanceProperties (CollectionID);
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Databases_Collection' AND object_id = OBJECT_ID('dbo.Databases'))
    CREATE INDEX IX_Databases_Collection ON dbo.Databases (CollectionID) INCLUDE (DatabaseName, SizeMB);
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

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AgentJobs_Collection' AND object_id = OBJECT_ID('dbo.AgentJobs'))
    CREATE INDEX IX_AgentJobs_Collection ON dbo.AgentJobs (CollectionID);
GO

-- ============================================================
-- dbo.DiskSpace
-- One row per volume per collection run (best effort — requires
-- WMI/CIM access to the host; rows are absent when unavailable).
-- ============================================================
IF OBJECT_ID('dbo.DiskSpace', 'U') IS NULL
CREATE TABLE dbo.DiskSpace
(
    ID           INT           IDENTITY(1,1) NOT NULL,
    CollectionID INT           NOT NULL,
    SqlInstance  NVARCHAR(256) NOT NULL,
    ComputerName NVARCHAR(256) NULL,
    Volume       NVARCHAR(256) NOT NULL,
    Label        NVARCHAR(256) NULL,
    CapacityGB   DECIMAL(18,2) NULL,
    FreeGB       DECIMAL(18,2) NULL,
    PercentFree  DECIMAL(5,2)  NULL,
    CollectedAt  DATETIME      NOT NULL DEFAULT GETDATE(),
    CONSTRAINT PK_DiskSpace PRIMARY KEY (ID),
    CONSTRAINT FK_DiskSpace_Log
        FOREIGN KEY (CollectionID) REFERENCES dbo.CollectionLog (CollectionID)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DiskSpace_Collection' AND object_id = OBJECT_ID('dbo.DiskSpace'))
    CREATE INDEX IX_DiskSpace_Collection ON dbo.DiskSpace (CollectionID);
GO

-- ============================================================
-- dbo.DiscoveredInstances
-- Instances found via Active Directory SPN lookup (read-only
-- directory query — no network scanning). One row per instance;
-- Discover-Instances.ps1 upserts and stamps LastSeen.
-- IsRegisteredInCMS = 0 highlights instances that exist in AD
-- but are not yet in a CMS group (i.e. not being inventoried).
-- ============================================================
IF OBJECT_ID('dbo.DiscoveredInstances', 'U') IS NULL
CREATE TABLE dbo.DiscoveredInstances
(
    DiscoveryID       INT           IDENTITY(1,1) NOT NULL,
    SqlInstance       NVARCHAR(256) NOT NULL,
    ComputerName      NVARCHAR(256) NULL,
    InstanceName      NVARCHAR(256) NULL,
    Port              INT           NULL,
    Source            NVARCHAR(50)  NOT NULL DEFAULT 'AD SPN',
    IsRegisteredInCMS BIT           NOT NULL DEFAULT 0,
    FirstSeen         DATETIME      NOT NULL DEFAULT GETDATE(),
    LastSeen          DATETIME      NOT NULL DEFAULT GETDATE(),
    Notes             NVARCHAR(MAX) NULL,
    CONSTRAINT PK_DiscoveredInstances PRIMARY KEY (DiscoveryID),
    CONSTRAINT UQ_DiscoveredInstances_Instance UNIQUE (SqlInstance)
);
GO

-- ============================================================
-- Verify
-- ============================================================
SELECT
    t.name           AS TableName,
    p.rows           AS [RowCount]
FROM sys.tables t
JOIN sys.partitions p
    ON t.object_id = p.object_id
   AND p.index_id IN (0, 1)
WHERE t.schema_id = SCHEMA_ID('dbo')
ORDER BY t.name;
GO
