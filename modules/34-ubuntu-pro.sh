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

    # Say plainly when the subscription would buy this host nothing today.
    # Livepatch only covers certain kernel flavours — notably not the
    # Raspberry Pi kernel — and ESM matters only once standard support ends,
    # which for a freshly released LTS is years away. Better to say so than to
    # let someone attach a seat that does nothing.
    if pro status 2>/dev/null | grep -q "not covered by livepatch"; then
        info "Note: this kernel is NOT covered by Livepatch (the Raspberry Pi"
        info "kernel isn't). ESM also only matters once standard support ends,"
        info "which is years away on a freshly released LTS — so on this host a"
        info "Pro subscription may buy you nothing today."
    fi

    if ! ask_yesno "Attach Ubuntu Pro?" "n"; then
        state_set UBUNTU_PRO_ENABLED no
        state_mark_skipped ubuntu_pro
        return 0
    fi

    # ask_input_optional, not ask_input: with no token already in state there
    # is no default, and plain ask_input loops forever on empty input. An
    # operator who says yes and then realises the token isn't to hand had no
    # way forward or back except Ctrl+C, which aborts the whole wizard.
    info "Leave blank to skip if you don't have your token to hand."
    ask_input_optional "Ubuntu Pro token (from ubuntu.com/pro/dashboard)" \
        "$(state_get UBUNTU_PRO_TOKEN)"
    if [[ -z "$REPLY" ]]; then
        warn "No token entered — skipping Ubuntu Pro."
        state_set UBUNTU_PRO_ENABLED no
        state_mark_skipped ubuntu_pro
        return 0
    fi
    state_set UBUNTU_PRO_TOKEN "$REPLY"
    state_set UBUNTU_PRO_ENABLED yes
}

# Returns 0 only when this host really is attached. When Pro was declined
# there is nothing to check — but returning 0 made the standalone block print
# "Already attached; skipping" on a host that was never attached and never
# would be, so the two cases are now distinguished by the caller.
check_ubuntu_pro() {
    # `pro status | grep -q attached` was a false positive: the unattached
    # message is "This machine is not attached to an Ubuntu Pro subscription",
    # which contains the word. Every unattached host therefore looked attached,
    # and the module skipped itself.
    #
    # pro's own guidance is to use the machine-readable interfaces rather than
    # the human status output. The JSON `attached` boolean is the plainest;
    # `pro api u.pro.status.is_attached.v1` is the newer equivalent and is
    # tried first, falling back for older clients.
    local out
    out="$(pro api u.pro.status.is_attached.v1 2>/dev/null || true)"
    if [[ "$out" == *'"is_attached":'* ]]; then
        [[ "$out" == *'"is_attached": true'* || "$out" == *'"is_attached":true'* ]]
        return $?
    fi

    out="$(pro status --format json 2>/dev/null || true)"
    if [[ "$out" == *'"attached":'* ]]; then
        [[ "$out" == *'"attached": true'* || "$out" == *'"attached":true'* ]]
        return $?
    fi

    # Last resort: match the negative sentence rather than the word.
    ! pro status 2>/dev/null | grep -qi "not attached"
}

run_ubuntu_pro() {
    [[ "$(state_get UBUNTU_PRO_ENABLED)" == yes ]] || { log "Ubuntu Pro disabled."; return 0; }
    local token
    token="$(state_get UBUNTU_PRO_TOKEN)"
    if [[ -z "$token" ]]; then
        warn "Ubuntu Pro enabled but no token provided; skipping."
        return 0
    fi

    # Report the truth. This used to `warn` on failure and then print
    # "[OK] Ubuntu Pro attached" unconditionally on the next line, telling the
    # operator it worked when it hadn't.
    if ! pro attach "$token"; then
        err "Ubuntu Pro attachment failed. Check the token at"
        err "  https://ubuntu.com/pro/dashboard"
        err "and that this host can reach contracts.canonical.com."
        return 1
    fi
    record_note "Ubuntu Pro attached — detach with: sudo pro detach (also frees the seat on your Canonical account)"
    log "Ubuntu Pro attached"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    configure_ubuntu_pro
    state_skipped ubuntu_pro && exit 0
    check_ubuntu_pro && { log "Already attached; skipping."; exit 0; }
    run_ubuntu_pro
    check_ubuntu_pro || { err "Ubuntu Pro verification failed"; exit 1; }
fi
