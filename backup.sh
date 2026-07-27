# shellcheck shell=bash
# =============================================================================
# backup.sh — Original-file preservation + change manifest (reversibility)
# =============================================================================
#
# hardenup used to be a one-way door: every module did a truncating write,
# nothing was preserved, and after `99-finalize` wiped the tmpfs state file
# there was no record that the tool had ever run. This library is what makes
# `undo.sh` possible.
#
# Two stores, both OUTSIDE /run — /run is tmpfs and vanishes on reboot, and a
# record of what changed must outlive the run that made it:
#
#   /var/backups/hardenup/originals/<mirrored path>
#       The file as it was BEFORE hardenup first touched it.
#   /var/lib/hardenup/manifest.tsv
#       Append-only log of every change, newest last.
#
# --- Why "first touch" is global, not per-run --------------------------------
#
# The original is stored only if no copy exists yet, keyed by absolute path
# across ALL runs. Backing up per-run would mean a second run captures the
# FIRST run's already-modified file and calls it the original — after two runs
# the pristine version is gone forever. Since `run_` functions are idempotent
# and re-run freely (`--redo`), that would happen constantly. So: the first
# copy wins and is never overwritten.
#
# --- Why TSV and not JSON ----------------------------------------------------
#
# The obvious choice is JSON, but the only sane way to write it from bash is
# jq — and jq is installed by 23-packages, which runs AFTER 15/18/20/21/22.
# A backup library that can't record anything until a third of the wizard has
# already run is useless. TSV needs nothing but the shell, and undo parses it
# with `read -r`. Paths containing a literal tab would corrupt a row; such a
# path would break most of this repo long before it got here, and _mf_append
# rejects them rather than writing a bad row.
#
# Manifest columns:
#   1 ISO-8601 timestamp
#   2 action    file_modified | file_created | pkg_installed
#               | service_enabled | user_created | note
#   3 target    absolute path, package name, unit name, username
#   4 detail    backup path for file_modified; "-" otherwise
#
# Actions are recorded ONCE per target. Re-running a module must not append a
# duplicate row, or undo would try to restore the same file repeatedly.
# =============================================================================

[[ -n "${_BACKUP_SH_LOADED:-}" ]] && return 0
_BACKUP_SH_LOADED=1

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/hardenup}"
BACKUP_ORIGINALS="${BACKUP_ROOT}/originals"
MANIFEST_DIR="${MANIFEST_DIR:-/var/lib/hardenup}"
MANIFEST_FILE="${MANIFEST_FILE:-${MANIFEST_DIR}/manifest.tsv}"

# Create both stores. 0700 throughout: originals can contain secrets (an
# sshd_config with a key path, a daemon.json with registry credentials), and
# the manifest reveals the host's whole hardening posture.
backup_init() {
    install -m 0700 -d "$BACKUP_ROOT" "$BACKUP_ORIGINALS" "$MANIFEST_DIR"
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        : > "$MANIFEST_FILE"
        chmod 0600 "$MANIFEST_FILE"
    fi
    return 0
}

_mf_timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# True when this action+target pair is already recorded.
_mf_has() {
    local action="$1" target="$2"
    [[ -f "$MANIFEST_FILE" ]] || return 1
    # Anchor on the tab-delimited fields so /etc/foo doesn't match /etc/foobar.
    grep -qF "	${action}	${target}	" "$MANIFEST_FILE" 2>/dev/null
}

_mf_append() {
    local action="$1" target="$2" detail="${3:--}"
    backup_init
    # A tab in any field would shift every later column and silently corrupt
    # the row. Refuse rather than write something undo will misread.
    case "${action}${target}${detail}" in
        *"	"*) warn "Manifest: refusing to record a value containing a tab: ${target}"
              return 1 ;;
    esac
    _mf_has "$action" "$target" && return 0
    printf '%s\t%s\t%s\t%s\n' "$(_mf_timestamp)" "$action" "$target" "$detail" \
        >> "$MANIFEST_FILE"
}

# Mirror an absolute path under the originals tree:
#   /etc/ssh/sshd_config -> /var/backups/hardenup/originals/etc/ssh/sshd_config
# Mirroring beats escaping the path into a filename: the result stays
# browsable with ls, and `diff -r` against / shows what changed at a glance.
_backup_path_for() {
    printf '%s%s' "$BACKUP_ORIGINALS" "$1"
}

# backup_file PATH
#
# Call BEFORE modifying PATH. Preserves the pristine copy on first touch and
# records the change, so undo can put it back (or delete a file we created).
# Safe to call repeatedly and from any module.
backup_file() {
    local target="$1"
    [[ -n "$target" ]] || return 0
    [[ "$target" == /* ]] || { warn "backup_file needs an absolute path: $target"; return 1; }
    backup_init

    local stored
    stored="$(_backup_path_for "$target")"

    if [[ -e "$target" ]]; then
        # Existing file: keep the first version we ever saw, never overwrite.
        if [[ ! -e "$stored" ]]; then
            install -m 0700 -d "$(dirname "$stored")"
            # -p preserves mode/owner/timestamps so a restore returns the file
            # exactly as it was, not as root:root 0644.
            cp -p "$target" "$stored" || {
                warn "Could not back up ${target}; continuing without a restore point."
                return 1
            }
        fi
        _mf_append file_modified "$target" "$stored"
    else
        # Absent: hardenup is creating it, so undo should DELETE it rather
        # than restore anything. Recorded even though there's no copy to keep.
        _mf_append file_created "$target" "-"
    fi
    return 0
}

# backup_dir_files DIR [GLOB]
# Back up every file directly inside DIR (non-recursive). For directories
# whose contents are rewritten wholesale — /etc/ufw/*.rules being the case
# that motivated it.
backup_dir_files() {
    local dir="$1" glob="${2:-*}" f
    [[ -d "$dir" ]] || return 0
    shopt -s nullglob
    for f in "$dir"/$glob; do
        [[ -f "$f" ]] && backup_file "$f"
    done
    shopt -u nullglob
    return 0
}

# record_pkg_installed NAME
# Only records packages that were NOT already installed, so undo never offers
# to remove something the operator had before hardenup ran.
record_pkg_installed() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 0
    dpkg -s "$pkg" >/dev/null 2>&1 && return 0   # already present — not ours
    _mf_append pkg_installed "$pkg" "-"
}

record_service_enabled() {
    local unit="$1"
    [[ -n "$unit" ]] || return 0
    systemctl is-enabled --quiet "$unit" 2>/dev/null && return 0  # already on
    _mf_append service_enabled "$unit" "-"
}

record_user_created() {
    local user="$1"
    [[ -n "$user" ]] || return 0
    id "$user" &>/dev/null && return 0   # already existed — not ours to remove
    _mf_append user_created "$user" "-"
}

# record_note TEXT — free-form breadcrumb for changes undo cannot reverse
# automatically (an Ubuntu Pro attachment, a swarm this node joined).
record_note() {
    local text="$1"
    _mf_append note "$text" "-"
}
