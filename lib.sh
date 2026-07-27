# shellcheck shell=bash
# =============================================================================
# lib.sh — Shared function library sourced by all init scripts
# =============================================================================
#
# Usage:
#   source "$(dirname "$0")/lib.sh"
#
# A double-source guard (_LIB_SH_LOADED) prevents re-initialization when
# multiple scripts source this file in the same shell session.
#
# ---------------------------------------------------------------------------
# Function Reference
# ---------------------------------------------------------------------------
#
# OUTPUT
#   log MSG                       Print green  [OK]    message to stdout
#   warn MSG                      Print yellow [WARN]  message to stdout
#   err MSG                       Print red    [ERROR] message to stderr
#   info MSG                      Print blue   [INFO]  message to stdout
#   separator TITLE               Section divider with centered title
#   banner TITLE [SUBTITLE]       Top-of-script box with timestamp + hostname
#   print_summary TITLE KV...     Key/value summary box (pipe-delimited pairs)
#
# INTERACTIVE PROMPTS
#   ask_choice PROMPT DEFAULT OPT...        Numbered menu  -> sets REPLY (1-based index)
#   ask_yesno PROMPT [DEFAULT]              Yes/no         -> returns 0=yes, 1=no
#   ask_input PROMPT [DEFAULT] [REGEX]      Free text      -> sets REPLY
#   ask_password PROMPT [MIN_LEN]           Hidden input   -> sets REPLY
#   ask_multiselect PROMPT OPT...           Toggle list    -> sets MULTISELECT_RESULT array ("on"/"off")
#
# VALIDATORS                                All return 0=valid, 1=invalid
#   validate_ip IP                          IPv4 address (format + octet range)
#   validate_cidr CIDR                      IPv4 CIDR (address + /0-32 prefix)
#   validate_private_cidr CIDR              RFC1918 CIDR (rejects 0.0.0.0/0 and public space)
#   validate_hostname HOST                  RFC-952 hostname (max 253 chars)
#   validate_username USER                  Linux username  (lowercase, max 32 chars)
#   validate_port PORT                      TCP/UDP port    (1-65535)
#   validate_ssh_key KEY                    Public key prefix (rsa/ed25519/ecdsa)
#
# SYSTEM DETECTION
#   detect_private_iface                    Sets global PRIVATE_IFACE or returns 1
#   detect_public_iface                     Sets global PUBLIC_IFACE (default-route iface) or returns 1
#   detect_ssh_service                      Sets global SSH_SERVICE ("ssh"|"sshd") or returns 1
#   get_private_ip [IFACE]                  Sets global PRIVATE_IP from interface or returns 1
#   require_root                            Exits if not root
#   require_ubuntu                          Exits if not Ubuntu; sets UBUNTU_VERSION
#   require_cmd CMD                         Returns 1 if CMD is not in PATH
#   ensure_tmux                             Re-launches script inside tmux; detects
#                                           existing sessions and installs tmux on demand
#   generate_token                          Prints 64 hex chars (256-bit random token) to stdout
#   test_tcp_connectivity HOST PORT [T]     Returns 0 if TCP connection succeeds within T seconds
#   wait_for DESC TIMEOUT INTERVAL CMD...  Poll CMD; return 0 on success, 1 on timeout
# =============================================================================

# Guard against double-sourcing
[[ -n "${_LIB_SH_LOADED:-}" ]] && return 0
_LIB_SH_LOADED=1

# =============================================================================
# Colors & Output
# =============================================================================

# ANSI escape sequences used by all output functions below.
# NC (No Color) resets formatting so colors don't leak into subsequent output.
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Errors go to stderr (fd 2) so they can be separated from normal output in pipelines.
log()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

# Visual section divider for grouping related prompts during interactive runs.
separator() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Top-of-script banner shown once at the start of each init script.
# Includes UTC timestamp and hostname so logs are self-documenting.
banner() {
    local title="$1"
    local subtitle="${2:-}"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${GREEN}║${NC}  %-60s${GREEN}║${NC}\n" "$title"
    if [[ -n "$subtitle" ]]; then
        printf "${GREEN}║${NC}  %-60s${GREEN}║${NC}\n" "$subtitle"
    fi
    printf "${GREEN}║${NC}  %-60s${GREEN}║${NC}\n" "$(date -u '+%Y-%m-%d %H:%M UTC') | $(hostname)"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# Interactive Prompts
# =============================================================================

# ask_choice "prompt" default_num "Label|Description" ...
# Presents a numbered menu. Sets REPLY to the chosen index (1-based).
# Options are split on "|" into a left-aligned label and a description column.
ask_choice() {
    local prompt="$1"
    local default="$2"
    shift 2

    # Split each "Label|Description" argument into parallel arrays.
    local -a labels=()
    local -a descs=()
    local i=1

    for opt in "$@"; do
        labels+=("${opt%%|*}")
        descs+=("${opt#*|}")
        i=$((i + 1))
    done

    echo ""
    echo -e "${BOLD}${prompt}${NC}"
    for i in "${!labels[@]}"; do
        local num=$((i + 1))
        local marker=""
        if [[ "$num" -eq "$default" ]]; then
            marker=" [default]"
        fi
        printf "  ${BOLD}%d)${NC} %-16s— %s%s\n" "$num" "${labels[$i]}" "${descs[$i]}" "$marker"
    done

    # Loop until a valid numeric choice is entered. An EOF on stdin (piped
    # /dev/null, closed tty) exits loudly instead of busy-looping on "Invalid".
    local input
    while true; do
        read -rp "Choice [${default}]: " input || { err "stdin closed"; exit 1; }
        input="${input:-$default}"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#labels[@]} )); then
            REPLY="$input"
            return 0
        fi
        err "Invalid choice. Enter a number between 1 and ${#labels[@]}."
    done
}

# ask_yesno "prompt" default(y/n)
# Returns 0 for yes, 1 for no. Presents a numbered menu like ask_choice.
ask_yesno() {
    local prompt="$1"
    local default="${2:-n}"

    # Map y/n default to a 1-based menu index.
    local default_num=2
    if [[ "$default" == "y" ]]; then
        default_num=1
    fi

    local marker_yes="" marker_no=""
    if [[ "$default_num" -eq 1 ]]; then
        marker_yes=" [default]"
    else
        marker_no=" [default]"
    fi

    echo ""
    echo -e "${BOLD}${prompt}${NC}"
    printf "  ${BOLD}1)${NC} Yes%s\n" "$marker_yes"
    printf "  ${BOLD}2)${NC} No%s\n" "$marker_no"

    local input
    while true; do
        read -rp "Choice [${default_num}]: " input || { err "stdin closed"; exit 1; }
        input="${input:-$default_num}"
        case "$input" in
            1) return 0 ;;
            2) return 1 ;;
            *) err "Invalid choice. Enter 1 or 2." ;;
        esac
    done
}

# ask_input "prompt" default [regex]
# Sets REPLY to the input value. If a regex is provided, input must match it.
ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local regex="${3:-}"

    local display_default=""
    if [[ -n "$default" ]]; then
        display_default=" [${default}]"
    fi

    local input
    while true; do
        read -rp "${prompt}${display_default}: " input || { err "stdin closed"; exit 1; }
        input="${input:-$default}"

        if [[ -z "$input" ]]; then
            err "A value is required."
            continue
        fi

        # Optional regex gate — callers pass patterns like ^[0-9]+$ for strict input.
        if [[ -n "$regex" ]] && ! [[ "$input" =~ $regex ]]; then
            err "Invalid format."
            continue
        fi

        REPLY="$input"
        return 0
    done
}

# ask_password "prompt" [min_length]
# Sets REPLY to the password value. Uses -s flag to suppress terminal echo.
ask_password() {
    local prompt="$1"
    local min_length="${2:-0}"

    while true; do
        # -s suppresses echo; the manual echo "" adds the missing newline after input.
        read -srp "${prompt}: " input || { echo ""; err "stdin closed"; exit 1; }
        echo ""

        if [[ ${#input} -lt $min_length ]]; then
            err "Must be at least ${min_length} characters."
            continue
        fi

        REPLY="$input"
        return 0
    done
}

# ask_multiselect "prompt" "Label|Desc|on" ...
# Checkbox-style toggle menu. Sets MULTISELECT_RESULT array (0-indexed, "on" or "off").
# The user enters a number to flip an item, or presses Enter to confirm all selections.
ask_multiselect() {
    local prompt="$1"
    shift

    # Parse each option into three parallel arrays: label, description, initial state.
    local -a labels=()
    local -a descs=()
    local -a states=()

    for opt in "$@"; do
        IFS='|' read -r label desc state <<< "$opt"
        labels+=("$label")
        descs+=("$desc")
        states+=("${state:-off}")
    done

    local count=${#labels[@]}

    # Re-render the full list on each iteration so the [x] marks stay current.
    local input
    while true; do
        echo ""
        echo -e "${BOLD}${prompt}${NC}"
        for i in "${!labels[@]}"; do
            local num=$((i + 1))
            local mark=" "
            if [[ "${states[$i]}" == "on" ]]; then
                mark="x"
            fi
            printf "  ${BOLD}%d)${NC} [%s] %-28s— %s\n" "$num" "$mark" "${labels[$i]}" "${descs[$i]}"
        done
        echo ""
        read -rp "Toggle number, or Enter to confirm: " input || { err "stdin closed"; exit 1; }

        # Empty input = user is done selecting; export current states.
        if [[ -z "$input" ]]; then
            # Used by callers after sourcing lib.sh.
            # shellcheck disable=SC2034
            MULTISELECT_RESULT=("${states[@]}")
            return 0
        fi

        # Toggle the selected item between "on" and "off".
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= count )); then
            local idx=$((input - 1))
            if [[ "${states[$idx]}" == "on" ]]; then
                states[idx]="off"
            else
                states[idx]="on"
            fi
        else
            err "Enter a number between 1 and ${count}, or press Enter to confirm."
        fi
    done
}

# =============================================================================
# Validation
# =============================================================================

# Regex matches IPv4 format, then verifies each octet is 0-255.
# Regex alone can't check numeric ranges, so the loop handles that.
validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -ra octets <<< "$ip"
    for o in "${octets[@]}"; do
        (( o <= 255 )) || return 1
    done
    return 0
}

# Validates CIDR notation by splitting at "/" — delegates the IP part to validate_ip
# and checks that the prefix length is 0-32.
validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    validate_ip "$ip" && (( prefix <= 32 ))
}

# Stricter CIDR check for values that feed "trusted" allow-lists (private-net
# firewall rules, DOCKER-USER allow-from, ingress-nginx proxy-real-ip-cidr).
# Rejects 0.0.0.0/0 and anything outside RFC1918 (10/8, 172.16/12, 192.168/16).
# A lone validate_cidr accepts 0.0.0.0/0, which would silently open the host
# when used as NET_PRIVATE_CIDR.
validate_private_cidr() {
    local cidr="$1"
    validate_cidr "$cidr" || return 1
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    [[ "$ip" == "0.0.0.0" ]] && return 1
    if [[ "$ip" =~ ^10\. ]]                          && (( prefix >= 8  )); then return 0; fi
    if [[ "$ip" =~ ^192\.168\. ]]                    && (( prefix >= 16 )); then return 0; fi
    if [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && (( prefix >= 12 )); then return 0; fi
    return 1
}

# RFC-952 hostname: starts and ends with alphanumeric, allows dots and hyphens, max 253 chars.
validate_hostname() {
    local h="$1"
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ ${#h} -le 253 ]]
}

# Linux username rules: lowercase start, alphanumeric/underscore/hyphen, max 32 chars.
validate_username() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

# TCP/UDP port range: 1-65535 (port 0 is reserved).
validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# Validates that $1 is a single, well-formed SSH public key line. Rejects
# multi-line input — authorized_keys is line-oriented, and a newline in the
# value would cascade into a second file line on append (CWE-74/93). Accepts
# RSA, Ed25519, and ECDSA keys with an optional comment. The regex anchors
# to the full string so trailing garbage can't sneak past the prefix check.
validate_ssh_key() {
    [[ "$1" != *$'\n'* ]] || return 1
    [[ "$1" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9-]+)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

# =============================================================================
# System Detection
# =============================================================================

# Common Hetzner/cloud private interface names. Order matters: first match wins.
# Sets global PRIVATE_IFACE for use by get_private_ip and calling scripts.
detect_private_iface() {
    local candidates=(enp7s0 ens10 ens7 eth1)
    for iface in "${candidates[@]}"; do
        if ip link show "$iface" &>/dev/null; then
            PRIVATE_IFACE="$iface"
            return 0
        fi
    done
    PRIVATE_IFACE=""
    return 1
}

# detect_public_iface — sets PUBLIC_IFACE to the default-route interface
detect_public_iface() {
    PUBLIC_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -n "$PUBLIC_IFACE" ]]
}

# Ubuntu uses "ssh" as the service name, most other distros use "sshd".
# We probe both via systemctl to stay portable.
detect_ssh_service() {
    export SSH_SERVICE
    if systemctl cat ssh.service &>/dev/null; then
        SSH_SERVICE="ssh"
    elif systemctl cat sshd.service &>/dev/null; then
        SSH_SERVICE="sshd"
    else
        SSH_SERVICE=""
        return 1
    fi
    return 0
}

# Extracts the first IPv4 address from the given (or previously detected) interface.
# Falls back to PRIVATE_IFACE if no argument is passed.
get_private_ip() {
    local iface="${1:-${PRIVATE_IFACE:-}}"
    if [[ -z "$iface" ]]; then
        PRIVATE_IP=""
        return 1
    fi
    PRIVATE_IP=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    [[ -n "$PRIVATE_IP" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
}

# Also captures the Ubuntu version string for use in version-specific logic.
require_ubuntu() {
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        err "This script requires Ubuntu."
        exit 1
    fi
    export UBUNTU_VERSION
    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command not found: ${cmd}"
        return 1
    fi
}

# Re-launch the current script inside a tmux session for SSH disconnect
# protection. Long-running operations (apt upgrade, image pulls, docker install)
# survive connection drops when wrapped in tmux. The operator can reattach with
# `tmux attach -t <session>` after reconnecting.
#
# Decision tree:
#   1. Already inside tmux ($TMUX set)         → continue, no wrap.
#   2. tmux missing                            → offer to apt-get install; if
#                                                declined or install fails,
#                                                prompt to continue unprotected.
#   3. Session with our name already exists    → print attach instructions and
#                                                exit (never overwrite — might
#                                                be a live run from another
#                                                operator window).
#   4. Otherwise                               → exec into a fresh tmux session,
#                                                forwarding original argv.
#
# Respects ${NON_INTERACTIVE:-0} (set by main.sh after arg-parse). In
# non-interactive mode, skips prompts and picks the safe default.
ensure_tmux() {
    # (1) Already inside tmux — nothing to do.
    [[ -n "${TMUX:-}" ]] && return 0

    # Prefix with "cloud-" so our sessions are identifiable and don't collide
    # with unrelated tmux sessions the operator may already have.
    local session_name
    session_name="cloud-$(basename "$0" .sh | tr '.' '-')"

    # (2) tmux missing — offer to install it.
    if ! command -v tmux &>/dev/null; then
        if [[ "${NON_INTERACTIVE:-0}" -eq 0 ]]; then
            warn "tmux is not installed. Session protection requires it."
            if ask_yesno "Install tmux now (apt-get)?" "y"; then
                apt-get install -y -qq tmux &>/dev/null || true
            fi
        else
            # Headless mode: attempt a silent install but don't block on failure.
            apt-get install -y -qq tmux &>/dev/null || true
        fi
    fi

    # Still missing after install attempt — surface the risk and bail out.
    if ! command -v tmux &>/dev/null; then
        warn "tmux unavailable — an SSH disconnect will terminate this script."
        if [[ "${NON_INTERACTIVE:-0}" -eq 0 ]]; then
            if ! ask_yesno "Continue without tmux session protection?" "n"; then
                err "Aborted by operator. Install tmux and re-run."
                exit 1
            fi
        fi
        return 0
    fi

    # (3) Existing session detected — likely a previous invocation. Never
    # overwrite; it could be a live run. Guide the operator to attach.
    if tmux has-session -t "$session_name" 2>/dev/null; then
        separator "tmux session '${session_name}' already exists"
        warn "A previous run is still alive (or its tmux session wasn't closed)."
        echo ""
        info "  Attach:   tmux attach -t ${session_name}"
        info "  Dismiss:  tmux kill-session -t ${session_name}  (then re-run)"
        echo ""
        exit 0
    fi

    # (4) Fresh re-exec. Pass through caller's argv so --phase/--answers/etc.
    # survive the wrap.
    log "Re-launching inside tmux session '${session_name}'"
    info "  If disconnected, reattach with: tmux attach -t ${session_name}"
    exec tmux new-session -s "$session_name" -- "$0" "$@"
}

# 256 bits of entropy (32 hex bytes = 64 hex chars) — sufficient for cluster
# authentication tokens. Requires openssl in PATH.
generate_token() {
    openssl rand -hex 32
}

# Returns 0 if a TCP connection to host:port succeeds within the timeout.
# Uses bash built-in /dev/tcp to avoid requiring nc/ncat/nmap dependencies.
test_tcp_connectivity() {
    local host="$1"
    local port="$2"
    local tout="${3:-5}"
    timeout "$tout" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null
}

# Generic poll/retry helper. Runs CMD every INTERVAL seconds until it succeeds
# (exit 0) or TIMEOUT seconds have elapsed. All CMD output is suppressed —
# callers should rely on wait_for's own log/warn messages for status.
wait_for() {
    local desc="$1" timeout="$2" interval="$3"
    shift 3
    local elapsed=0
    info "Waiting for ${desc} (timeout ${timeout}s)..."
    while (( elapsed < timeout )); do
        if "$@" &>/dev/null; then
            log "${desc} — ready (${elapsed}s)"
            return 0
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
    warn "${desc} — not ready after ${timeout}s"
    return 1
}

# =============================================================================
# Summary Box
# =============================================================================

# print_summary "Title" "Key|Value" ...
# Renders a bordered box with a title row and key/value rows.
# Pipe-delimited pairs are split into fixed-width columns for alignment.
print_summary() {
    local title="$1"
    shift

    local width=62
    echo ""
    echo -e "${BLUE}┌$(printf '─%.0s' $(seq 1 $width))┐${NC}"
    printf "${BLUE}│${NC} ${BOLD}%-$((width - 1))s${BLUE}│${NC}\n" "$title"
    echo -e "${BLUE}├$(printf '─%.0s' $(seq 1 $width))┤${NC}"

    for pair in "$@"; do
        local key="${pair%%|*}"
        local val="${pair#*|}"
        printf "${BLUE}│${NC}  %-20s %-$((width - 23))s${BLUE}│${NC}\n" "$key" "$val"
    done

    echo -e "${BLUE}└$(printf '─%.0s' $(seq 1 $width))┘${NC}"
    echo ""
}
