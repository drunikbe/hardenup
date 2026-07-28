# shellcheck shell=bash
# =============================================================================
# 23-packages.sh — apt update/upgrade + common base packages
# =============================================================================
#
# Installs the short list of tools every host wants (curl, jq, git, htop,
# etc.). Runtime-specific packages live with their runtimes:
#   - Docker packages are installed by 40-runtime.sh from the docker.com repo.
# =============================================================================

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../lib.sh"
# shellcheck source=/dev/null
source "${MODULE_DIR}/../state.sh"

applies_packages()   { return 0; }
detect_packages()    { return 0; }
configure_packages() {
    info "apt update + upgrade + install base tools:"
    info "  curl wget ca-certificates gnupg jq git vim tmux htop unzip net-tools"
    if ! ask_yesno "Install base packages?" "y"; then
        state_mark_skipped packages
        return 0
    fi
}

check_packages() {
    # Cheap to re-run (apt-get update + a second install pass is a few
    # seconds). Return 1 so main.sh's verifier uses verify_packages instead.
    return 1
}

verify_packages() {
    # Require a handful of the base tools to exist. If apt install failed
    # halfway, these will be missing.
    command -v curl >/dev/null 2>&1 \
        && command -v jq >/dev/null 2>&1 \
        && command -v git >/dev/null 2>&1
}

run_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq

    # Only packages that are actually used or genuinely wanted, and only ones
    # Ubuntu does NOT already guarantee (all of these are priority=optional).
    #
    # Deliberately absent — do not add them back:
    #   net-tools                  nothing here calls ifconfig/netstat/route;
    #                              every network read uses `ip`, and iproute2
    #                              is priority=important so it is always there.
    #                              net-tools is deprecated upstream too.
    #   apt-transport-https        a dummy transitional package; https support
    #                              has been part of apt itself for years.
    #   software-properties-common only provides add-apt-repository, which this
    #                              repo never calls — third-party repos are set
    #                              up by writing a .sources file directly.
    local common=(
        curl wget ca-certificates gnupg lsb-release
        jq git vim tmux htop unzip
    )

    # Skip the apt call entirely when everything is already present. apt-get
    # install is a no-op on installed packages, but on a stock Ubuntu image
    # that is the common case, and the call still costs a lock + dependency
    # resolution on every run.
    local missing=() pkg
    for pkg in "${common[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "Common packages: all present already"
        return 0
    fi

    for pkg in "${missing[@]}"; do
        record_pkg_installed "$pkg"
    done
    apt-get install -y -qq "${missing[@]}" 2>/dev/null
    log "Common packages installed: ${missing[*]}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    require_root
    state_init
    detect_packages
    configure_packages
    state_skipped packages && exit 0
    run_packages
    verify_packages || { err "Packages verification failed"; exit 1; }
fi
