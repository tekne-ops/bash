#!/bin/bash
set -euo pipefail

#######################################
# AUR Build Script for Tekne Repo
#
# Flow: clone repo -> compare repo version vs local packages -> build only when
#       repo version > local. Moves packages to /srv/repo/tekne/, adds to tekne.db.
#######################################

readonly AUR_BASE="https://aur.archlinux.org"
readonly LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-/var/local/repo/tekne}"
readonly OUTPUT_REPO_DIR="${OUTPUT_REPO_DIR:-/var/local/repo/tekne}"
readonly REPO_NAME="tekne"
readonly BUILD_DIR="${BUILD_DIR:-/tmp/aur-build-tekne}"
readonly REPO_USER="${REPO_USER:-$(id -un)}"
readonly LOG_DIR="${OUTPUT_REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/build_$(date +%Y%m%d_%H%M%S).log"
readonly LOG_FILE

declare -a PACKAGES=(
    'onedrive-abraunegg' 'google-chrome' 'microsoft-edge-stable-bin' 'blesh-git'
    'ocs-url' 'aic94xx-firmware' 'ast-firmware' 'wd719x-firmware' 'upd72020x-fw'
    'laptop-mode-tools-git' 'schedtoold' 'zoom' 'ventoy-bin' 'visual-studio-code-bin'
    'proton-ge-custom-bin' 'teams-for-linux-bin' 'sound-theme-smooth' 'bitwarden-bin'
    'pikaur' 'yubico-authenticator-bin' 'bibata-cursor-theme-bin' 'flat-remix'
    'kora-icon-theme' 'httpfs2-2gbplus' 'ttf-ms-win10-auto' 'libwireplumber-4.0-compat'
    'heroic-games-launcher' 'crossover' 'deezer' 'cursor-bin' 'omnissa-horizon-client'
    'lib32-gstreamer' 'python311' 'edk2-ovmf-fedora'
)

declare -a FAILED_PACKAGES=()
declare -a SUCCESS_PACKAGES=()

#######################################
# Logging
#######################################
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

refresh_mirrorlist() {
    log_info "Refreshing mirrorlist"
    log_info "Running system update..."
    if ! sudo pacman -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "pacman -Syy failed (tekne repo may be unavailable); continuing build"
    fi
    if ! sudo pacman -Syu --noconfirm 2>&1 | tee -a "$LOG_FILE"; then
        log_warn "pacman -Syu failed; continuing build"
    fi
    log_info "Updating mirrorlist..."
    local args=(--country 'United States' --latest 100 --sort rate --protocol 'https,ftp' --age 168 --save /etc/pacman.d/mirrorlist)
    local rc=0

    if [[ $EUID -eq 0 ]]; then
        /usr/bin/reflector "${args[@]}" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    elif command -v sudo &>/dev/null; then
        sudo /usr/bin/reflector "${args[@]}" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    else
        rc=1
    fi

    if [[ $rc -ne 0 ]]; then
        log_warn "Mirrorlist refresh failed (exit $rc); continuing with existing mirrorlist"
    fi
}

#######################################
# Error handling
#######################################
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code"
    fi
    print_summary
}
trap cleanup EXIT

print_summary() {
    echo ""
    log_info "========== BUILD SUMMARY =========="
    log_info "Successful: ${#SUCCESS_PACKAGES[@]}"
    log_info "Failed: ${#FAILED_PACKAGES[@]}"
    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        log_warn "Failed packages: ${FAILED_PACKAGES[*]}"
    fi
    log_info "Log file: $LOG_FILE"
}

#######################################
# Version comparison (uses cloned repo; falls back to AUR API)
#######################################
get_upstream_version() {
    local pkg="$1"
    local pkg_dir="${BUILD_DIR}/${pkg}"

    # Prefer version from cloned repo (makepkg --printsrcinfo)
    if [[ -d "$pkg_dir" && -f "${pkg_dir}/PKGBUILD" ]]; then
        local srcinfo pkgver pkgrel
        srcinfo=$(timeout 120 bash -c "cd '$pkg_dir' && makepkg --printsrcinfo" 2>/dev/null) || true
        if [[ -n "$srcinfo" ]]; then
            pkgver=$(grep -E '^\s*pkgver\s*=' <<<"$srcinfo" | head -1 | sed -E 's/^[[:space:]]*pkgver[[:space:]]*=[[:space:]]*//')
            pkgrel=$(grep -E '^\s*pkgrel\s*=' <<<"$srcinfo" | head -1 | sed -E 's/^[[:space:]]*pkgrel[[:space:]]*=[[:space:]]*//')
            if [[ -n "$pkgver" ]]; then
                if [[ -n "$pkgrel" ]]; then
                    echo "${pkgver}-${pkgrel}"
                else
                    echo "$pkgver"
                fi
                return 0
            fi
        fi
    fi

    # Fallback: AUR RPC API (no clone needed)
    local json
    json=$(curl -sSf --max-time 30 "${AUR_BASE}/rpc/v5/info?arg[]=${pkg}") || return 1
    if command -v jq &>/dev/null; then
        jq -r '.results[0].Version // empty' <<<"$json"
    else
        return 1
    fi
}

# Extract version from package file using pacman (pkgver-pkgrel format)
_get_version_from_pkgfile() {
    local f="$1"
    pacman -Qp "$f" 2>/dev/null | awk '{print $2}'
}

get_local_version() {
    local pkg="$1"
    local dir="${LOCAL_REPO_DIR}"
    local f

    # Check for packages in LOCAL_REPO_DIR (could be repo/ subdir or flat)
    for search_dir in "$dir" "${dir}/repo"; do
        [[ -d "$search_dir" ]] || continue
        for f in "${search_dir}/${pkg}"-*.pkg.tar.zst; do
            [[ -e "$f" ]] || continue
            _get_version_from_pkgfile "$f"
            return 0
        done
        # Some packages have different pkgbase (e.g. google-chrome -> google-chrome)
        for f in "${search_dir}"/*"${pkg}"*.pkg.tar.zst; do
            [[ -e "$f" ]] || continue
            [[ "$f" == *"/${pkg}-"* ]] || [[ "$f" == *"/${pkg}"* ]] || continue
            _get_version_from_pkgfile "$f"
            return 0
        done
    done

    # Also check OUTPUT_REPO_DIR in case we're doing incremental runs
    for f in "${OUTPUT_REPO_DIR}/${pkg}"-*.pkg.tar.zst; do
        [[ -e "$f" ]] || continue
        _get_version_from_pkgfile "$f"
        return 0
    done

    echo ""
}

upstream_greater_than_local() {
    local pkg="$1"
    local upstream local_ver cmp

    upstream=$(get_upstream_version "$pkg") || return 1
    local_ver=$(get_local_version "$pkg")

    if [[ -z "$local_ver" ]]; then
        return 0 # No local version -> build
    fi
    if [[ -z "$upstream" ]]; then
        return 1 # Can't get upstream -> skip
    fi

    cmp=$(vercmp "$upstream" "$local_ver" 2>/dev/null) || true
    [[ "${cmp:-0}" -gt 0 ]]
}

#######################################
# Package operations
#######################################
validate_package_name() {
    local pkg="$1"
    if [[ ! "$pkg" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid package name: $pkg"
        return 1
    fi
    return 0
}

clone_repo() {
    local pkg="$1"
    validate_package_name "$pkg" || return 1

    local pkg_dir="${BUILD_DIR}/${pkg}"
    rm -rf "$pkg_dir"
    mkdir -p "$(dirname "$pkg_dir")"

    log_info "Cloning ${pkg} from ${AUR_BASE}/${pkg}.git"
    git clone "${AUR_BASE}/${pkg}.git" "$pkg_dir" 2>&1 | tee -a "$LOG_FILE"
}

build_package() {
    local pkg="$1"
    local pkg_dir="${BUILD_DIR}/${pkg}"

    log_info "Building ${pkg} with makepkg"
    if ! (cd "$pkg_dir" && makepkg --needed --noconfirm --syncdeps --cleanbuild --clean --skippgpcheck --force) 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to build $pkg"
        return 1
    fi

    return 0
}

move_packages_to_repo() {
    local pkg="$1"
    local pkg_dir="${BUILD_DIR}/${pkg}"
    local repo_out="${OUTPUT_REPO_DIR}"

    mkdir -p "$repo_out"
    find "$pkg_dir" -maxdepth 1 -name "*.pkg.tar.zst" -exec mv -f {} "$repo_out/" \; 2>/dev/null || true
}

#######################################
# Repository management
#######################################
update_repo_db() {
    local repo_out="${OUTPUT_REPO_DIR}"
    local db_final="${repo_out}/${REPO_NAME}.db.tar.gz"
    local files_final="${repo_out}/${REPO_NAME}.files.tar.gz"
    local db_tmp="${repo_out}/${REPO_NAME}.db.tar.gz.new"
    local files_tmp="${repo_out}/${REPO_NAME}.files.tar.gz.new"
    local -a pkgs=()

    log_info "Updating repository database: ${REPO_NAME}.db"
    mkdir -p "$repo_out"

    shopt -s nullglob
    pkgs=("${repo_out}"/*.pkg.tar.zst)
    shopt -u nullglob

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        if [[ -f "$db_final" ]]; then
            log_warn "No packages in $repo_out; keeping existing ${REPO_NAME}.db"
            return 0
        fi
        log_error "No packages in $repo_out; cannot create ${REPO_NAME}.db"
        return 1
    fi

    # IMPORTANT:
    # Do NOT use repo-add -n here. Some AUR packages can be rebuilt/re-downloaded
    # with the same pkgver-pkgrel filename but different contents; -n would keep
    # the old DB entry (old checksums) and pacman will fail with "corrupted package".
    #
    # Rebuild the db atomically: write to a temp filename, then move into place.
    # Never delete the live db until the new one is ready.
    rm -f -- "$db_tmp" "$files_tmp"

    if ! sudo -u "$REPO_USER" repo-add -v "$db_tmp" "${pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "repo-add failed; existing ${REPO_NAME}.db left unchanged"
        rm -f -- "$db_tmp" "$files_tmp"
        return 1
    fi

    [[ -f "$files_tmp" ]] || files_tmp="${db_tmp/.db.tar.gz.new/.files.tar.gz.new}"
    if [[ ! -f "$db_tmp" || ! -f "$files_tmp" ]]; then
        log_error "repo-add did not produce database files"
        rm -f -- "$db_tmp" "$files_tmp"
        return 1
    fi

    mv -f -- "$db_tmp" "$db_final"
    mv -f -- "$files_tmp" "$files_final"

    # Hardlink aliases for HTTP clients (nginx often rejects symlinks for tekne.db).
    rm -f -- "${repo_out}/${REPO_NAME}.db" "${repo_out}/${REPO_NAME}.files"
    ln -f -- "$db_final" "${repo_out}/${REPO_NAME}.db"
    ln -f -- "$files_final" "${repo_out}/${REPO_NAME}.files"
}

#######################################
# Main
#######################################
process_package() {
    local pkg="$1"
    log_info "========== Processing: $pkg =========="

    clone_repo "$pkg" || return 1

    if ! upstream_greater_than_local "$pkg"; then
        log_info "Skipping $pkg (repo version not newer than local)"
        return 0
    fi

    if build_package "$pkg"; then
        move_packages_to_repo "$pkg"
        SUCCESS_PACKAGES+=("$pkg")
        log_info "Successfully built: $pkg"
    else
        FAILED_PACKAGES+=("$pkg")
        log_warn "Failed to build: $pkg (continuing...)"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build AUR packages and add them to the Tekne repository.
Only downloads/builds when upstream version > version in ${LOCAL_REPO_DIR}.

Options:
  --force       Build all packages regardless of version (ignore version check)
  -h, --help    Show this help.

Environment:
  LOCAL_REPO_DIR    Where to read existing package versions (default: /var/local/repo/tekne)
  OUTPUT_REPO_DIR   Where to put built packages (default: /var/local/repo/tekne)
  BUILD_DIR         Temporary build directory (default: /tmp/aur-build-tekne)

Requires: jq, vercmp (pacman), git, base-devel
EOF
}

main() {
    local force_build=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force_build=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done

    mkdir -p "$LOG_DIR"
    log_info "Starting AUR build for Tekne repo"
    refresh_mirrorlist
    log_info "Local repo (version source): $LOCAL_REPO_DIR"
    log_info "Output repo: $OUTPUT_REPO_DIR"
    log_info "Packages: ${#PACKAGES[@]}"

    if ! command -v jq &>/dev/null; then
        log_error "jq is required. Install: pacman -S jq"
        exit 1
    fi

    if ! command -v vercmp &>/dev/null; then
        log_error "vercmp is required (pacman). Install: pacman -S pacman"
        exit 1
    fi

    for pkg in "${PACKAGES[@]}"; do
        if [[ $force_build -eq 1 ]]; then
            log_info "Force build: skipping version check for $pkg"
            clone_repo "$pkg" || continue
            if build_package "$pkg"; then
                move_packages_to_repo "$pkg"
                SUCCESS_PACKAGES+=("$pkg")
            else
                FAILED_PACKAGES+=("$pkg")
            fi
        else
            process_package "$pkg"
        fi
    done

    update_repo_db
    log_info "Build process completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
