# shellcheck shell=bash
# =============================================================================
# 30-intrusion.sh — Host-level intrusion detection: fail2ban XOR crowdsec
# =============================================================================
#
# One step, three answers: none / fail2ban / crowdsec. Merges what used to be
# three separate modules (30-security-choice, 31-fail2ban, 32-crowdsec-host)
# so the wizard has exactly one y/n + one radio choice for this concern.
#
# Both backends are private-net-aware:
#   fail2ban: adds NET_PRIVATE_CIDR to `ignoreip`.
#   crowdsec: drops a whitelist parser at
#             /etc/crowdsec/parsers/s02-enrich/private-whitelist.yaml.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_intrusion() { return 0; }

detect_intrusion() {
    if command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec; then
        state_set SECURITY_TOOL crowdsec
    elif systemctl is-active --quiet fail2ban; then
        state_set SECURITY_TOOL fail2ban
    fi
}

configure_intrusion() {
    info "Watches auth logs for brute-force attempts and adds dynamic bans."
    info "Sits on top of the host firewall — does not replace it."
    if ! ask_yesno "Enable host-level intrusion detection (fail2ban/crowdsec)?" "y"; then
        state_set SECURITY_TOOL none
        state_mark_skipped intrusion
        return 0
    fi

    local default=1
    [[ "$(state_get SECURITY_TOOL)" == "crowdsec" ]] && default=2
    ask_choice "Intrusion detection tool" "$default" \
        "Fail2ban|Lightweight SSH brute-force protection via UFW bans" \
        "CrowdSec|Community-shared blocklists + iptables bouncer"
    case "$REPLY" in
        1) state_set SECURITY_TOOL fail2ban ;;
        2) state_set SECURITY_TOOL crowdsec ;;
    esac

    # CrowdSec: ask about console enrollment.
    if [[ "$(state_get SECURITY_TOOL)" == "crowdsec" ]]; then
        if [[ -z "$(state_get CROWDSEC_ENROLL_KEY)" ]]; then
            info "CrowdSec's web console (app.crowdsec.net) is free for community use"
            info "and gives you a dashboard showing blocked IPs, attack patterns, and"
            info "alerts across all your enrolled machines. In exchange, your local"
            info "agent sends decisions + sensor metrics to CrowdSec Inc. Decline for"
            info "pure local operation — detection and blocking still work offline."
            if ask_yesno "Enroll CrowdSec in the web console dashboard?" "n"; then
                ask_input "CrowdSec enrollment key (from app.crowdsec.net console; blank to skip)" ""
                state_set CROWDSEC_ENROLL_KEY "$REPLY"
            fi
        fi
    fi
}

check_intrusion() {
    case "$(state_get SECURITY_TOOL)" in
        fail2ban) [[ -f /etc/fail2ban/jail.local ]] && systemctl is-active --quiet fail2ban ;;
        crowdsec) command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec ;;
        none|*)   return 0 ;;
    esac
}

verify_intrusion() { check_intrusion; }

_run_fail2ban() {
    apt-get install -y -qq fail2ban 2>/dev/null

    local ssh_port priv_cidr ignore
    ssh_port="$(state_get SSH_PORT 22)"
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    ignore="127.0.0.1/8 ::1"
    [[ -n "$priv_cidr" ]] && ignore+=" $priv_cidr"

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
banaction = ufw
ignoreip = ${ignore}

[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF

    systemctl enable fail2ban --now 2>/dev/null || true
    systemctl restart fail2ban
    log "Fail2ban active (SSH: 3 retries, 1h ban; ignoring: ${ignore})"
}

_run_crowdsec() {
    # Official installer script sets up the repository and apt key.
    curl -s https://install.crowdsec.net | bash
    apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables

    local priv_cidr
    priv_cidr="$(state_get NET_PRIVATE_CIDR)"
    if [[ -n "$priv_cidr" ]]; then
        mkdir -p /etc/crowdsec/parsers/s02-enrich
        cat > /etc/crowdsec/parsers/s02-enrich/private-whitelist.yaml <<EOF
name: cloud/private-whitelist
description: "Whitelist intra-server private CIDR"
whitelist:
  reason: "private network (hardenup)"
  cidr:
    - "${priv_cidr}"
EOF
        log "CrowdSec whitelist: ${priv_cidr}"
    fi

    # Install a curated default set of collections. The installer script's
    # auto-detection does most of this already based on running services,
    # but being explicit prevents missing coverage when a service gets
    # added later (e.g. the operator installs nginx at step 51 after
    # crowdsec is already running). cscli is idempotent.
    cscli collections install \
        crowdsecurity/linux \
        crowdsecurity/sshd \
        crowdsecurity/base-http-scenarios \
        crowdsecurity/http-cve \
        crowdsecurity/iptables \
        2>/dev/null || warn "One or more collections failed to install; check 'cscli collections list'."
    cscli hub upgrade >/dev/null 2>&1 || true

    local key
    key="$(state_get CROWDSEC_ENROLL_KEY)"
    if [[ -n "$key" ]]; then
        cscli console enroll -e context "$key" || warn "CrowdSec enrollment failed."
        warn "Accept the enrollment in the CrowdSec console."
    fi

    systemctl restart crowdsec
    log "CrowdSec installed with default collections (linux, sshd, base-http, http-cve, iptables)"
}

run_intrusion() {
    case "$(state_get SECURITY_TOOL)" in
        fail2ban) _run_fail2ban ;;
        crowdsec) _run_crowdsec ;;
        none|"")  log "Intrusion detection: disabled" ;;
        *)        err "Unknown SECURITY_TOOL=$(state_get SECURITY_TOOL)"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_intrusion
    configure_intrusion
    state_skipped intrusion && exit 0
    run_intrusion
    verify_intrusion || { err "Intrusion verification failed"; exit 1; }
fi
