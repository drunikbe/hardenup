# shellcheck shell=bash
# =============================================================================
# 42-docker-daemon.sh — Docker daemon defaults (/etc/docker/daemon.json)
# =============================================================================
#
# Docker ships NO log rotation by default. Every container's stdout/stderr is
# appended to a json-file under /var/lib/docker/containers/<id>/ that grows
# without bound until the disk fills. On a long-lived host that is a matter of
# when, not if — and a full disk takes the daemon (and every service on the
# node) down with it. This module sets json-file rotation so each container's
# logs are capped at max-size × max-file.
#
# Deliberately NOT set here:
#
#   live-restore — keeps containers running across a daemon restart, but it is
#   incompatible with Swarm mode; dockerd refuses to start with both enabled.
#   On a swarm node a daemon restart dropping containers is the expected
#   behaviour: the cluster reschedules them. Do not "helpfully" add it.
#
# The file is MERGED, not overwritten. Other tooling (and the operator) may
# have put registry mirrors, insecure-registries, proxies or storage options
# in daemon.json, and clobbering those would break the host in ways that are
# hard to trace back to this wizard. Only the keys this module owns are
# replaced; everything else is preserved byte-for-byte in value.
#
# Load-bearing: log-driver/log-opts are NOT reloadable options. `systemctl
# reload docker` (SIGHUP) leaves the daemon's log config untouched — verified
# on Ubuntu 26.04 / Docker 29.6.2: a container created after a reload still
# had an empty LogConfig.Config, and only a full restart applied it. So this
# module restarts the daemon, which stops running containers. run_ pauses for
# confirmation when any are running.
#
# Rotation applies to containers created AFTER the restart. Pre-existing
# containers keep the log config they were created with until recreated.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

DOCKER_DAEMON_JSON=/etc/docker/daemon.json

applies_docker_daemon() {
    [[ "$(state_get STEP_docker_SELECTED no)" == "yes" ]]
}

detect_docker_daemon() {
    [[ -f "$DOCKER_DAEMON_JSON" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Prepopulate the prompts from whatever is already configured, so a
    # re-run shows the operator their current values rather than the
    # module defaults. `// empty` keeps unset keys from becoming "null".
    local size count
    size="$(jq -r '.["log-opts"]["max-size"] // empty' "$DOCKER_DAEMON_JSON" 2>/dev/null || true)"
    count="$(jq -r '.["log-opts"]["max-file"] // empty' "$DOCKER_DAEMON_JSON" 2>/dev/null || true)"
    [[ -n "$size"  ]] && state_set DOCKER_LOG_MAX_SIZE "$size"
    [[ -n "$count" ]] && state_set DOCKER_LOG_MAX_FILE "$count"
    return 0
}

configure_docker_daemon() {
    info "Docker sets no log rotation by default — container logs grow until"
    info "the disk fills, which takes the daemon and the whole node down."
    info "This caps each container at max-size × max-file, then rotates."
    if ! ask_yesno "Configure Docker daemon log rotation (/etc/docker/daemon.json)?" "y"; then
        state_mark_skipped docker_daemon
        return 0
    fi

    # Per-container ceiling is max-size × max-file. The 50m × 5 default is
    # 250 MB per container — generous enough to keep a useful history for
    # debugging, small enough that a dozen chatty services can't fill a
    # modest VPS disk.
    info "Size of one log file before it rotates. Accepts a k/m/g suffix."
    ask_input "Max size per log file (e.g. 50m)" \
        "$(state_get DOCKER_LOG_MAX_SIZE 50m)" \
        '^[0-9]+[kmg]$'
    state_set DOCKER_LOG_MAX_SIZE "$REPLY"

    info "How many rotated files to keep. Total per container = size × count"
    info "(the default 50m × 5 = 250 MB of logs per container, then oldest drop)."
    ask_input "Number of rotated files to keep (e.g. 5)" \
        "$(state_get DOCKER_LOG_MAX_FILE 5)" \
        '^[1-9][0-9]*$'
    state_set DOCKER_LOG_MAX_FILE "$REPLY"
}

# True when daemon.json already carries exactly the requested rotation.
check_docker_daemon() {
    [[ -f "$DOCKER_DAEMON_JSON" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local want_size want_file got_size got_file got_driver
    want_size="$(state_get DOCKER_LOG_MAX_SIZE 50m)"
    want_file="$(state_get DOCKER_LOG_MAX_FILE 5)"

    got_driver="$(jq -r '.["log-driver"] // empty' "$DOCKER_DAEMON_JSON" 2>/dev/null || true)"
    got_size="$(jq -r '.["log-opts"]["max-size"] // empty' "$DOCKER_DAEMON_JSON" 2>/dev/null || true)"
    got_file="$(jq -r '.["log-opts"]["max-file"] // empty' "$DOCKER_DAEMON_JSON" 2>/dev/null || true)"

    [[ "$got_driver" == "json-file" ]] \
        && [[ "$got_size" == "$want_size" ]] \
        && [[ "$got_file" == "$want_file" ]]
}

verify_docker_daemon() {
    check_docker_daemon || return 1
    # A daemon that won't start is worse than unrotated logs — make sure the
    # JSON we wrote is actually one dockerd accepted.
    systemctl is-active --quiet docker
}

run_docker_daemon() {
    local size count
    size="$(state_get DOCKER_LOG_MAX_SIZE 50m)"
    count="$(state_get DOCKER_LOG_MAX_FILE 5)"

    # jq comes from 23-packages, but this module can run standalone.
    if ! command -v jq >/dev/null 2>&1; then
        apt-get install -y -qq jq
    fi

    install -m 0755 -d /etc/docker

    # Merge rather than truncate: preserve registry mirrors, proxies, storage
    # options and anything else already in the file. `.` starts from the
    # existing object (or {} when the file is absent/empty), and only the two
    # keys this module owns are replaced.
    local tmp
    tmp="$(mktemp)"
    local existing='{}'
    if [[ -s "$DOCKER_DAEMON_JSON" ]]; then
        if ! jq empty "$DOCKER_DAEMON_JSON" 2>/dev/null; then
            err "$DOCKER_DAEMON_JSON exists but is not valid JSON."
            err "Refusing to touch it — fix or move it, then re-run this step."
            rm -f "$tmp"
            return 1
        fi
        existing="$(cat "$DOCKER_DAEMON_JSON")"
    fi

    if ! jq --arg size "$size" --arg count "$count" \
        '.["log-driver"] = "json-file"
         | .["log-opts"] = ((.["log-opts"] // {})
             + {"max-size": $size, "max-file": $count})' \
        <<<"$existing" > "$tmp"; then
        err "Failed to build the new daemon.json."
        rm -f "$tmp"
        return 1
    fi

    install -m 0644 "$tmp" "$DOCKER_DAEMON_JSON"
    rm -f "$tmp"
    log "Wrote $DOCKER_DAEMON_JSON (max-size=${size}, max-file=${count})"

    # log-driver/log-opts are not reloadable — only a restart applies them.
    # A restart stops running containers (live-restore is deliberately unset;
    # it is incompatible with Swarm). Warn before doing it.
    local running
    running="$(docker ps -q 2>/dev/null | wc -l)"
    if [[ "$running" -gt 0 ]]; then
        warn "Restarting Docker will STOP ${running} running container(s)."
        warn "Docker log settings cannot be applied with a reload — only a"
        warn "restart works. On a swarm node the cluster reschedules services;"
        warn "standalone containers with a restart policy come back on their own."
        if ! ask_yesno "Restart the Docker daemon now?" "y"; then
            warn "Skipped the restart. daemon.json is written but NOT yet active."
            warn "Apply it later with:  sudo systemctl restart docker"
            return 0
        fi
    fi

    # Clear any prior failed state first. systemd rate-limits unit starts
    # (StartLimitBurst); several restarts in quick succession — a couple of
    # --redo runs while tuning the values, say — leave the unit in
    # "failed (start-limit-hit)" and every later restart is refused until
    # the counter is reset. Observed on Ubuntu 26.04 / Docker 29.6.2 while
    # testing this module. Harmless when the unit is healthy.
    systemctl reset-failed docker.service docker.socket 2>/dev/null || true
    systemctl restart docker

    # Give dockerd a moment to come back before the verify step asks.
    if ! wait_for "Docker daemon" 30 2 systemctl is-active --quiet docker; then
        err "Docker did not come back after the restart."
        err "Check:  journalctl -u docker -n 50"
        err "If it says 'start-limit-hit', run: sudo systemctl reset-failed docker"
        return 1
    fi

    log "Docker restarted; rotation applies to containers created from now on."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_docker_daemon
    configure_docker_daemon
    state_skipped docker_daemon && exit 0
    check_docker_daemon && { log "Docker log rotation already configured; skipping."; exit 0; }
    run_docker_daemon
    verify_docker_daemon || { err "Docker daemon config verification failed"; exit 1; }
fi
