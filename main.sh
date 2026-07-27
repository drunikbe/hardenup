#!/usr/bin/env bash
# =============================================================================
# main.sh — Linear yes/no wizard for hardened Ubuntu + Docker Swarm setup
# =============================================================================
#
# Walks modules/NN-*.sh in filename-sort order. For each module:
#   1. applies_<name> gate — re-evaluated every iteration, so it can consult
#      state that EARLIER modules set (e.g. STEP_docker_SELECTED gates 41).
#   2. If STEP_<name>_COMPLETED=yes and --redo didn't list it → print
#      "✓ [done at <ts>]" and continue.
#   3. detect_<name> — populate state from canonical config files.
#   4. configure_<name> — module asks its own top-level y/n (+ sub-questions).
#      If the operator declines, configure_ calls state_mark_skipped <name>
#      and returns; main.sh sees the flag and moves on.
#   5. run_<name> — execute immediately. Per-step safety pauses live here.
#   6. verify_<name> (or check_<name> as fallback) — read canonical state
#      to confirm the action landed. If it fails, HALT the wizard (exit 1);
#      state is preserved so the next invocation resumes at this step.
#   7. Mark step completed with an ISO timestamp, move to next.
#
# State lives at /run/hardenup/state.env for the full run. It
# survives Ctrl+C / lost connections / failed steps, so re-running resumes
# at the first incomplete step. The terminal 99-finalize.sh step prints
# a run summary to stdout and wipes the state file.
#
# Usage:
#   sudo ./main.sh                       # walk the full wizard
#   sudo ./main.sh --only 25-firewall    # run exactly one step
#   sudo ./main.sh --redo 24-ssh-harden  # clear completion flag and rerun
#   sudo ./main.sh --redo "2*"           # re-run all modules matching a glob
#   sudo ./main.sh --reset               # wipe state.env; re-ask every question
#   sudo ./main.sh --force-reset         # --reset without confirmation (for --non-interactive)
#   sudo ./main.sh --answers FILE        # pre-seed state from KEY=VALUE file
#   sudo ./main.sh --non-interactive     # no prompts; require seeded answers
#   sudo ./main.sh --dry-run             # list remaining steps; no changes
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=state.sh
source "${SCRIPT_DIR}/state.sh"

MODULE_DIR="${SCRIPT_DIR}/modules"

# Capture argv before the parsing loop shifts it away — ensure_tmux re-execs
# the script inside tmux and needs the operator's original flags.
ORIG_ARGS=("$@")

# Flags
ONLY=""
REDO=""
ANSWERS_FILE=""
NON_INTERACTIVE=0
DRY_RUN=0
RESET=0
FORCE_RESET=0

usage() {
    sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Guard each value-taking flag so `./main.sh --redo` (no arg) prints a usage
# error instead of tripping `set -u` with an "unbound variable" at "$2".
_require_value() {
    [[ $# -ge 2 && -n "${2:-}" ]] || { err "$1 requires a value"; usage; exit 2; }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)            _require_value "$@"; ONLY="$2"; shift 2 ;;
        --redo)            _require_value "$@"; REDO="$2"; shift 2 ;;
        --answers)         _require_value "$@"; ANSWERS_FILE="$2"; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --reset)           RESET=1; shift ;;
        --force-reset)     RESET=1; FORCE_RESET=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

# Refuse --redo + --only together. --redo mutates persistent state (clears
# completion flags in state.env for every matched module); --only changes
# which module runs THIS invocation. When combined, --redo's flag-clearing
# side effects apply to modules that the --only filter then prevents from
# running — so the next plain `main.sh` invocation surprises the operator
# by re-running modules they didn't ask for. Keeping these flags mutually
# exclusive removes the ambiguity entirely.
if [[ -n "$REDO" && -n "$ONLY" ]]; then
    err "--redo and --only cannot be combined."
    err "  --redo clears completion flags across modules (persistent)."
    err "  --only narrows execution to one module this run (transient)."
    err "  Use them in separate invocations."
    exit 2
fi

# Given a module file path, echo its short name: "/x/25-firewall.sh" → "25-firewall".
mod_name() {
    local f="$1"
    f="${f##*/}"
    echo "${f%.sh}"
}

# Echo the function-suffix for a module short-name:
# "25-firewall" → "firewall"; "22-ssh-keygen" → "ssh_keygen".
mod_func_suffix() {
    local name="$1"
    name="${name#*-}"
    echo "${name//-/_}"
}

# Preflight
require_root
require_ubuntu

# tmux session protection. Re-execs inside tmux (if available) and forwards
# the operator's original argv so --redo / --answers / etc. are preserved.
ensure_tmux ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}

banner "Cloud VPS Setup — main.sh" "Ubuntu ${UBUNTU_VERSION}"

# --reset wipes state.env BEFORE state_init, so old answers are never loaded
# into the shell. Config files on disk (sshd, UFW, installed
# packages) are NOT touched — only the wizard's orchestration state is cleared.
if [[ $RESET -eq 1 ]]; then
    # Refuse STATE_DIR overrides — rm -rf on an operator-supplied path is a
    # footgun (STATE_DIR=/etc sudo ./main.sh --reset would rm -rf /etc). If
    # the override was intentional, the operator can wipe it manually.
    if [[ "$STATE_DIR" != "/run/hardenup" ]]; then
        err "--reset refuses: STATE_DIR has been overridden ($STATE_DIR)."
        err "If intentional, clean it up manually: rm -rf $STATE_DIR"
        exit 1
    fi

    if [[ -e "$STATE_FILE" ]]; then
        warn "--reset wipes state.env only. Config files and installed packages"
        warn "on disk stay — they are DETECTED and USED as defaults on the next"
        warn "run, which can desync from state other systems hold:"
        warn "  - Swarm peers store the current join tokens cluster-side."
        warn "  - CrowdSec bouncer is registered with the CrowdSec console."
        warn "Existing users, SSH keys, UFW rules, and sshd drop-ins persist."
        warn "For a clean slate, reprovision the VM instead."
        if [[ $FORCE_RESET -eq 1 ]]; then
            info "--force-reset: proceeding without confirmation."
        elif [[ $NON_INTERACTIVE -eq 1 ]]; then
            err "--reset + --non-interactive requires --force-reset to proceed."
            err "The confirmation prompt exists because reset is unrecoverable."
            exit 1
        elif ! ask_yesno "Proceed with reset?" "n"; then
            err "Aborted."
            exit 1
        fi
        rm -rf "$STATE_DIR"
        log "State reset; starting fresh."
    else
        info "--reset: no prior state to wipe."
    fi
fi

# Initialize the state file. If one already exists (previous run Ctrl+C'd),
# load its contents so the wizard resumes at the first incomplete step.
state_init
state_load

# Optional --answers pre-seed. Values in the file override current state.
if [[ -n "$ANSWERS_FILE" ]]; then
    info "Loading answers from $ANSWERS_FILE"
    state_load_answers "$ANSWERS_FILE"
fi

# Apply --redo by clearing completion flags on matched modules. Accepts
# comma-separated module stems (e.g. "25-firewall") or glob patterns
# (e.g. "2*" to re-run every 20-29 hardening step, "*-ssh-*" for
# all SSH-related modules). A pattern matching zero modules is an error
# so typos fail loud instead of silently doing nothing.
if [[ -n "$REDO" ]]; then
    IFS=',' read -ra REDO_LIST <<< "$REDO"
    # Two-pass: resolve every pattern into a unique set first, then clear
    # flags. If any pattern matches nothing, we exit BEFORE mutating state
    # so typos don't leave completion flags partially cleared.
    declare -A REDO_MATCHED
    for pattern in "${REDO_LIST[@]}"; do
        [[ -z "$pattern" ]] && continue   # tolerate "a,,b" typos
        any_match=0
        for f in "$MODULE_DIR"/??-*.sh; do
            [[ -f "$f" ]] || continue
            mod_stem="$(mod_name "$f")"
            # shellcheck disable=SC2053  # intentional glob match on $pattern
            if [[ "$mod_stem" == $pattern ]]; then
                REDO_MATCHED["$mod_stem"]=1
                any_match=1
            fi
        done
        if [[ $any_match -eq 0 ]]; then
            err "--redo pattern '$pattern' matched no modules"
            exit 2
        fi
    done
    for mod_stem in "${!REDO_MATCHED[@]}"; do
        sfx="$(mod_func_suffix "$mod_stem")"
        state_clear_step "$sfx"
        info "Cleared completion flag for $mod_stem"
    done
fi

# -----------------------------------------------------------------------------
# Discover modules
# -----------------------------------------------------------------------------

ALL_MODULES=()
for f in "$MODULE_DIR"/??-*.sh; do
    [[ -f "$f" ]] || continue
    ALL_MODULES+=("$f")
done

if [[ -n "$ONLY" ]]; then
    match=""
    for f in "${ALL_MODULES[@]}"; do
        if [[ "$(mod_name "$f")" == "$ONLY" ]]; then
            match="$f"; break
        fi
    done
    [[ -z "$match" ]] && { err "Module '$ONLY' not found under $MODULE_DIR"; exit 2; }
    ALL_MODULES=( "$match" )
fi

if [[ ${#ALL_MODULES[@]} -eq 0 ]]; then
    warn "No modules found in $MODULE_DIR"
    exit 0
fi

# Source every module so its functions (applies_, detect_, configure_, run_,
# verify_, check_) are defined in our shell.
for f in "${ALL_MODULES[@]}"; do
    # shellcheck source=/dev/null
    source "$f"
done

# -----------------------------------------------------------------------------
# Dry run: enumerate remaining steps
# -----------------------------------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    separator "Dry run — step status"
    for f in "${ALL_MODULES[@]}"; do
        name="$(mod_name "$f")"
        sfx="$(mod_func_suffix "$name")"
        if declare -F "applies_${sfx}" >/dev/null && ! "applies_${sfx}"; then
            continue
        fi
        if state_completed "$sfx"; then
            echo "  ✓ $name  [done at $(state_get "STEP_${sfx}_COMPLETED_AT")]"
        elif state_skipped "$sfx"; then
            echo "  ⊘ $name  [skipped]"
        else
            echo "  … $name  [pending]"
        fi
    done
    exit 0
fi

# -----------------------------------------------------------------------------
# Walk the wizard
# -----------------------------------------------------------------------------

for f in "${ALL_MODULES[@]}"; do
    name="$(mod_name "$f")"
    sfx="$(mod_func_suffix "$name")"

    # applies_<name> gates against state set by earlier steps (e.g.
    # STEP_docker_SELECTED). Re-evaluated each iteration so the gate sees the
    # most recent state.
    if declare -F "applies_${sfx}" >/dev/null && ! "applies_${sfx}"; then
        continue
    fi

    # Completed steps are shown and skipped. --redo already cleared the ones
    # the operator wants to rerun.
    if state_completed "$sfx"; then
        log "✓ $name  [done at $(state_get "STEP_${sfx}_COMPLETED_AT")]"
        continue
    fi

    separator "Step: $name"

    # detect_ reads canonical config to populate defaults for configure_ prompts.
    if declare -F "detect_${sfx}" >/dev/null; then
        "detect_${sfx}" || true
    fi

    # Modules that MUST always run (network detection at 15, finalize at 99)
    # don't wrap their configure_ in an ask_yesno; they just do their work.
    # Everything else asks its own Y/N inside configure_ and either proceeds
    # or calls state_mark_skipped — main.sh checks that flag below.
    if declare -F "configure_${sfx}" >/dev/null; then
        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            export CLOUD_NON_INTERACTIVE=1
            # Module decides whether to prompt or use seeded state.
        fi
        "configure_${sfx}"

        # Modules set STEP_<sfx>_SKIPPED=yes in configure_ when the operator
        # declined the top-level ask_yesno. Honour that.
        if state_skipped "$sfx"; then
            log "⊘ $name — skipped by operator"
            continue
        fi
    fi

    # Execute. Per-step safety pauses (SSH secondary terminal, etcd quorum,
    # Proxy Protocol ordering) live inside the module's run_.
    if declare -F "run_${sfx}" >/dev/null; then
        if ! "run_${sfx}"; then
            err "$name — run_ failed. Fix the underlying issue and re-run main.sh to resume."
            exit 1
        fi
    else
        warn "$name — no run_ function; nothing executed"
    fi

    # Verify. A module's verify_ (or check_ as fallback) MUST confirm the
    # action persisted to the canonical config. If verification fails, the
    # step is NOT marked completed and the wizard halts.
    verify_fn=""
    if declare -F "verify_${sfx}" >/dev/null; then
        verify_fn="verify_${sfx}"
    elif declare -F "check_${sfx}" >/dev/null; then
        verify_fn="check_${sfx}"
    fi

    if [[ -n "$verify_fn" ]]; then
        if ! "$verify_fn"; then
            err "$name — verification failed. The action ran but the canonical"
            err "config does not reflect the expected state."
            err "Investigate, then re-run main.sh (or main.sh --redo $name)."
            exit 1
        fi
    else
        warn "$name — no verify_ or check_ function; step marked completed without verification"
    fi

    state_mark_completed "$sfx"
    log "$name — done"
done

separator "Wizard complete"
log "All applicable steps finished."
