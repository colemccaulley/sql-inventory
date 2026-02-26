# SQL Server Inventory

A lightweight DBA toolset for automatically collecting and reporting on SQL Server estate data across multiple instances managed via a Central Management Server (CMS).

## Overview

This solution uses the [dbatools](https://dbatools.io/) PowerShell module to collect instance-level metadata, database details, and SQL Agent job status from CMS-registered server groups. Data is stored in a dedicated `DBAInventory` SQL Server database and can be queried using the included reporting scripts.

## Files

| File | Description |
|------|-------------|
| `Create-InventoryDB.sql` | Creates the `DBAInventory` database and all tables. Run once before first use. |
| `Create-AgentJob.sql` | Creates a SQL Agent job that runs the collection script on a weekly schedule (Sundays at 2:00 AM). |
| `Collect-Inventory.ps1` | PowerShell script that queries each registered server and writes results to `DBAInventory`. |
| `Inventory-Reports.sql` | A library of reporting queries for analyzing the collected data. |

## Database Schema

All tables live in `DBAInventory.dbo` and are linked by `CollectionID`:

- **CollectionLog** — One row per server per collection run. Tracks success, failure, or unreachable status with timestamps and error messages.
- **InstanceProperties** — Instance-level metadata: SQL version, edition, patch level, memory, MAXDOP, CTFP, clustering, and HA settings.
- **Databases** — Per-database details: size, recovery model, compatibility level, backup dates, owner, and read-only status.
- **AgentJobs** — Per-job details: enabled status, last run outcome, next scheduled run, and category.

## Prerequisites

- **PowerShell 5.1** on the CMS server
- **dbatools** module installed for all users:
  ```powershell
  Install-Module dbatools -Scope AllUsers
  ```
- The SQL Agent service account must have `VIEW SERVER STATE` on all target instances.

## Setup

1. **Create the database** — Run `Create-InventoryDB.sql` on your CMS instance.
2. **Deploy the script** — Copy `Collect-Inventory.ps1` to `C:\DBA\Inventory\` on the CMS server.
3. **Configure server groups** — Edit the `$ServerGroups` array in `Collect-Inventory.ps1` to match your CMS registered server group names exactly (nested groups use backslash paths, e.g. `"ParentGroup\ChildGroup"`).
4. **Create the Agent job** — Run `Create-AgentJob.sql` on your CMS instance to create the weekly scheduled job.

## Configuration

At the top of `Collect-Inventory.ps1`, update these variables as needed:

```powershell
$CMSInstance  = $env:COMPUTERNAME   # CMS server name (or "SERVER\INSTANCE" for named instances)
$InventoryDB  = 'DBAInventory'       # Target database name
$LogDirectory = 'C:\DBA\Inventory\Logs'  # Log file output path

$ServerGroups = @(
    'PROD',
    'DEV',
    'Manufacturing'
)
```

## Running the Collection

The Agent job runs automatically every Sunday at 2:00 AM. To run manually:

```powershell
powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\DBA\Inventory\Collect-Inventory.ps1"
```

Logs are written to `C:\DBA\Inventory\Logs\` with a timestamped filename.

## Reports

`Inventory-Reports.sql` includes six sections of queries to run against `DBAInventory`:

| Section | Queries |
|---------|---------|
| 1. Inventory & Estate Overview | Server count by group/version; full instance inventory |
| 2. Version & Patch Compliance | Servers not on target CU; databases below target compatibility level |
| 3. Backup Health | Databases missing full backups in 7 days; FULL recovery model DBs missing log backups in 24 hours |
| 4. Capacity & Growth | Largest databases across the estate; size growth between collection runs |
| 5. Agent Job Health | Failed jobs; enabled jobs with no schedule; jobs that have never run |
| 6. Collection Health | Unreachable/failed servers in latest run; run history summary; servers never successfully collected |
