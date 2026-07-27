# shellcheck shell=bash
# =============================================================================
# 29-unattended.sh — unattended-upgrades for automatic security patching
# =============================================================================
#
# Operator chooses whether to enable at all, whether to auto-reboot when a
# security update requires it, and at what wall-clock time. Auto-reboot
# default is "y" (uncoordinated reboots are fine for single-node VPS / Docker
# hosts); Swarm manager operators should answer "n" when the wizard asks,
# because uncoordinated reboots on a cluster node can break Raft quorum.
# The reboot time defaults to 04:00 (UTC, quiet for EU); operators serving
# other timezones should pick a low-traffic window for their audience.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_unattended() { return 0; }

detect_unattended() {
    # Read the existing reboot time so a repeat run prepopulates the prompt
    # with whatever the operator chose previously. Falls through to the
    # 04:00 default in configure_ if the file doesn't exist or has no value.
    local cfg=/etc/apt/apt.conf.d/50unattended-upgrades
    [[ -f "$cfg" ]] || return 0
    local existing
    existing=$(grep -oP 'Automatic-Reboot-Time\s+"\K[0-9]{2}:[0-9]{2}' "$cfg" 2>/dev/null | head -1)
    [[ -n "$existing" ]] && state_set UNATTENDED_REBOOT_TIME "$existing"
    return 0
}

configure_unattended() {
    info "Daily apt security patching via unattended-upgrades."
    info "Security-only channel; feature updates stay manual."
    if ! ask_yesno "Enable unattended security upgrades?" "y"; then
        state_mark_skipped unattended
        return 0
    fi

    # Email for unattended-upgrades MailReport. Defaults to the MTA's
    # notification email (set in 19-mta) so operators who configured mail
    # earlier just hit Enter; they can still override per-concern here.
    # Delivery only actually works if 19-mta ran OR an external MTA exists.
    ask_input "Email for upgrade reports (blank to skip)" \
        "$(state_get UNATTENDED_MAIL "$(state_get MTA_NOTIFY_EMAIL)")"
    state_set UNATTENDED_MAIL "$REPLY"

    # 29 runs before the runtime/cluster choice at 40-43, so we can't default
    # this off based on a Swarm selection that hasn't been made yet. Operators
    # on cluster nodes must answer "n" — documented in the prompt so it's hard
    # to miss.
    info "Note: Docker Swarm managers should answer 'n' below — three managers"
    info "rebooting together at 04:00 loses Raft quorum. Reboot them by hand,"
    info "one at a time, waiting for each to rejoin."
    if ask_yesno "Auto-reboot when a kernel update requires it?" "y"; then
        state_set UNATTENDED_AUTO_REBOOT yes
        # Wall-clock time is in 24h system-local TZ (UTC on most cloud images).
        # Pick a window that's quiet for *your* audience: 04:00 covers EU,
        # ~11:00 UTC is overnight in US East, ~18:00 UTC is overnight in Asia.
        # Backups must finish before this — a reboot mid-pg_dump truncates it.
        info "Reboot time uses the host's local timezone (UTC on most cloud images)."
        info "Pick a low-traffic window; ensure scheduled backups finish before it."
        ask_input "Reboot time (HH:MM, 24h)" \
            "$(state_get UNATTENDED_REBOOT_TIME 04:00)" \
            '^([01][0-9]|2[0-3]):[0-5][0-9]$'
        state_set UNATTENDED_REBOOT_TIME "$REPLY"
    else
        state_set UNATTENDED_AUTO_REBOOT no
    fi
}

check_unattended() {
    [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] \
        && systemctl is-active --quiet unattended-upgrades
}

verify_unattended() { check_unattended; }

run_unattended() {
    apt-get install -y -qq unattended-upgrades 2>/dev/null

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    local reboot_block
    if [[ "$(state_get UNATTENDED_AUTO_REBOOT no)" == "yes" ]]; then
        local reboot_time
        reboot_time="$(state_get UNATTENDED_REBOOT_TIME 04:00)"
        reboot_block="Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${reboot_time}\";"
    else
        reboot_block='// Auto-reboot disabled (reboot cluster nodes manually, one at a time)
Unattended-Upgrade::Automatic-Reboot "false";'
    fi

    local mail_block=""
    local mail_addr
    mail_addr="$(state_get UNATTENDED_MAIL)"
    if [[ -n "$mail_addr" ]]; then
        # MailReport "on-change" = only when something actually got upgraded
        # or an error occurred. Quieter than the default "always".
        mail_block="Unattended-Upgrade::Mail \"${mail_addr}\";
Unattended-Upgrade::MailReport \"on-change\";"
    fi

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
${reboot_block}
${mail_block}
Unattended-Upgrade::SyslogEnable "true";
EOF

    # Build a human-readable reboot status that includes the time when set,
    # so the OK line answers "did it apply, and when will it fire?" at once.
    local reboot_status
    reboot_status="$(state_get UNATTENDED_AUTO_REBOOT)"
    [[ "$reboot_status" == "yes" ]] && reboot_status="yes @ $(state_get UNATTENDED_REBOOT_TIME)"

    systemctl enable --now unattended-upgrades
    if [[ -n "$mail_addr" ]]; then
        log "Unattended upgrades enabled (auto-reboot=${reboot_status}; mail→${mail_addr})"
        # Warn if an email was set but no sendmail is present — otherwise the
        # reports vanish into /dev/null without a hint. 19-mta is the normal
        # way to fix this; a pre-existing postfix/exim4 is also fine.
        if ! command -v sendmail >/dev/null 2>&1 && [[ ! -x /usr/sbin/sendmail ]]; then
            warn "No sendmail found — upgrade reports will be dropped silently."
            warn "Re-run 19-mta (sudo ./main.sh --redo mta) to set up msmtp."
        fi
    else
        log "Unattended upgrades enabled (auto-reboot=${reboot_status}; no mail)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_unattended
    configure_unattended
    state_skipped unattended && exit 0
    run_unattended
    verify_unattended || { err "unattended-upgrades verification failed"; exit 1; }
fi
