# shellcheck shell=bash
# =============================================================================
# 99-finalize.sh — Print generated secrets, wipe state.env, verify wipe
# =============================================================================
#
# Always runs last. Gathers every generated secret from state (RKE2 token,
# SSH keys, Grafana password, Rancher bootstrap, CrowdSec bouncer keys) and
# prints them to stdout for the operator to copy. Then deletes state.env
# and verifies the file is gone — exits non-zero if cleanup failed.
#
# Secrets printed here are ALSO retrievable from their canonical locations
# (kubectl secrets, /etc/rancher/rke2/config.yaml, ~/.ssh/id_ed25519.pub).
# This module is the single-stop summary during the wizard, not a permanent
# credential store.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_finalize() { return 0; }
detect_finalize()  { return 0; }

configure_finalize() {
    info "Prints generated secrets (RKE2 token, Grafana/Rancher passwords, etc.)"
    info "for you to save, then wipes /run/hardenup/state.env."
    if ! ask_yesno "Run the finalize step (print secrets + wipe state)?" "y"; then
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

    local any_secret=0

    # Only print the secrets block if there's anything to show. Anything
    # sensitive lives in state.env during the run and gets wiped below.
    if [[ -n "$(state_get RKE2_TOKEN)" ]] \
        || [[ -n "$(state_get PLATFORM_GRAFANA_PASSWORD)" ]] \
        || [[ -n "$(state_get PLATFORM_RANCHER_PASSWORD)" ]] \
        || [[ -n "$(state_get CROWDSEC_BOUNCER_KEY)" ]]; then
        any_secret=1

        echo ""
        warn "═══════════════════════════════════════════════════════════════"
        warn "  SECRETS — save these before continuing; they will be wiped"
        warn "═══════════════════════════════════════════════════════════════"

        if [[ -n "$(state_get RKE2_TOKEN)" ]]; then
            warn "  RKE2 cluster token:      $(state_get RKE2_TOKEN)"
            warn "  (also in /etc/rancher/rke2/config.yaml)"
        fi
        if [[ -n "$(state_get PLATFORM_GRAFANA_PASSWORD)" ]]; then
            warn "  Grafana admin password:  $(state_get PLATFORM_GRAFANA_PASSWORD)"
            warn "  (also in k8s secret monitoring/kube-prometheus-stack-grafana)"
        fi
        if [[ -n "$(state_get PLATFORM_RANCHER_PASSWORD)" ]]; then
            warn "  Rancher bootstrap pass:  $(state_get PLATFORM_RANCHER_PASSWORD)"
            warn "  (used on first login at https://$(state_get PLATFORM_RANCHER_HOST))"
        fi
        if [[ -n "$(state_get CROWDSEC_BOUNCER_KEY)" ]]; then
            warn "  CrowdSec bouncer key:    $(state_get CROWDSEC_BOUNCER_KEY)"
            warn "  (also in k8s Secret ingress-nginx/crowdsec-bouncer-key)"
        fi
        warn "═══════════════════════════════════════════════════════════════"
    fi

    if [[ -n "$(state_get SSH_KEYGEN_PUBKEY)" ]]; then
        echo ""
        info "Host Ed25519 public key (add to GitHub / peer authorized_keys):"
        info "  $(state_get SSH_KEYGEN_PUBKEY)"
    fi

    if [[ $any_secret -eq 1 ]]; then
        echo ""
        info "Press Enter once you have copied the secrets above — the state file will be wiped."
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
