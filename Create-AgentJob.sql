-- ============================================================
-- Create-AgentJob.sql
-- Creates the SQL Agent job that runs the inventory pipeline
-- daily at 6:00 AM:
--   Step 1: Collect inventory from CMS-registered servers
--   Step 2: Discover instances via AD SPNs (continues on failure)
--   Step 3: Export the HTML dashboard
--
-- Run on the CMS instance after deploying:
--   1. Create-InventoryDB.sql
--   2. Create-InventoryViews.sql
--   3. Collect-Inventory.ps1, Discover-Instances.ps1,
--      Export-Dashboard.ps1 -> C:\DBA\Inventory\
-- ============================================================

USE msdb;
GO

-- ── Drop existing job if re-running ───────────────────────────────────────────
IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - SQL Inventory Collection'
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name              = N'DBA - SQL Inventory Collection',
        @delete_unused_schedule = 1;
END
GO

-- ── Create Job ────────────────────────────────────────────────────────────────
EXEC msdb.dbo.sp_add_job
    @job_name              = N'DBA - SQL Inventory Collection',
    @enabled               = 1,
    @description           = N'Daily SQL Server estate pipeline: collects inventory (instance properties, databases, agent jobs, disk space) from CMS-registered server groups into DBAInventory, refreshes AD SPN discovery, and regenerates the HTML estate dashboard.',
    @category_name         = N'Database Maintenance',
    @notify_level_eventlog = 2;   -- Write to Windows Event Log on failure
GO

-- ── Job Steps ─────────────────────────────────────────────────────────────────
-- Uses CmdExec (not the PowerShell subsystem) to invoke a full PS 5.1
-- environment with dbatools available. The PowerShell subsystem uses
-- sqlps which is incompatible with dbatools.

-- Step 1: Collect inventory
EXEC msdb.dbo.sp_add_jobstep
    @job_name          = N'DBA - SQL Inventory Collection',
    @step_id           = 1,
    @step_name         = N'Collect Inventory',
    @subsystem         = N'CmdExec',
    @command           = N'powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\DBA\Inventory\Collect-Inventory.ps1"',
    @on_success_action = 3,   -- Go to next step
    @on_fail_action    = 2;   -- Quit with failure
GO

-- Step 2: AD SPN discovery. Failure here (e.g. transient AD issue) should
-- not block the dashboard, so it continues to the next step either way.
EXEC msdb.dbo.sp_add_jobstep
    @job_name          = N'DBA - SQL Inventory Collection',
    @step_id           = 2,
    @step_name         = N'Discover Instances (AD SPN)',
    @subsystem         = N'CmdExec',
    @command           = N'powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\DBA\Inventory\Discover-Instances.ps1"',
    @on_success_action = 3,   -- Go to next step
    @on_fail_action    = 3;   -- Go to next step anyway
GO

-- Step 3: Regenerate the dashboard from the freshly collected data
EXEC msdb.dbo.sp_add_jobstep
    @job_name          = N'DBA - SQL Inventory Collection',
    @step_id           = 3,
    @step_name         = N'Export Dashboard',
    @subsystem         = N'CmdExec',
    @command           = N'powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\DBA\Inventory\Export-Dashboard.ps1"',
    @on_success_action = 1,   -- Quit with success
    @on_fail_action    = 2;   -- Quit with failure
GO

-- ── Daily Schedule (06:00 AM) ─────────────────────────────────────────────────
-- freq_type 4       = Daily
-- freq_interval 1   = every 1 day
-- active_start_time = HHMMSS as integer
EXEC msdb.dbo.sp_add_jobschedule
    @job_name               = N'DBA - SQL Inventory Collection',
    @name                   = N'Daily - 6AM',
    @enabled                = 1,
    @freq_type              = 4,
    @freq_interval          = 1,
    @freq_subday_type       = 1,    -- Once per day
    @freq_subday_interval   = 0,
    @active_start_time      = 60000; -- 06:00:00 AM
GO

-- ── Target local server ───────────────────────────────────────────────────────
EXEC msdb.dbo.sp_add_jobserver
    @job_name    = N'DBA - SQL Inventory Collection',
    @server_name = N'(local)';
GO

-- ── Verify ────────────────────────────────────────────────────────────────────
SELECT
    j.name                                         AS JobName,
    j.enabled                                      AS IsEnabled,
    js.step_id                                     AS StepId,
    js.step_name                                   AS StepName,
    js.subsystem                                   AS Subsystem,
    s.name                                         AS ScheduleName,
    CASE s.freq_type WHEN 4 THEN 'Daily' WHEN 8 THEN 'Weekly' END AS Frequency,
    RIGHT('000000' + CAST(s.active_start_time AS VARCHAR(6)), 6) AS StartTime_HHMMSS
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps      js  ON j.job_id = js.job_id
JOIN msdb.dbo.sysjobschedules  jsc ON j.job_id = jsc.job_id
JOIN msdb.dbo.sysschedules     s   ON jsc.schedule_id = s.schedule_id
WHERE j.name = N'DBA - SQL Inventory Collection'
ORDER BY js.step_id;
GO
