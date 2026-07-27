# shellcheck shell=bash
# =============================================================================
# 25-firewall.sh — UFW with multi-network rules and SSH scope selection
# =============================================================================
#
# Public network (NET_PUBLIC_IFACE, always present):
#   HTTP/HTTPS only when the operator opts in. SSH presence depends on
#   SSH_SCOPE. Note that a Cloudflare Tunnel needs NO public inbound ports
#   at all — cloudflared dials out — so a tunnel-fronted host can leave
#   80/443 closed.
#
# Private network (NET_PRIVATE_IFACE, if NET_HAS_PRIVATE=yes):
#   Allow-all on the private interface. Intra-server traffic (Swarm control
#   plane, overlay VXLAN, DB replication) changes as components come and go — a port
#   allow-list on a trusted private net is fragile and adds no real security
#   over deny-from-public. SSH_SCOPE=vpn_only adds a targeted deny for the
#   SSH port on this interface, keeping the allow-all for everything else.
#
# VPN interface (VPN_IFACE from 18-vpn, if VPN_ENABLED=yes):
#   Allow-all on whichever interface the VPN brought up (tailscale0 or the
#   operator-chosen wg* name). Tailscale enforces identity/ACL at its own
#   layer; WireGuard is trusted by the cryptographic peer handshake.
#
# SSH_SCOPE controls WHERE on the host the SSH port (SSH_PORT) is reachable:
#   - all        : public + private + VPN (classical, default)
#   - no_public  : block public; private + VPN allowed
#   - vpn_only   : block public AND private; VPN only (⚠ console-recovery
#                  dependency if the VPN breaks — warned at configure time)
#
# SSH_SCOPE is set by _configure_ssh_scope based on what's available: with
# neither VPN nor private LAN, the scope collapses to 'all' without asking
# (no meaningful choice exists). When NET_HAS_PRIVATE=no the private-rule
# block is skipped entirely.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_firewall() { return 0; }

detect_firewall() {
    # UFW status is the canonical source of truth; no state to import.
    return 0
}

configure_firewall() {
    info "Host packet filter: default-deny incoming, allow SSH + selected ports."
    info "Complements (not replaces) intrusion detection in the next step."
    if ! ask_yesno "Configure host firewall (ufw)?" "y"; then
        state_mark_skipped firewall
        return 0
    fi

    # 25 runs before the runtime choice at 40, so it can't know whether the
    # operator will publish container ports on the host — hence we ask rather
    # than infer. Answering "n" is correct for a Cloudflare Tunnel host:
    # cloudflared makes an OUTBOUND connection to Cloudflare's edge, so no
    # inbound port needs to be open. Either answer is reversible later with:
    #   sudo ./main.sh --redo 25-firewall
    info "A Cloudflare Tunnel needs no inbound ports — cloudflared dials out."
    info "Answer 'n' if this host is tunnel-fronted; 'y' if you publish 80/443."
    if ask_yesno "Open HTTP/HTTPS (80/443) on the public interface?" "y"; then
        state_set FIREWALL_OPEN_HTTP yes
    else
        state_set FIREWALL_OPEN_HTTP no
    fi

    _configure_swarm_ports
    _configure_ssh_scope
}

# Docker Swarm needs four node-to-node ports open between cluster members.
# They are declared HERE rather than in 43-docker-swarm because run_firewall
# starts with `ufw --force reset` — a rule added by a later module would be
# silently wiped the next time anyone runs `--redo 25-firewall`. Same reason
# the VPN interface rule lives here. All UFW state is co-located.
#
# 25 runs before the runtime choice at 40, so it cannot know whether Docker
# (let alone Swarm) will be picked. Hence a direct question rather than a
# gate on STEP_docker_SELECTED, which doesn't exist yet.
_configure_swarm_ports() {
    info "Docker Swarm needs four ports open between cluster nodes:"
    info "  2377/tcp  cluster management (managers only)"
    info "  7946/tcp + 7946/udp  node discovery / gossip"
    info "  4789/udp  overlay network traffic (VXLAN)"
    info "Skip this on a single-node host — nothing else needs these ports."
    local default="n"
    [[ "$(state_get SWARM_PORTS_ENABLED)" == "yes" ]] && default="y"
    if ! ask_yesno "Open Docker Swarm cluster ports (2377, 7946, 4789)?" "$default"; then
        state_set SWARM_PORTS_ENABLED no
        return 0
    fi
    state_set SWARM_PORTS_ENABLED yes

    # These ports MUST be scoped to the node subnet. An internet-reachable
    # 2377 plus a leaked join token is a whole-cluster takeover, and 7946
    # gossip is unauthenticated enough to be worth keeping off the WAN.
    # validate_private_cidr rejects 0.0.0.0/0 and anything non-RFC1918, so
    # the wildcard answer that would open these to the world is impossible.
    #
    # Default: the private CIDR when one was detected. Otherwise fall back to
    # the public interface's own subnet — on a single-NIC LAN host (a Pi
    # cluster, most homelabs) 15-networks classifies the only NIC as "public"
    # because it carries the default route, even when its address is RFC1918.
    # That host still has a perfectly good node subnet; it just isn't in
    # NET_PRIVATE_CIDR.
    local suggested
    suggested="$(state_get SWARM_NODE_CIDR "$(state_get NET_PRIVATE_CIDR)")"
    [[ -z "$suggested" ]] && suggested="$(_local_subnet_of "$(state_get NET_PUBLIC_IFACE)")"

    info "Subnet the other swarm nodes live on — these four ports are opened"
    info "ONLY to it, never to the internet. On a LAN cluster this is your LAN"
    info "range (e.g. 10.0.0.0/24); on a cloud provider it's the private network."
    while true; do
        ask_input "Swarm node subnet (RFC1918 CIDR, e.g. 10.0.0.0/24)" "$suggested"
        if validate_private_cidr "$REPLY"; then
            state_set SWARM_NODE_CIDR "$REPLY"
            break
        fi
        warn "Must be an RFC1918 CIDR (10/8, 172.16/12, 192.168/16) and not a wildcard."
    done
}

# Echo the network address of IFACE's first IPv4 (10.0.0.169/24 → 10.0.0.0/24).
# Empty when the interface has no address or python3 is unavailable.
_local_subnet_of() {
    local iface="$1" cidr
    [[ -n "$iface" ]] || return 0
    cidr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -n1)"
    [[ -n "$cidr" ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c "import ipaddress;print(ipaddress.ip_network('$cidr',strict=False))" 2>/dev/null || true
}

# Asks where SSH should be reachable from. Options depend on what earlier
# steps enabled — VPN (18-vpn) and private network (15-networks). Default
# is always "anywhere" so a quick wizard run keeps classical behaviour;
# opt-in restriction is a conscious choice by the operator.
_configure_ssh_scope() {
    local has_vpn vpn_kind has_private ssh_port
    has_vpn="$(state_get VPN_ENABLED no)"
    vpn_kind="$(state_get VPN_KIND none)"
    has_private="$(state_get NET_HAS_PRIVATE no)"
    ssh_port="$(state_get SSH_PORT 22)"

    # No VPN and no private LAN means there's only one answer: public-reachable.
    if [[ "$has_vpn" != yes && "$has_private" != yes ]]; then
        state_set SSH_SCOPE all
        return 0
    fi

    # Build the "anywhere" option label dynamically.
    local anywhere_desc="public internet"
    [[ "$has_private" == yes ]] && anywhere_desc+=" + private LAN"
    [[ "$has_vpn"     == yes ]] && anywhere_desc+=" + VPN (${vpn_kind})"

    info "Decide where port ${ssh_port} is reachable from. UFW only — sshd itself"
    info "keeps listening on all interfaces; this just controls the packet filter."
    if [[ "$has_vpn" == yes ]]; then
        info "⚠ 'VPN only' means: if the VPN breaks (account lockout, coordination"
        info "⚠ server outage, key mismatch, daemon crash) you lose SSH from the"
        info "⚠ public AND private paths. Recovery requires console/serial access"
        info "⚠ from your host provider — Hetzner provides it, some do not. Verify."
    fi

    # Assemble the choice list. Index mapping is position-based so we track
    # which option maps to which scope via parallel arrays.
    local -a labels=() descs=() scopes=()

    labels+=("Anywhere");  descs+=("$anywhere_desc");                       scopes+=("all")
    labels+=("No public"); descs+=("block public; allow everything else");  scopes+=("no_public")
    if [[ "$has_vpn" == yes ]]; then
        labels+=("VPN only"); descs+=("block public AND private LAN; VPN only"); scopes+=("vpn_only")
    fi

    local -a opts=()
    local i
    for i in "${!labels[@]}"; do
        opts+=("${labels[$i]}|${descs[$i]}")
    done

    ask_choice "Where should SSH be reachable from?" "1" "${opts[@]}"
    state_set SSH_SCOPE "${scopes[$((REPLY - 1))]}"
}

check_firewall()  { return 1; }  # UFW reset is cheap; always re-run.

verify_firewall() {
    ufw status 2>/dev/null | grep -q "Status: active" || return 1
    # Verification depends on scope: 'all' requires a port-specific allow; the
    # restricted scopes rely on a VPN-interface or private-interface allow-all.
    local port scope vpn_iface
    port="$(state_get SSH_PORT 22)"
    scope="$(state_get SSH_SCOPE all)"
    vpn_iface="$(state_get VPN_IFACE)"
    case "$scope" in
        all)
            ufw status 2>/dev/null | grep -qE "^${port}/tcp |^.* ALLOW .*${port}" || return 1
            ;;
        *)
            ufw status 2>/dev/null | grep -qE "${vpn_iface:-@@nope@@}|Private network" || return 1
            ;;
    esac
}

run_firewall() {
    apt-get install -y -qq ufw 2>/dev/null
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing

    local ssh_port pub_if priv_if has_priv has_vpn vpn_iface vpn_kind open_http ssh_scope
    ssh_port="$(state_get SSH_PORT 22)"
    pub_if="$(state_get NET_PUBLIC_IFACE)"
    priv_if="$(state_get NET_PRIVATE_IFACE)"
    has_priv="$(state_get NET_HAS_PRIVATE no)"
    has_vpn="$(state_get VPN_ENABLED no)"
    vpn_iface="$(state_get VPN_IFACE)"
    vpn_kind="$(state_get VPN_KIND none)"
    open_http="$(state_get FIREWALL_OPEN_HTTP no)"
    ssh_scope="$(state_get SSH_SCOPE all)"

    # --- Public interface rules -------------------------------------------------
    # HTTP/HTTPS are orthogonal to SSH_SCOPE — a public web server with
    # VPN-only SSH is a perfectly sensible setup.
    if [[ -n "$pub_if" ]]; then
        if [[ "$ssh_scope" == all ]]; then
            ufw allow in on "$pub_if" to any port "$ssh_port" proto tcp comment 'SSH (public)'
        fi
        if [[ "$open_http" == yes ]]; then
            ufw allow in on "$pub_if" to any port 80 proto tcp  comment 'HTTP (public)'
            ufw allow in on "$pub_if" to any port 443 proto tcp comment 'HTTPS (public)'
        fi
    elif [[ "$ssh_scope" == all ]]; then
        # No named public interface — fall back to an unscoped SSH allow.
        ufw allow "${ssh_port}/tcp" comment 'SSH'
        if [[ "$open_http" == yes ]]; then
            ufw allow 80/tcp  comment 'HTTP'
            ufw allow 443/tcp comment 'HTTPS'
        fi
    fi

    # --- Private interface rules ------------------------------------------------
    # In "vpn_only" mode we deny SSH specifically on the private interface but
    # keep the allow-all for everything else (DB replication, exporters, etc).
    # UFW evaluates rules in insertion order, so the deny must come first.
    if [[ "$has_priv" == yes && -n "$priv_if" ]]; then
        if [[ "$ssh_scope" == vpn_only ]]; then
            ufw deny in on "$priv_if" to any port "$ssh_port" proto tcp comment 'SSH blocked on private (VPN-only)'
        fi
        ufw allow in on "$priv_if" comment 'Private network'
    fi

    # --- VPN rules --------------------------------------------------------------
    if [[ "$has_vpn" == yes && -n "$vpn_iface" ]]; then
        ufw allow in on "$vpn_iface" comment "VPN (${vpn_kind})"
    fi

    # --- Docker Swarm cluster ports ---------------------------------------------
    # Scoped to the node subnet, never opened globally. Redundant on a host
    # whose private allow-all already covers the same range — harmless, and it
    # keeps the intent explicit and survives a change of private topology.
    local swarm_cidr
    swarm_cidr="$(state_get SWARM_NODE_CIDR)"
    if [[ "$(state_get SWARM_PORTS_ENABLED no)" == yes && -n "$swarm_cidr" ]]; then
        ufw allow from "$swarm_cidr" to any port 2377 proto tcp comment 'Swarm management'
        ufw allow from "$swarm_cidr" to any port 7946 proto tcp comment 'Swarm node discovery'
        ufw allow from "$swarm_cidr" to any port 7946 proto udp comment 'Swarm node discovery'
        ufw allow from "$swarm_cidr" to any port 4789 proto udp comment 'Swarm overlay (VXLAN)'
    fi

    ufw --force enable
    log "UFW enabled — ssh_scope=${ssh_scope} public=${pub_if:-any} http=${open_http} private=${priv_if:-none} vpn=${vpn_kind}/${vpn_iface:-none} swarm=${swarm_cidr:-none}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_firewall
    configure_firewall
    state_skipped firewall && exit 0
    run_firewall
    verify_firewall || { err "Firewall verification failed"; exit 1; }
fi
