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

- **[`linux/`](#linux-tools)** — Server/homelab maintenance helpers. Should work on any modern distro.
- **[`jetson/`](#jetson-tools)** — Tools specific to **NVIDIA Jetson** devices.
- **[`windows/`](#windows-tools)** — PowerShell scripts for Windows. *(More landing here soon.)*

---

## Installation

Clone the repo, then install the tools for your platform onto your `PATH`.

```bash
git clone https://github.com/<your-username>/robs-tools.git
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

| Tool | Needs |
| --- | --- |
| `drivehealth`, `drivetemps`, `nvmehealth` | [`smartmontools`](https://www.smartmontools.org/) — `sudo apt install smartmontools` |
| `cputemps` | [`lm-sensors`](https://github.com/lm-sensors/lm-sensors) — `sudo apt install lm-sensors && sudo sensors-detect` |
| `dprune` | [`docker`](https://docs.docker.com/engine/) |
| `ports` | `iproute2` (`ss`) — usually preinstalled |
| `myip` | `curl`, `iproute2` — usually preinstalled |
| `jtop` | [`jetson-stats`](https://github.com/rbonghi/jetson_stats) — `sudo pip3 install jetson-stats` (Jetson only) |

Several tools use `sudo` internally, so you'll want appropriate privileges when running them.

---

## Linux tools

Listed alphabetically. Each entry notes what it does and any parameters it accepts.

### `cdl`

**Clear Docker Logs.** Truncates every Docker container's JSON log file to zero bytes, reclaiming disk space eaten by chatty containers — without stopping or removing anything.

```bash
cdl
```

Runs against `/var/lib/docker/containers/*/*-json.log`. Takes no parameters. Uses `sudo` internally.

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

| Param | Default | Description |
| --- | --- | --- |
| `path` | `.` (current dir) | Directory to scan |
| `count` | `15` | How many top entries to list |

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

| Param | Description |
| --- | --- |
| *(none)* | Prune containers, images, networks, and build cache |
| `--volumes`, `-v` | **Also** prune unused volumes (⚠️ may delete data) |
| `--help`, `-h` | Show usage |

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

Takes no parameters — it auto-detects which of `/dev/sda`–`/dev/sdf` exist. Uses `sudo smartctl` internally. (For NVMe drives, see [`nvmehealth`](#nvmehealth).)

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

SMART health at-a-glance for **NVMe** drives (`/dev/nvme0` through `/dev/nvme5`) — the companion to `drivehealth`, which only covers `/dev/sd*`. NVMe drives report different, more useful fields:

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

| Param | Description |
| --- | --- |
| *(none)* | List all listening TCP/UDP ports |
| `port` | Show only the given port number |

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

| Param | Description |
| --- | --- |
| `hostname...` | One or more hosts to set up (required) |
| `-u`, `--user <username>` | Remote username to log in as. Defaults to `$SSH_USER`, then your current user (`$USER`) |
| `-h`, `--help` | Show usage |

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

| Param | Description |
| --- | --- |
| *(none)* | List all failed units |
| `unit` | Show the last 30 journal lines for that unit |

Uses `sudo` for `journalctl`. Requires a `systemd` system.

```bash
svcfail                 # anything broken?
svcfail nginx.service   # why did nginx fail?
```

---

## Jetson tools

### `jtop`

**NVIDIA Jetson only.** A small launcher for [`jtop`](https://github.com/rbonghi/jetson_stats), the excellent interactive monitoring tool for Jetson boards (think `htop`, but Jetson-aware: GPU, power modes, temps, etc.). This wrapper just invokes the installed `jetson-stats` entry point.

```bash
jtop
```

Requires `jetson-stats` (`sudo pip3 install jetson-stats`). Parameters are passed straight through to the underlying `jtop` tool.

---

## Windows tools

PowerShell tools live in [`windows/`](windows/). This section is growing — check back soon. Each tool will get an entry here (alphabetical, same format as above) as it lands.

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
