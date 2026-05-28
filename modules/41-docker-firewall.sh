# shellcheck shell=bash
# =============================================================================
# 41-docker-firewall.sh — DOCKER-USER chain rules + ip_forward + bridge-nf
# =============================================================================
#
# Docker inserts its own rules into FORWARD (via DOCKER-USER chain) that run
# BEFORE UFW's rules, so bound container ports bypass UFW's deny policy. Fix
# by explicitly placing rules in DOCKER-USER:
#   - Allow from NET_PRIVATE_CIDR (intra-server is trusted)
#   - Allow RELATED,ESTABLISHED (return traffic)
#   - Default drop for everything else
#
# Also enables the kernel tunables Docker bridge networking needs:
#   - net.ipv4.ip_forward = 1
#   - net.bridge.bridge-nf-call-iptables = 1
#
# Rules persist via iptables-persistent; sysctl via /etc/sysctl.d/99-docker.conf.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_docker_firewall() {
    # Three gates. STEP_docker_SELECTED is the primary switch (set by
    # 40-runtime when docker is chosen). The CONTAINER_RUNTIME check
    # protects against stale flags on --redo / answers.env import.
    # DOCKER_FIREWALL_MODE lets the operator opt out of the DOCKER-USER
    # chain when they handle port exposure via a provider firewall
    # (Hetzner Cloud Firewall, AWS SG, etc.) that blocks inbound traffic
    # before it hits this host's kernel — in that case Docker's iptables
    # bypass doesn't matter.
    [[ "$(state_get STEP_docker_SELECTED)" == "yes" ]] \
        && [[ "$(state_get CONTAINER_RUNTIME)" == "docker" ]] \
        && [[ "$(state_get DOCKER_FIREWALL_MODE)" == "docker-user" ]]
}

detect_docker_firewall() { return 0; }

configure_docker_firewall() {
    info "Docker bypasses UFW by binding container ports via its own iptables"
    info "rules; this step closes that hole with DOCKER-USER chain + ip_forward=1."
    if ! ask_yesno "Apply Docker firewall hardening?" "y"; then
        state_mark_skipped docker_firewall
        return 0
    fi
}

check_docker_firewall() {
    iptables -L DOCKER-USER -n 2>/dev/null | grep -q "hardenup:docker-firewall"
}

verify_docker_firewall() {
    check_docker_firewall \
        && [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]
}

run_docker_firewall() {
    # Docker bridge networking needs ip_forward and bridge-nf-call. Both are
    # set here so 26-sysctl can stay runtime-agnostic.
    modprobe br_netfilter 2>/dev/null || true
    cat > /etc/sysctl.d/99-docker.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    sysctl --system >/dev/null 2>&1 || true

    # iptables-persistent preseeds to avoid the installer prompt.
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent

    # Flush our previously-tagged rules if re-running.
    while iptables -D DOCKER-USER -m comment --comment "hardenup:docker-firewall" -j RETURN 2>/dev/null; do :; done
    while iptables -D DOCKER-USER -m comment --comment "hardenup:docker-firewall" -j DROP 2>/dev/null; do :; done

    local priv_cidr
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    if [[ -n "$priv_cidr" ]]; then
        iptables -I DOCKER-USER -s "$priv_cidr" \
            -m comment --comment "hardenup:docker-firewall" -j RETURN
    fi
    iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "hardenup:docker-firewall" -j RETURN
    iptables -A DOCKER-USER -m comment --comment "hardenup:docker-firewall" -j DROP

    netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4
    log "Docker firewall configured; ip_forward=1; private allow: ${priv_cidr:-none}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_docker_firewall || exit 0
    check_docker_firewall && { log "Already configured; skipping."; exit 0; }
    run_docker_firewall
    verify_docker_firewall || { err "Docker firewall verification failed"; exit 1; }
fi
