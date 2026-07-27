# shellcheck shell=bash
# =============================================================================
# 28-timezone.sh — System timezone + NTP
# =============================================================================
#
# Auto-detects the current system timezone (or tries a best-effort guess from
# the public IP geolocation via `timedatectl`, which consults the kernel's
# /etc/timezone first). Operator can accept the detected value or override
# with any IANA zone name like "Europe/Brussels" or "America/Los_Angeles".
# UTC is recommended for servers (keeps logs unambiguous, no DST bugs) —
# wizard default is still UTC if nothing else is detected.
#
# --- Do not name an NTP implementation --------------------------------------
#
# This module used to hard-code systemd-timesyncd: `systemctl enable
# systemd-timesyncd --now` in run_, and `systemctl is-active
# systemd-timesyncd` in the verify. Ubuntu 26.04 ships **chrony** instead and
# doesn't install timesyncd at all, so the enable failed (swallowed by
# `|| true`), the verify could never pass, and main.sh halted the whole wizard
# at step 28 on every stock 26.04 host — while the clock was in fact perfectly
# synchronised by chrony.
#
# So: detect whatever is present rather than dictating. `timedatectl` already
# abstracts this — NTP=yes means some time sync is enabled, NTPSynchronized=yes
# means it is actually working, whichever daemon provides it. Installing a
# second daemon alongside an existing one would leave two processes fighting
# over the clock, so we only install when nothing is there at all.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_timezone() { return 0; }

detect_timezone() {
    # If state already has a choice (from a previous run / --answers seed),
    # keep it. Otherwise auto-detect from the running system.
    [[ -n "$(state_get TIMEZONE)" ]] && return 0
    local current
    current="$(timedatectl show --value -p Timezone 2>/dev/null)"
    # timedatectl returns "Etc/UTC" or similar on a fresh Ubuntu; normalise
    # to plain UTC for readability and pass-through otherwise.
    [[ "$current" == "Etc/UTC" ]] && current="UTC"
    state_set TIMEZONE "${current:-UTC}"
}

configure_timezone() {
    info "Sets system timezone and enables systemd-timesyncd for NTP."
    info "UTC is recommended for servers; local zones are supported."
    if ! ask_yesno "Configure timezone and NTP?" "y"; then
        state_mark_skipped timezone
        return 0
    fi
    while true; do
        ask_input "Timezone (IANA name, e.g. UTC, Europe/Brussels, America/Los_Angeles)" \
            "$(state_get TIMEZONE UTC)"
        # Validate against the kernel's list of known zones.
        if timedatectl list-timezones 2>/dev/null | grep -qx "$REPLY"; then
            state_set TIMEZONE "$REPLY"
            break
        fi
        err "Unknown timezone: $REPLY"
        info "List available zones: timedatectl list-timezones | less"
    done
}

check_timezone() {
    local want have
    want="$(state_get TIMEZONE UTC)"
    have="$(timedatectl show --value -p Timezone 2>/dev/null)"
    # Treat Etc/UTC as UTC for the equality check.
    [[ "$have" == "Etc/UTC" ]] && have="UTC"
    [[ "$want" == "$have" ]] || return 1

    # Ask timedatectl, not a named unit. NTP=yes means time sync is enabled by
    # whatever daemon this distro ships; naming one is how this module broke on
    # 26.04. NTPSynchronized is deliberately NOT required: it is false for the
    # first few moments after a daemon starts, and failing the step because the
    # clock hasn't converged yet would be a flaky verify.
    [[ "$(timedatectl show --value -p NTP 2>/dev/null)" == "yes" ]]
}

verify_timezone() { check_timezone; }

# Echo the NTP daemon unit that is installed on this host, or "" if none.
# Order matters only for reporting; either satisfies the verify.
_ntp_unit() {
    local unit
    for unit in chrony chronyd systemd-timesyncd ntpsec ntp; do
        if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 \
            && systemctl cat "${unit}.service" >/dev/null 2>&1; then
            echo "$unit"
            return 0
        fi
    done
    return 0
}

run_timezone() {
    local tz unit
    tz="$(state_get TIMEZONE UTC)"
    timedatectl set-timezone "$tz"

    unit="$(_ntp_unit)"
    if [[ -z "$unit" ]]; then
        # Nothing installed — pick the distro default rather than a favourite.
        # chrony is what Ubuntu ships now; timesyncd remains available.
        info "No NTP daemon installed; installing chrony."
        record_pkg_installed chrony
        apt-get install -y -qq chrony 2>/dev/null || true
        unit="$(_ntp_unit)"
    fi

    if [[ -n "$unit" ]]; then
        # Only enable if it isn't already running: a daemon the operator (or
        # the image) already configured shouldn't be restarted just to prove
        # a point, and two NTP daemons must never run together.
        if ! systemctl is-active --quiet "$unit"; then
            record_service_enabled "$unit"
            systemctl enable "$unit" --now 2>/dev/null \
                || warn "Could not enable ${unit}; check: systemctl status ${unit}"
        fi
        log "Timezone ${tz}, NTP via ${unit}"
    else
        # Truthful failure. The old code printed [OK] here regardless.
        warn "Timezone ${tz} set, but no NTP daemon could be enabled."
        warn "Time will drift. Install one: sudo apt-get install chrony"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_timezone
    configure_timezone
    check_timezone && { log "Timezone + NTP already set; skipping."; exit 0; }
    run_timezone
    check_timezone || { err "Timezone verification failed"; exit 1; }
fi
