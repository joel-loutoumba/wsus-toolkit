# WSUS Topology Maintenance

A single PowerShell script that performs **monthly WSUS housekeeping across an entire
server topology** (upstream + downstream/replica servers) and e-mails a **consolidated
HTML report**. Designed to run unattended as a scheduled task.

It is API-based, so one run from a single host maintains every WSUS server in the list,
including remote ones.

## Features

- **Per-server health snapshot** — role (upstream/replica), last synchronization result,
  total clients, clients in error, clients needing updates.
- **Decline 32-bit (x86) updates** — only where enabled (see *Replica topology* below).
- **Native cleanup** — obsolete computers (>30 days), expired updates, unneeded content
  files, and obsolete updates (run as an isolated step).
- **Consolidated HTML e-mail** — totals banner, health table, actions table, legend.
- **CSV of clients in error** — computer / IP / KB / update title, attached automatically
  when at least one client is in error.
- **`-ReportOnly` simulation** — counts everything, changes nothing. Ideal for a first run.
- Resilient: each server and each step is isolated; one failure never aborts the rest.

## Requirements

- Windows Server with the **WSUS role / RSAT** (provides the `UpdateServices` PowerShell
  module) on the host that runs the script.
- The running account must be a member of the local **WSUS Administrators** group on
  **every** target server.
- The WSUS API ports (default **8530**, or **8531** for SSL) must be reachable from the
  host running the script.
- An **SMTP relay** that accepts the sender address (for the report).
- PowerShell 5.1+.

> **Note on neglected databases.** The "obsolete updates" cleanup uses the native WSUS
> cmdlet, which can time out on a large WSUS database that has never been maintained
> (missing internal indexes, huge backlog). On such a server, run a one-time local
> database remediation first (reindex + drain). The script isolates this step so the rest
> of the maintenance still completes and is reported.

## Configuration

Everything is parameterized — no value is hard-coded. Edit the defaults at the top of the
script, or pass parameters on the command line.

| Parameter | Default | Description |
|---|---|---|
| `-Servers` | example array | Topology: `@{ Name; Port; Secure; DeclineX86 }` per server. |
| `-SmtpServer` | `smtp.example.local` | SMTP relay. |
| `-From` | `WSUS Report <wsus-report@example.local>` | Sender (supports `Display Name <addr>`). |
| `-To` | `it-admin@example.local` | Recipient(s); array or comma/semicolon string. |
| `-LogPath` | `%ProgramData%\WsusMaintenance\maintenance.log` | Transcript log. |
| `-ErrorCsvPath` | `%ProgramData%\WsusMaintenance\…csv` | CSV of clients in error. |
| `-SkipDeclineX86` | off | Globally disable the x86 decline step. |
| `-ReportOnly` | off | Simulation; change nothing. |
| `-NoMail` | off | Do not send e-mail (console/log only). |

### Defining the topology

```powershell
$Servers = @(
    @{ Name = 'WSUS-UPSTREAM';      Port = 8531; Secure = $true; DeclineX86 = $true  }
    @{ Name = 'WSUS-DOWNSTREAM-01'; Port = 8531; Secure = $true; DeclineX86 = $false }
    @{ Name = 'WSUS-DOWNSTREAM-02'; Port = 8531; Secure = $true; DeclineX86 = $false }
)
```

### Replica topology (`DeclineX86`)

On a **replica** downstream server, approvals and declines are **read-only** — they are
inherited from the upstream. Declining there raises an error. Therefore set
`DeclineX86 = $true` **only on the upstream** (and on any autonomous server). Check a
server's mode with:

```powershell
(Get-WsusServer -Name 'WSUS-DOWNSTREAM-01' -PortNumber 8531).GetConfiguration().IsReplicaServer
```

## Usage

```powershell
# 1) Dry run first — nothing is modified, but the full report is produced/sent
.\Invoke-WsusMaintenance.ps1 -ReportOnly

# 2) Real monthly run
.\Invoke-WsusMaintenance.ps1

# 3) Real run without e-mail (console + log only)
.\Invoke-WsusMaintenance.ps1 -NoMail

# 4) Override recipients / relay on the fly
.\Invoke-WsusMaintenance.ps1 -SmtpServer 'relay.lab.local' -To 'a@lab.local','b@lab.local'
```

## Scheduling (monthly)

`New-ScheduledTaskTrigger` has no native monthly trigger; build it via CIM. Example using
a Group Managed Service Account (gMSA) — replace `DOMAIN\gmsa-wsus$` and the path:

```powershell
$class   = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskMonthlyTrigger
$Trigger = New-CimInstance -CimClass $class -ClientOnly
$Trigger.DaysOfMonth   = 1
$Trigger.MonthsOfYear  = 4095          # every month (bitmask Jan..Dec)
$Trigger.StartBoundary = (Get-Date '01:00').ToString('yyyy-MM-ddTHH:mm:ss')

$Action = New-ScheduledTaskAction -Execute 'PowerShell.exe' `
    -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\Invoke-WsusMaintenance.ps1"'

$Principal = New-ScheduledTaskPrincipal -UserId 'DOMAIN\gmsa-wsus$' -LogonType Password -RunLevel Highest

Register-ScheduledTask -TaskName 'WSUS-Monthly-Maintenance' -Action $Action -Trigger $Trigger -Principal $Principal
```

The gMSA must be installed on the host (`Install-ADServiceAccount`), granted
*Log on as a batch job*, and added to the **WSUS Administrators** group on every target server.

## The e-mail report

- **Totals banner** — clients, clients in error, and the sum of all cleanup actions.
- **Server health** — role, state, last sync (red if not *Succeeded*), client counts.
- **Maintenance actions** — x86/expired/obsolete/computers/content removed, per-server
  duration, and any issues.
- **Attachment** — when clients are in error, a CSV listing each failed update per computer.

The subject line includes the global status and the number of clients in error, so issues
are visible without opening the message.

## Output / CSV

The clients-in-error CSV (`;`-delimited, UTF-8) contains:

`Server; Computer; IPAddress; LastContact; KB; Classification; FailedUpdate`

> WSUS records *which* update failed on *which* computer, but **not** the Windows Update
> error code (`0x8024…`). Retrieve that on the client (e.g. `Get-WindowsUpdateLog`, the
> update history, or the event log).

## Notes & limitations

- Database-level operations (reindex, internal index creation, low-level obsolete-update
  deletion) require **local** access to the WSUS database and are intentionally **not**
  part of this script; perform them locally on each server when needed.
- x86 detection is title-based (`x86` / `32-Bit`), which is reliable for Microsoft update
  titles but remains a heuristic; review with `-ReportOnly` before enabling declines.

## License

MIT — see `LICENSE`.

## Disclaimer

Provided as-is, without warranty. Test in a non-production environment first. You are
responsible for validating its behavior against your own WSUS topology.
