# shellcheck shell=bash
# =============================================================================
# 20-hostname.sh — Set system hostname
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_hostname() { return 0; }

detect_hostname() {
    [[ -n "$(state_get HOSTNAME_FQDN)" ]] && return 0
    state_set HOSTNAME_FQDN "$(hostname)"
}

configure_hostname() {
    info "Sets the system hostname via hostnamectl."
    info "Used later as the Docker Swarm node name."
    if ! ask_yesno "Configure the system hostname?" "y"; then
        state_mark_skipped hostname
        return 0
    fi
    local cur
    cur="$(state_get HOSTNAME_FQDN "$(hostname)")"
    while true; do
        ask_input "Hostname (short name or FQDN)" "$cur"
        if validate_hostname "$REPLY"; then
            state_set HOSTNAME_FQDN "$REPLY"
            break
        fi
        err "Invalid hostname: $REPLY"
    done
}

check_hostname() {
    [[ "$(hostname)" == "$(state_get HOSTNAME_FQDN)" ]]
}

run_hostname() {
    local fqdn
    fqdn="$(state_get HOSTNAME_FQDN)"
    hostnamectl set-hostname "$fqdn"
    log "Hostname set to: $fqdn"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_hostname
    configure_hostname
    check_hostname && { log "Hostname already set; nothing to do."; exit 0; }
    run_hostname
    check_hostname || { err "Hostname verification failed"; exit 1; }
fi
