# shellcheck shell=bash
# =============================================================================
# 15-networks.sh — Public and private network detection
# =============================================================================
#
# Detects the host's public interface (default route) and optional private
# interface (RFC1918 on a secondary NIC). Operator confirms or overrides.
# Writes to state:
#   NET_PUBLIC_IFACE     — e.g. eth0
#   NET_PUBLIC_IP        — primary public IPv4
#   NET_PRIVATE_IFACE    — e.g. enp7s0, or empty if none
#   NET_PRIVATE_IP       — primary private IPv4, or empty
#   NET_PRIVATE_CIDR     — private CIDR used for allow-lists, or empty
#   NET_HAS_PRIVATE      — "yes" or "no"
#
# When NET_HAS_PRIVATE=no, all downstream modules that have multi-network
# decisions (firewall, intrusion, docker-firewall, swarm) collapse
# their private-net branches away and behave as single-network hosts.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_networks() { return 0; }

# Detect from running kernel state. Populates state vars.
detect_networks() {
    # Public interface: default route.
    if detect_public_iface 2>/dev/null; then
        state_set NET_PUBLIC_IFACE "$PUBLIC_IFACE"
        local pub_ip
        pub_ip="$(ip -4 -o addr show dev "$PUBLIC_IFACE" \
                  | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        [[ -n "$pub_ip" ]] && state_set NET_PUBLIC_IP "$pub_ip"
    fi

    # Private interface: RFC1918 on a non-default iface.
    if detect_private_iface 2>/dev/null; then
        state_set NET_PRIVATE_IFACE "$PRIVATE_IFACE"
        if get_private_ip "$PRIVATE_IFACE" 2>/dev/null; then
            state_set NET_PRIVATE_IP "$PRIVATE_IP"
            # Derive CIDR from the interface's assigned network.
            local cidr
            cidr="$(ip -4 -o addr show dev "$PRIVATE_IFACE" \
                    | awk '{print $4}' | head -n1)"
            if [[ -n "$cidr" ]]; then
                # Normalise host-bits → network-bits (e.g. 10.0.0.5/24 → 10.0.0.0/24)
                local prefix ip net
                ip="${cidr%/*}"
                prefix="${cidr#*/}"
                # Use python for correct mask arithmetic; fall back to raw if missing.
                if command -v python3 >/dev/null 2>&1; then
                    net="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network('$ip/$prefix', strict=False))" 2>/dev/null || echo "$cidr")"
                else
                    net="$cidr"
                fi
                state_set NET_PRIVATE_CIDR "$net"
            fi
        fi
    fi

    if [[ -n "$(state_get NET_PRIVATE_IFACE)" ]]; then
        state_set NET_HAS_PRIVATE yes
    else
        state_set NET_HAS_PRIVATE no
    fi
}

# Prints up, non-loopback interfaces with their IPv4 addresses and a role hint
# (default route / RFC1918). Shown before the first prompt so the operator has
# context when overriding auto-detected defaults on multi-homed hosts.
_show_interfaces() {
    local default_iface
    default_iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"

    echo ""
    info "Detected network interfaces:"

    local iface addrs primary role
    while read -r iface; do
        # Strip @parent suffix (VLAN/veth: "eth0.100@eth0" → "eth0.100").
        iface="${iface%@*}"
        [[ "$iface" == "lo" ]] && continue

        # All IPv4 addresses on this iface, comma-joined (CIDR form).
        addrs="$(ip -4 -o addr show dev "$iface" 2>/dev/null \
                 | awk '{print $4}' | paste -sd, -)"
        addrs="${addrs:-(no IPv4)}"

        role=""
        if [[ "$iface" == "$default_iface" ]]; then
            role="default route — public"
        else
            # Test the first IP against RFC1918 ranges (10/8, 172.16/12, 192.168/16).
            primary="${addrs%%,*}"
            primary="${primary%/*}"
            if [[ "$primary" =~ ^10\. ]] \
               || [[ "$primary" =~ ^192\.168\. ]] \
               || [[ "$primary" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
                role="RFC1918 — private candidate"
            fi
        fi

        if [[ -n "$role" ]]; then
            printf "  %-12s %-22s (%s)\n" "$iface" "$addrs" "$role"
        else
            printf "  %-12s %-22s\n" "$iface" "$addrs"
        fi
    done < <(ip -br link show up 2>/dev/null | awk '{print $1}')
    echo ""
}

configure_networks() {
    info "Detects the public (WAN) and optional private (intra-server) NICs."
    info "Consumed by firewall, intrusion, docker-firewall and swarm modules."
    _show_interfaces

    # Confirm / override public interface + IP. Soft-warn on values the kernel
    # doesn't recognise — typos here cascade into confusing failures in
    # 25-firewall's `allow in on $iface` rules.
    ask_input "Public interface (WAN-facing NIC name)" "$(state_get NET_PUBLIC_IFACE)"
    ip link show "$REPLY" &>/dev/null \
        || warn "Interface '$REPLY' not currently visible; downstream modules may fail."
    state_set NET_PUBLIC_IFACE "$REPLY"
    ask_input "Public IPv4" "$(state_get NET_PUBLIC_IP)"
    validate_ip "$REPLY" \
        || warn "'$REPLY' is not a valid IPv4 address; rules referencing it will be rejected."
    state_set NET_PUBLIC_IP "$REPLY"

    # Does this host have a private network? Name the detected iface in the
    # prompt so the operator doesn't have to cross-reference the preview above.
    local default_priv priv_prompt
    default_priv="$([[ "$(state_get NET_HAS_PRIVATE no)" == yes ]] && echo y || echo n)"
    if [[ -n "$(state_get NET_PRIVATE_IFACE)" ]]; then
        priv_prompt="Use private network on $(state_get NET_PRIVATE_IFACE) ($(state_get NET_PRIVATE_IP))?"
    else
        priv_prompt="Does this host have a private (intra-server) network?"
    fi
    if ask_yesno "$priv_prompt" "$default_priv"; then
        ask_input "Private interface (intra-server NIC name)" "$(state_get NET_PRIVATE_IFACE)"
        ip link show "$REPLY" &>/dev/null \
            || warn "Interface '$REPLY' not currently visible; downstream modules may fail."
        state_set NET_PRIVATE_IFACE "$REPLY"
        ask_input "Private IPv4" "$(state_get NET_PRIVATE_IP)"
        validate_ip "$REPLY" \
            || warn "'$REPLY' is not a valid IPv4 address; rules referencing it will be rejected."
        state_set NET_PRIVATE_IP "$REPLY"
        local cur_cidr
        cur_cidr="$(state_get NET_PRIVATE_CIDR)"
        info "Subnet the firewall trusts for intra-server traffic (used by"
        info "ingress/firewall allow-lists). Hetzner Cloud assigns /32 per NIC"
        info "even though the real subnet is /16 or /24 — the actual range is"
        info "in Hetzner Console → Networks → IP range."
        # Stricter than validate_cidr: rejects 0.0.0.0/0 and non-RFC1918. An
        # operator typing a wildcard here would silently open the host via
        # 25-firewall's private allow-any, 41-docker-firewall's DOCKER-USER
        # allow-from, and 72's proxy-real-ip-cidr PP trust zone.
        while true; do
            ask_input "Private CIDR (RFC1918 allow-list scope)" "$cur_cidr"
            if validate_private_cidr "$REPLY"; then
                state_set NET_PRIVATE_CIDR "$REPLY"
                break
            fi
            err "Must be RFC1918 (10/8, 172.16/12, or 192.168/16): $REPLY"
        done
        state_set NET_HAS_PRIVATE yes
    else
        state_set NET_PRIVATE_IFACE ""
        state_set NET_PRIVATE_IP ""
        state_set NET_PRIVATE_CIDR ""
        state_set NET_HAS_PRIVATE no
    fi
}

check_networks() { return 1; }  # Always re-runnable; emits a summary.

verify_networks() {
    # Detection succeeded if we have at least a public interface. A private
    # network is optional and is reflected in NET_HAS_PRIVATE.
    [[ -n "$(state_get NET_PUBLIC_IFACE)" ]]
}

run_networks() {
    local has_priv
    has_priv="$(state_get NET_HAS_PRIVATE)"
    log "Public:  $(state_get NET_PUBLIC_IFACE) $(state_get NET_PUBLIC_IP)"
    if [[ "$has_priv" == yes ]]; then
        log "Private: $(state_get NET_PRIVATE_IFACE) $(state_get NET_PRIVATE_IP) ($(state_get NET_PRIVATE_CIDR))"
    else
        log "Private: (none)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_networks
    configure_networks
    run_networks
    verify_networks || { err "Network detection verification failed"; exit 1; }
fi
