# shellcheck shell=bash
# =============================================================================
# 22-ssh-keygen.sh — Generate host-side Ed25519 keypair for outbound access
# =============================================================================
#
# Creates an Ed25519 keypair on the host so it can:
#   - Clone private Git repos (GitHub Deploy Keys, self-hosted Forgejo, ...)
#   - SSH to peer servers for cluster bootstrapping, backup, etc.
#
# Owner: USER_NAME from state (if set); otherwise root.
# Optionally: also generate a root key (SSH_KEYGEN_ALSO_ROOT=yes) for
# system-level automation that needs git access (unattended pulls, etc.).
#
# Never overwrites an existing id_ed25519 — prints a notice and moves on.
#
# This module only generates OUTBOUND keys. Inbound peer authorization
# (other machines SSH-ing into this host) is handled by 66-ssh-peers.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_ssh_keygen() { return 0; }

# Resolve the primary owner (non-root user if present, else root).
_keygen_owner() {
    local u
    u="$(state_get USER_NAME)"
    if [[ -n "$u" ]] && id "$u" &>/dev/null; then
        echo "$u"
    else
        echo "root"
    fi
}

_home_for() {
    local u="$1"
    if [[ "$u" == "root" ]]; then echo "/root"
    else echo "/home/$u"
    fi
}

detect_ssh_keygen() {
    local owner home key
    owner="$(_keygen_owner)"
    home="$(_home_for "$owner")"
    key="$home/.ssh/id_ed25519"
    if [[ -f "$key" ]]; then
        state_set SSH_KEYGEN_OWNER "$owner"
        state_set SSH_KEYGEN_EXISTS yes
        state_set SSH_KEYGEN_PUBKEY "$(cat "$key.pub" 2>/dev/null || true)"
    else
        state_set SSH_KEYGEN_OWNER "$owner"
        state_set SSH_KEYGEN_EXISTS no
    fi
}

configure_ssh_keygen() {
    info "Creates a new Ed25519 identity on this host for outbound SSH."
    info "Useful for GitHub deploy keys, rsync backups, and deploys between nodes."
    if ! ask_yesno "Generate an Ed25519 keypair on this host (for GitHub, peers, etc.)?" "y"; then
        state_set SSH_KEYGEN_ENABLED no
        return 0
    fi
    state_set SSH_KEYGEN_ENABLED yes

    # Also generate one for root? Useful when root-owned systemd timers
    # pull from private git repos.
    local also_root_default="n"
    [[ "$(_keygen_owner)" == "root" ]] && also_root_default="y"
    if ask_yesno "Also generate a keypair for root?" "$also_root_default"; then
        state_set SSH_KEYGEN_ALSO_ROOT yes
    else
        state_set SSH_KEYGEN_ALSO_ROOT no
    fi
}

check_ssh_keygen() {
    [[ "$(state_get SSH_KEYGEN_ENABLED)" == yes ]] || return 0   # disabled → nothing to do
    local owner home key
    owner="$(_keygen_owner)"
    home="$(_home_for "$owner")"
    key="$home/.ssh/id_ed25519"
    [[ -f "$key" ]] || return 1
    # If also_root requested, verify root key too.
    if [[ "$(state_get SSH_KEYGEN_ALSO_ROOT)" == yes && "$owner" != "root" ]]; then
        [[ -f "/root/.ssh/id_ed25519" ]] || return 1
    fi
    return 0
}

_generate_for() {
    local owner="$1"
    local home ssh_dir key
    home="$(_home_for "$owner")"
    ssh_dir="$home/.ssh"
    key="$ssh_dir/id_ed25519"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "$owner:$owner" "$ssh_dir"

    if [[ -f "$key" ]]; then
        info "Keypair already exists for $owner — preserving."
        return 0
    fi

    local comment
    comment="hardenup@$(hostname)-$(date -u +%Y-%m-%d)"
    # -N "" = no passphrase; unattended-use pattern.
    sudo -u "$owner" ssh-keygen -t ed25519 -N "" -C "$comment" -f "$key" >/dev/null
    log "Generated Ed25519 keypair for $owner: $key"

    # Print the pubkey prominently so the operator can copy it.
    separator "Public key for $owner"
    cat "$key.pub"
    echo ""
}

run_ssh_keygen() {
    [[ "$(state_get SSH_KEYGEN_ENABLED)" == yes ]] || { log "ssh-keygen disabled — skipping."; return 0; }
    local primary
    primary="$(_keygen_owner)"
    _generate_for "$primary"
    if [[ "$(state_get SSH_KEYGEN_ALSO_ROOT)" == yes && "$primary" != "root" ]]; then
        _generate_for "root"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_ssh_keygen
    configure_ssh_keygen
    check_ssh_keygen && { log "Keys already in desired state; skipping."; exit 0; }
    run_ssh_keygen
    check_ssh_keygen || { err "ssh-keygen verification failed"; exit 1; }
fi
