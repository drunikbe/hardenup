# shellcheck shell=bash
# =============================================================================
# 99-finalize.sh — Print generated secrets, wipe state.env, verify wipe
# =============================================================================
#
# Always runs last. Prints a summary of what this run set up (host, sudo user,
# networks, generated SSH public key), then deletes state.env and verifies the
# file is gone — exits non-zero if cleanup failed.
#
# Anything printed here is ALSO retrievable from its canonical location on
# disk (e.g. ~/.ssh/id_ed25519.pub). This module is the single-stop summary
# during the wizard, not a permanent credential store.
#
# When a step starts generating a real secret again (e.g. a Swarm join token),
# print it here BEFORE the wipe and pause for the operator to copy it —
# state.env is gone by the time this function returns.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_finalize() { return 0; }
detect_finalize()  { return 0; }

configure_finalize() {
    info "Prints a summary of this run (host, user, networks, SSH public key)"
    info "for you to save, then wipes /run/hardenup/state.env."
    if ! ask_yesno "Run the finalize step (print summary + wipe state)?" "y"; then
        state_mark_skipped finalize
        warn "Skipping finalize — state.env will remain at /run/hardenup/."
        warn "Secrets stay on tmpfs (gone at next reboot). Run finalize manually when ready."
        return 0
    fi
}

run_finalize() {
    separator "Summary"

    # Operator-facing overview of what was done this run.
    if [[ -n "$(state_get HOSTNAME_FQDN)" ]]; then
        info "Host:          $(state_get HOSTNAME_FQDN)"
    fi
    if [[ -n "$(state_get USER_NAME)" ]]; then
        info "Sudo user:     $(state_get USER_NAME) (ssh -p $(state_get SSH_PORT 22) $(state_get USER_NAME)@<host>)"
    fi
    if [[ -n "$(state_get NET_PUBLIC_IFACE)" ]]; then
        info "Public net:    $(state_get NET_PUBLIC_IFACE) $(state_get NET_PUBLIC_IP)"
    fi
    if [[ "$(state_get NET_HAS_PRIVATE)" == "yes" ]]; then
        info "Private net:   $(state_get NET_PRIVATE_IFACE) $(state_get NET_PRIVATE_IP) ($(state_get NET_PRIVATE_CIDR))"
    fi

    if [[ -n "$(state_get SSH_KEYGEN_PUBKEY)" ]]; then
        echo ""
        info "Host Ed25519 public key (add to GitHub / peer authorized_keys):"
        info "  $(state_get SSH_KEYGEN_PUBKEY)"
    fi

    # Swarm join tokens are real cluster credentials — the manager token grants
    # control-plane access to whoever holds it. They live in state.env, which
    # is wiped a few lines below, so print them and pause for the operator.
    # They remain retrievable afterwards from any manager:
    #   docker swarm join-token -q worker | manager
    local tok_worker tok_manager
    tok_worker="$(state_get SWARM_TOKEN_WORKER)"
    tok_manager="$(state_get SWARM_TOKEN_MANAGER)"
    if [[ -n "$tok_worker" || -n "$tok_manager" ]]; then
        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  SWARM JOIN TOKENS — save these; they are wiped with the state"
        warn "═══════════════════════════════════════════════════════════════"
        [[ -n "$tok_worker" ]] && \
            warn "  Worker:   docker swarm join --token ${tok_worker} $(state_get SWARM_ADVERTISE_ADDR):2377"
        [[ -n "$tok_manager" ]] && \
            warn "  Manager:  docker swarm join --token ${tok_manager} $(state_get SWARM_ADVERTISE_ADDR):2377"
        warn "  Re-readable on any manager: docker swarm join-token -q worker"
        warn "═══════════════════════════════════════════════════════════════"
        echo ""
        info "Press Enter once you have copied the tokens above — the state"
        info "file will then be wiped."
        # shellcheck disable=SC2162
        read _ack
    fi

    # Wipe state.env and verify.
    if state_finalize_and_wipe; then
        log "state.env wiped ✓  ($STATE_DIR no longer exists)"
    else
        err "state.env was NOT wiped. See warnings above."
        return 1
    fi
}

# verify_finalize is defined for main.sh's verify gate. The wipe itself is the
# verification: if state_finalize_and_wipe returned 0, the file is gone.
verify_finalize() {
    [[ ! -e "$STATE_FILE" && ! -e "$STATE_DIR" ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_finalize
    state_skipped finalize && exit 0
    run_finalize
    verify_finalize || { err "Finalize verification failed"; exit 1; }
fi
