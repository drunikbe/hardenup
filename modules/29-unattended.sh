# shellcheck shell=bash
# =============================================================================
# 29-unattended.sh — unattended-upgrades for automatic security patching
# =============================================================================
#
# Operator chooses whether to enable at all, whether to auto-reboot when a
# security update requires it, and at what wall-clock time.
#
# --- Why this writes a drop-in instead of rewriting the distro files ---------
#
# Ubuntu ships unattended-upgrades pre-installed, enabled and configured —
# verified on 26.04: the package is `ii`, the timer is active+enabled, and
# /etc/apt/apt.conf.d/50unattended-upgrades already carries Allowed-Origins
# (including both ESM origins), Package-Blacklist and DevRelease.
#
# This module used to `cat >` over 50unattended-upgrades wholesale, which
# destroyed whatever the distro — or the operator — had put there, most
# notably any Package-Blacklist entries. There is no reason to: apt reads
# /etc/apt/apt.conf.d/* in lexical order and later assignments win for scalar
# options, so a file sorting after "50unattended-upgrades" can override
# exactly the handful of settings we care about and leave everything else
# untouched.
#
# Hence UNATTENDED_DROPIN below. Every value it sets is a scalar. We
# deliberately do NOT touch Allowed-Origins: it is a list (`Foo:: "x"` appends
# rather than replaces), the distro's default is already the correct
# security+ESM set, and a botched override here silently stops security
# patching. Verified on 26.04 that the drop-in's scalars take effect while all
# four distro Allowed-Origins entries survive, via `apt-config dump`.
#
# 20auto-upgrades is likewise left alone. The two keys that must be on
# (Update-Package-Lists, Unattended-Upgrade) are already set by the distro,
# and our drop-in sorts later, so it can assert them for minimal images
# without rewriting the distro's file.
#
# --- Auto-reboot defaults to "n" ---------------------------------------------
#
# Three Swarm managers rebooting together at 04:00 lose Raft quorum, and 29
# runs long before the swarm choice at 43, so it cannot infer the answer. An
# unplanned quorum loss is worse than a delayed kernel patch, so the default
# is off and the prompt explains both cases. A single-node host with no
# cluster to break should answer "y".
#
# The reboot time defaults to 04:00 in the host's local timezone (UTC on most
# cloud images); operators serving other regions should pick their own quiet
# window.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

# Sorts after 50unattended-upgrades, so its scalars override the distro's.
UNATTENDED_DROPIN=/etc/apt/apt.conf.d/52-hardenup-unattended

applies_unattended() { return 0; }

# Echo the EFFECTIVE value of an apt option, with the distro default and every
# drop-in already merged. Much more honest than grepping one file, which can't
# see an override that another file makes later in the sequence.
_apt_effective() {
    apt-config dump --format '%v%n' "$1" 2>/dev/null | head -1
}

detect_unattended() {
    # Prepopulate prompts from the effective config so a re-run shows what is
    # actually in force. configure_'s own defaults apply when these are empty.
    local t reboot mail
    t="$(_apt_effective Unattended-Upgrade::Automatic-Reboot-Time)"
    [[ "$t" =~ ^[0-9]{2}:[0-9]{2}$ ]] && state_set UNATTENDED_REBOOT_TIME "$t"

    reboot="$(_apt_effective Unattended-Upgrade::Automatic-Reboot)"
    [[ "$reboot" == "true"  ]] && state_set UNATTENDED_AUTO_REBOOT yes
    [[ "$reboot" == "false" ]] && state_set UNATTENDED_AUTO_REBOOT no

    mail="$(_apt_effective Unattended-Upgrade::Mail)"
    [[ -n "$mail" ]] && state_set UNATTENDED_MAIL "$mail"
    return 0
}

configure_unattended() {
    info "Daily apt security patching via unattended-upgrades."
    info "Security-only channel; feature updates stay manual."
    info "Ubuntu already ships this enabled — we add settings in a drop-in"
    info "(${UNATTENDED_DROPIN##*/}) and leave the distro's own config intact."
    if ! ask_yesno "Enable unattended security upgrades?" "y"; then
        state_mark_skipped unattended
        return 0
    fi

    # Email for unattended-upgrades MailReport. Gated behind its own y/n
    # because ask_input cannot return an empty string — it loops on "A value
    # is required" — so the previous "(blank to skip)" label was unreachable:
    # an operator with no mail relay had no way past it but to invent an
    # address. Delivery only actually works if 19-mta ran OR an external MTA
    # exists; the default follows whether a notification address is known.
    local mail_default="n"
    [[ -n "$(state_get UNATTENDED_MAIL "$(state_get MTA_NOTIFY_EMAIL)")" ]] && mail_default="y"
    info "Reports are sent only when something was upgraded or failed."
    info "Needs a working local MTA — step 19 sets one up (msmtp)."
    if ask_yesno "Email a report when upgrades run?" "$mail_default"; then
        ask_input "Email address for upgrade reports" \
            "$(state_get UNATTENDED_MAIL "$(state_get MTA_NOTIFY_EMAIL)")"
        state_set UNATTENDED_MAIL "$REPLY"
    else
        state_set UNATTENDED_MAIL ""
    fi

    # Default "n": 29 runs before the swarm choice at 43, so it cannot know
    # whether this host will be a cluster manager. Losing Raft quorum to a
    # synchronized 04:00 reboot is worse than a kernel patch waiting for a
    # maintenance window, so the safe answer is the default one.
    local reboot_default="n"
    [[ "$(state_get UNATTENDED_AUTO_REBOOT)" == "yes" ]] && reboot_default="y"
    info "Answer 'n' on Docker Swarm managers — three of them rebooting"
    info "together at 04:00 loses Raft quorum. Reboot cluster nodes by hand,"
    info "one at a time, waiting for each to rejoin."
    info "Answer 'y' on a standalone host: kernel CVEs then get patched"
    info "without you, which is what you want when nothing depends on quorum."
    if ask_yesno "Auto-reboot when a kernel update requires it?" "$reboot_default"; then
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
    [[ -f "$UNATTENDED_DROPIN" ]] || return 1
    systemctl is-active --quiet unattended-upgrades || return 1

    # Compare against the EFFECTIVE config, not our own file: that is what
    # actually governs, and it catches a later drop-in overriding us.
    local want_reboot
    if [[ "$(state_get UNATTENDED_AUTO_REBOOT no)" == "yes" ]]; then
        want_reboot=true
    else
        want_reboot=false
    fi
    [[ "$(_apt_effective Unattended-Upgrade::Automatic-Reboot)" == "$want_reboot" ]] || return 1

    if [[ "$want_reboot" == true ]]; then
        [[ "$(_apt_effective Unattended-Upgrade::Automatic-Reboot-Time)" \
            == "$(state_get UNATTENDED_REBOOT_TIME 04:00)" ]] || return 1
    fi
    return 0
}

verify_unattended() {
    check_unattended || return 1
    # A syntactically broken apt.conf makes EVERY apt invocation fail, which
    # is a much bigger outage than missing patches. apt-config exits non-zero
    # when it can't parse the merged configuration.
    apt-config dump >/dev/null 2>&1
}

run_unattended() {
    # Already present on stock Ubuntu; this covers minimal//container images.
    if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
        apt-get install -y -qq unattended-upgrades
    fi

    local reboot_block mail_block="" mail_addr reboot_time
    reboot_time="$(state_get UNATTENDED_REBOOT_TIME 04:00)"
    if [[ "$(state_get UNATTENDED_AUTO_REBOOT no)" == "yes" ]]; then
        reboot_block="Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${reboot_time}\";"
    else
        reboot_block="// Off by default: a synchronized reboot across Swarm
// managers loses Raft quorum. Reboot cluster nodes manually, one at a time.
Unattended-Upgrade::Automatic-Reboot \"false\";"
    fi

    mail_addr="$(state_get UNATTENDED_MAIL)"
    if [[ -n "$mail_addr" ]]; then
        # MailReport "on-change" = only when something actually got upgraded
        # or an error occurred. Quieter than the default "always".
        mail_block="Unattended-Upgrade::Mail \"${mail_addr}\";
Unattended-Upgrade::MailReport \"on-change\";"
    fi

    # Only scalars, and only the ones this module owns. Allowed-Origins is
    # deliberately absent — see the header.
    cat > "$UNATTENDED_DROPIN" <<EOF
// Managed by hardenup (29-unattended). Overrides the matching settings in
// 50unattended-upgrades and 20auto-upgrades, which are left untouched:
// apt reads this directory in lexical order and later scalars win.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
${reboot_block}
${mail_block}
Unattended-Upgrade::SyslogEnable "true";
EOF
    chmod 0644 "$UNATTENDED_DROPIN"

    # Reject our own bad syntax immediately: a broken file here breaks every
    # subsequent apt command on the host, including the rest of this wizard.
    if ! apt-config dump >/dev/null 2>&1; then
        err "The drop-in produced an unparseable apt configuration; removing it."
        rm -f "$UNATTENDED_DROPIN"
        return 1
    fi

    local reboot_status
    reboot_status="$(state_get UNATTENDED_AUTO_REBOOT no)"
    [[ "$reboot_status" == "yes" ]] && reboot_status="yes @ ${reboot_time}"

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
    log "Distro config untouched; hardenup settings live in ${UNATTENDED_DROPIN}"
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
