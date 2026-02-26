-- ============================================================
-- Create-AgentJob.sql
-- Creates the SQL Agent job that runs the inventory collection
-- script on a weekly schedule (Sunday at 2:00 AM).
--
-- Run on the CMS instance after deploying:
--   1. Create-InventoryDB.sql
--   2. Collect-Inventory.ps1 -> C:\DBA\Inventory\
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
    @description           = N'Weekly collection of SQL Server inventory data (instance properties, databases, agent jobs) from CMS-registered server groups PROD, DEV, and Manufacturing. Results stored in DBAInventory.',
    @category_name         = N'Database Maintenance',
    @notify_level_eventlog = 2;   -- Write to Windows Event Log on failure
GO

-- ── Add Job Step ──────────────────────────────────────────────────────────────
-- Uses CmdExec (not the PowerShell subsystem) to invoke a full PS 5.1
-- environment with dbatools available. The PowerShell subsystem uses
-- sqlps which is incompatible with dbatools.
EXEC msdb.dbo.sp_add_jobstep
    @job_name          = N'DBA - SQL Inventory Collection',
    @step_name         = N'Run Inventory Collection',
    @subsystem         = N'CmdExec',
    @command           = N'powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\DBA\Inventory\Collect-Inventory.ps1"',
    @on_success_action = 1,   -- Quit with success
    @on_fail_action    = 2;   -- Quit with failure
GO

-- ── Add Weekly Schedule (Sunday 02:00 AM) ─────────────────────────────────────
-- freq_type 8        = Weekly
-- freq_interval 1    = Sunday (bitmask: Sun=1, Mon=2, Tue=4, Wed=8, Thu=16, Fri=32, Sat=64)
-- active_start_time  = 020000 (HHMMSS as integer, no leading zero needed for midnight-range)
EXEC msdb.dbo.sp_add_jobschedule
    @job_name               = N'DBA - SQL Inventory Collection',
    @name                   = N'Weekly - Sunday 2AM',
    @enabled                = 1,
    @freq_type              = 8,
    @freq_interval          = 1,
    @freq_recurrence_factor = 1,
    @freq_subday_type       = 1,    -- Once per day
    @freq_subday_interval   = 0,
    @active_start_time      = 20000; -- 02:00:00 AM
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
    js.step_name                                   AS StepName,
    js.subsystem                                   AS Subsystem,
    s.name                                         AS ScheduleName,
    CASE s.freq_type WHEN 8 THEN 'Weekly' END      AS Frequency,
    RIGHT('000000' + CAST(s.active_start_time AS VARCHAR(6)), 6) AS StartTime_HHMMSS
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps      js  ON j.job_id = js.job_id
JOIN msdb.dbo.sysjobschedules  jsc ON j.job_id = jsc.job_id
JOIN msdb.dbo.sysschedules     s   ON jsc.schedule_id = s.schedule_id
WHERE j.name = N'DBA - SQL Inventory Collection';
GO
