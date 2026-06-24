# Client Update Troubleshooting (WSUS)

Runbook for technicians: diagnose and fix a client that fails to install an update
offered by WSUS, from the most common cause to the most complex.

> WSUS records *which* update failed on *which* computer, but **not** the Windows Update
> error code (`0x8024…` / `0x800f…`). That code lives on the client. Step 1 retrieves it.

## 0. Before you start

From the WSUS error CSV (produced by `Invoke-WsusMaintenance.ps1`) collect: computer name,
IP, the failed **KB(s)**, and last contact.

| Observation | Meaning |
|---|---|
| **Same KB** on several computers | **Systemic** cause (prerequisite, WSUS content, bad update) → §5, §6 |
| **Different KBs** on one computer | **Local** problem (WU cache, disk, corruption) → §4 |
| Unreachable / offline | Not an install error |

## 1. Decision tree

```
Same KB fails on MANY computers ?
 ├─ YES → systemic: verify the KB is approved AND downloaded on WSUS [§6];
 │        check client disk space; disable "express installation files" [§6];
 │        decline/re-approve, or approve the latest cumulative.
 └─ NO  → local: reboot pending → disk space → rescan → reset WU cache →
          component repair (DISM/SFC) → manual install → advanced.
```

## 2. Diagnostic — get the real error code (remote)

Queries each client's Windows Update history (`Microsoft.Update.Session`) for the real
**HResult**, plus free space, OS build and pending-reboot. Requires WinRM and an admin
account.

```powershell
$Computers = @('PC-001','PC-002')   # or: (Import-Csv .\wsus-clients-in-error.csv -Delimiter ';').Computer | Sort-Object -Unique

$diag = foreach ($pc in $Computers) {
    try {
        Invoke-Command -ComputerName $pc -ErrorAction Stop -ScriptBlock {
            $os   = Get-CimInstance Win32_OperatingSystem
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
            $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                      (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            $fails = @()
            try {
                $se = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
                $n  = $se.GetTotalHistoryCount()
                if ($n -gt 0) {
                    $fails = $se.QueryHistory(0,$n) | Where-Object { $_.ResultCode -eq 4 } |
                        Sort-Object Date -Descending | Select-Object -First 5 |
                        ForEach-Object { "{0} [0x{1:X8}]" -f $_.Title, ($_.HResult -band 0xFFFFFFFF) }
                }
            } catch {}
            [PSCustomObject]@{
                Computer = $env:COMPUTERNAME; OSBuild = $os.Version
                FreeGB = [math]::Round($disk.FreeSpace/1GB,1)
                RebootPending = $reboot; LastErrors = ($fails -join '  |  ')
            }
        }
    } catch {
        [PSCustomObject]@{ Computer=$pc; OSBuild='?'; FreeGB='?'; RebootPending='?'; LastErrors="UNREACHABLE: $_" }
    }
}
$diag | Format-Table -AutoSize
```

## 3. Common error codes

| Code | Meaning | Likely cause | Action |
|---|---|---|---|
| `0x80070070` | Not enough space | Disk `C:` full | §4.1 |
| `0x800F0922` | Install failure | System-reserved partition too small, VPN during install | §4.1, §4.6 |
| `0x800F0831` | Missing package in store | Broken cumulative/checkpoint chain | §4.4 + §6 |
| `0x80073712` | Component store corrupt | CBS corruption | §4.4 |
| `0x80070643` | Fatal install error | Common on .NET cumulatives; damaged store | §5 |
| `0x80070002/3` | Files not found | Corrupt WU cache | §4.3 |
| `0x8024xxxx` | WU agent / WSUS comms | Agent or server-side | §4.3 / §6 |

## 4. Local remediation (simplest → hardest)

Run in order; retest with `UsoClient StartScan` after each level.

### 4.1 Quick checks
- **Pending reboot** blocks all installs → reboot, then rescan.
- **Free space**: aim for 10–15 GB for a modern cumulative.
  ```powershell
  DISM /Online /Cleanup-Image /StartComponentCleanup
  cleanmgr /sagerun:1
  ```
- **Force a rescan/report** (the shown error may be stale): `UsoClient StartScan`.

### 4.2 Restart the WU cycle
```powershell
Stop-Service wuauserv -Force; Start-Service wuauserv; UsoClient StartInteractiveScan
```

### 4.3 Reset the Windows Update cache
```powershell
$svc='wuauserv','bits','cryptsvc','msiserver'; Stop-Service $svc -Force -EA SilentlyContinue
$s=Get-Date -Format yyyyMMddHHmmss
Rename-Item "$env:windir\SoftwareDistribution" "SoftwareDistribution.$s.old" -EA SilentlyContinue
Rename-Item "$env:windir\System32\catroot2"    "catroot2.$s.old"            -EA SilentlyContinue
Start-Service $svc -EA SilentlyContinue
Start-Process "$env:windir\System32\UsoClient.exe" 'StartScan'
```

### 4.4 Component store repair (DISM + SFC)
> In a WSUS environment, `DISM /RestoreHealth` cannot reach Windows Update and fails.
> Use an ISO source of the **same build**:
```powershell
DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:1 /LimitAccess
sfc /scannow
```
Logs: `C:\Windows\Logs\CBS\CBS.log`, `C:\Windows\Logs\DISM\dism.log`.

### 4.5 Manual install
Download the `.msu` from the Microsoft Update Catalog (matching OS/arch), then:
```powershell
wusa.exe C:\Temp\<update>.msu /quiet /norestart
# .cab variant:
# DISM /Online /Add-Package /PackagePath:C:\Temp\<update>.cab
```
A manual install that succeeds while WSUS fails points to a **WSUS content** issue (§6).

### 4.6 Reserved / WinRE partition (`0x800F0922`)
```powershell
reagentc /info
reagentc /disable   # then install the KB, then:
reagentc /enable
```

### 4.7 Advanced
- DISM/SFC fail → **in-place upgrade** with same-build ISO (`setup.exe`, keep apps & files).
- Check date/time (certificates), third-party AV (exclude `SoftwareDistribution`), proxy.

## 5. .NET cumulative failures (`0x80070643`)
1. Install the **OS cumulative first** if also pending (order matters).
2. Reset WU cache (§4.3).
3. Repair components (§4.4); if needed, the offline **.NET Framework Repair Tool**.
4. Last resort: manual install of the .NET `.msu` (§4.5).

## 6. WSUS-side actions (systemic)
1. Confirm the KB is **approved and downloaded** (content present).
2. **Disable express installation files** (Options → Update Files), then re-sync — a frequent
   cause of large/failed downloads on recent builds.
3. **Decline then re-approve** to force re-evaluation; or approve the **latest** cumulative.
4. Verify the server's **last synchronization** succeeded (see the maintenance report).
5. On client timeouts (`0x8024401C`), check the `WsusPool` IIS app pool and that the database
   has been remediated (`Repair-WsusDatabase.ps1`).

## 7. Mass remediation (remote)

```powershell
$Computers = (Import-Csv .\wsus-clients-in-error.csv -Delimiter ';').Computer | Sort-Object -Unique

# Reset WU cache on all
Invoke-Command -ComputerName $Computers -ErrorAction Continue -ScriptBlock {
    $svc='wuauserv','bits','cryptsvc','msiserver'; Stop-Service $svc -Force -EA SilentlyContinue
    $s=Get-Date -Format yyyyMMddHHmmss
    Rename-Item "$env:windir\SoftwareDistribution" "SoftwareDistribution.$s.old" -EA SilentlyContinue
    Rename-Item "$env:windir\System32\catroot2" "catroot2.$s.old" -EA SilentlyContinue
    Start-Service $svc -EA SilentlyContinue
    Start-Process "$env:windir\System32\UsoClient.exe" 'StartScan'
}
```

## 8. Close the ticket
```powershell
UsoClient StartScan
$se=(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$n=$se.GetTotalHistoryCount()
$se.QueryHistory(0,$n) | Where-Object {$_.ResultCode -eq 4} |
    Sort-Object Date -Descending | Select-Object -First 5 Date,Title,@{n='HResult';e={'0x{0:X8}' -f ($_.HResult -band 0xFFFFFFFF)}}
```
The client should move from **In error** to **OK** / **Reboot required** at its next report.

## Appendix — readable WindowsUpdate.log
```powershell
Get-WindowsUpdateLog -LogPath "$env:USERPROFILE\Desktop\WindowsUpdate.log"
```
