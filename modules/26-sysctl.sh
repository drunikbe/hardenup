# shellcheck shell=bash
# =============================================================================
# 26-sysctl.sh — Runtime-agnostic kernel hardening baseline
# =============================================================================
#
# Writes /etc/sysctl.d/99-hardening.conf with defenses every VPS wants:
# rp_filter, SYN cookies, no source routing, no ICMP redirects, ASLR,
# log_martians. Deliberately does NOT set ip_forward — that decision belongs
# to the container runtime modules:
#   - 41-docker-firewall.sh sets ip_forward=1 + bridge-nf-call when Docker
#     is selected.
#
# Also writes defensive host-level settings: disable core dumps, restrict
# cron directory permissions.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_sysctl()   { return 0; }
detect_sysctl()    { return 0; }
configure_sysctl() {
    info "Baseline kernel hardening: ASLR, SYN cookies, no source routing,"
    info "no ICMP redirects, log martians, core dumps off, cron restricted."
    if ! ask_yesno "Apply kernel hardening baseline?" "y"; then
        state_mark_skipped sysctl
        return 0
    fi
}

check_sysctl() {
    [[ -f /etc/sysctl.d/99-hardening.conf ]] \
        && grep -q 'kernel.randomize_va_space = 2' /etc/sysctl.d/99-hardening.conf
}

verify_sysctl() {
    check_sysctl
}

run_sysctl() {
    cat > /etc/sysctl.d/99-hardening.conf <<'SYSEOF'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# ASLR
kernel.randomize_va_space = 2
SYSEOF

    # Disable core dumps — core files can leak sensitive memory (keys, etc.).
    cat > /etc/security/limits.d/99-disable-core-dumps.conf <<'EOF'
* hard core 0
* soft core 0
EOF

    # Restrict cron directory access to root.
    chmod 600 /etc/crontab 2>/dev/null || true
    chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null || true

    sysctl --system >/dev/null 2>&1 || true
    log "Kernel hardening baseline applied"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    run_sysctl
    verify_sysctl || { err "sysctl verification failed"; exit 1; }
fi
