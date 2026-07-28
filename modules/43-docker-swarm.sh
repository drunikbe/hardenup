# shellcheck shell=bash
# =============================================================================
# 43-docker-swarm.sh — Initialize or join a Docker Swarm
# =============================================================================
#
# Swarm is the orchestrator this repo targets: a handful of nodes, an overlay
# network, and cloudflared as the ingress service. This step turns a hardened
# Docker host into a cluster member.
#
# Three paths:
#
#   init   — this is the FIRST manager. Creates the swarm and prints the
#            manager + worker join tokens.
#   join   — this node joins an existing swarm, as manager or worker. Needs a
#            token and the address of any current manager.
#   skip   — leave Docker standalone.
#
# The four cluster ports (2377/tcp, 7946/tcp+udp, 4789/udp) are NOT opened
# here. 25-firewall owns them, because its run_ starts with `ufw --force
# reset` and would wipe anything a later module added — see the swarm block
# there. If the operator declined those ports at 25, this module warns: a
# swarm whose members can't reach each other looks "up" on the first node and
# fails only when the second one tries to join.
#
# --- etcd/Raft quorum, the thing that bites people ---------------------------
#
# Managers form a Raft group. Quorum is floor(N/2)+1, so:
#   1 manager  → tolerates 0 failures
#   3 managers → tolerates 1 failure   ← the useful minimum
#   2 managers → tolerates 0 failures, and is WORSE than 1: either node dying
#                takes the cluster's control plane down.
# Always go 1 → 3, never linger on 2. Workers have no Raft membership and can
# join in any number, in parallel, at any time.
#
# Docker Swarm's Raft implementation lives in the daemon, so a manager reboot
# is a quorum event. This is why 29-unattended tells swarm managers to answer
# "n" to auto-reboot.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_docker_swarm() {
    [[ "$(state_get STEP_docker_SELECTED no)" == "yes" ]] \
        && [[ "$(state_get CONTAINER_RUNTIME)" == "docker" ]]
}

# Current swarm membership straight from the daemon — the canonical source.
_swarm_state() {
    docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo unknown
}

detect_docker_swarm() {
    local st
    st="$(_swarm_state)"
    if [[ "$st" == "active" ]]; then
        state_set SWARM_JOINED yes
        # Manager vs worker matters for what we can print later: only a
        # manager can be asked for join tokens.
        if docker node ls >/dev/null 2>&1; then
            state_set SWARM_ROLE manager
        else
            state_set SWARM_ROLE worker
        fi
    else
        state_set SWARM_JOINED no
    fi
    return 0
}

configure_docker_swarm() {
    info "Docker Swarm clusters this host with others: overlay networking,"
    info "service scheduling, rolling updates, and secrets. Skip it for a"
    info "single standalone Docker host — nothing else here depends on it."

    if [[ "$(state_get SWARM_JOINED no)" == "yes" ]]; then
        info "This node is ALREADY in a swarm as a $(state_get SWARM_ROLE)."
        info "Nothing to do; leave with 'docker swarm leave --force' first if"
        info "you want to re-form the cluster."
        state_mark_skipped docker_swarm
        return 0
    fi

    # Default "n" — clustering a host is opt-in. It follows SWARM_MODE when
    # that's already set, which is what lets a recipe (or a re-run after
    # --redo) turn the step on: with a hard-coded "n" the swarm recipes would
    # take the default under --recipe and skip the one step they exist for.
    local default="n"
    case "$(state_get SWARM_MODE)" in
        init|join) default="y" ;;
    esac
    if ! ask_yesno "Set up Docker Swarm on this host?" "$default"; then
        state_set SWARM_MODE none
        state_mark_skipped docker_swarm
        return 0
    fi

    local default=1
    [[ "$(state_get SWARM_MODE)" == "join" ]] && default=2
    ask_choice "Swarm role for this host" "$default" \
        "Initialize a new swarm|this is the FIRST manager; prints the join tokens for the others" \
        "Join an existing swarm|needs a join token and a current manager's address"
    case "$REPLY" in
        1) _configure_swarm_init ;;
        2) _configure_swarm_join ;;
    esac

    # A swarm whose nodes can't reach each other's cluster ports fails in a
    # confusing way: init succeeds (it's a local operation), and only the
    # second node's join times out. Say so now, while the operator can act.
    if [[ "$(state_get SWARM_PORTS_ENABLED no)" != "yes" ]]; then
        warn "You declined the swarm cluster ports at step 25-firewall."
        warn "If UFW is active, other nodes will NOT be able to join or gossip."
        warn "Fix with:  sudo ./main.sh --redo 25-firewall"
    fi
}

_configure_swarm_init() {
    state_set SWARM_MODE init

    # --advertise-addr is mandatory in practice: with several interfaces
    # dockerd refuses to guess, and with one it may still advertise an
    # address the other nodes can't route to (a docker bridge, say).
    local suggested
    suggested="$(state_get SWARM_ADVERTISE_ADDR)"
    [[ -z "$suggested" ]] && suggested="$(state_get NET_PRIVATE_IP)"
    [[ -z "$suggested" ]] && suggested="$(state_get NET_PUBLIC_IP)"

    info "The address other nodes will use to reach THIS one. It must be"
    info "reachable from them — a LAN/private IP, not a docker bridge address."
    while true; do
        ask_input "Advertise address (this node's IP, e.g. 10.0.0.10)" "$suggested"
        if validate_ip "$REPLY"; then
            state_set SWARM_ADVERTISE_ADDR "$REPLY"
            break
        fi
        warn "'$REPLY' is not a valid IPv4 address."
    done

    info "Quorum note: go from 1 manager straight to 3. Two managers tolerate"
    info "ZERO failures — strictly worse than one — because Raft quorum is"
    info "floor(N/2)+1. Workers have no Raft membership; add them freely."
}

_configure_swarm_join() {
    state_set SWARM_MODE join

    local default=1
    [[ "$(state_get SWARM_JOIN_ROLE)" == "manager" ]] && default=2
    ask_choice "Join as" "$default" \
        "Worker|runs containers; no Raft membership; can join in parallel with others" \
        "Manager|also schedules and holds Raft state; join these ONE AT A TIME"
    case "$REPLY" in
        1) state_set SWARM_JOIN_ROLE worker  ;;
        2) state_set SWARM_JOIN_ROLE manager ;;
    esac

    if [[ "$(state_get SWARM_JOIN_ROLE)" == "manager" ]]; then
        warn "Join managers ONE AT A TIME, waiting for each to show 'Ready' in"
        warn "'docker node ls' before starting the next. Two managers joining"
        warn "concurrently can split the Raft group."
    fi

    info "Token from the first manager. Get it there with:"
    info "  docker swarm join-token -q worker    (or: manager)"
    while true; do
        ask_input "Swarm join token (starts with SWMTKN-)" "$(state_get SWARM_JOIN_TOKEN)"
        if [[ "$REPLY" == SWMTKN-* ]]; then
            state_set SWARM_JOIN_TOKEN "$REPLY"
            break
        fi
        warn "A swarm join token starts with 'SWMTKN-'."
    done

    info "Any current manager's address and cluster port (2377 unless changed)."
    while true; do
        ask_input "Manager address (host:port, e.g. 10.0.0.10:2377)" \
            "$(state_get SWARM_MANAGER_ADDR)"
        if [[ "$REPLY" =~ ^[0-9a-zA-Z._-]+:[0-9]+$ ]]; then
            state_set SWARM_MANAGER_ADDR "$REPLY"
            break
        fi
        warn "Expected host:port, e.g. 10.0.0.10:2377"
    done
}

check_docker_swarm() {
    [[ "$(_swarm_state)" == "active" ]]
}

verify_docker_swarm() {
    check_docker_swarm || return 1
    # On a manager, also assert the control plane actually answers — an
    # "active" node whose Raft isn't serving is not a working cluster.
    if [[ "$(state_get SWARM_MODE)" == "init" ]]; then
        docker node ls >/dev/null 2>&1 || return 1
    fi
    return 0
}

run_docker_swarm() {
    case "$(state_get SWARM_MODE)" in
        init) _run_swarm_init ;;
        join) _run_swarm_join ;;
        *)    log "Swarm: not configured"; return 0 ;;
    esac
}

_run_swarm_init() {
    local addr
    addr="$(state_get SWARM_ADVERTISE_ADDR)"

    if ! docker swarm init --advertise-addr "$addr"; then
        err "docker swarm init failed."
        err "If it complains about multiple addresses, re-run this step and"
        err "give the IP other nodes actually route to."
        return 1
    fi

    # Stash both tokens so 99-finalize can print them with the other secrets.
    # They are cluster credentials: anyone holding the manager token can join
    # a node with full control-plane access.
    state_set SWARM_TOKEN_WORKER  "$(docker swarm join-token -q worker  2>/dev/null || true)"
    state_set SWARM_TOKEN_MANAGER "$(docker swarm join-token -q manager 2>/dev/null || true)"
    state_set SWARM_ROLE manager
    state_set SWARM_JOINED yes
    record_note "this node initialized a Docker Swarm as manager (leave with: docker swarm leave --force)"

    log "Swarm initialized; this node is the first manager (${addr})."
    log "Join tokens are held in state and printed again at step 99."
}

_run_swarm_join() {
    local role token addr
    role="$(state_get SWARM_JOIN_ROLE worker)"
    token="$(state_get SWARM_JOIN_TOKEN)"
    addr="$(state_get SWARM_MANAGER_ADDR)"

    if ! docker swarm join --token "$token" "$addr"; then
        err "docker swarm join failed."
        err "Check from this host that the manager is reachable:"
        err "  nc -vz ${addr%:*} ${addr##*:}"
        err "A timeout here usually means 2377/tcp is closed between nodes —"
        err "see the swarm ports question in 25-firewall."
        return 1
    fi

    state_set SWARM_ROLE "$role"
    state_set SWARM_JOINED yes
    record_note "this node joined a Docker Swarm as ${role} — remove it cluster-side too: docker node rm <id>"
    log "Joined swarm at ${addr} as ${role}."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    applies_docker_swarm || { log "Docker not selected; nothing to do."; exit 0; }
    detect_docker_swarm
    configure_docker_swarm
    state_skipped docker_swarm && exit 0
    check_docker_swarm && { log "Already in a swarm; skipping."; exit 0; }
    run_docker_swarm
    verify_docker_swarm || { err "Swarm verification failed"; exit 1; }
fi
