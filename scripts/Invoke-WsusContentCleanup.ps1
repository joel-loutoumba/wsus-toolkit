<#
.SYNOPSIS
    Resilient WSUS cleanup with progress: decline expired updates + remove obsolete
    computers (manual API loops), and free unneeded content files (native, isolated).

.DESCRIPTION
    Invoke-WsusServerCleanup runs each task as one opaque operation that can time out on a
    large database, with no progress. This script instead declines expired updates and
    removes obsolete computers ONE BY ONE over the API (each call is independent, so no
    global timeout, with progress every 100). Only "free content files" stays native (no
    per-item API), isolated in its own try/catch and resumable on the next run.

    Low-level obsolete-UPDATE deletion (spDeleteUpdate) is NOT done here; use
    Repair-WsusDatabase.ps1 locally for that.

.PARAMETER UpdateServer       WSUS server name (empty = local).
.PARAMETER Port               API port (8530; 8531 for SSL).
.PARAMETER Secure             Use HTTPS.
.PARAMETER StaleDays          Age in days for obsolete computers (default 30).
.PARAMETER SkipContentFiles   Skip the native content-file cleanup (the only native step).
.PARAMETER LogPath            Transcript log file.

.EXAMPLE
    .\Invoke-WsusContentCleanup.ps1
.EXAMPLE
    .\Invoke-WsusContentCleanup.ps1 -UpdateServer 'WSUS-DOWNSTREAM-01' -Port 8530
.EXAMPLE
    .\Invoke-WsusContentCleanup.ps1 -SkipContentFiles
.NOTES
    Project: WSUS Toolkit. License: MIT.
#>

[CmdletBinding()]
param(
    [string] $UpdateServer,
    [int]    $Port = 8531,
    [switch] $Secure,
    [int]    $StaleDays = 30,
    [switch] $SkipContentFiles,
    [string] $LogPath = "$env:ProgramData\WsusMaintenance\content-cleanup.log"
)

$ErrorActionPreference = 'Stop'
$dir = Split-Path $LogPath -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Start-Transcript -Path $LogPath -Append -Force | Out-Null

try {
    Write-Output "=== WSUS CONTENT CLEANUP : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Import-Module UpdateServices -ErrorAction Stop

    if ($UpdateServer) {
        $p = @{ Name = $UpdateServer; PortNumber = $Port }; if ($Secure) { $p.UseSsl = $true }
        $Wsus = Get-WsusServer @p
    } else { $Wsus = Get-WsusServer }
    Write-Output "WSUS server: $($Wsus.Name):$($Wsus.PortNumber)"

    # --- Phase 1: decline expired updates (manual loop, progress /100) ---
    Write-Output '--- Phase 1: decline expired updates ---'
    $expired = $Wsus.GetUpdates() | Where-Object { (-not $_.IsDeclined) -and ($_.PublicationState -eq 'Expired') }
    $total = $expired.Count
    Write-Output "$total expired update(s) not declined."
    $n = 0; $okE = 0; $koE = 0
    foreach ($u in $expired) {
        $n++
        try { $u.Decline(); $okE++ } catch { $koE++; if ($koE -le 10) { Write-Warning "Decline failed: $($u.Title)" } }
        if ($n % 100 -eq 0) { Write-Output "  ... $n / $total  (declined: $okE, failed: $koE)" }
    }
    Write-Output "Expired declined: $okE ($koE failed)."

    # --- Phase 2: remove obsolete computers (manual loop, progress /100) ---
    Write-Output "--- Phase 2: remove obsolete computers (> $StaleDays days) ---"
    $threshold = (Get-Date).AddDays(-$StaleDays)
    $stale = $Wsus.GetComputerTargets() | Where-Object {
        $c = @($_.LastSyncTime, $_.LastReportedStatusTime) | Where-Object { $_ -gt [DateTime]::MinValue }
        if ($c) { (($c | Sort-Object)[-1]) -lt $threshold } else { $false }
    }
    $totalC = $stale.Count
    Write-Output "$totalC obsolete computer(s)."
    $m = 0; $okC = 0; $koC = 0
    foreach ($comp in $stale) {
        $m++
        try { $comp.Delete(); $okC++ } catch { $koC++; if ($koC -le 10) { Write-Warning "Remove failed: $($comp.FullDomainName)" } }
        if ($m % 100 -eq 0) { Write-Output "  ... $m / $totalC  (removed: $okC, failed: $koC)" }
    }
    Write-Output "Computers removed: $okC ($koC failed)."

    # --- Phase 3: free unneeded content files (native, isolated) ---
    $freedGB = 0
    if (-not $SkipContentFiles) {
        Write-Output '--- Phase 3: free unneeded content files ---'
        try {
            $r = Invoke-WsusServerCleanup -UpdateServer $Wsus -CleanupUnneededContentFiles
            $freedGB = [Math]::Round($r.DiskSpaceFreed / 1GB, 2)
            Write-Output "Disk space freed: $freedGB GB."
        } catch { Write-Warning "Content cleanup timed out/failed (resumable next run): $_" }
    } else { Write-Output '--- Phase 3: content cleanup SKIPPED ---' }

    Write-Output ''
    Write-Output '--- Summary ---'
    Write-Output "  Expired declined  : $okE"
    Write-Output "  Computers removed : $okC"
    Write-Output "  Content freed     : $freedGB GB"
    Write-Output "=== DONE : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
}
catch { Write-Error "Cleanup failed: $_"; exit 1 }
finally { Stop-Transcript | Out-Null }
