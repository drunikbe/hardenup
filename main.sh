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
#   sudo ./main.sh --recipe swarm-worker # apply a shipped preset (see recipes/)
#   sudo ./main.sh --recipe --list       # list available recipes
#   sudo ./main.sh --non-interactive     # no prompts; require seeded answers
#   sudo ./main.sh --unattended          # also auto-answer safety confirmations
#   sudo ./main.sh --dry-run             # list remaining steps; no changes
# =============================================================================
#
# Prompt modes, in increasing order of "don't ask me"
# ---------------------------------------------------
#   (none)              every prompt asked.
#   --recipe NAME       the recipe's answers are used without confirming each
#                       one; prompts it left undefined (per-host secrets) are
#                       still asked, and so are the load-bearing safety
#                       confirmations.
#   --non-interactive   every ordinary prompt takes its default; a prompt with
#                       no default is a hard error naming the key to seed.
#                       Safety confirmations still stop the run.
#   --unattended        + safety confirmations take their default. Must be
#                       combined with --non-interactive, and is refused when
#                       SSH hardening is in the plan — auto-answering "yes I
#                       verified SSH in another terminal" is how a config typo
#                       becomes a permanent lockout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=state.sh
source "${SCRIPT_DIR}/state.sh"

# shellcheck source=recipes.sh
source "${SCRIPT_DIR}/recipes.sh"

MODULE_DIR="${SCRIPT_DIR}/modules"

# Capture argv before the parsing loop shifts it away — ensure_tmux re-execs
# the script inside tmux and needs the operator's original flags.
ORIG_ARGS=("$@")

# Flags
ONLY=""
REDO=""
ANSWERS_FILE=""
RECIPE=""
RECIPE_FILE=""
MISSING_KEYS=""
LIST_RECIPES=0
NON_INTERACTIVE=0
RECIPE_MODE=0
UNATTENDED=0
DRY_RUN=0
RESET=0
FORCE_RESET=0

# Print the header comment block verbatim, minus the ==== dividers. Derived
# from the file rather than a hard-coded line range so the two can't drift
# apart when the header grows.
usage() {
    awk 'NR<3 {next} !/^#/ {exit} {sub(/^# ?/, ""); if ($0 !~ /^=+$/) print}' \
        "${BASH_SOURCE[0]}"
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
        # `--recipe --list` is the documented spelling for enumerating them;
        # accept the bare word too rather than making "list" an unusable name.
        --recipe)          _require_value "$@"
                           case "$2" in
                               --list|list) LIST_RECIPES=1 ;;
                               *)           RECIPE="$2" ;;
                           esac
                           shift 2 ;;
        --list-recipes)    LIST_RECIPES=1; shift ;;
        --unattended)      UNATTENDED=1; shift ;;
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

# Listing recipes reads nothing but recipes/ — no root, no state, no tmux.
if [[ $LIST_RECIPES -eq 1 ]]; then
    recipe_list
    exit 0
fi

# A recipe supplies answers, so ordinary prompts stop asking. lib.sh reads
# RECIPE_MODE; see its "Prompt modes" block for how it differs from
# --non-interactive (undefined values are still asked for, not fatal).
#
# Resolved here rather than at load time so a typo'd name fails on the name,
# before the root check and the tmux re-exec — "no recipe named swarm-mangler"
# is more use than "this script must be run as root".
if [[ -n "$RECIPE" ]]; then
    RECIPE_MODE=1
    recipe_path "$RECIPE" >/dev/null || exit 2
fi

# --unattended only means anything when nothing else is going to prompt, and
# pairing it with an interactive run would be a silent downgrade of the
# safety confirmations for no benefit. Make the operator say both.
if [[ $UNATTENDED -eq 1 && $NON_INTERACTIVE -ne 1 ]]; then
    err "--unattended requires --non-interactive."
    err "It only silences the load-bearing safety confirmations; every other"
    err "prompt is governed by --non-interactive / --recipe."
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
#
# Skipped for --dry-run: it changes nothing, so there is no half-applied state
# for a dropped connection to leave behind — and re-execing a planning command
# into a new session makes its output land somewhere the operator isn't
# looking (or fails outright when there's no terminal to attach).
if [[ $DRY_RUN -eq 0 ]]; then
    ensure_tmux ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
fi

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

# --dry-run must not persist anything, and pre-seeding is a write: state_set
# writes through to state.env, so previewing a recipe used to leave all of its
# answers behind for the next real run to silently inherit. Load the real
# state first (so the plan reflects genuinely completed steps), then redirect
# further writes to a throwaway copy inside the same tmpfs directory.
#
# This is the one trap-on-EXIT in the tree, and it removes only the scratch
# copy. The real state.env is still deleted solely by 99-finalize — that is
# what makes an interrupted run resumable.
if [[ $DRY_RUN -eq 1 ]]; then
    DRY_STATE="$(mktemp "${STATE_DIR}/dryrun.XXXXXX")"
    chmod 0600 "$DRY_STATE"
    cat "$STATE_FILE" > "$DRY_STATE"
    STATE_FILE="$DRY_STATE"
    # shellcheck disable=SC2064  # expand DRY_STATE now, not at trap time
    trap "rm -f '$DRY_STATE'" EXIT
fi

# Layered pre-seed, weakest first:
#   detected values  →  recipe  →  --answers FILE  →  interactive answers
# The recipe goes on before --answers so an operator can deviate from a
# shipped preset for one host without editing a file that's in git.
if [[ -n "$RECIPE" ]]; then
    recipe_load "$RECIPE" || exit 1
fi

# Optional --answers pre-seed. Values in the file override current state.
if [[ -n "$ANSWERS_FILE" ]]; then
    info "Loading answers from $ANSWERS_FILE"
    state_load_answers "$ANSWERS_FILE"
fi

# A recipe declares the per-host values it deliberately doesn't carry (SSH
# public key, swarm join token). Report the missing ones NOW: discovering at
# step 43 that there's no join token leaves the host hardened, firewalled and
# half-clustered, which is the worst place to stop.
if [[ -n "$RECIPE" ]]; then
    RECIPE_FILE="$(recipe_path "$RECIPE")"
    MISSING_KEYS="$(recipe_missing_requires "$RECIPE_FILE" | tr '\n' ' ')"
    if [[ -n "${MISSING_KEYS// /}" ]]; then
        if [[ $NON_INTERACTIVE -eq 1 ]]; then
            err "Recipe '${RECIPE}' needs values it does not define: ${MISSING_KEYS}"
            err "A --non-interactive run cannot prompt for them. Seed them:"
            err "  sudo ./main.sh --recipe ${RECIPE} --answers ./secrets.env --non-interactive"
            err ""
            err "Nothing was configured, but the recipe's answers are now in"
            err "state.env and the next run will use them as defaults."
            err "Discard them with:  sudo ./main.sh --reset"
            exit 1
        fi
        warn "Recipe '${RECIPE}' does not define: ${MISSING_KEYS}"
        warn "You will be prompted for each when its step is reached."
    fi
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

# --unattended silences the load-bearing confirmations, one of which is
# 24-ssh-harden's "have you verified SSH from another terminal?". That pause
# is the only thing between an sshd_config mistake and a box reachable solely
# by console, so the two are refused together — the same treatment --reset
# gets from --force-reset, and for the same reason.
#
# Checked against the modules this invocation will actually walk, so
# `--only 27-journald --unattended` is fine, and an answers file that turns
# SSH hardening off is a deliberate, visible opt-out.
if [[ $UNATTENDED -eq 1 ]]; then
    for f in "${ALL_MODULES[@]}"; do
        [[ "$(mod_name "$f")" == *-ssh-harden ]] || continue
        if ! state_skipped ssh_harden && ! state_completed ssh_harden; then
            err "--unattended refuses to run while SSH hardening is in the plan."
            err "24-ssh-harden pauses for you to confirm SSH still works from a"
            err "second terminal, and rolls the drop-in back if it doesn't."
            err "Auto-answering that turns any sshd typo into a permanent lockout."
            err ""
            err "Either drop --unattended, or take SSH hardening out of this run:"
            err "  echo 'STEP_ssh_harden_SKIPPED=yes' >> answers.env"
            exit 1
        fi
    done
fi

# -----------------------------------------------------------------------------
# Dry run: enumerate remaining steps
# -----------------------------------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    separator "Dry run — step status"

    # Collected while walking the plan, printed underneath it: the prompts a
    # recipe run will still stop on. Without this, "--recipe X --dry-run" would
    # imply the run is hands-off when in practice it pauses three times.
    PENDING_PROMPTS=()

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
            # Optional per-module hook: echoes one line per load-bearing
            # confirmation the step would raise GIVEN the current state, so a
            # conditional pause (42's restart prompt only fires when
            # containers are running) isn't announced when it won't happen.
            if declare -F "critical_prompts_${sfx}" >/dev/null; then
                while IFS= read -r prompt_line; do
                    [[ -n "$prompt_line" ]] && PENDING_PROMPTS+=("${name}: ${prompt_line}")
                done < <("critical_prompts_${sfx}" 2>/dev/null || true)
            fi
        fi
    done

    if [[ ${#PENDING_PROMPTS[@]} -gt 0 ]]; then
        separator "Still to be confirmed by a human"
        for prompt_line in "${PENDING_PROMPTS[@]}"; do
            echo "  ⏸ $prompt_line"
        done
        echo ""
        info "These are the load-bearing confirmations. --recipe and"
        info "--non-interactive do NOT answer them; only --unattended does."
    fi

    if [[ -n "$RECIPE" && -n "${MISSING_KEYS// /}" ]]; then
        separator "Values this recipe does not define"
        for missing_key in $MISSING_KEYS; do
            echo "  ? $missing_key"
        done
        echo ""
        info "Supply them with --answers FILE, or answer the prompt when it appears."
    fi

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

    # A recipe or answers file turns a whole step off with
    # STEP_<name>_SKIPPED=yes. Honoured HERE, before configure_, so the
    # outcome doesn't depend on what the module happens to default its own
    # y/n to — seeding the flag for a step that defaults to "y" would
    # otherwise run it anyway.
    #
    # Gated on the auto-answer modes on purpose. Interactively, a step skipped
    # earlier in this state file is deliberately re-asked when the wizard
    # resumes, so an operator who Ctrl+C'd can change their mind without
    # reaching for --redo.
    if [[ $RECIPE_MODE -eq 1 || $NON_INTERACTIVE -eq 1 ]] && state_skipped "$sfx"; then
        log "⊘ $name — skipped by recipe/answers"
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
