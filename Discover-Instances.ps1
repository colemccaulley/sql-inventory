#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers SQL Server instances via Active Directory Service Principal
    Names (SPNs) and records them in DBAInventory.dbo.DiscoveredInstances,
    flagging any that are not registered in CMS.

.DESCRIPTION
    Every domain-joined SQL Server running under a domain account (or the
    machine account) registers MSSQLSvc/* SPNs in Active Directory. Reading
    them is a standard, read-only LDAP directory query — it does NOT probe,
    ping, or port-scan any server on the network. This is the safe way to
    answer "are there SQL Servers out there we aren't inventorying?"

    Discovered instances are upserted into dbo.DiscoveredInstances. Each is
    compared against the CMS registered-servers list; anything not found is
    flagged IsRegisteredInCMS = 0 and surfaces on the dashboard and in
    dbo.vw_UnregisteredInstances for review. Nothing is connected to or
    collected from automatically — a DBA decides whether to register it.

.NOTES
    - PowerShell 5.1 compatible; uses System.DirectoryServices directly,
      so the RSAT ActiveDirectory module is NOT required.
    - Requires only ordinary domain-user read access to AD.
    - SPN gaps: instances running under local accounts without SPNs, or in
      untrusted domains, won't appear here. This finds the common case.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ─────────────────────────────────────────────────────────────
$CMSInstance  = $env:COMPUTERNAME
$InventoryDB  = 'DBAInventory'
$LogDirectory = 'C:\DBA\Inventory\Logs'
# ──────────────────────────────────────────────────────────────────────────────

Import-Module dbatools -ErrorAction Stop

if (-not (Test-Path -Path $LogDirectory)) {
    $null = New-Item -ItemType Directory -Path $LogDirectory -Force
}

$LogFile = Join-Path $LogDirectory "Discovery_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Output $entry
}

# Short uppercase hostname: "sqlprod01.corp.local" -> "SQLPROD01"
function Get-ShortHost {
    param([string]$HostName)
    return ($HostName -split '\.')[0].ToUpperInvariant()
}

Write-Log '======= AD SPN discovery started ======='

# ── 1. Query AD for MSSQLSvc SPNs (read-only LDAP search) ─────────────────────
$spns = @()
try {
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter   = '(servicePrincipalName=MSSQLSvc/*)'
    $searcher.PageSize = 1000
    $null = $searcher.PropertiesToLoad.Add('servicePrincipalName')

    foreach ($result in $searcher.FindAll()) {
        foreach ($spn in $result.Properties['serviceprincipalname']) {
            if ($spn -like 'MSSQLSvc/*') { $spns += $spn }
        }
    }
}
catch {
    Write-Log "AD query failed (is this machine domain-joined?): $($_.Exception.Message)" -Level ERROR
    exit 1
}

Write-Log "Found $($spns.Count) MSSQLSvc SPN entries in Active Directory"

# ── 2. Parse SPNs into candidate instances ────────────────────────────────────
# SPN forms:
#   MSSQLSvc/host.fqdn            -> default instance
#   MSSQLSvc/host.fqdn:1433       -> default instance
#   MSSQLSvc/host.fqdn:INSTANCE   -> named instance
#   MSSQLSvc/host.fqdn:49152      -> a port; usually the same named instance's
#                                    port SPN, so only kept when the host has
#                                    no named-instance SPN to attribute it to.
$hosts = @{}   # shortHost -> @{ HasDefault; NamedInstances (hashtable-as-set); Ports (hashtable-as-set) }

foreach ($spn in $spns) {
    $body  = $spn.Substring('MSSQLSvc/'.Length)
    $parts = $body -split ':', 2
    $hostShort = Get-ShortHost $parts[0]
    if ([string]::IsNullOrWhiteSpace($hostShort)) { continue }

    if (-not $hosts.ContainsKey($hostShort)) {
        $hosts[$hostShort] = @{ HasDefault = $false; NamedInstances = @{}; Ports = @{} }
    }
    $entry = $hosts[$hostShort]

    if ($parts.Count -eq 1 -or [string]::IsNullOrWhiteSpace($parts[1])) {
        $entry.HasDefault = $true
    }
    elseif ($parts[1] -match '^\d+$') {
        if ([int]$parts[1] -eq 1433) { $entry.HasDefault = $true }
        else                         { $entry.Ports[[int]$parts[1]] = $true }
    }
    else {
        $entry.NamedInstances[$parts[1].ToUpperInvariant()] = $true
    }
}

$candidates = foreach ($hostShort in $hosts.Keys) {
    $entry = $hosts[$hostShort]

    if ($entry.HasDefault) {
        [PSCustomObject]@{
            SqlInstance  = $hostShort
            ComputerName = $hostShort
            InstanceName = 'MSSQLSERVER'
            Port         = 1433
        }
    }
    foreach ($inst in $entry.NamedInstances.Keys) {
        [PSCustomObject]@{
            SqlInstance  = "$hostShort\$inst"
            ComputerName = $hostShort
            InstanceName = $inst
            Port         = $null
        }
    }
    # Orphan ports: only meaningful when there's nothing to attribute them to
    if ($entry.NamedInstances.Count -eq 0 -and -not $entry.HasDefault) {
        foreach ($port in $entry.Ports.Keys) {
            [PSCustomObject]@{
                SqlInstance  = "$hostShort,$port"
                ComputerName = $hostShort
                InstanceName = $null
                Port         = $port
            }
        }
    }
}

Write-Log "Parsed $(@($candidates).Count) distinct SQL Server instances from SPNs"

# ── 3. Build the set of CMS-registered instances for comparison ──────────────
$registeredKeys = @{}
try {
    $regServers = Get-DbaRegServer -SqlInstance $CMSInstance -EnableException
    foreach ($reg in $regServers) {
        # Normalize "host.fqdn\INSTANCE,port" down to "HOST\INSTANCE"
        $name = ($reg.ServerName -split ',')[0]
        $segs = $name -split '\\', 2
        $key  = Get-ShortHost $segs[0]
        if ($segs.Count -eq 2) { $key = "$key\$($segs[1].ToUpperInvariant())" }
        $registeredKeys[$key] = $true
    }
    Write-Log "CMS has $($registeredKeys.Count) registered instances"
}
catch {
    Write-Log "Could not read CMS registered servers: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# ── 4. Upsert into dbo.DiscoveredInstances ────────────────────────────────────
$mergeQuery = @"
MERGE dbo.DiscoveredInstances AS t
USING (SELECT @SqlInstance AS SqlInstance) AS s
    ON t.SqlInstance = s.SqlInstance
WHEN MATCHED THEN UPDATE SET
    ComputerName      = @ComputerName,
    InstanceName      = @InstanceName,
    Port              = @Port,
    IsRegisteredInCMS = @IsRegistered,
    LastSeen          = GETDATE()
WHEN NOT MATCHED THEN INSERT
    (SqlInstance, ComputerName, InstanceName, Port, IsRegisteredInCMS)
VALUES
    (@SqlInstance, @ComputerName, @InstanceName, @Port, @IsRegistered);
"@

$unregistered = 0
foreach ($candidate in $candidates) {

    $key = if ($candidate.InstanceName -and $candidate.InstanceName -ne 'MSSQLSERVER') {
        "$($candidate.ComputerName)\$($candidate.InstanceName)"
    } else {
        $candidate.ComputerName
    }
    $isRegistered = $registeredKeys.ContainsKey($key)
    if (-not $isRegistered) { $unregistered++ }

    $sqlParams = @{
        SqlInstance  = $candidate.SqlInstance
        ComputerName = $candidate.ComputerName
        InstanceName = if ($candidate.InstanceName) { $candidate.InstanceName } else { [System.DBNull]::Value }
        Port         = if ($null -ne $candidate.Port) { $candidate.Port } else { [System.DBNull]::Value }
        IsRegistered = $isRegistered
    }

    try {
        Invoke-DbaQuery -SqlInstance $CMSInstance -Database $InventoryDB `
                        -Query $mergeQuery -SqlParameter $sqlParams -EnableException
    }
    catch {
        Write-Log "Upsert failed for $($candidate.SqlInstance): $($_.Exception.Message)" -Level ERROR
    }
}

Write-Log "======= Discovery complete: $(@($candidates).Count) instances seen | $unregistered not registered in CMS ======="
