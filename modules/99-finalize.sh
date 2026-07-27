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
