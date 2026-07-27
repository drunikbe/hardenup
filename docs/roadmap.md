# hardenup roadmap

Execution order for the refocus tracked in [#1](https://github.com/drunikbe/hardenup/issues/1):
make `main`/`develop` target exactly one stack — **Ubuntu 26.04 + Docker Swarm + Cloudflare Tunnel** — and preserve the Kubernetes/RKE2 work on a branch instead of carrying it in the core.

**Issues are the source of truth for _what_; this file is the source of truth for _when_.**

## Guiding principle

Do the work on the **live Ubuntu 26.04 Raspberry Pi** and let the box confirm every change:

- `lsb_release -cs`, `apt-cache policy <pkg>`, `apt-get -s install <pkg>` (simulate before touching apt)
- inspect existing state before writing — `/etc/apt/apt.conf.d/`, `/etc/docker/daemon.json`, `systemctl` units
- run each touched module with `--dry-run` and verify against real system state, per hardenup's `configure_/run_/verify_` cycle and its "visibility over brevity" rule

## Order

1. **Preserve, then prune — [#2](https://github.com/drunikbe/hardenup/issues/2).**
   First: `git switch -c k8s && git push -u origin k8s` from current `main` HEAD (RKE2 intact). Nothing else starts until this branch exists on origin. Then remove RKE2 from `main` (spans modules 40 + 60–65 + 70–79).

2. **Get Docker installing on 26.04 — [#3](https://github.com/drunikbe/hardenup/issues/3).** Nothing downstream can be tested until Docker installs. Verify the docker.com codename actually 404s on the box, then pick the fallback.

3. **Docker daemon log rotation — [#6](https://github.com/drunikbe/hardenup/issues/6).** Small; do it as part of the Docker step so no swarm workload ever runs without bounded logs.

4. **Swarm awareness — [#5](https://github.com/drunikbe/hardenup/issues/5).** The point of the exercise: open the four cluster ports (scoped to the node subnet) and optionally offer `swarm init`/join. Default the docker-firewall path to "provider firewall" so it doesn't fight the overlay (there are no public ports anyway — Cloudflare Tunnel is the ingress).

5. **Drop the host web servers — [#7](https://github.com/drunikbe/hardenup/issues/7).** With Cloudflare Tunnel there's no host reverse proxy and no host certs — remove nginx/OpenResty from the main path (keep on a branch for a single-node fallback).

6. **Unattended-upgrades idempotency — [#4](https://github.com/drunikbe/hardenup/issues/4).** Reconcile with 26.04's pre-configured defaults instead of clobbering; default auto-reboot **off** on swarm managers (three rebooting at 04:00 = lost quorum).

## Definition of done

A single `sudo ./main.sh` run on a fresh Ubuntu 26.04 arm64 Pi produces a hardened host with Docker Engine installed, the swarm ports open on the LAN, bounded container logs, and no k8s/web-server prompts — and three such hosts form a healthy 3-manager swarm (`docker node ls`) with working overlay networking.
