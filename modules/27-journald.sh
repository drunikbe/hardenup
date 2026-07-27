# shellcheck shell=bash
# =============================================================================
# 27-journald.sh — Cap journald disk usage (1G / 100M / 7 days)
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_journald()  { return 0; }
detect_journald()   { return 0; }
configure_journald() {
    info "Caps journald at 1G total / 100M per file / 7-day retention."
    info "Prevents runaway logs from filling /var on a busy host."
    if ! ask_yesno "Configure journald disk caps?" "y"; then
        state_mark_skipped journald
        return 0
    fi
}
check_journald() {
    [[ -f /etc/systemd/journald.conf.d/99-cap.conf ]] \
        && grep -q "SystemMaxUse=1G" /etc/systemd/journald.conf.d/99-cap.conf
}

run_journald() {
    info "Capping journald at 1G total / 100M per file / 7-day retention."
    info "Prevents runaway logs from filling /var on a busy host."
    mkdir -p /etc/systemd/journald.conf.d
    backup_file /etc/systemd/journald.conf.d/99-cap.conf
    cat > /etc/systemd/journald.conf.d/99-cap.conf <<'EOF'
[Journal]
SystemMaxUse=1G
SystemMaxFileSize=100M
MaxRetentionSec=7day
Compress=yes
EOF
    systemctl restart systemd-journald
    log "Journald: 1G cap, 7-day retention"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    check_journald && { log "Journald cap already in place; skipping."; exit 0; }
    run_journald
    check_journald || { err "Journald verification failed"; exit 1; }
fi
