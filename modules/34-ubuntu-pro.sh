# shellcheck shell=bash
# =============================================================================
# 34-ubuntu-pro.sh — Optional Ubuntu Pro attachment (ESM + Livepatch)
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_ubuntu_pro() { return 0; }
detect_ubuntu_pro()  { return 0; }

configure_ubuntu_pro() {
    info "Canonical subscription: ESM (extended security patches) + Livepatch (kernel hotfixes)."
    info "Free for personal use up to 5 machines; requires a token from ubuntu.com/pro."
    if ask_yesno "Attach Ubuntu Pro?" "n"; then
        ask_input "Ubuntu Pro token (from ubuntu.com/pro/dashboard)" "$(state_get UBUNTU_PRO_TOKEN)"
        state_set UBUNTU_PRO_TOKEN "$REPLY"
        state_set UBUNTU_PRO_ENABLED yes
    else
        state_set UBUNTU_PRO_ENABLED no
    fi
}

check_ubuntu_pro() {
    [[ "$(state_get UBUNTU_PRO_ENABLED)" == yes ]] || return 0
    pro status 2>/dev/null | grep -q "attached"
}

run_ubuntu_pro() {
    [[ "$(state_get UBUNTU_PRO_ENABLED)" == yes ]] || { log "Ubuntu Pro disabled."; return 0; }
    local token
    token="$(state_get UBUNTU_PRO_TOKEN)"
    if [[ -z "$token" ]]; then
        warn "Ubuntu Pro enabled but no token provided; skipping."
        return 0
    fi
    record_note "Ubuntu Pro attached — detach with: sudo pro detach (also frees the seat on your Canonical account)"
    pro attach "$token" || warn "Ubuntu Pro attachment failed."
    log "Ubuntu Pro attached"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_ubuntu_pro
    check_ubuntu_pro && { log "Already attached; skipping."; exit 0; }
    run_ubuntu_pro
    check_ubuntu_pro || { err "Ubuntu Pro verification failed"; exit 1; }
fi
