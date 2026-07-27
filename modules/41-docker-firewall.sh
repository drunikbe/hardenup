# shellcheck shell=bash
# =============================================================================
# 41-docker-firewall.sh — DOCKER-USER chain rules + ip_forward + bridge-nf
# =============================================================================
#
# Docker inserts its own rules into FORWARD (via DOCKER-USER chain) that run
# BEFORE UFW's rules, so bound container ports bypass UFW's deny policy. Fix
# by explicitly placing rules in DOCKER-USER:
#   - Allow RELATED,ESTABLISHED (return traffic)
#   - Allow from NET_PRIVATE_CIDR and SWARM_NODE_CIDR (trusted node subnets)
#   - Drop NEW traffic ARRIVING ON THE PUBLIC INTERFACE
#
# --- Why the drop is scoped to the public interface --------------------------
#
# DOCKER-USER sits in FORWARD, which carries BOTH directions of container
# traffic: inbound (public -> container) and outbound (container -> internet).
# An unqualified `-j DROP` therefore kills container EGRESS as well, since a
# new outbound connection matches neither RETURN rule.
#
# That was this module's behaviour, and on a single-NIC host — where
# 15-networks finds no private network, so there was no allow rule at all —
# it broke every container's outbound networking, DNS included. Verified on
# Ubuntu 26.04 / Docker 29.6.2: `docker run alpine wget https://...` failed
# with "bad address" and the DROP counter advanced; deleting the rule fixed
# it immediately.
#
# That is fatal for this stack specifically: ingress is a Cloudflare Tunnel,
# and cloudflared works by dialling OUT to Cloudflare's edge. A rule that
# blocks container egress blocks the ingress path.
#
# Scoping the drop with `-i <public iface>` keeps the property that matters
# (unsolicited inbound from the internet cannot reach a published container
# port) while leaving egress, inter-container and overlay traffic alone.
# Overlay VXLAN (4789/udp) between nodes is addressed to the HOST, so it
# traverses INPUT and never reaches this chain — 25-firewall owns that.
#
# Also enables the kernel tunables Docker bridge networking needs:
#   - net.ipv4.ip_forward = 1
#   - net.bridge.bridge-nf-call-iptables = 1
#
# Sysctl persists via /etc/sysctl.d/99-docker.conf. Rule persistence across
# reboots is NOT handled here — see the note in _persist_rules.
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

# Delete every DOCKER-USER rule this module has ever written, whatever its
# shape, so a re-run replaces rather than accumulates.
#
# Deleting by rule spec (`iptables -D ... -j RETURN`) does NOT work: -D
# requires the COMPLETE spec, so a spec carrying only the comment never
# matches a rule that also has `-m conntrack --ctstate ...` or `-s <cidr>`.
# The previous drain loops had exactly that hole — the conntrack RETURN and
# the per-CIDR RETURNs were never removed, so each run appended another copy.
#
# Deleting by line number matches on the comment instead, which covers every
# variant including the pre-public-scoping bare DROP. Highest line first, so
# each deletion doesn't renumber the rules still queued for removal.
_flush_tagged_rules() {
    local nums n
    nums="$(iptables -L DOCKER-USER -n --line-numbers 2>/dev/null \
            | awk '/hardenup:docker-firewall/ {print $1}' | sort -rn)"
    for n in $nums; do
        iptables -D DOCKER-USER "$n" 2>/dev/null || true
    done
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

    _flush_tagged_rules

    local priv_cidr swarm_cidr pub_if
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    swarm_cidr="$(state_get SWARM_NODE_CIDR)"
    pub_if="$(state_get NET_PUBLIC_IFACE)"

    # Trusted source subnets get a RETURN before the drop. The swarm node
    # subnet is included so published service ports stay reachable BETWEEN
    # cluster members even though they're closed to the internet.
    if [[ -n "$priv_cidr" ]]; then
        iptables -I DOCKER-USER -s "$priv_cidr" \
            -m comment --comment "hardenup:docker-firewall" -j RETURN
    fi
    if [[ -n "$swarm_cidr" && "$swarm_cidr" != "$priv_cidr" ]]; then
        iptables -I DOCKER-USER -s "$swarm_cidr" \
            -m comment --comment "hardenup:docker-firewall" -j RETURN
    fi
    iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED \
        -m comment --comment "hardenup:docker-firewall" -j RETURN

    # The drop MUST stay scoped to the public interface — see the header.
    # Without a known public interface there is nothing safe to scope to, so
    # skip the drop rather than install one that kills container egress.
    if [[ -n "$pub_if" ]]; then
        iptables -A DOCKER-USER -i "$pub_if" \
            -m comment --comment "hardenup:docker-firewall" -j DROP
        log "Docker firewall: drop inbound on ${pub_if}; allow ${priv_cidr:-none}/${swarm_cidr:-none}; ip_forward=1"
    else
        warn "NET_PUBLIC_IFACE is unset — no public interface to scope the drop to."
        warn "Skipping the DROP rule: an unscoped one would break ALL container"
        warn "egress, including cloudflared. Re-run 15-networks, then --redo 41."
    fi

    _persist_rules
}

# Persist the DOCKER-USER rules across reboots.
#
# Ubuntu 26.04 dropped BOTH iptables-persistent and netfilter-persistent from
# the archive — verified on resolute with main/restricted/universe/multiverse
# enabled: no installation candidate for either, and nothing else provides the
# service. The old code called them unconditionally, so on 26.04 it printed
# "Package 'iptables-persistent' has no installation candidate", fell through
# to `iptables-save > /etc/iptables/rules.v4` against a directory that doesn't
# exist, and left the rules alive only until the next reboot.
#
# So we install our own restore unit. iptables here is the nft backend
# (iptables v1.8.11 (nf_tables)), and iptables-save/restore round-trip
# correctly through it.
#
# The unit runs before docker.service: Docker creates DOCKER-USER at startup,
# and restoring into a chain Docker has not made yet fails. `|| true` on the
# restore keeps a stale rules file from blocking boot.
_persist_rules() {
    install -m 0755 -d /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    chmod 0600 /etc/iptables/rules.v4

    cat > /etc/systemd/system/hardenup-iptables.service <<'EOF'
[Unit]
Description=Restore hardenup iptables rules (DOCKER-USER)
DefaultDependencies=no
After=network-pre.target
Before=network-pre.target docker.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '[ -f /etc/iptables/rules.v4 ] && /usr/sbin/iptables-restore < /etc/iptables/rules.v4 || true'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if systemctl enable hardenup-iptables.service >/dev/null 2>&1; then
        log "Rule persistence: hardenup-iptables.service enabled"
    else
        warn "Could not enable hardenup-iptables.service; rules will NOT survive a reboot."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_docker_firewall || exit 0
    check_docker_firewall && { log "Already configured; skipping."; exit 0; }
    run_docker_firewall
    verify_docker_firewall || { err "Docker firewall verification failed"; exit 1; }
fi
