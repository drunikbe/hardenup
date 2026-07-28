# Roadmap — refocus on one stack

Tracking issue: [#1](https://github.com/drunikbe/hardenup/issues/1).

## The target stack

hardenup used to serve three container runtimes (Podman / Docker / RKE2) and
three web servers (OpenResty / nginx / Apache). That breadth was the main
source of complexity and of code paths nobody ever ran. `main` / `develop`
now target exactly one stack:

| Layer | Choice |
|-------|--------|
| OS | Ubuntu 26.04 (`resolute`) — Raspberry Pi 5 dev cluster + Hetzner prod |
| Runtime | Docker Engine (`docker-ce` from download.docker.com) |
| Orchestration | Docker Swarm — 3 managers on the Pi cluster; single-node prod grows into a swarm later |
| Ingress | Cloudflare Tunnel (`cloudflared` as a swarm service) — outbound-only, TLS terminated at the CF edge |
| Kept from before | hardened user creation, SSH hardening, UFW, fail2ban/CrowdSec, unattended-upgrades |

Because ingress is a Cloudflare Tunnel, there are **no public inbound ports**
and **no host-managed certificates**. That is what makes the host reverse
proxy and the ACME modules unnecessary rather than merely optional.

## Preserved, not deleted

The Kubernetes work is intact on the **[`k8s`](https://github.com/drunikbe/hardenup/tree/k8s)**
branch, cut from the last `main` commit that contained it
(`74250e9`). That branch still has RKE2 (modules 60–65), the platform stack
(70–79: Helm, local-path, ingress-nginx, cert-manager, monitoring, logging,
CrowdSec, Rancher, PSS, NetworkPolicy), and the docs describing them. Nothing
was lost — if the k8s path is ever wanted again, it is finished work.

## Execution order

Work happens on branches off `develop`, one issue per PR, verified on a live
Ubuntu 26.04 arm64 box before merge.

| Order | Issue | Why here |
|-------|-------|----------|
| 1 | [#2](https://github.com/drunikbe/hardenup/issues/2) Preserve RKE2 on `k8s`, remove from main | Preservation must happen before any removal. Deleting 16 modules first also shrinks the surface every later change has to consider. |
| 2 | [#7](https://github.com/drunikbe/hardenup/issues/7) Drop the web-server modules | Same reasoning — removal before addition. Also unblocks the ingress story: nothing should suggest a host reverse proxy once CF Tunnel is the answer. |
| 3 | [#3](https://github.com/drunikbe/hardenup/issues/3) Docker Engine install on 26.04 | Everything downstream (log rotation, Swarm) assumes a working Docker install, so this is verified first. |
| 4 | [#6](https://github.com/drunikbe/hardenup/issues/6) Docker daemon log rotation | Small, self-contained, and wants to land before nodes start running real workloads that fill the disk. |
| 5 | [#5](https://github.com/drunikbe/hardenup/issues/5) Docker Swarm awareness | The largest addition: UFW ports scoped to the node subnet, optional init/join, DOCKER-USER interaction with overlay traffic. |
| 6 | [#4](https://github.com/drunikbe/hardenup/issues/4) unattended-upgrades idempotency | Depends on knowing whether the node is a Swarm manager (auto-reboot must default off there), so it lands after #5. |

## Verification notes from the live 26.04 box

Recorded here so the next person doesn't have to re-derive them.

### download.docker.com publishes `resolute` (issue #3 premise was wrong)

Issue #3 predicted the docker.com apt repo would 404 on 26.04. It does not.
Verified 2026-07-27 on Ubuntu 26.04 arm64:

```
$ curl -fsI https://download.docker.com/linux/ubuntu/dists/resolute/Release
HTTP/2 200

$ apt-get -s install docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
Inst containerd.io (2.2.6-1~ubuntu.26.04~resolute Docker CE:resolute [arm64])
Inst docker-ce-cli (5:29.6.2-1~ubuntu.26.04~resolute Docker CE:resolute [arm64])
Inst docker-ce (5:29.6.2-1~ubuntu.26.04~resolute Docker CE:resolute [arm64])
...
```

The repo carries `amd64 arm64 armhf s390x ppc64el` and a current docker-ce
(29.6.2). No codename fallback is needed. Ubuntu's own `docker.io` (29.1.3)
is also available in `universe` as a fallback, but the upstream repo is
preferred — it tracks releases faster and ships the compose/buildx plugins.

A real install on the box confirmed it end to end: docker-ce 29.6.2,
compose v5.3.1, buildx 0.35.0, `docker info` healthy (overlayfs, systemd
cgroup v2), `docker swarm init` elects a leader, and an attachable overlay
network creates and deletes cleanly.

### The actual bug in that code path was `gpg --dearmor`

Issue #3 pointed at the right function for the wrong reason. `_run_docker`
piped the Docker GPG key into `gpg --dearmor -o /etc/apt/keyrings/docker.gpg`
with no `--yes`. gpg refuses to overwrite an existing file, and with no tty
to prompt on it exits 2 — which under `set -euo pipefail` aborted the whole
module. So `--redo 40-runtime` on any host that had already installed Docker
would fail, violating the repo's "idempotent by overwrite" convention.

Verified on the box, with the keyring already present:

```
$ curl -fsSL .../gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
exit 0
$ curl -fsSL .../gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
gpg: cannot open '/dev/tty': No such device or address
exit 2
```

### Codename resolution is now defensive anyway

`_docker_repo_codename` reads `VERSION_CODENAME` from `/etc/os-release`
(always present — `lsb_release` comes from a package a minimal image may
lack, and 40-runtime can run standalone before 23-packages installs it),
probes the docker.com `Release` file for that suite, and only falls back to
the newest published LTS if the probe fails. Today it falls back on nothing;
it exists so a future Ubuntu release degrades gracefully instead of writing
a source file that 404s.

### Anything that pins a codename is still worth auditing

The 404 risk is real in general, just not today: the nginx and OpenResty
modules removed in #7 keyed their apt repos off `lsb_release -cs` against
`nginx.org` and `openresty.org`, which publish far fewer suites than Docker
does. Any future module adding a third-party apt repo should verify the
suite exists for the running codename before writing the source file.

### Swarm work (#5) turned up three pre-existing bugs

**1. `DOCKER-USER` default-drop broke container egress.** `DOCKER-USER` is in
`FORWARD`, which carries both directions of container traffic, so the
unqualified `-j DROP` matched new *outbound* connections too. On a single-NIC
host — where 15-networks reports no private network, so there was no allow
rule at all — every container lost outbound networking including DNS.
Verified: `docker run alpine wget https://download.docker.com/` failed with
`bad address`, the DROP counter advanced, and removing the rule fixed it.

This is fatal for this stack specifically, because ingress is a Cloudflare
Tunnel and `cloudflared` works by dialling **out**. The drop is now scoped
with `-i <public iface>`; with no known public interface the module installs
no drop at all rather than an unscoped one.

**2. Rule flush never removed most of its own rules.** `iptables -D` needs the
complete rule spec, so the drain loops — which passed only the comment — never
matched the `-m conntrack` RETURN or the `-s <cidr>` RETURNs. Every re-run
appended another copy. Now flushed by line number matched on the comment.

**3. 26.04 has no `iptables-persistent` *or* `netfilter-persistent`.** Both are
gone from the archive (checked with main/restricted/universe/multiverse
enabled; no candidate for either, nothing else provides the service). The old
code called them unconditionally, then fell back to writing
`/etc/iptables/rules.v4` into a directory that didn't exist — so the
DOCKER-USER rules silently vanished on the next reboot. 41 now installs a
small `hardenup-iptables.service` ordered before `docker.service`.

### Single-NIC LAN hosts aren't "private" to 15-networks

15-networks defines the private interface as *RFC1918 on a non-default-route
NIC*. A Pi cluster (or any homelab box) has one NIC carrying the default
route, so `NET_HAS_PRIVATE=no` even though its only address is 10.0.0.0/24.
Declaring that NIC as "private" would be wrong — 25-firewall's private rule is
`allow in on <iface>`, i.e. allow-all, which on a single-NIC host disables the
firewall entirely. Hence the swarm prompt asks for the node subnet separately
and defaults it to the public interface's own network.

### Verified on the box, single node

`docker swarm init`, an attachable overlay network, and a replicated service
with a published port all work with the DOCKER-USER rules active: egress OK,
published port HTTP 200, overlay service-name resolution OK, and exactly three
tagged rules after three runs. Multi-node join and a 3-manager quorum could
not be verified — there is only one Pi in this session. The UFW rules were
validated with `ufw --dry-run` rather than by enabling UFW, because this
session rides the SSH connection those rules would filter.

### unattended-upgrades (#4): drop-in beats rewrite

26.04 ships unattended-upgrades `ii`, active+enabled, with a populated
`50unattended-upgrades` (Allowed-Origins incl. both ESM origins,
Package-Blacklist, DevRelease). The module used to `cat >` over it.

apt reads `/etc/apt/apt.conf.d/*` in lexical order and later assignments win
for **scalars**, so hardenup now owns a single `52-hardenup-unattended`
drop-in and never touches the distro's files. Confirmed on the box: after two
runs, `50unattended-upgrades` and `20auto-upgrades` are byte-identical
(md5 unchanged), all four distro Allowed-Origins remain effective, and
`unattended-upgrades --dry-run` resolves them correctly.

`Allowed-Origins` is deliberately excluded from the drop-in — it is a list
(`Foo:: "x"` appends, it does not replace), the distro's value is already
right, and a botched override silently stops security patching.

Auto-reboot now defaults to **n**, per the issue's cluster-safety point: 29
runs long before the swarm choice at 43 and cannot infer whether the host is a
manager, and losing Raft quorum to a synchronized 04:00 reboot is worse than a
kernel patch waiting for a window.

Also fixed while here: the mail prompt was labelled "(blank to skip)" but
`ask_input` loops on empty input, so the no-mail path was unreachable — an
operator without a relay had to invent an address. It is now gated behind its
own y/n.

### Recipes (#30) rested on three premises that were wrong

The issue proposed building recipes on `--answers`, `--non-interactive` and
`STEP_<name>_SKIPPED=yes`, on the grounds that all three already worked. Two
of the three did not, and the third only half did.

**1. `STEP_*` keys were silently dropped from every answers file.**
`state_load_answers` matched `^[A-Z_][A-Z0-9_]*=`, which does not match
`STEP_docker_SELECTED` — the module-derived middle segment is lowercase. So
the documented "put `STEP_<name>_SKIPPED=yes` in an answers file to turn a
step off" had never worked; the line was skipped as if it were a comment.
Verified before changing anything:

```
$ [[ "STEP_docker_SELECTED=yes" =~ ^[A-Z_][A-Z0-9_]*= ]] && echo match || echo no
no
$ [[ "SSH_PORT=2222" =~ ^[A-Z_][A-Z0-9_]*= ]] && echo match || echo no
match
```

Now `^[A-Z_][A-Za-z0-9_]*=`. It must still start uppercase — that is what
keeps stray shell (`if [[ ... ]]`, `foo() {`) from being read as an
assignment by a parser that deliberately never sources the file.

**2. `--non-interactive` could not run headless.** `ensure_tmux` re-execs into
a fresh tmux session before any module runs, and tmux cannot allocate one
without a terminal:

```
$ sudo ./main.sh --recipe swarm-worker --non-interactive
[OK] Re-launching inside tmux session 'cloud-main'
open terminal failed: not a terminal
```

Which means the flag only ever worked from an operator's terminal — the exact
situation it exists to avoid. `ensure_tmux` now returns early when stdin or
stdout isn't a tty. There is nothing to protect in that case: session
protection exists so a dropped SSH connection can't strand a half-applied
run, and a cloud-init invocation has no SSH session to drop.

**3. A recipe can only steer a prompt whose default comes from state.**
Recipe mode makes a prompt take its *default*, so `ask_yesno "Open
HTTP/HTTPS?" "y"` ignores whatever the recipe put in `FIREWALL_OPEN_HTTP`.
Four prompts needed converting to the `state_get`-derived idiom the rest of
the repo already used: 25's HTTP toggle, 25's SSH-scope `ask_choice`, 40's
docker-group toggle, and — worst — 43's top-level y/n, which defaults to `n`,
so both swarm recipes were skipping the one step they exist for.

### `--dry-run` was writing to the live state file

Pre-seeding is a write: `state_set` writes through to `state.env`. So
`--recipe X --dry-run`, a command whose entire purpose is to change nothing,
left all of the recipe's answers behind for the next real run to inherit
silently. Observed on the box — `state.env` held all 16 of swarm-manager's
keys after a dry run. `--dry-run` now loads the real state (the plan has to
reflect genuinely completed steps) and then repoints `STATE_FILE` at a
throwaway copy in the same tmpfs directory. It also no longer re-execs into
tmux, which is why the command above could not be run from a non-terminal at
all.

### Verified on the box (Pi 5, 26.04 arm64, swarm01)

End to end, `--recipe swarm-manager` driving real modules with zero prompts:

- **20-hostname** — took `swarm01` from `hostnamectl`. The recipe carries no
  hostname, which is the point: the same file works on the next node.
- **15-networks** — derived `eth0` / `10.0.0.169`, correctly answered "no
  private network" on this single-NIC host.
- **42-docker-daemon** — wrote `50m` × `5` from the recipe, restarted dockerd,
  verify passed against `/etc/docker/daemon.json`.
- **43-docker-swarm** — `docker swarm init --advertise-addr 10.0.0.169`, with
  the address derived from the NIC rather than named in the file. Node came up
  `Ready` / `Leader`. The swarm was left afterwards to restore the box.
- **25-firewall's derivations**, exercised through `configure_` only:
  `SWARM_NODE_CIDR=10.0.0.0/24` from `_local_subnet_of eth0`, and
  `FIREWALL_OPEN_HTTP=no` surviving from the recipe (which is what proves the
  hard-coded-default fix landed). The resulting swarm-port rules were checked
  with `ufw --dry-run`, which applies nothing:
  `-A ufw-user-input -p tcp --dport 2377 -s 10.0.0.0/24 -j ACCEPT`.

The safety property, tested against a real pty:

| mode | `ask_confirm_critical` behaviour |
|------|----------------------------------|
| `RECIPE_MODE=1`, terminal | renders the menu and reads the answer |
| `NON_INTERACTIVE=1`, terminal | renders the menu and reads the answer |
| either, no terminal, no `--unattended` | refuses with the flag name, returns "no" |
| `UNATTENDED=1` | takes the default, logged at WARN |

and `--unattended` is refused outright while 24-ssh-harden is in the plan,
with `STEP_ssh_harden_SKIPPED=yes` as the deliberate opt-out (confirmed the
escape hatch is accepted once set).

**Not verified.** UFW was never enabled — this session rides SSH from
10.0.0.101 over the rules 25-firewall installs, so the firewall step was
checked with `ufw --dry-run` only, as in earlier sessions. 24-ssh-harden was
not run against live sshd for the same reason; its confirmation prompt was
tested as a function, not as a step. Multi-node join (`swarm-worker` against a
real manager) still needs a second Pi — see #20.
