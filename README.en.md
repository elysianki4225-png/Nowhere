# Nowhere (NW3) One-Click Scripts

One-click installation & operations scripts for the [Nowhere](https://github.com/NodePassProject/Nowhere)
protocol (NW3): download the official `nowhere` binary from GitHub Releases,
generate systemd services, and manage the **Portal**, **Vector** and **Egress**
roles from an interactive menu.

- Upstream protocol: <https://github.com/NodePassProject/Nowhere>
- 中文说明: [README.md](README.md)
- License: GPL-3.0-or-later (same as upstream)

## What it is

Nowhere relays TCP and UDP traffic over **TLS / QUIC** to an exit of your choice.
A single binary provides three roles:

```
              TLS / QUIC                      QUIC
+----------+                 +----------+                 +----------+
|  Vector  |---------------->|  Portal  |<----------------|  Egress  |
| (client) |                 | (server) |                 | (exit)   |
+----------+                 +----------+                 +----------+
     |                            |  direct / SOCKS5            |
     v                            v                             v
  local SOCKS5                 Target                         Target
```

| Role | Purpose | Where it runs |
| --- | --- | --- |
| **Portal** | Server relay: TLS+QUIC listeners, one fixed exit (direct / SOCKS5 / Egress) | Public VPS |
| **Vector** | Client: local SOCKS5 ingress that connects to Portal | Local machine |
| **Egress** | Remote exit: dials back to Portal over QUIC and reaches targets | Exit host (no inbound port) |

## Features

- **One command install**: `curl | bash` downloads, verifies, configures and starts everything
- **Verified downloads**: official GitHub Releases binaries, SHA-256 checked against the release API
- **Interactive wizard**: Enter accepts every default; full non-interactive mode via `--yes` + flags
- **All three roles**: Portal (direct / SOCKS5 / Egress exits), Vector, Egress
- **systemd managed**: one service per instance (`nowhere-<name>`), auto-restart, low-port binding
- **Client links**: prints `nowhere://` share links and `vector://` client URLs, QR code support
- **Certificate pinning**: fetch the Portal self-signed fingerprint and write `pin` in one step
- **Bilingual UI**: auto-detects system language; `--lang zh|en` or the menu can switch
- **Operations**: status, logs, probe, rate limits, update, uninstall

## Requirements

- Linux (x86_64 / aarch64, glibc or musl) with systemd
- `curl`, `tar`, root privileges
- Optional: `qrencode` (QR output), `openssl` (key generation fallback)
- FreeBSD / macOS can install the binary and run in the foreground (`nw run <name>`);
  systemd service management is Linux-only

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/elysianki4225-png/Nowhere/main/install.sh | sudo bash
```

If `raw.githubusercontent.com` is unreachable, use a mirror:

```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/elysianki4225-png/Nowhere/main/install.sh | sudo bash
```

## Quick start

### 1. Portal (server side)

```bash
sudo bash install.sh portal --yes
```

Open **TCP and UDP** on the listen port (default 2000) in the server firewall and
cloud security group. The installer prints the client links:

```
nowhere://<KEY>@1.2.3.4:2000?morph=1
vector://<KEY>@1.2.3.4:2000?in=127.0.0.1:1080&morph=1&pin=<fingerprint>
```

### 2. Vector (client side)

```bash
sudo bash install.sh vector --yes --portal-host 1.2.3.4 --portal-port 2000
```

Point applications at SOCKS5 `127.0.0.1:1080`. With a self-signed Portal
certificate, pass the fingerprint with `--pin`.

### 3. Egress (remote exit, no inbound port)

On the Portal host:

```bash
sudo bash install.sh portal --out egress --yes
```

On the exit host:

```bash
sudo bash install.sh egress --portal-host 1.2.3.4 --portal-port 2000 --pin <64-hex>
```

## Management menu

```bash
sudo nw menu
```

Instance status, start/stop/restart, log following, client links, reconfigure,
update and uninstall — all from the menu.

## Commands

| Command | Description |
| --- | --- |
| `nw menu` | Interactive management menu |
| `nw list` | List instances and their state |
| `nw status` | Service state + `nowhere status` telemetry |
| `nw start \| stop \| restart [name\|--all]` | Service lifecycle |
| `nw logs <name> [-f]` | Journal logs (follow with `-f`) |
| `nw link [name]` | Print client links + QR code |
| `nw key` | Generate a 32-hex shared key |
| `nw pin <name> [--apply]` | Fetch certificate fingerprint; `--apply` writes it and restarts |
| `nw probe <name> <host:port>` | Establish one real TCP Flow through Portal to verify setup |
| `nw run <name>` | Run in the foreground (no systemd) |
| `nw update` | Refresh the script and binary, restart instances |
| `nw uninstall <name\|--all>` | Remove instances (optionally the binary) |
| `nw version` | Script and binary versions |
| `nw lang zh\|en` | Switch UI language |

## Non-interactive options

```bash
bash nw.sh <portal|vector|egress|install> [options]
```

| Option | Description | Default |
| --- | --- | --- |
| `--role ROLE` | `portal` / `vector` / `egress` | wizard |
| `--name NAME` | Instance name; service becomes `nowhere-<NAME>` | role |
| `--key HEX` | 32 lowercase hex shared key | generated |
| `--port PORT` | Portal listen port | `2000` |
| `--tcp-port` / `--udp-port` | Separate TCP/UDP ports | — |
| `--carrier MODE` | `same` / `split` / `tcp` / `udp` | `same` |
| `--out MODE` | Portal exit: `direct` / `socks` / `egress` | `direct` |
| `--socks [user:pass@]host:port` | SOCKS5 upstream (with `--out socks`) | — |
| `--portal-host HOST` | Portal address for vector/egress | required |
| `--portal-port PORT` | Portal port for vector/egress | `2000` |
| `--net tcp\|udp` | Vector carrier | `tcp` |
| `--in [user:pass@]host:port` | Vector SOCKS5 listen address | `127.0.0.1:1080` |
| `--in-auth USER:PASS` | SOCKS5 authentication | none |
| `--pin HEX64` | Certificate SHA-256 pin | none |
| `--sni NAME` | Verified server name | endpoint host |
| `--morph 0\|1` | Wire masking (peers must agree) | `1` |
| `--rate N` / `--etar N` | Upload / download limit in Mbps (0 = off) | `0` |
| `--tls 1\|2` `--crt P` `--key P` | Self-signed (1) or PEM files (2) | `1` |
| `--public-addr ADDR` | Public address used in links | auto-detected |
| `--version TAG` | Install a specific release (e.g. `v3.0.1`) | latest |
| `--open-firewall` | Allow ports in ufw / firewalld | no |
| `--yes` | Non-interactive with defaults | no |
| `--lang zh\|en` | UI language | auto |

Environment variables: `NW_REF` (script ref), `NW_RAW_BASE` (script source, mirror
friendly), `NW_PREFIX` (default `/usr/local`), `NW_ETC` (default `/etc/nowhere`),
`NW_VERSION` (pin upstream release), `NW_LOCAL_TARBALL` (install from a local
archive), `NW_SKIP_VERIFY=1` (skip checksum, not recommended).

## File layout

```
/usr/local/bin/nowhere                 # official binary
/usr/local/bin/nw                      # this manager
/usr/local/bin/nowhere-<name>          # instance launcher (reads the url file)
/etc/nowhere/<name>/url                # runtime URL (role, key, parameters)
/etc/nowhere/<name>/meta               # instance metadata
/etc/nowhere/<name>/env                # optional NOW_* runtime tuning
/etc/systemd/system/nowhere-<name>.service
```

## Firewall

- Portal: allow **TCP + UDP** on the listen port (default 2000), including the
  cloud security group
- Vector: only the local SOCKS5 port must be reachable by applications
- Egress: **no inbound port needed** (QUIC dial-out)

The script detects `ufw` / `firewalld` and prints the right commands;
`--open-firewall` applies them automatically.

## Security notes

- The 32-hex shared key is the only credential — distribute it over a trusted
  channel and keep it identical on both peers
- With self-signed certificates (`tls=1`), clients **must** set `pin`
  (`nw pin <portal-instance>` prints it)
- Prefer `tls=2` with a CA-issued certificate and hostname when available
- Services run as root (low ports may be bound); `NoNewPrivileges` is enabled

## FAQ

**Connection fails after install?**
Check in order: ① TCP+UDP port open on Portal (firewall + security group);
② identical keys on both peers; ③ identical `morph` (default 1); ④ `pin` set for
self-signed certs; ⑤ `nw probe <portal-instance> example.com:443`.

**`nowhere status` prints nothing?**
`status` reads running instances over local IPC — run it as root and make sure
the service is up (`nw list`).

**Multiple instances?**
Use `--name`, e.g. `bash nw.sh portal --name p2 --port 3000` → service
`nowhere-p2`, config in `/etc/nowhere/p2/`.

**Upgrade?**
`sudo nw update` refreshes the script and the latest binary, then restarts all
instances. Pin a version with `nw update --version v3.0.1`.

**Remove everything?**
`sudo nw uninstall --all` (optionally removes the binary too).

## Related projects

- [Nowhere](https://github.com/NodePassProject/Nowhere) — protocol & official binary (upstream)
- [nowhere-sh](https://github.com/NodePassProject/nowhere-sh) — official Linux deployment script
- [Anywhere](https://github.com/NodePassProject/Anywhere) — native Apple clients
- [NowhereDash](https://github.com/NodePassProject/NowhereDash) — web fleet dashboard

## Disclaimer

These scripts only automate installation and operation of the upstream Nowhere
protocol; they do not redistribute or modify the official binary. You are
responsible for complying with applicable laws and regulations.

## License

[GPL-3.0-or-later](LICENSE), matching upstream Nowhere.
