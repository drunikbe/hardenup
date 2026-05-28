# hardenup

Provision a hardened Ubuntu 24.04 VPS for running Docker or Podman containers behind a Let's Encrypt-fronted reverse proxy — SSH hardening, firewall, intrusion detection, sensible kernel and logging defaults, all interactive. Optional Kubernetes (RKE2) path for operators who need it.

One entry point — `sudo ./main.sh` — walks through each capability in order. Every step prints a two-line description and asks for permission before doing anything. Ctrl+C or lose the connection? Re-run the script; it resumes at the first incomplete step.

## What you get

- Non-root sudo user with an installed public SSH key + a generated Ed25519 keypair for outbound access (GitHub, peers).
- `sshd` locked to key-only auth, root login disabled, rate limits, secondary-terminal confirmation before the daemon reloads (no remote-lockout surprises).
- UFW: deny all incoming, SSH on the public interface, HTTP/HTTPS when you want it, allow-all on the private network if one is detected.
- Intrusion detection: fail2ban or CrowdSec — with sensible collections preinstalled for crowdsec (`linux`, `sshd`, `http-cve`, ...).
- Kernel hardening baseline (ASLR, SYN cookies, no source routing) + journald disk cap + UTC/NTP + unattended security upgrades (optional email notifications through a small MTA).
- **Podman** (default, rootless, daemonless) or **Docker Engine** (from `docker.com`). If Docker: either the `DOCKER-USER` iptables hardening or "I handle port exposure via my cloud provider's firewall".
- **OpenResty** (default, nginx + Lua), **nginx** (upstream `nginx.org`), or **Apache** (upstream `ppa:ondrej/apache2`) as a host reverse proxy — with optional **CrowdSec Lua bouncer** on OpenResty.
- **Let's Encrypt** via certbot or acme.sh, HTTP-01 or DNS-01 challenge, wildcards supported with Cloudflare / Route53 / DigitalOcean DNS plugins.

Optional (step 60, default `n`): turn this host into an **RKE2 Kubernetes node** — see [Kubernetes path](#kubernetes-path-optional) at the bottom.

## Requirements

- Ubuntu 24.04 (amd64 or arm64).
- Root — run with `sudo`.
- Outbound internet for package installs.
- Optional: a private network between hosts (auto-detected; used for firewall rules, fail2ban ignores, CrowdSec whitelists, inter-node traffic).

## Quick start

```bash
git clone https://github.com/drunikbe/hardenup.git /opt/hardenup
cd /opt/hardenup
sudo ./main.sh
```

Accept the defaults (press Enter) for a standard Docker-/Podman-with-reverse-proxy host. Answer `n` at step 60 to skip Kubernetes.

## Usage

```bash
sudo ./main.sh                                  # walk the full wizard
sudo ./main.sh --dry-run                        # list remaining steps, no changes
sudo ./main.sh --only 25-firewall               # run exactly one step
sudo ./main.sh --redo 24-ssh-harden             # re-run a completed step
sudo ./main.sh --redo "7*"                      # re-run matching glob (whole 70-79)
sudo ./main.sh --answers FILE --non-interactive # headless run (KEY="VALUE" lines)
sudo ./main.sh --reset                          # wipe state.env + re-ask everything
sudo ./main.sh --force-reset                    # --reset without confirmation
```

`--redo` and `--only` are mutually exclusive (`--redo` mutates persistent state; `--only` just narrows this invocation). Use them in separate runs.

## How the wizard works

State lives at `/run/hardenup/state.env` (tmpfs, 0600, root-only) for the duration of the run. If the wizard is interrupted (Ctrl+C, lost SSH, failed step), the file stays and the next `sudo ./main.sh` picks up where you left off:

- Completed steps show as `✓ <name> [done at <timestamp>]` and are skipped.
- Skipped steps (answered `n` previously) re-prompt so you can reconsider.
- The final `99-finalize` step prints any generated secrets (Grafana password, RKE2 token, CrowdSec bouncer key, Rancher bootstrap) for you to save, then wipes the state file and verifies the wipe.

`/run` is tmpfs, so a full reboot clears it. Wait until the wizard finishes before rebooting, or use `--redo` afterwards to re-walk specific steps.

**Nothing runs silently.** Every step prints a one- or two-line description before asking for permission. Answer `n` and the step is marked skipped in `state.env` and bypassed.

## Steps (Docker/Podman path)

These are the steps a non-Kubernetes operator sees. Answer `n` at step 60 and nothing past it runs.

| # | Step | Notes |
|---|------|-------|
| `15` | Network detection | Public + (optional) private interface, IP, CIDR. Consumed by firewall, intrusion, webserver, Docker firewall. |
| `19` | MTA (msmtp) | Optional: set up a small mail relay so `unattended-upgrades` and cron email actually deliver. |
| `20` | Hostname | `hostnamectl set-hostname` |
| `21` | Non-root sudo user (+ SSH key) | Lockout guard: refuses to continue if you'd lose SSH access. |
| `22` | Ed25519 outbound keypair | For outbound Git / peer-to-peer SSH. |
| `18` | VPN (optional) | **Tailscale** (zero-config, account required) or **WireGuard** (paste peer config from UniFi / WG-Easy / self-hosted). WireGuard path offers a one-way sub-prompt (conntrack egress block in PostUp/PreDown) so the server can respond to inbound but can't initiate outbound over the tunnel. Installed early so 24 and 25 can offer VPN-aware options. |
| `23` | Base packages | apt update + curl, jq, git, htop, vim, tmux, unzip, net-tools. |
| `24` | SSH hardening | Drop-in config + secondary-terminal confirm before the daemon reloads. Sub-prompt when `VPN_KIND=tailscale`: enable Tailscale SSH (identity+ACL auth, `n` default — sshd-everywhere is the simpler model). No equivalent for WireGuard. |
| `25` | Host firewall (UFW) | Multi-network-aware with SSH scope selector: **Anywhere** (default), **No public** (block public SSH; private+VPN allowed), **VPN only** (block public AND private SSH; VPN only — ⚠ console-recovery dependency if the VPN breaks). HTTP/HTTPS independent of scope. |
| `26` | Kernel hardening baseline | Security sysctls. `ip_forward` is set by 41 / 62 if the container runtime needs it. |
| `27` | Journald cap | 1G / 100M / 7d |
| `28` | Timezone + NTP | Defaults to UTC; accepts any IANA zone (`Europe/Brussels`, `America/Los_Angeles`...). |
| `29` | Unattended upgrades | Security-only patches; optional auto-reboot; optional `Mail` directive (needs step 19). |
| `30` | Intrusion detection | None / fail2ban / CrowdSec. Both ignore `NET_PRIVATE_CIDR`. CrowdSec also auto-installs sensible collections. |
| `34` | Ubuntu Pro | Optional (ESM + Livepatch). |
| `40` | Container runtime | **Podman (default)** / Docker Engine / none. If Docker: sub-prompts for docker-group membership and UFW mitigation (`DOCKER-USER` chain or provider firewall). |
| `41` | Docker firewall | DOCKER-USER chain + `ip_forward=1`. Runs only when Docker is chosen AND the `DOCKER-USER` mitigation is picked at step 40. Podman doesn't have the UFW-bypass problem. |
| `50` | Host reverse proxy selector | **Shape** first: `single-site` (wizard wires default vhost + LE cert), `multi-site` (wizard installs engine only; operator adds per-site vhosts/certs), `other` (internal / proxy-only / advanced). Then **engine**: **OpenResty (default)** / nginx / Apache. All three install from upstream repos. Domain + LE email are only prompted in `single-site` shape. |
| `51–53` | Install chosen proxy | Writes an HTTP-only default vhost with an ACME webroot location. OpenResty additionally gets the CrowdSec Lua bouncer if step 30 picked CrowdSec. TLS is step 54. |
| `54` | TLS certificates | Optional Let's Encrypt. Client: certbot / acme.sh. Challenge: HTTP-01 (default) or DNS-01 (wildcards / private hosts). DNS providers: Cloudflare / Route53 / DigitalOcean / manual. Writes the TLS server block for whichever proxy was installed. |
| `60` | **Install Kubernetes (RKE2)?** | Default: `n`. Answer `n` to stop here — steps 61–79 are all gated on yes. See the Kubernetes section if you want to say yes. |
| `99` | Finalize | Prints generated secrets, wipes state.env, verifies the wipe. |

---

## Kubernetes path (optional)

Answer `y` at step 60 to turn this host into an RKE2 node. The wizard continues through 60–79 using everything you already set up in the Docker path — base hardening, user, SSH, firewall, intrusion detection, and private-network awareness all apply equally to a K8s node.

### Steps 60–79

| # | Step | Notes |
|---|------|-------|
| `60` | RKE2 preflight | Asks "Install Kubernetes?". All subsequent steps gate on this yes. |
| `61` | RKE2 config | Role (bootstrap / additional server / worker), cluster token, CNI (Calico/Cilium/Canal), WireGuard, TLS SANs, audit rules. Private IP auto-populated from step 15. |
| `62` | RKE2 install | K8s apt packages (ipset, conntrack, socat, open-iscsi, nfs-common, auditd) + CNI sysctl/modules + sha256-verified installer. |
| `63` | RKE2 service | `systemctl enable --now rke2-{server,agent}`; waits for Node Ready. |
| `64` | RKE2 WireGuard | `HelmChartConfig` for Cilium/Canal (bootstrap only). Calico WG is post-install. |
| `65` | RKE2 post | `/etc/profile.d/rke2.sh` (kubectl on PATH) + `/usr/local/bin/rke2-enable-wireguard` for Calico+WG. |
| `66` | SSH peers | Pre-authorize inter-node SSH keys so operators can `ssh node02` from `node01`. |
| `70–79` | Platform stack | Helm / local-path-provisioner / ingress-nginx / cert-manager / monitoring (Prom + Grafana + AM) / logging (Loki + Promtail) / CrowdSec k8s / Rancher / Pod Security Standards / NetworkPolicy. Each is its own y/n; all gate on RKE2 being up. |

### Multi-node bring-up

1. **First server** — `sudo ./main.sh` → say yes at step 60 → role `bootstrap`. Save the cluster token printed at step 99.
2. **Additional servers, one at a time** — wait for each to show `Ready` before starting the next. `sudo ./main.sh` → role `Additional server` → paste the token.
3. **Workers** — can join in parallel. `sudo ./main.sh` → role `Worker`.
4. **Platform stack** — once all nodes are `Ready`, run `sudo ./main.sh` again on any server and say yes to the platform-stack modules (70–79).
5. **Calico + WireGuard** — after all nodes have joined, run `sudo /usr/local/bin/rke2-enable-wireguard` on the bootstrap node.

## Files

```
main.sh         wizard orchestrator
state.sh        ephemeral-per-run state helpers
lib.sh          shared functions (prompts, validators, detection)
modules/        numbered steps
CLAUDE.md       maintainer notes + gotchas
```
