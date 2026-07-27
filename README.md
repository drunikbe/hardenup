# hardenup

Provision a hardened Ubuntu VPS for running Docker containers — SSH hardening, firewall, intrusion detection, sensible kernel and logging defaults, all interactive. Ingress is a [Cloudflare Tunnel](#ingress-cloudflare-tunnel), so no inbound ports and no host-managed certificates.

One entry point — `sudo ./main.sh` — walks through each capability in order. Every step prints a two-line description and asks for permission before doing anything. Ctrl+C or lose the connection? Re-run the script; it resumes at the first incomplete step.

## What you get

- Non-root sudo user with an installed public SSH key + a generated Ed25519 keypair for outbound access (GitHub, peers).
- `sshd` locked to key-only auth, root login disabled, rate limits, secondary-terminal confirmation before the daemon reloads (no remote-lockout surprises).
- UFW: deny all incoming, SSH on the public interface, HTTP/HTTPS when you want it, allow-all on the private network if one is detected.
- Intrusion detection: fail2ban or CrowdSec — with sensible collections preinstalled for crowdsec (`linux`, `sshd`, `http-cve`, ...).
- Kernel hardening baseline (ASLR, SYN cookies, no source routing) + journald disk cap + UTC/NTP + unattended security upgrades (optional email notifications through a small MTA).
- Docker daemon log rotation, so container logs can't silently fill the disk.
- **Reversible**: originals of every touched file are preserved and `./undo.sh` puts them back.
- Optional **Docker Swarm** setup: cluster ports scoped to your node subnet, swarm init/join, and join tokens printed before the state file is wiped.
- **Docker Engine** (default, from `docker.com`) or **Podman** (rootless, daemonless). If Docker: either the `DOCKER-USER` iptables hardening or "I handle port exposure via my cloud provider's firewall".

> **Kubernetes?** RKE2 and the 60–79 platform stack used to live here. They are preserved on the [`k8s` branch](https://github.com/drunikbe/hardenup/tree/k8s) and are not part of this tree — see [`docs/roadmap.md`](docs/roadmap.md).

## Requirements

- Ubuntu 24.04 or newer (amd64 or arm64). Developed and verified on 26.04.
- Root — run with `sudo`.
- Outbound internet for package installs.
- Optional: a private network between hosts (auto-detected; used for firewall rules, fail2ban ignores, CrowdSec whitelists, inter-node traffic).

## Quick start

```bash
git clone https://github.com/drunikbe/hardenup.git /opt/hardenup
cd /opt/hardenup
sudo ./main.sh
```

Accept the defaults (press Enter) for a standard hardened Docker host.

## Usage

```bash
sudo ./main.sh                                  # walk the full wizard
sudo ./main.sh --dry-run                        # list remaining steps, no changes
sudo ./main.sh --only 25-firewall               # run exactly one step
sudo ./main.sh --redo 24-ssh-harden             # re-run a completed step
sudo ./main.sh --redo "2*"                      # re-run matching glob (whole 20-29)
sudo ./main.sh --answers FILE --non-interactive # headless run (KEY="VALUE" lines)
sudo ./main.sh --reset                          # wipe state.env + re-ask everything
sudo ./main.sh --force-reset                    # --reset without confirmation
```

`--redo` and `--only` are mutually exclusive (`--redo` mutates persistent state; `--only` just narrows this invocation). Use them in separate runs.

## How the wizard works

State lives at `/run/hardenup/state.env` (tmpfs, 0600, root-only) for the duration of the run. If the wizard is interrupted (Ctrl+C, lost SSH, failed step), the file stays and the next `sudo ./main.sh` picks up where you left off:

- Completed steps show as `✓ <name> [done at <timestamp>]` and are skipped.
- Skipped steps (answered `n` previously) re-prompt so you can reconsider.
- The final `99-finalize` step prints a run summary (host, user, networks, generated SSH public key) for you to save, then wipes the state file and verifies the wipe.

`/run` is tmpfs, so a full reboot clears it. Wait until the wizard finishes before rebooting, or use `--redo` afterwards to re-walk specific steps.

**Nothing runs silently.** Every step prints a one- or two-line description before asking for permission. Answer `n` and the step is marked skipped in `state.env` and bypassed.

## Steps

| # | Step | Notes |
|---|------|-------|
| `15` | Network detection | Public + (optional) private interface, IP, CIDR. Consumed by firewall, intrusion, Docker firewall. |
| `19` | MTA (msmtp) | Optional: set up a small mail relay so `unattended-upgrades` and cron email actually deliver. |
| `20` | Hostname | `hostnamectl set-hostname` |
| `21` | Non-root sudo user (+ SSH key) | Lockout guard: refuses to continue if you'd lose SSH access. |
| `22` | Ed25519 outbound keypair | For outbound Git / peer-to-peer SSH. |
| `18` | VPN (optional) | **Tailscale** (zero-config, account required) or **WireGuard** (paste peer config from UniFi / WG-Easy / self-hosted). WireGuard path offers a one-way sub-prompt (conntrack egress block in PostUp/PreDown) so the server can respond to inbound but can't initiate outbound over the tunnel. Installed early so 24 and 25 can offer VPN-aware options. |
| `23` | Base packages | apt update + curl, jq, git, htop, vim, tmux, unzip, net-tools. |
| `24` | SSH hardening | Drop-in config + secondary-terminal confirm before the daemon reloads. Sub-prompt when `VPN_KIND=tailscale`: enable Tailscale SSH (identity+ACL auth, `n` default — sshd-everywhere is the simpler model). No equivalent for WireGuard. |
| `25` | Host firewall (UFW) | Optional Docker Swarm cluster ports (2377/tcp, 7946/tcp+udp, 4789/udp) scoped to an RFC1918 node subnet — declared here so `--redo 25-firewall` can't wipe them. HTTP/HTTPS prompt (answer `n` on a tunnel-fronted host — cloudflared needs no inbound port). Multi-network-aware with SSH scope selector: **Anywhere** (default), **No public** (block public SSH; private+VPN allowed), **VPN only** (block public AND private SSH; VPN only — ⚠ console-recovery dependency if the VPN breaks). HTTP/HTTPS independent of scope. |
| `26` | Kernel hardening baseline | Security sysctls. `ip_forward` is set by 41 if the container runtime needs it. |
| `27` | Journald cap | 1G / 100M / 7d |
| `28` | Timezone + NTP | Defaults to UTC; accepts any IANA zone (`Europe/Brussels`, `America/Los_Angeles`...). |
| `29` | Unattended upgrades | Security-only patches. Writes a **drop-in** (`52-hardenup-unattended`) and leaves Ubuntu's own `50unattended-upgrades` / `20auto-upgrades` untouched — later apt files win for scalars, so the distro's `Allowed-Origins` (incl. both ESM origins) and any `Package-Blacklist` survive. Auto-reboot defaults **off**: synchronized reboots across Swarm managers lose Raft quorum. |
| `30` | Intrusion detection | None / fail2ban / CrowdSec. Both ignore `NET_PRIVATE_CIDR`. CrowdSec also auto-installs sensible collections. |
| `34` | Ubuntu Pro | Optional (ESM + Livepatch). |
| `40` | Container runtime | **Docker Engine (default)** / Podman / none. If Docker: sub-prompts for docker-group membership and UFW mitigation (`DOCKER-USER` chain or provider firewall). |
| `41` | Docker firewall | DOCKER-USER chain + `ip_forward=1`. Drops unsolicited inbound **on the public NIC only** — container egress (cloudflared!), overlay and swarm-node traffic keep working. Installs a small systemd unit for reboot persistence, since 26.04 dropped `iptables-persistent`. |
| `42` | Docker daemon config | Log rotation in `/etc/docker/daemon.json` (`json-file`, default 50m × 5). Docker ships **no** rotation, so container logs otherwise grow until the disk fills. Merges into an existing `daemon.json` rather than overwriting it. Requires a daemon restart — pauses for confirmation if containers are running. |
| `43` | Docker Swarm | Optional (default `n`): initialize a new swarm (prints join tokens) or join an existing one as manager/worker. Warns about Raft quorum — go 1 manager → 3, never sit on 2. |
| `66` | SSH peers | Optional (default `n`): pre-authorize inbound SSH keys from peer machines (Swarm nodes, backup host) so they can reach this host without a later `ssh-copy-id`. |
| `99` | Finalize | Prints a run summary, wipes state.env, verifies the wipe. |

## Ingress: Cloudflare Tunnel

hardenup does **not** install a host reverse proxy or manage certificates. Ingress is a Cloudflare Tunnel: `cloudflared` runs as a container, dials **out** to Cloudflare's edge, and traffic reaches your services over that outbound connection. TLS terminates at the edge.

What that buys you:

- **No inbound ports.** Answer `n` to step 25's HTTP/HTTPS question — nothing needs to listen on the public interface. The host's attack surface is SSH (or not even that, with `vpn_only` scope).
- **No certificate management.** No certbot, no acme.sh, no renewal cron, no DNS-01 plugin credentials sitting on the box.
- **No host web server.** Services are reached by their service name on a Docker overlay network, not through a local nginx vhost.

Sketch of the swarm-service pattern (create the tunnel and copy its token from the Cloudflare Zero Trust dashboard first):

```bash
docker service create --name cloudflared \
  --mode replicated --replicas 2 \
  --network my-overlay \
  --secret cf_tunnel_token \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate run
```

Point each public hostname at `http://<service-name>:<port>` in the tunnel's ingress rules. Two replicas give you a highly-available tunnel across swarm nodes.

> If you need a CF-independent fallback (host nginx/OpenResty/Apache + Let's Encrypt), that code is preserved on the [`k8s` branch](https://github.com/drunikbe/hardenup/tree/k8s) — it was removed from this tree in #7, not deleted.

## Undoing a run

hardenup preserves the original of every file it touches, and records what it changed:

- `/var/backups/hardenup/originals/` — each file exactly as it was before hardenup first touched it, in a mirrored tree (`/etc/ufw/user.rules` → `originals/etc/ufw/user.rules`).
- `/var/lib/hardenup/manifest.tsv` — append-only log of files modified/created, packages installed, services enabled, users created.

Both live outside `/run`, so they survive reboots and the state-file wipe at step 99.

```bash
sudo ./undo.sh --dry-run   # show what would be reverted; changes nothing
sudo ./undo.sh             # restore originals, asking before each change
sudo ./undo.sh --yes       # no per-item prompts
sudo ./undo.sh --packages  # ALSO remove packages hardenup installed
```

The original is captured on **first touch only**, keyed by path across all runs — so re-running a step (or `--redo`) never overwrites the pristine copy with an already-modified one.

Deliberately not automatic:

- **Packages** are opt-in (`--packages`). Removing `docker-ce` takes every container with it. Only packages hardenup itself installed are ever candidates — anything already present is never recorded as ours.
- **Users are never deleted** — `userdel -r` destroys a home directory. They're listed for you.
- **Ubuntu Pro and Swarm membership** are recorded as notes, not reversed: both have effects off this machine (a seat on your Canonical account, a node in the cluster's Raft state).

## Files

```
main.sh         wizard orchestrator
state.sh        ephemeral-per-run state helpers
lib.sh          shared functions (prompts, validators, detection)
modules/        numbered steps
CLAUDE.md       maintainer notes + gotchas
```
