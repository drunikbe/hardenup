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

### Anything that pins a codename is still worth auditing

The 404 risk is real in general, just not today: the nginx and OpenResty
modules removed in #7 keyed their apt repos off `lsb_release -cs` against
`nginx.org` and `openresty.org`, which publish far fewer suites than Docker
does. Any future module adding a third-party apt repo should verify the
suite exists for the running codename before writing the source file.
