<#
.SYNOPSIS
    One-time remediation of a bloated/unmaintained WSUS database (SUSDB).

.DESCRIPTION
    Fixes the timeout that hits Invoke-WsusServerCleanup -CleanupObsoleteUpdates on a
    neglected WSUS server, by working directly against SUSDB:
      Phase 0  Create the two missing indexes that make spDeleteUpdate fast (idempotent).
      Phase 1  Reindex SUSDB (ALTER INDEX ... REBUILD).
      Phase 2  Delete obsolete updates ONE BY ONE via spGetObsoleteUpdatesToCleanup +
               spDeleteUpdate, looping until none remain. Each delete is its own
               transaction, so there is no global timeout and the run is resumable.
    Reports SUSDB size before/after.

    Run LOCALLY on the WSUS server, as administrator, in a maintenance window. SUSDB on
    Windows Internal Database (WID) is only reachable locally.

.PARAMETER ConnectionString
    SUSDB connection string. Default targets WID. For a full SQL Server instance, e.g.:
    "Server=SQLHOST\INSTANCE;Database=SUSDB;Integrated Security=True;".
.PARAMETER SkipReindex          Skip the reindex phase.
.PARAMETER SkipDeleteObsolete   Skip the obsolete-update deletion phase.

.EXAMPLE
    .\Repair-WsusDatabase.ps1
.EXAMPLE
    .\Repair-WsusDatabase.ps1 -SkipReindex
.NOTES
    Project: WSUS Toolkit. License: MIT.
#>

[CmdletBinding()]
param(
    [string] $ConnectionString = 'Server=np:\\.\pipe\MICROSOFT##WID\tsql\query;Database=SUSDB;Integrated Security=True;',
    [switch] $SkipReindex,
    [switch] $SkipDeleteObsolete
)

$ErrorActionPreference = 'Stop'

function Invoke-SusdbNonQuery {
    param([System.Data.SqlClient.SqlConnection]$Connection, [string]$Sql, [int]$Timeout = 0)
    $cmd = $Connection.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = $Timeout
    return $cmd.ExecuteNonQuery()
}
function Get-SusdbSnapshot {
    param([System.Data.SqlClient.SqlConnection]$Connection)
    $a = $Connection.CreateCommand()
    $a.CommandText = "SELECT CAST(SUM(CAST(size AS BIGINT)) * 8 / 1024.0 AS DECIMAL(12,2)) FROM sys.database_files"
    $a.CommandTimeout = 120; $alloc = [decimal]$a.ExecuteScalar()
    $u = $Connection.CreateCommand()
    $u.CommandText = "SELECT CAST(SUM(CAST(used_pages AS BIGINT)) * 8 / 1024.0 AS DECIMAL(12,2)) FROM sys.allocation_units"
    $u.CommandTimeout = 120; $used = [decimal]$u.ExecuteScalar()
    return [PSCustomObject]@{ AllocatedMB = $alloc; UsedMB = $used }
}

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = $ConnectionString

try {
    Write-Output "=== SUSDB REMEDIATION : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    $conn.Open(); Write-Output 'Connected to SUSDB.'

    $before = Get-SusdbSnapshot -Connection $conn
    Write-Output ("SUSDB before: allocated {0} MB / used {1} MB" -f $before.AllocatedMB, $before.UsedMB)

    # --- Phase 0: acceleration indexes (always; idempotent) ---
    Write-Output '--- Phase 0: acceleration indexes for spDeleteUpdate ---'
    $indexSql = @"
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tbRevisionSupersedesUpdate')
    CREATE NONCLUSTERED INDEX IX_tbRevisionSupersedesUpdate
        ON dbo.tbRevisionSupersedesUpdate(SupersededUpdateID);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tbLocalizedPropertyForRevision')
    CREATE NONCLUSTERED INDEX IX_tbLocalizedPropertyForRevision
        ON dbo.tbLocalizedPropertyForRevision(LocalizedPropertyID);
"@
    Invoke-SusdbNonQuery -Connection $conn -Sql $indexSql -Timeout 0 | Out-Null
    Write-Output 'Acceleration indexes present.'

    # --- Phase 1: reindex ---
    if (-not $SkipReindex) {
        Write-Output '--- Phase 1: reindex SUSDB ---'
        $reindexSql = @"
DECLARE @stmt NVARCHAR(MAX);
DECLARE idx_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT N'ALTER INDEX ALL ON [' + s.name + N'].[' + t.name + N'] REBUILD'
    FROM sys.indexes i
    JOIN sys.tables  t ON i.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE i.index_id > 0;
OPEN idx_cursor; FETCH NEXT FROM idx_cursor INTO @stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_executesql @stmt; END TRY
    BEGIN CATCH PRINT 'Skipped: ' + @stmt + ' (' + ERROR_MESSAGE() + ')'; END CATCH
    FETCH NEXT FROM idx_cursor INTO @stmt;
END
CLOSE idx_cursor; DEALLOCATE idx_cursor;
"@
        Invoke-SusdbNonQuery -Connection $conn -Sql $reindexSql -Timeout 0 | Out-Null
        Write-Output 'Reindex complete.'
    } else { Write-Output '--- Phase 1: reindex SKIPPED ---' }

    # --- Phase 2: delete obsolete updates (loop until none remain) ---
    if (-not $SkipDeleteObsolete) {
        Write-Output '--- Phase 2: delete obsolete updates (loop until 0) ---'
        $grandOk = 0; $grandKo = 0; $pass = 0; $maxPasses = 50
        do {
            $pass++
            $get = $conn.CreateCommand(); $get.CommandText = 'EXEC spGetObsoleteUpdatesToCleanup'; $get.CommandTimeout = 0
            $reader = $get.ExecuteReader()
            $ids = New-Object System.Collections.Generic.List[int]
            while ($reader.Read()) { $ids.Add([int]$reader.GetValue(0)) }
            $reader.Close()
            $total = $ids.Count
            Write-Output "Pass $pass : $total obsolete update(s)."
            if ($total -eq 0) { break }
            $n = 0; $ok = 0; $ko = 0
            foreach ($id in $ids) {
                $n++
                try {
                    $del = $conn.CreateCommand(); $del.CommandText = "EXEC spDeleteUpdate @localUpdateID=$id"; $del.CommandTimeout = 600
                    $del.ExecuteNonQuery() | Out-Null; $ok++
                } catch { $ko++; if ($ko -le 10) { Write-Warning "spDeleteUpdate failed for ID $id : $_" } }
                if ($n % 200 -eq 0) { Write-Output "  ... $n / $total" }
            }
            Write-Output "  Pass $pass done: $ok deleted, $ko failed."
            $grandOk += $ok; $grandKo += $ko
        } while ($total -gt 0 -and $pass -lt $maxPasses)
        Write-Output "Obsolete cleanup: $grandOk deleted, $grandKo failed over $pass pass(es)."
        if ($pass -ge $maxPasses) { Write-Warning "Reached $maxPasses passes; run again to finish." }
    } else { Write-Output '--- Phase 2: deletion SKIPPED ---' }

    $after = Get-SusdbSnapshot -Connection $conn
    Write-Output ''
    Write-Output '--- SUSDB summary ---'
    Write-Output ("  Allocated (file) : {0} MB -> {1} MB" -f $before.AllocatedMB, $after.AllocatedMB)
    Write-Output ("  Used (data)      : {0} MB -> {1} MB  (freed {2} MB)" -f `
        $before.UsedMB, $after.UsedMB, [Math]::Round($before.UsedMB - $after.UsedMB, 2))
    Write-Output '  Note: allocated file size does not shrink automatically; freed space is reused by WSUS.'
    Write-Output "=== DONE : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Write-Output ''
    Write-Output '>>> Next: free disk space with the native cleanup (now fast):'
    Write-Output '    Invoke-WsusServerCleanup -CleanupUnneededContentFiles -CleanupObsoleteComputers -DeclineExpiredUpdates'
}
catch { Write-Error "FATAL: $_"; exit 1 }
finally {
    if ($conn.State -eq 'Open') { $conn.Close() }
    $conn.Dispose()
}
