# shellcheck shell=bash
# =============================================================================
# recipes.sh — Named presets that pre-answer the wizard
# =============================================================================
#
# A recipe is a curated answers file that ships with the tool. It says "this
# host is a swarm manager" and supplies the ~20 answers that follow from that,
# so building the fourth identical node isn't 21 interactive steps.
#
# Format
# ------
# `recipes/<name>.recipe` is a plain KEY=VALUE file parsed by the SAME
# state_load_answers() the --answers flag uses — never sourced, so a recipe
# cannot execute code. Everything else is a `#` comment, which lets the
# metadata live in the header:
#
#   # description: one line, shown by --recipe --list
#   # requires: KEY [KEY ...]     keys the recipe deliberately does NOT define
#
# `requires` is how a recipe declares its per-host inputs (SSH public key,
# swarm join token). main.sh reports missing ones BEFORE the first module
# runs, rather than failing at step 43 with the host half-configured.
#
# Load order
# ----------
#   detected values  →  recipe  →  --answers FILE  →  interactive answers
#
# Each layer overrides the one before, so --answers stays the escape hatch for
# a one-off deviation without editing a file that's in git.
#
# What a recipe must never contain
# --------------------------------
# Secrets and per-host identity: USER_SSH_KEY, SWARM_JOIN_TOKEN,
# SWARM_TOKEN_MANAGER, SWARM_TOKEN_WORKER, UBUNTU_PRO_TOKEN, MTA_PASSWORD,
# CROWDSEC_ENROLL_KEY, SSH_PEERS_PUBKEYS. These come from --answers or get
# prompted. Recipes express POLICY (which ports, which runtime, don't
# auto-reboot); detection supplies the FACTS (hostname, advertise address,
# node subnet) — see the "derive, don't hard-code" note in each recipe.
#
# Why validate the name
# ---------------------
# `recipe_path` refuses anything but [a-z0-9-]. The name is concatenated into
# a filesystem path, so an unvalidated `--recipe ../../etc/shadow` would read
# an arbitrary root-readable file and feed its lines to state_set.
# =============================================================================

[[ -n "${_RECIPES_SH_LOADED:-}" ]] && return 0
_RECIPES_SH_LOADED=1

_RECIPES_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE_DIR="${RECIPE_DIR:-${_RECIPES_SH_DIR}/recipes}"

# Echo the path to recipe <name>; non-zero (with a diagnostic) if the name is
# malformed or the file doesn't exist.
recipe_path() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        err "Invalid recipe name '${name}' — use lowercase letters, digits and '-'."
        return 1
    fi
    local path="${RECIPE_DIR}/${name}.recipe"
    if [[ ! -f "$path" ]]; then
        err "No recipe named '${name}' in ${RECIPE_DIR}"
        err "Available: $(recipe_names | tr '\n' ' ')"
        return 1
    fi
    printf '%s' "$path"
}

# Echo one recipe name per line, sorted.
recipe_names() {
    local f
    for f in "$RECIPE_DIR"/*.recipe; do
        [[ -f "$f" ]] || continue
        f="${f##*/}"
        printf '%s\n' "${f%.recipe}"
    done
}

# Echo the value of a `# <field>: <value>` header line, or nothing.
recipe_meta() {
    local path="$1" field="$2"
    awk -v f="$field" '
        $0 ~ "^#[[:space:]]*" f ":" {
            sub("^#[[:space:]]*" f ":[[:space:]]*", "")
            print
            exit
        }' "$path"
}

# Echo the keys a recipe declares it does NOT define (space-separated).
recipe_requires() {
    local path="$1"
    recipe_meta "$path" requires
}

# Echo the subset of a recipe's required keys that are still empty in state.
recipe_missing_requires() {
    local path="$1" key
    for key in $(recipe_requires "$path"); do
        [[ -z "$(state_get "$key")" ]] && printf '%s\n' "$key"
    done
    return 0
}

# Print the available recipes with their descriptions. Used by --recipe --list.
recipe_list() {
    local names
    names="$(recipe_names)"
    if [[ -z "$names" ]]; then
        warn "No recipes found in ${RECIPE_DIR}"
        return 0
    fi
    separator "Available recipes"
    local name path
    while IFS= read -r name; do
        path="${RECIPE_DIR}/${name}.recipe"
        printf "  %-16s %s\n" "$name" "$(recipe_meta "$path" description)"
    done <<< "$names"
    echo ""
    info "Use:  sudo ./main.sh --recipe <name>"
    info "      sudo ./main.sh --recipe <name> --answers ./secrets.env"
}

# Load recipe <name> into state. Prints what it is and what it still needs.
recipe_load() {
    local name="$1" path
    path="$(recipe_path "$name")" || return 1

    separator "Recipe: ${name}"
    info "$(recipe_meta "$path" description)"
    local requires
    requires="$(recipe_requires "$path")"
    [[ -n "$requires" ]] && info "Per-host values this recipe does not define: ${requires}"

    state_load_answers "$path" || return 1
    log "Recipe '${name}' loaded from ${path}"
}
