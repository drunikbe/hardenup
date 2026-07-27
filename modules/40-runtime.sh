# shellcheck shell=bash
# =============================================================================
# 40-runtime.sh — Container platform: Docker Engine / Podman
# =============================================================================
#
# Single fork in the road. Two mutually exclusive options + none:
#
#   Docker Engine — docker.com's `docker-ce` apt package. The stack this repo
#                   targets: Docker Swarm for orchestration, Cloudflare Tunnel
#                   for ingress. Runs as a root daemon and manipulates iptables
#                   in a way that bypasses UFW; step 41-docker-firewall closes
#                   that hole (or the operator uses a provider firewall).
#                   Default.
#
#   Podman        — daemonless, rootless-by-default. Fine for a single host
#                   running plain containers, but it has no Swarm equivalent,
#                   so the Docker-only steps (41 firewall, 42 daemon config,
#                   43 swarm) won't apply. Drop-in `docker` CLI via the
#                   podman-docker shim. No iptables bypass.
#
# Sets CONTAINER_RUNTIME to `docker` / `podman` / `none`.
# Downstream gate flags are wired from the choice so mutually-exclusive
# modules stay invisible on the wrong path:
#   - STEP_docker_SELECTED=yes  → 41-docker-firewall, 42-docker-daemon apply
# When the choice changes on --redo, the inverse flag is unset so stale
# state from a prior run doesn't leak into the new path.
#
# Kubernetes (RKE2) used to be the third option here, pulling in a 60-79
# platform stack. That path is preserved on the `k8s` branch and is not part
# of this one-stack tree — see docs/roadmap.md.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_runtime() { return 0; }

detect_runtime() {
    if systemctl is-active --quiet docker 2>/dev/null; then
        state_set CONTAINER_RUNTIME docker
    elif command -v podman >/dev/null 2>&1; then
        state_set CONTAINER_RUNTIME podman
    fi
}

configure_runtime() {
    info "Pick ONE container platform for this host. Docker Engine is what this"
    info "repo targets — it's the only one with Swarm, so the cluster step (43)"
    info "and Cloudflare Tunnel ingress assume it. Podman is daemonless and"
    info "rootless-by-default, but single-host only: no Swarm, no step 43."
    if ! ask_yesno "Install a container platform (docker/podman)?" "y"; then
        state_set CONTAINER_RUNTIME none
        state_unset STEP_docker_SELECTED 2>/dev/null || true
        state_mark_skipped runtime
        return 0
    fi

    # Docker is idx 1 and the default. Default carries over from
    # detect_runtime when a platform is already present.
    local default=1
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) default=1 ;;
        podman) default=2 ;;
    esac
    ask_choice "Container platform" "$default" \
        "Docker Engine (recommended)|docker.com's docker-ce; root daemon; supports Swarm; needs step 41 or a provider firewall" \
        "Podman|daemonless; rootless by default; drop-in docker CLI via podman-docker; no Swarm"
    case "$REPLY" in
        1) _configure_docker ;;
        2) _configure_podman ;;
    esac
}

_configure_docker() {
    state_set CONTAINER_RUNTIME docker
    state_set STEP_docker_SELECTED yes

    # docker.com's step 1: conflicting packages must go before docker-ce goes
    # on. Asked rather than done silently — this uninstalls software, which is
    # never something a step should commit to without showing the operator.
    # Only prompted when something actually conflicts, so the common clean-host
    # case adds no friction.
    local conflicts
    conflicts="$(_docker_conflicts_installed)"
    if [[ -n "$conflicts" ]]; then
        info "These installed packages conflict with Docker Engine:"
        info "  ${conflicts}"
        info "They ship rival binaries (podman-docker and docker.io both provide"
        info "/usr/bin/docker) or a second container runtime. docker.com's install"
        info "guide removes them first; leaving them makes the install unreliable."
        if ask_yesno "Remove the conflicting packages listed above?" "y"; then
            state_set DOCKER_REMOVE_CONFLICTS yes
        else
            state_set DOCKER_REMOVE_CONFLICTS no
            warn "Keeping them — 'docker' on your PATH may not be Docker Engine."
        fi
    else
        state_set DOCKER_REMOVE_CONFLICTS no
    fi

    local user default="n"
    user="$(state_get USER_NAME)"
    [[ -n "$user" ]] && default="y"
    if [[ -n "$user" ]]; then
        info "Docker-group membership lets '$user' run 'docker' without sudo — but"
        info "it's effectively root on this host: any member can run"
        info "  docker run -v /:/host ...  and read/write ANY file as root."
        info "Decline if you'd rather keep using 'sudo docker' for a clean audit trail."
        if ask_yesno "Add '$user' to the 'docker' group?" "$default"; then
            state_set DOCKER_ADD_USER yes
        else
            state_set DOCKER_ADD_USER no
        fi
    else
        state_set DOCKER_ADD_USER no
    fi

    # Docker's daemon inserts iptables rules that bypass UFW, so bound
    # container ports become reachable from the internet unless mitigated.
    # Two ways to handle it:
    info "Docker bypasses UFW by default — bound container ports are"
    info "reachable from the internet unless you mitigate this."
    local fw_default=1
    [[ "$(state_get DOCKER_FIREWALL_MODE)" == "provider" ]] && fw_default=2
    ask_choice "How to control exposed Docker container ports" "$fw_default" \
        "DOCKER-USER chain|Step 41 drops unsolicited inbound on the public NIC; container egress, overlay and swarm-node traffic are unaffected" \
        "Provider firewall|Skip step 41; you block traffic at the cloud provider (Hetzner Cloud Firewall, AWS SG, GCP/DO Firewall, etc.). Make sure 22/80/443 are open upstream."
    case "$REPLY" in
        1) state_set DOCKER_FIREWALL_MODE docker-user ;;
        2) state_set DOCKER_FIREWALL_MODE provider ;;
    esac
}

_configure_podman() {
    state_set CONTAINER_RUNTIME podman
    # Clear the Docker gate so 41-docker-firewall stays invisible when the
    # operator switches runtimes via --redo.
    state_unset STEP_docker_SELECTED 2>/dev/null || true

    if ask_yesno "Install podman-docker (provides a 'docker' CLI shim for compatibility)?" "y"; then
        state_set PODMAN_DOCKER_SHIM yes
    else
        state_set PODMAN_DOCKER_SHIM no
    fi
    if ask_yesno "Install podman-compose (docker-compose equivalent)?" "y"; then
        state_set PODMAN_COMPOSE yes
    else
        state_set PODMAN_COMPOSE no
    fi
}

check_runtime() {
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker ;;
        podman) command -v podman >/dev/null 2>&1 ;;
        none|*) return 0 ;;
    esac
}

verify_runtime() {
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) command -v docker >/dev/null 2>&1 \
                    && systemctl is-active --quiet docker \
                    && docker info >/dev/null 2>&1 ;;
        podman) command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1 ;;
        none|*) return 0 ;;
    esac
}

# Resolve the apt suite to use against download.docker.com.
#
# Normally this is just the running release's codename. But docker.com
# publishes a suite per Ubuntu release on its own schedule, so a brand-new
# release can exist before its suite does — and writing a source file for a
# suite that isn't published turns the next `apt-get update` into a 404.
#
# So: probe the Release file, and only fall back if the probe fails. As of
# 2026-07 `resolute` (26.04) IS published with a current docker-ce for
# amd64/arm64, so this falls back on nothing today — it's here so a future
# Ubuntu release degrades to the newest LTS suite instead of breaking.
#
# Codename comes from /etc/os-release, which is always present; lsb_release
# is a package (lsb-release) that a minimal image may not have, and this
# module can run standalone before 23-packages installs it.
_docker_repo_codename() {
    local running fallback
    # UBUNTU_CODENAME first, matching the official docs. On plain Ubuntu the
    # two are identical (verified on 26.04: both `resolute`). On a derivative
    # — Mint, Pop!_OS — VERSION_CODENAME is the derivative's own name, which
    # docker.com never publishes; UBUNTU_CODENAME gives the Ubuntu base the
    # repo is actually keyed on.
    running="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
    [[ -z "$running" ]] && running="$(lsb_release -cs 2>/dev/null || true)"

    if [[ -z "$running" ]]; then
        err "Cannot determine Ubuntu codename (/etc/os-release has no VERSION_CODENAME)."
        return 1
    fi

    if curl -fsI --max-time 15 \
        "https://download.docker.com/linux/ubuntu/dists/${running}/Release" >/dev/null 2>&1; then
        echo "$running"
        return 0
    fi

    # Newest-first. Only reached when docker.com hasn't published the
    # running release yet.
    for fallback in noble jammy; do
        if curl -fsI --max-time 15 \
            "https://download.docker.com/linux/ubuntu/dists/${fallback}/Release" >/dev/null 2>&1; then
            warn "download.docker.com has no '${running}' suite yet; using '${fallback}' packages."
            warn "Re-run 'sudo ./main.sh --redo 40-runtime' once ${running} is published."
            echo "$fallback"
            return 0
        fi
    done

    err "download.docker.com is unreachable, or publishes no usable suite."
    err "Checked: ${running}, noble, jammy."
    return 1
}

# Packages docker.com says to remove before installing docker-ce, because they
# ship conflicting binaries (most obviously /usr/bin/docker) or an incompatible
# container runtime.
#
# Note what is NOT here: `containerd.io`, `docker-buildx-plugin` and
# `docker-compose-plugin` are docker.com's OWN packages and must survive.
# Ubuntu's near-namesakes `containerd` and `docker-buildx` are different
# packages and do conflict. Getting that pair backwards would uninstall the
# runtime we just asked for.
DOCKER_CONFLICTING_PKGS=(
    docker.io
    docker-compose
    docker-compose-v2
    docker-doc
    docker-buildx
    podman-docker
    containerd
    runc
)

# Echo the installed subset of the conflict list, space-separated.
_docker_conflicts_installed() {
    local pkg found=()
    for pkg in "${DOCKER_CONFLICTING_PKGS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 && found+=("$pkg")
    done
    printf '%s' "${found[*]:-}"
}

_run_docker() {
    local codename
    codename="$(_docker_repo_codename)" || return 1

    # Step 1 of docker.com's install guide, which this module used to skip
    # entirely. Removal is gated on the operator's answer from configure_ —
    # uninstalling packages without asking would violate the module contract.
    if [[ "$(state_get DOCKER_REMOVE_CONFLICTS)" == yes ]]; then
        local conflicts
        conflicts="$(_docker_conflicts_installed)"
        if [[ -n "$conflicts" ]]; then
            # Recorded before removal: undo restores files, but it has no way
            # to reinstate a package it didn't install, so the operator needs
            # the list to put anything back by hand.
            record_note "removed packages conflicting with Docker Engine: ${conflicts} (reinstall with: apt-get install ${conflicts})"
            # Word-splitting is intended: conflicts is a space-separated list.
            # shellcheck disable=SC2086
            apt-get remove -y -qq $conflicts \
                || warn "Some conflicting packages could not be removed; continuing."
            log "Removed conflicting packages: ${conflicts}"
        fi
    fi

    install -m 0755 -d /etc/apt/keyrings

    # Official docs now store the ARMORED key and point signed-by at it, rather
    # than dearmoring into a .gpg. Both work, but `curl -o` overwrites on its
    # own — which is precisely the "File exists" crash that had to be worked
    # around with `gpg --batch --yes` when this used the .gpg form.
    backup_file /etc/apt/keyrings/docker.asc
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # deb822 .sources, matching the official docs and Ubuntu's own
    # /etc/apt/sources.list.d/ubuntu.sources.
    backup_file /etc/apt/sources.list.d/docker.sources
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # Drop the previous-format files. Leaving them would declare the same repo
    # twice and make every apt run print "Target Packages is configured
    # multiple times". Backed up first so undo can restore either shape.
    local old
    for old in /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg; do
        if [[ -e "$old" ]]; then
            backup_file "$old"
            rm -f "$old"
            log "Removed superseded ${old}"
        fi
    done

    apt-get update -qq
    for _p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
        record_pkg_installed "$_p"
    done
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    record_service_enabled docker
    systemctl enable docker --now

    if [[ "$(state_get DOCKER_ADD_USER)" == yes ]]; then
        local u
        u="$(state_get USER_NAME)"
        usermod -aG docker "$u"
        log "User '$u' added to docker group (re-login to take effect)"
    fi

    log "Docker Engine + compose plugin installed"
}

_run_podman() {
    apt-get install -y -qq podman

    [[ "$(state_get PODMAN_DOCKER_SHIM)" == yes ]] \
        && apt-get install -y -qq podman-docker
    [[ "$(state_get PODMAN_COMPOSE)" == yes ]] \
        && apt-get install -y -qq podman-compose

    # Enable the rootless user-mode socket + lingering so tools that rely
    # on DOCKER_HOST or user-service containers keep working after the
    # operator logs out. Only meaningful when a non-root user exists.
    local user
    user="$(state_get USER_NAME)"
    if [[ -n "$user" ]] && id "$user" &>/dev/null; then
        local uid runtime_dir
        uid="$(id -u "$user")"
        runtime_dir="/run/user/${uid}"

        # loginctl enable-linger spawns the user's systemd manager and keeps
        # it alive past logout. The `|| true` is intentional: on some minimal
        # installs linger is already enabled and the call is a no-op error.
        loginctl enable-linger "$user" 2>/dev/null || true

        # sudo -u does NOT create a PAM session, so XDG_RUNTIME_DIR and
        # DBUS_SESSION_BUS_ADDRESS aren't set automatically. Without them,
        # `systemctl --user` fails with "Failed to connect to bus" because
        # it can't locate the per-user systemd manager socket at
        # $XDG_RUNTIME_DIR/systemd/private. Export them explicitly.
        #
        # Real errors surface — no `|| true` swallow — so the operator
        # learns when the user-mode socket didn't come up.
        if sudo -u "$user" \
               XDG_RUNTIME_DIR="$runtime_dir" \
               DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
               systemctl --user enable --now podman.socket; then
            log "Rootless podman socket enabled for '$user' (${runtime_dir}/podman/podman.sock)"
        else
            warn "podman user socket failed to enable for '$user'."
            warn "Podman itself works; only tools that expect DOCKER_HOST are affected."
            warn "Manual fix as $user:  systemctl --user enable --now podman.socket"
        fi
    fi

    log "Podman installed (rootless by default)"
}

run_runtime() {
    case "$(state_get CONTAINER_RUNTIME)" in
        docker) _run_docker ;;
        podman) _run_podman ;;
        none|"") log "Container runtime: none" ;;
        *)      err "Unknown CONTAINER_RUNTIME=$(state_get CONTAINER_RUNTIME)"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_runtime
    configure_runtime
    state_skipped runtime && exit 0
    check_runtime && { log "Runtime already installed; skipping."; exit 0; }
    run_runtime
    verify_runtime || { err "Runtime verification failed"; exit 1; }
fi
