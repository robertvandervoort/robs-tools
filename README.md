# rob's-tools

A small, growing collection of command-line tools I've built and leaned on over the past year or so. They're the kind of little helpers that save you from re-typing the same long `smartctl` incantation or `echo` into `/proc` for the hundredth time.

They're all short, dependency-light, and meant to live somewhere on your `PATH` (I keep the Linux/Jetson ones in `/usr/local/bin`) so they're always a keystroke away.

I'm sharing these freely with the community in the hope they're useful. If you find a bug, have an idea, or want to add your own tool to the pile, **contributions are very welcome** — see [Contributing](#contributing) below.

---



## Repository layout

Tools are organized into folders by operating system:

```
robs-tools/
├── linux/      # General-purpose Linux CLI tools
├── jetson/     # NVIDIA Jetson-specific tools
└── windows/    # PowerShell tools for Windows (growing)
```

- `[linux/](#linux-tools)` — Server/homelab maintenance helpers. Should work on any modern distro.
- `[jetson/](#jetson-tools)` — Tools specific to **NVIDIA Jetson** devices.
- `[windows/](#windows-tools)` — PowerShell scripts for Windows. *(More landing here soon.)*

---



## Installation

Clone the repo, then install the tools for your platform onto your `PATH`.

```bash
git clone https://github.com/robertvandervoort/robs-tools.git
cd robs-tools
```

**Linux / Jetson** — copy into `/usr/local/bin` and make them executable:

```bash
# Linux tools
sudo cp linux/* /usr/local/bin/
sudo chmod +x /usr/local/bin/{cdl,cputemps,diskhog,dprune,drivehealth,drivetemps,dropcachee,myip,nvmehealth,ports,setup-ssh.sh,svcfail}

# Jetson tools (Jetson devices only)
sudo cp jetson/jtop /usr/local/bin/ && sudo chmod +x /usr/local/bin/jtop
```

You can also symlink instead of copying, so they stay updated from your clone:

```bash
sudo ln -s "$PWD/linux/drivehealth" /usr/local/bin/drivehealth
```

**Windows** — see the [Windows tools](#windows-tools) section.

### Dependencies

Most tools are plain shell/coreutils, but a few lean on external packages:


| Tool                                      | Needs                                                                                                           |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `drivehealth`, `drivetemps`, `nvmehealth` | `[smartmontools](https://www.smartmontools.org/)` — `sudo apt install smartmontools`                            |
| `cputemps`                                | `[lm-sensors](https://github.com/lm-sensors/lm-sensors)` — `sudo apt install lm-sensors && sudo sensors-detect` |
| `dprune`                                  | `[docker](https://docs.docker.com/engine/)`                                                                     |
| `ports`                                   | `iproute2` (`ss`) — usually preinstalled                                                                        |
| `myip`                                    | `curl`, `iproute2` — usually preinstalled                                                                       |
| `jtop`                                    | `[jetson-stats](https://github.com/rbonghi/jetson_stats)` — `sudo pip3 install jetson-stats` (Jetson only)      |


Several tools use `sudo` internally, so you'll want appropriate privileges when running them.

---



## Linux tools

Listed alphabetically. Each entry notes what it does and any parameters it accepts.

### `cdl`

**Clear Docker Logs.** Truncates every Docker container's JSON log file to zero bytes, reclaiming disk space eaten by chatty containers — without stopping or removing anything.

```bash
cdl
```

Runs against `/var/lib/docker/containers/*/*-json.log`. Takes no parameters. Uses `sudo` internally. I push all my logs into Loki so this is a no-brainer cleanup for me.

> Handy when `df -h` is looking scary and you've traced the culprit back to runaway container logs. Consider also setting up log rotation in your Docker daemon config for a longer-term fix.

---



### `cputemps`

Quick CPU temperature readout with an at-a-glance status, in the same spirit as `drivetemps`:

- **OK** — below 70 °C
- **WARM** — 70–84 °C
- **CRITICAL** — 85 °C and above

```bash
cputemps
```

Takes no parameters. Requires `lm-sensors` (`sudo apt install lm-sensors && sudo sensors-detect`). Reads per-core, package, and AMD `Tctl`/`Tdie` sensors.

---



### `diskhog`

Show the biggest space consumers under a path — the natural next step when `df -h` is scary and clearing logs/cache didn't cut it.

```bash
diskhog [path] [count]
```


| Param   | Default           | Description                  |
| ------- | ----------------- | ---------------------------- |
| `path`  | `.` (current dir) | Directory to scan            |
| `count` | `15`              | How many top entries to list |


Stays on a single filesystem (`du -x`) so it won't wander into mounts or network shares. Uses `sudo` internally.

```bash
diskhog /var 20     # top 20 space hogs under /var
```

---



### `dprune`

A **guarded** `docker system prune` wrapper — the bigger-hammer companion to `cdl`. Shows disk usage before/after, prompts for confirmation, then reclaims stopped containers, dangling images, unused networks, and build cache.

```bash
dprune [--volumes]
```


| Param             | Description                                         |
| ----------------- | --------------------------------------------------- |
| *(none)*          | Prune containers, images, networks, and build cache |
| `--volumes`, `-v` | **Also** prune unused volumes (⚠️ may delete data)  |
| `--help`, `-h`    | Show usage                                          |


Requires `docker`. Uses `sudo` internally.

---



### `drivehealth`

Prints a compact SMART health table for your SATA/SAS drives (`/dev/sda` through `/dev/sdf`), focusing on the attributes that actually predict failure:

- **Realloc** — Reallocated sector count
- **Pending** — Current pending sectors
- **Uncorrect** — Offline uncorrectable sectors
- **Seek Err** — Seek error rate

```bash
drivehealth
```

Takes no parameters — it auto-detects which of `/dev/sda`–`/dev/sdf` exist. Uses `sudo smartctl` internally. (For NVMe drives, see `[nvmehealth](#nvmehealth)`.)

Example output:

```
-----------------------------------------------------------------------
Drive | Serial Number      | Realloc | Pending | Uncorrect | Seek Err
-----------------------------------------------------------------------
/dev/sda | WD-WCC4E1234567    |       0 |       0 |         0 | 0
/dev/sdb | S3Z1NB0K123456     |       0 |       0 |         0 | 0
-----------------------------------------------------------------------
```

> Non-zero values in Realloc, Pending, or Uncorrect are worth watching closely — they're often the earliest sign a drive is on its way out.

---



### `drivetemps`

Prints a quick temperature readout for your SATA/SAS drives (`/dev/sda` through `/dev/sdf`) with an at-a-glance status:

- **OK** — below 45 °C
- **WARM** — 45–54 °C
- **CRITICAL** — 55 °C and above

```bash
drivetemps
```

Takes no parameters — it auto-detects which of `/dev/sda`–`/dev/sdf` exist. Uses `sudo smartctl` internally.

Example output:

```
--------------------------
Drive | Temp (C) | Status
--------------------------
/dev/sda |   38°C   | OK
/dev/sdb |   47°C   | WARM
--------------------------
```

---



### `dropcachee`

Drops the Linux page cache, dentries, and inodes by writing `3` to `/proc/sys/vm/drop_caches`. Useful for benchmarking (getting a clean, cold-cache baseline) or freeing up cached memory for inspection.

```bash
dropcachee
```

Takes no parameters. Uses `sudo` internally.

> This is safe — the kernel only drops *clean*, reclaimable cache and never discards dirty data. It won't speed up a running system (the cache exists for good reason); it's mainly a benchmarking/diagnostic aid.

---



### `myip`

Shows your local interface IPs **and** your public IP in one shot — no more juggling `ip a` and a web lookup.

```bash
myip
```

Takes no parameters. Lists non-loopback IPv4 interfaces via `ip`, then queries public IP services (`ifconfig.me`, `api.ipify.org`, `icanhazip.com`) with a short timeout and graceful fallback if you're offline. Requires `curl` and `iproute2`.

---



### `nvmehealth`

SMART health at-a-glance for **NVMe** drives (`/dev/nvme0` through `/dev/nvme5`) — the companion to `drivehealth`, which only covers `/dev/sd`*. NVMe drives report different, more useful fields:

- **Used%** — Percentage of rated endurance consumed
- **Spare%** — Available spare capacity remaining
- **Temp** — Composite temperature
- **MediaErr** — Media and data integrity errors
- **Warn** — SMART critical warning flags

```bash
nvmehealth
```

Takes no parameters — it auto-detects which `/dev/nvme*` devices exist. Uses `sudo smartctl` internally.

> Used% climbing toward 100, Spare% dropping below the drive's threshold, or a non-zero critical warning are your cues to plan a replacement.

---



### `ports`

"What's listening on this box?" — a clean, formatted view of listening TCP/UDP ports and the process behind each one.

```bash
ports [port]
```


| Param    | Description                      |
| -------- | -------------------------------- |
| *(none)* | List all listening TCP/UDP ports |
| `port`   | Show only the given port number  |


Wraps `ss -tulpn`. Uses `sudo` internally (needed to see process names). Requires `iproute2`.

```bash
ports 443     # who's on 443?
```

---



### `setup-ssh.sh`

Bootstraps passwordless SSH to one or more hosts. For each hostname you pass, it:

1. Generates a **dedicated** `ed25519` keypair (`~/.ssh/id_ed25519_<host>`) if one doesn't already exist.
2. Appends a matching `Host` block to `~/.ssh/config` (with `IdentitiesOnly yes`), skipping hosts already present.
3. Runs `ssh-copy-id` to install the public key on the remote (prompts for the password interactively).

```bash
setup-ssh.sh [-u <username>] <hostname1> [hostname2 ...]
```


| Param                     | Description                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------- |
| `hostname...`             | One or more hosts to set up (required)                                                  |
| `-u`, `--user <username>` | Remote username to log in as. Defaults to `$SSH_USER`, then your current user (`$USER`) |
| `-h`, `--help`            | Show usage                                                                              |


The remote username is fully configurable — pass `-u`/`--user`, set the `SSH_USER` environment variable, or just let it default to whoever you're logged in as. The generated key comment uses your local hostname automatically.

Run it with no hostnames, an unknown option, or `--help` and it prints the usage instructions (and exits non-zero on misuse).

```bash
setup-ssh.sh server1 server2         # uses your current username
setup-ssh.sh -u admin nas.local      # log in as 'admin'
SSH_USER=deploy setup-ssh.sh web01   # via environment variable
```

After it finishes you can simply `ssh <hostname>`. Per-host keys keep things tidy and easy to revoke individually.

---



### `svcfail`

Fast server triage: list any **failed** `systemd` units, then optionally pull the recent journal for one of them.

```bash
svcfail [unit]
```


| Param    | Description                                  |
| -------- | -------------------------------------------- |
| *(none)* | List all failed units                        |
| `unit`   | Show the last 30 journal lines for that unit |


Uses `sudo` for `journalctl`. Requires a `systemd` system.

```bash
svcfail                 # anything broken?
svcfail nginx.service   # why did nginx fail?
```

---



## Jetson tools



### `jtop`

**NVIDIA Jetson only.** A small launcher for `[jtop](https://github.com/rbonghi/jetson_stats)`, the excellent interactive monitoring tool for Jetson boards (think `htop`, but Jetson-aware: GPU, power modes, temps, etc.). This wrapper just invokes the installed `jetson-stats` entry point.

```bash
jtop
```

Requires `jetson-stats` (`sudo pip3 install jetson-stats`). Parameters are passed straight through to the underlying `jtop` tool.

---



## Windows tools

PowerShell (and a little Python) tooling in [`windows/`](windows/), grown out of real-world troubleshooting of a Windows workstation — event-log forensics, Windows Update repair, DCOM permission audits, and targeted cleanups. Tools are grouped by job below; within each group they're listed alphabetically.

**A few things that apply to most of these:**

- **Run as Administrator.** Most scripts self-elevate-check and exit if not elevated. Launch an elevated PowerShell first.
- **Execution policy.** If scripts are blocked, run them with `powershell -ExecutionPolicy Bypass -File .\script.ps1`.
- **Logging.** The Windows Update scripts write a transcript to `windows-update-repair-logs\` next to the script.
- **Python bits** need `pandas` (`pip install pandas`). The analyzers read `log_analysis_config.json` (shipped with sensible defaults) for tuning — edit it to change time windows, tracked event IDs, and pattern keywords. If the file is missing, the same defaults are used from code.

### ⚠️ Safety, compatibility & recovery

These scripts were written to fix real problems on a Windows 11 workstation. They work by stopping services, editing the registry, renaming system folders, and deleting cached data — so please read this before running anything, especially on a machine you can't afford to break.

**Read before you run:**

- **Understand it first.** Open the script and read it. Never run an admin PowerShell script from the internet (mine included) that you don't understand. Every script here is short and commented for exactly this reason.
- **Compatibility.** Developed and tested on **Windows 11 (64-bit)**. They should work on Windows 10 too, but some rely on components Microsoft changes between builds — notably `usoclient.exe` (the Update Session Orchestrator client), the `Microsoft.Update.Session` COM API, and Delivery Optimization cmdlets. Behavior can vary by build; a script that returns "0 updates" or an unfamiliar error is usually a version difference, not a crash.
- **Not for managed/domain PCs.** If your machine is managed by an employer, school, or MDM/WSUS, don't run the Windows Update or driver-policy scripts — they change update policy and can conflict with your admin's configuration.

**Take a backup / restore point first.** For anything in the "Windows Update repair" or "System cleanup" groups, create a System Restore point so you have a one-click way back:

```powershell
# Run as Administrator
Enable-ComputerRestore -Drive "C:\"
Checkpoint-Computer -Description "Before robs-tools" -RestorePointType MODIFY_SETTINGS
```

To roll back later, run `rstrui.exe` and pick that restore point. (A restore point covers registry and system-file changes; it does **not** restore deleted cache/report files — but those are safe to lose, see below.)

**Risk & reversibility at a glance:**

| Script | What it changes | Risk | How to recover |
| --- | --- | --- | --- |
| `analyze_*.py`, `export_events.ps1`, `audit_dcom_10016.ps1`, `resolve_clsid_appid.ps1` | Read-only. Only writes CSV/JSON reports. | None | Delete the generated report files |
| `disable-windows-update-drivers.ps1` | Sets `ExcludeWUDriversInQualityUpdate=1` policy; hides offered driver updates | Low | Run `enable-driver-suggestions.ps1` to reverse |
| `enable-driver-suggestions.ps1` | Removes that policy so drivers are offered again | Low | Run `disable-windows-update-drivers.ps1` to reverse |
| `install-pending-software-now.ps1`, `install-user-context-software-updates.ps1`, `install-user-context-driver-updates.ps1` | **Installs updates without further prompting** | Medium (a bad update/driver can misbehave) | Uninstall via Settings → Windows Update → Update history → Uninstall updates; roll back drivers in Device Manager |
| `repair-windows-update.ps1`, `full-reset-windows-update-state.ps1` | Renames `SoftwareDistribution` & `catroot2` to `*.bak-<timestamp>`; clears BITS/DO cache; runs DISM/SFC | Medium | Folders are **renamed, not deleted** — Windows rebuilds fresh ones; delete the `.bak-*` copies once updates work. A restore point covers the service/registry changes |
| `repair-delivery-optimization.ps1` | Sets Delivery Optimization to HTTP-only; **raises the interface metric** of non-routable NICs; clears DO/BITS/download cache | Medium | See the per-script note below to restore DO mode and NIC metrics |
| `cleanup-wer-queue.ps1` | Deletes queued Windows Error Reporting reports across all profiles (uses `takeown`/`icacls`); clears WER registry retry queue | Low | Deleted crash reports are gone, but they're just pending diagnostics — WER keeps working and tracks future crashes normally |
| `cleanup-gameinput.ps1` | Uninstalls Microsoft GameInput, deletes its folders, disables its services | Low | Reinstall GameInput from Microsoft or let a game reinstall it; the hardcoded MSI product code may not match every version |

None of these touch personal files/documents — the "destructive" actions are limited to Windows' own regenerable caches, queues, and service state.

### Event log analysis

A small pipeline: export events to CSV with PowerShell, then analyze them with Python.

#### `analyze_critical_events.py`

Analyzes critical shutdown/crash events (IDs 41, 6008, 46) and the events clustered around them, so you can spot what led up to an unexpected reboot. Reads `system_events.csv` / `app_events.csv` produced by `export_events.ps1`, groups events into time clusters, runs pattern detection (WSL, DCOM, Defender, Hyper-V, hardware, etc.), and prints a timeline + health summary. Takes no parameters; tune behavior via `log_analysis_config.json`.

#### `analyze_recent_events.py`

A quick "how's the system doing right now?" check. Pulls the last N minutes of System/Application events (default 30) via PowerShell and summarizes errors, warnings, notable patterns, and an overall health rating. Takes no parameters; the window is configurable through `log_analysis_config.json`.

#### `export_events.ps1`

Exports Windows event logs to CSV for the analyzers above, and does a quick critical-event count on the way out.

```powershell
.\export_events.ps1 [-HoursBack 12] [-SystemFile system_events.csv] [-AppFile app_events.csv] [-IncludeSecurity] [-Verbose]
```

| Param | Default | Description |
| --- | --- | --- |
| `-HoursBack` | `12` | How far back to export |
| `-SystemFile` | `system_events.csv` | Output path for System log |
| `-AppFile` | `app_events.csv` | Output path for Application log |
| `-IncludeSecurity` | off | Also export the Security log |
| `-Verbose` | off | Show a per-level event breakdown |

#### `log_analysis_utils.py`

Shared helper module for the analyzers (config loading, date parsing, pattern detection, health rating, formatting). Not run directly — imported by the analysis scripts.

#### `test_tools.py`

A small self-test harness that validates configuration loading, file validation, the export script, and both analyzers. Handy for contributors verifying the pipeline still works. Run with `python test_tools.py`.

### DCOM diagnostics

For chasing down the endless **DCOM 10016** "permission" errors in the System log.

#### `audit_dcom_10016.ps1`

Scans the System log for DistributedCOM 10016 events, parses out the CLSID/APPID/user/SID, resolves each CLSID/APPID to a friendly name and backing service via the registry, summarizes the offenders, and prints step-by-step remediation guidance (dcomcnfg). Optionally exports to CSV/JSON.

```powershell
.\audit_dcom_10016.ps1 [-HoursBack 24] [-OutputCsv dcom_10016_audit.csv] [-AsJson]
```

| Param | Default | Description |
| --- | --- | --- |
| `-HoursBack` | `24` | How far back to scan |
| `-OutputCsv` | `dcom_10016_audit.csv` | CSV output path (set empty to skip) |
| `-AsJson` | off | Emit JSON instead of a table |

#### `resolve_clsid_appid.ps1`

A focused lookup: given a CLSID and/or AppID GUID, resolves names, backing service, server paths, and launch/access permission SDDL from the registry. Great for identifying a mystery GUID from an event.

```powershell
.\resolve_clsid_appid.ps1 -Clsid "{GUID}" -AppId "{GUID}" [-AsJson]
```

#### `DComTools.psm1`

The PowerShell module backing the two DCOM scripts (registry resolution helpers). Imported automatically by them — not run directly.

### Windows Update repair

A graduated toolkit, from a full service/cache reset down to targeted install helpers. Reach for `repair-windows-update.ps1` first; escalate as needed.

#### `disable-windows-update-drivers.ps1`

Stops Windows Update from offering driver updates: sets the `ExcludeWUDriversInQualityUpdate` policy and hides any driver updates currently on offer. No parameters.

#### `enable-driver-suggestions.ps1`

The inverse of the above — clears the driver-exclusion policy so driver updates are suggested again (as reviewable offers, not forced installs), then rescans. No parameters.

#### `full-reset-windows-update-state.ps1`

A deeper reset than `repair-windows-update.ps1`: stops the update/transfer services, clears BITS jobs, `qmgr*.dat`, and the Delivery Optimization cache, renames `SoftwareDistribution` and `catroot2`, restarts services, forces a fresh scan, and re-hides driver offers. No parameters.

#### `install-pending-software-now.ps1`

Installs pending **software** updates immediately via the Windows Update COM API (clean search with retry, deliberately avoiding the flaky `usoclient` scan race), skipping drivers. No parameters.

#### `install-user-context-driver-updates.ps1`

Searches for and installs pending **driver** updates via the COM API. No parameters.

#### `install-user-context-software-updates.ps1`

Searches for and installs pending **software** updates via the COM API, deferring (listing) any drivers it finds. No parameters.

> **Note on overlap:** this and `install-pending-software-now.ps1` do largely the same job. The difference is the scan strategy — this one runs a `usoclient StartScan` first, while `install-pending-software-now.ps1` skips that (a clean COM search with retry) specifically to avoid an intermittent race that returns zero updates. If you only want one, keep `install-pending-software-now.ps1`.

#### `repair-delivery-optimization.ps1`

Targets stuck downloads (0x80D0xxxx no-progress errors): forces Delivery Optimization to HTTP-only (no peering), raises the interface metric of non-routable NICs so the real internet NIC is preferred, clears BITS/DO/download caches, then retries the software download+install. No parameters.

> **Recovering the changes it makes:** to restore Delivery Optimization to its default (peer-assisted) mode, run `Set-DODownloadMode -DownloadMode 1` (or 3), or delete the `DODownloadMode` value under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config`. The NIC metric change only *raises* the priority of gateway-less interfaces; to undo it, set the affected adapter back to automatic with `Set-NetIPInterface -InterfaceAlias "<name>" -AutomaticMetric Enabled` (find the name with `Get-NetIPInterface`).

#### `repair-windows-update.ps1`

The go-to first responder. Resets Windows Update services and caches, repairs the servicing stack (`DISM /RestoreHealth` + `sfc /scannow`), then searches, downloads, and installs pending software updates (deferring drivers) and prints recent update history. No parameters.

### System cleanup

#### `cleanup-gameinput.ps1`

Fully removes Microsoft GameInput: stops/disables its services, kills its processes, uninstalls the MSI, deletes leftover folders, and verifies removal. Interactive (waits for a keypress at the end). No parameters.

#### `cleanup-wer-queue.ps1`

Purges the Windows Error Reporting queue so WER stops spamming Event 1001 submission retries — **without** disabling WER (future crashes still get tracked). Enumerates WER dirs across system, service, and all user profiles, uses `takeown`/`icacls` to clear ACL-protected SYSTEM-owned reports, clears the registry retry queue, and reports space freed. No parameters.

---



## Contributing

These started as personal scratch-an-itch scripts, so they're intentionally simple. If you'd like to make them better, I'd love the help:

- **Found a bug or rough edge?** Open an issue with what you ran, what you expected, and what happened.
- **Have an improvement?** PRs welcome. Small, focused changes are easiest to review.
- **Want to add a tool?** Even better. Please keep the house style in mind:
  - Small, single-purpose, and readable.
  - Fail gracefully and avoid destructive surprises (prompt before anything irreversible).
  - Drop it in the right OS folder (`linux/`, `jetson/`, or `windows/`).
  - Add a matching entry to this README (alphabetical order, same format).

No CLA, no ceremony — just be kind and keep it useful.

## License

Released into the wild for free use. Add your preferred license here (MIT is a friendly default for tools like these).