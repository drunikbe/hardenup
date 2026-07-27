#!/usr/bin/env bash
# =============================================================================
# undo.sh — Reverse what hardenup changed, using the manifest + originals
# =============================================================================
#
# Reads /var/lib/hardenup/manifest.tsv and walks it NEWEST FIRST, so changes
# come off in the reverse order they went on. Files that existed before
# hardenup are restored from /var/backups/hardenup/originals; files hardenup
# created are deleted.
#
# Usage:
#   sudo ./undo.sh --dry-run     # show what would happen; touches nothing
#   sudo ./undo.sh               # restore files, ask before each risky step
#   sudo ./undo.sh --yes         # no per-item confirmation (still not packages)
#   sudo ./undo.sh --packages    # ALSO remove packages hardenup installed
#
# --- What this deliberately does NOT do --------------------------------------
#
# Packages are opt-in (--packages) and never touched by default. Removing
# docker-ce takes every container with it; removing ufw drops the firewall
# entirely. Only packages hardenup itself installed are ever candidates —
# record_pkg_installed skips anything already present — but "we installed it"
# still doesn't mean "nothing depends on it now".
#
# Users are NEVER deleted. `userdel -r` destroys a home directory, and by the
# time anyone runs undo that home may hold the only copy of something. They're
# listed for the operator to handle.
#
# Ubuntu Pro attachment and Swarm membership are recorded as notes, not
# reversed: both have side effects off this machine (a seat consumed on the
# Canonical account, a node entry in the cluster's Raft state).
#
# The firewall is left DOWN-but-restored: files under /etc/ufw are put back,
# but the service is not re-enabled, because the pre-hardenup host may well
# have had it disabled. The summary says what to run.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=backup.sh
source "${SCRIPT_DIR}/backup.sh"

DRY_RUN=0
ASSUME_YES=0
DO_PACKAGES=0

usage() { sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --yes|-y)   ASSUME_YES=1; shift ;;
        --packages) DO_PACKAGES=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

require_root

[[ -f "$MANIFEST_FILE" ]] || {
    err "No manifest at ${MANIFEST_FILE} — nothing recorded to undo."
    err "Either hardenup never ran on this host, or it ran before"
    err "reversibility existed (see issue #16)."
    exit 1
}

banner "hardenup undo" "$([[ $DRY_RUN -eq 1 ]] && echo 'DRY RUN — nothing will change' || echo 'live run')"

# Collected for the closing summary rather than printed inline, so the
# operator gets one clear list of what still needs a human.
MANUAL_NOTES=()
PKG_LIST=()
USER_LIST=()
SVC_LIST=()
RESTORED=0
DELETED=0
SKIPPED=0

# Ask, unless --yes or --dry-run. Dry runs answer "no" so nothing executes.
_confirm() {
    local prompt="$1"
    [[ $DRY_RUN -eq 1 ]] && return 1
    [[ $ASSUME_YES -eq 1 ]] && return 0
    ask_yesno "$prompt" "y"
}

_undo_file_modified() {
    local target="$1" stored="$2"
    if [[ ! -e "$stored" ]]; then
        warn "No stored original for ${target} — leaving it alone."
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    if [[ -e "$target" ]] && cmp -s "$stored" "$target"; then
        info "unchanged  ${target}"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        info "would restore  ${target}  <-  ${stored}"
        RESTORED=$((RESTORED + 1))
        return 0
    fi
    if _confirm "Restore ${target} from the pre-hardenup original?"; then
        install -m 0700 -d "$(dirname "$target")"
        # -p so mode/owner/timestamps come back with the contents.
        cp -p "$stored" "$target"
        log "restored   ${target}"
        RESTORED=$((RESTORED + 1))
    else
        info "kept       ${target}"
        SKIPPED=$((SKIPPED + 1))
    fi
}

_undo_file_created() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        info "already gone  ${target}"
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        info "would delete  ${target}  (hardenup created it)"
        DELETED=$((DELETED + 1))
        return 0
    fi
    # Always confirm deletions individually unless --yes: the operator may
    # have edited a file hardenup created and want to keep their edits.
    if _confirm "Delete ${target}? hardenup created it; it did not exist before."; then
        rm -f "$target"
        log "deleted    ${target}"
        DELETED=$((DELETED + 1))
    else
        info "kept       ${target}"
        SKIPPED=$((SKIPPED + 1))
    fi
}

separator "Reversing recorded changes (newest first)"

# tac = newest first. Read with IFS=tab so paths keep their spaces.
while IFS=$'\t' read -r _ts action target detail; do
    [[ -z "${action:-}" ]] && continue
    case "$action" in
        file_modified) _undo_file_modified "$target" "$detail" ;;
        file_created)  _undo_file_created  "$target" ;;
        pkg_installed) PKG_LIST+=("$target") ;;
        service_enabled) SVC_LIST+=("$target") ;;
        user_created)  USER_LIST+=("$target") ;;
        note)          MANUAL_NOTES+=("$target") ;;
        *)             warn "Unknown manifest action '${action}' for ${target}" ;;
    esac
done < <(tac "$MANIFEST_FILE")

# --- Services ---------------------------------------------------------------
if [[ ${#SVC_LIST[@]} -gt 0 ]]; then
    separator "Services hardenup enabled"
    for unit in "${SVC_LIST[@]}"; do
        if [[ $DRY_RUN -eq 1 ]]; then
            info "would disable  ${unit}"
        elif _confirm "Disable and stop ${unit}?"; then
            if systemctl disable --now "$unit" >/dev/null 2>&1; then
                log "disabled   ${unit}"
            else
                warn "Could not disable ${unit}"
            fi
        else
            info "left running  ${unit}"
        fi
    done
fi

# --- Packages (opt-in) ------------------------------------------------------
if [[ ${#PKG_LIST[@]} -gt 0 ]]; then
    separator "Packages hardenup installed"
    if [[ $DO_PACKAGES -eq 1 && $DRY_RUN -eq 0 ]]; then
        warn "Removing these can break running services — docker-ce takes every"
        warn "container with it; ufw removes the firewall entirely."
        if _confirm "Remove ${#PKG_LIST[@]} package(s) hardenup installed?"; then
            apt-get remove -y "${PKG_LIST[@]}" || warn "Some packages could not be removed."
        fi
    else
        for p in "${PKG_LIST[@]}"; do info "  ${p}"; done
        info "Not removed. Re-run with --packages to remove them."
    fi
fi

# --- Things undo will not do ------------------------------------------------
separator "Needs you"

if [[ ${#USER_LIST[@]} -gt 0 ]]; then
    warn "Users hardenup created (NOT deleted — home directories may hold data):"
    for u in "${USER_LIST[@]}"; do
        warn "  ${u}    remove with: sudo userdel -r ${u}"
    done
fi

if [[ ${#MANUAL_NOTES[@]} -gt 0 ]]; then
    warn "Changes with off-machine effects, not reversed here:"
    for n in "${MANUAL_NOTES[@]}"; do warn "  ${n}"; done
fi

if [[ -d /etc/ufw ]]; then
    info "Firewall files were restored but the service was left as-is."
    info "  check:  sudo ufw status verbose"
fi

separator "Summary"
info "restored: ${RESTORED}   deleted: ${DELETED}   kept: ${SKIPPED}"
if [[ $DRY_RUN -eq 1 ]]; then
    info "Dry run — nothing was changed. Re-run without --dry-run to apply."
else
    info "Originals remain at ${BACKUP_ORIGINALS} and the manifest at"
    info "${MANIFEST_FILE}; neither is deleted, so undo is repeatable."
    warn "Reboot, or reload the affected services, so every change takes effect."
fi
