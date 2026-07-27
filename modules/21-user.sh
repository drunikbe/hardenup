# shellcheck shell=bash
# =============================================================================
# 21-user.sh — Create non-root sudo user with SSH key
# =============================================================================
#
# Creates a dedicated sudo user so root login can be disabled later. An SSH
# public key is mandatory because password auth will be turned off by the SSH
# hardening step — without a valid key the new user cannot log in.
#
# Lockout guard: if the operator chooses NOT to create a user AND no existing
# /home/*/.ssh/authorized_keys is found, we warn loudly and require explicit
# confirmation before proceeding (PermitRootLogin=no would lock them out).
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_user() { return 0; }

# Find an existing non-system user with an authorized_keys file, if any.
_existing_ssh_user() {
    local hdir base
    for hdir in /home/*/; do
        [[ -d "$hdir" ]] || continue
        base=$(basename "$hdir")
        if [[ -f "${hdir}.ssh/authorized_keys" ]] && id "$base" &>/dev/null; then
            echo "$base"
            return 0
        fi
    done
    return 1
}

detect_user() {
    # If the operator already has a prompted USER_NAME, keep it.
    [[ -n "$(state_get USER_NAME)" ]] && return 0
    local existing
    if existing=$(_existing_ssh_user); then
        state_set USER_NAME_DETECTED "$existing"
    fi
}

configure_user() {
    local default_create="y"
    [[ -n "$(state_get USER_NAME)" ]] && default_create="y"

    info "Adds a sudo-capable user; SSH hardening (step 24) disables root login."
    info "Skip only if a non-root login is already configured out-of-band."
    if ask_yesno "Create a non-root sudo user?" "$default_create"; then
        while true; do
            ask_input "Username (must start with lowercase letter; lowercase/digits/-/_)" "$(state_get USER_NAME)" '^[a-z][a-z0-9_-]*$'
            if validate_username "$REPLY"; then
                state_set USER_NAME "$REPLY"
                break
            fi
            err "Invalid username: $REPLY"
        done

        local cur_key
        cur_key="$(state_get USER_SSH_KEY)"
        if [[ -n "$cur_key" ]]; then
            info "Existing SSH key on file: ${cur_key:0:40}..."
            if ! ask_yesno "Replace it?" "n"; then
                return 0
            fi
        fi

        info "Paste the SSH public key for $(state_get USER_NAME):"
        local key=""
        # Loop on bad paste instead of exiting the whole wizard — matches the
        # pattern the other input validators (port, CIDR, timezone) use.
        while true; do
            read -rp "Public key: " key || { err "stdin closed"; exit 1; }
            [[ -n "$key" ]] && validate_ssh_key "$key" && break
            err "Invalid or empty SSH key. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2."
        done
        state_set USER_SSH_KEY "$key"
    else
        # Lockout guard.
        state_set USER_NAME ""
        state_set USER_SSH_KEY ""
        if ! _existing_ssh_user >/dev/null; then
            echo ""
            warn "═══════════════════════════════════════════════════════════════"
            warn "  No non-root user with SSH keys found on this system!"
            warn "  PermitRootLogin=no later will LOCK YOU OUT."
            warn "═══════════════════════════════════════════════════════════════"
            echo ""
            if ! ask_yesno "Continue WITHOUT a non-root SSH user? (DANGEROUS)" "n"; then
                err "Aborted. Re-run and create a user."
                exit 0
            fi
        fi
    fi
}

check_user() {
    local u
    u="$(state_get USER_NAME)"
    [[ -z "$u" ]] && return 0  # nothing to create
    id "$u" &>/dev/null || return 1
    [[ -f "/home/$u/.ssh/authorized_keys" ]] || return 1
    return 0
}

run_user() {
    local u key home_dir ssh_dir
    u="$(state_get USER_NAME)"
    [[ -z "$u" ]] && { log "No user creation requested."; return 0; }

    if id "$u" &>/dev/null; then
        warn "User '$u' already exists. Skipping creation."
    else
        record_user_created "$u"
        adduser --disabled-password --gecos "" "$u"
        log "User '$u' created."
    fi

    usermod -aG sudo "$u"

    key="$(state_get USER_SSH_KEY)"
    if [[ -n "$key" ]]; then
        home_dir="/home/$u"
        ssh_dir="$home_dir/.ssh"
        mkdir -p "$ssh_dir"
        # Append-with-dedup so --redo user (or a --reset + rerun) doesn't
        # clobber keys added by 66-ssh-peers, ssh-copy-id, or manual edits.
        touch "$ssh_dir/authorized_keys"
        grep -qxF "$key" "$ssh_dir/authorized_keys" \
            || printf '%s\n' "$key" >> "$ssh_dir/authorized_keys"
        chmod 700 "$ssh_dir"
        chmod 600 "$ssh_dir/authorized_keys"
        chown -R "$u:$u" "$ssh_dir"
        log "SSH key installed for $u"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_user
    configure_user
    check_user && { log "User state matches desired; skipping."; exit 0; }
    run_user
    check_user || { err "User verification failed"; exit 1; }
fi
