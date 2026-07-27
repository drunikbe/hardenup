# shellcheck shell=bash
# =============================================================================
# state.sh — Wizard state helpers for main.sh
# =============================================================================
#
# State lives at /run/hardenup/state.env (tmpfs, mode 0600). It is
# populated incrementally as the wizard walks each step and holds EVERYTHING
# needed for the run: operator answers, generated secrets, step completion
# flags.
#
# Lifecycle
# ---------
#   - Created by state_init (first step of main.sh).
#   - Written by state_set as each step progresses.
#   - Preserved across Ctrl+C / lost connection / interrupted shells
#     (no trap-on-EXIT cleanup). Next main.sh invocation resumes at the
#     first incomplete step.
#   - Removed ONLY by state_finalize_and_wipe, called by the terminal
#     99-finalize.sh step after a clean run.
#
# Canonical source of truth
# -------------------------
# The real config files the modules write (sshd_config.d, ufw rules,
# /etc/crowdsec/*, /etc/docker/*, ~/.ssh/) are the
# long-term truth. state.env is the orchestration scratchpad — it vanishes
# when the run finishes. Sub-scripts invoked standalone do not rely on this
# file; they call detect_<name> to reconstruct from the real files.
#
# Usage
# -----
#   source "$(dirname "$0")/state.sh"
#   state_init
#   state_set FIREWALL_KIND ufw
#   mode="$(state_get FIREWALL_KIND default)"
#   if state_completed firewall; then ...
#   state_mark_completed firewall
#   state_finalize_and_wipe          # called by 99-finalize.sh only
# =============================================================================

[[ -n "${_STATE_SH_LOADED:-}" ]] && return 0
_STATE_SH_LOADED=1

STATE_DIR="${STATE_DIR:-/run/hardenup}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.env}"

# Initialize the state directory and (empty) state file. Safe to re-run.
state_init() {
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

# Load answers from a user-provided file (pre-seed state). Values override
# anything already in state.env. Used for headless/cloud-init invocation:
#   main.sh --answers /root/answers.env
#
# The file is parsed as KEY=VALUE line-by-line; it is NEVER sourced. An
# earlier implementation used `source` and was an arbitrary-code-execution
# sink (CWE-94) because any bash in the file would run as root before any
# validation could fire. Lines that don't match ^UPPER_UNDERSCORE= are
# skipped, so operators can intersperse comments (`# ...`) freely.
state_load_answers() {
    local file="$1"
    [[ -z "$file" ]] && { err "state_load_answers: no file given"; return 1; }
    [[ -r "$file" ]] || { err "state_load_answers: cannot read $file"; return 1; }

    local line key value
    while IFS= read -r line; do
        # Skip blank lines and full-line comments.
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        # Only accept lines shaped like SHELL_LIKE_KEY=... — anything else
        # (conditionals, function defs, command subst) is ignored silently.
        [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        # Strip one layer of matching surrounding quotes (single or double).
        # Escape sequences inside quotes are NOT expanded — operators who
        # need literal newlines should store them via state_set directly.
        if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        state_set "$key" "$value"
    done < "$file"
}

# Echo the value of KEY if set (non-empty), otherwise DEFAULT.
state_get() {
    local key="$1" default="${2:-}"
    if [[ -n "${!key:-}" ]]; then
        printf '%s' "${!key}"
    else
        printf '%s' "$default"
    fi
}

# Set KEY=VALUE in the current shell and write-through to state.env atomically.
# printf %q emits a shell-safe form that bash can re-read; handles quotes,
# whitespace, and backslashes without hand-escaping.
state_set() {
    local key="$1" value="$2"
    # Mixed case allowed — step-tracking keys are built from module filenames
    # that contain lowercase (e.g. STEP_firewall_COMPLETED, STEP_docker_SELECTED).
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { err "state_set: invalid key '$key'"; return 1; }

    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163  # $key holds the variable name, not its value.
    export "$key"

    [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    grep -vE "^${key}=" "$STATE_FILE" > "$tmp" || true
    printf "%s=%q\n" "$key" "$value" >> "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# Remove KEY from state.env and unset the shell variable.
state_unset() {
    local key="$1"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { err "state_unset: invalid key '$key'"; return 1; }
    unset "$key"
    [[ -f "$STATE_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    grep -vE "^${key}=" "$STATE_FILE" > "$tmp" || true
    chmod 0600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# Re-import the state file into the current shell. Safe to call repeatedly.
state_load() {
    [[ -f "$STATE_FILE" ]] || return 0
    # shellcheck source=/dev/null
    source "$STATE_FILE"
}

# -----------------------------------------------------------------------------
# Step completion helpers
# -----------------------------------------------------------------------------
# Step names are the module stem without the NN- prefix, snake_cased.
# Example: module file "25-firewall.sh" → step name "firewall"; the completion
# flag is stored as STEP_firewall_COMPLETED="yes".

# Return 0 if step <name> is marked completed.
state_completed() {
    local name="$1"
    [[ "$(state_get "STEP_${name}_COMPLETED")" == "yes" ]]
}

# Return 0 if step <name> is marked skipped.
state_skipped() {
    local name="$1"
    [[ "$(state_get "STEP_${name}_SKIPPED")" == "yes" ]]
}

# Mark step <name> completed with an ISO8601 timestamp. Clears any prior SKIP.
state_mark_completed() {
    local name="$1"
    state_set "STEP_${name}_COMPLETED" "yes"
    state_set "STEP_${name}_COMPLETED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    state_unset "STEP_${name}_SKIPPED" 2>/dev/null || true
}

# Mark step <name> skipped (operator answered 'n' to the top-level prompt).
state_mark_skipped() {
    local name="$1"
    state_set "STEP_${name}_SKIPPED" "yes"
    state_set "STEP_${name}_SKIPPED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Clear completion and skip flags for step <name>. Used by main.sh --redo.
state_clear_step() {
    local name="$1"
    state_unset "STEP_${name}_COMPLETED" 2>/dev/null || true
    state_unset "STEP_${name}_COMPLETED_AT" 2>/dev/null || true
    state_unset "STEP_${name}_SKIPPED" 2>/dev/null || true
    state_unset "STEP_${name}_SKIPPED_AT" 2>/dev/null || true
}

# Delete the state file and directory, then verify removal. Returns 0 if
# cleanup succeeded, non-zero with a loud warning otherwise. Called by the
# terminal 99-finalize.sh step.
state_finalize_and_wipe() {
    rm -f "$STATE_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
    if [[ -e "$STATE_FILE" || -e "$STATE_DIR" ]]; then
        err "FAILED to remove $STATE_FILE or $STATE_DIR"
        err "Secrets may remain on tmpfs. Manually: rm -rf $STATE_DIR"
        return 1
    fi
    return 0
}
