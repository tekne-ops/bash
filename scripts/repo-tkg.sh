#!/bin/bash
set -euo pipefail

#######################################
# TKG Build Script for Tekne Repo
#
# Flow: clone repo -> compare repo version vs local packages -> build only when
#       repo version > local. Copies config, runs makepkg, moves to /srv/repo/tekne/.
#
# linux-tkg: 3 builds (aster, themis, yugen configs)
# nvidia-all, wine-tkg-git: 1 build each
#######################################

readonly GITHUB_BASE="https://github.com/Frogging-Family"
readonly LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-/srv/repo/tekne}"
readonly OUTPUT_REPO_DIR="${OUTPUT_REPO_DIR:-/srv/repo/tekne}"
readonly REPO_NAME="tekne"
readonly BUILD_DIR="${BUILD_DIR:-/tmp/tkg-build-tekne}"
readonly REPO_USER="${REPO_USER:-$(id -un)}"
readonly LOG_DIR="${OUTPUT_REPO_DIR}/logs"
LOG_FILE="${LOG_DIR}/build_$(date +%Y%m%d_%H%M%S).log"
readonly LOG_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CFG_DIR="${CFG_DIR:-$SCRIPT_DIR/config}"

declare -a PACKAGES=('linux-tkg' 'nvidia-all' 'wine-tkg-git')

# linux-tkg: 3 configs -> 3 separate package builds
declare -a LINUX_TKG_CONFIGS=('repo-linux-tkg-aster.cfg' 'repo-linux-tkg-themis.cfg' 'repo-linux-tkg-yugen.cfg')

# Config file mapping: pkg -> cfg (for nvidia-all, wine-tkg-git)
declare -A PKG_CONFIG=(
    ['nvidia-all']='repo-nvidia-all.cfg'
    ['wine-tkg-git']='repo-wine-tkg-git.cfg'
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
# Version comparison
#######################################
_get_version_from_pkgfile() {
    local f="$1"
    pacman -Qp "$f" 2>/dev/null | awk '{print $2}'
}

get_local_version() {
    local pkg="$1"
    local variant="$2" # For linux-tkg: aster, themis, yugen, or empty
    local dir repo_out f pattern

    for dir in "$LOCAL_REPO_DIR" "$OUTPUT_REPO_DIR"; do
        [[ -d "$dir" ]] || continue
        for search_dir in "$dir" "${dir}/repo"; do
            [[ -d "$search_dir" ]] || continue
            repo_out="$search_dir"

            case "$pkg" in
                linux-tkg)
                    # linux-tkg produces linux*-tkg-*.pkg.tar.zst (e.g. linux61-tkg-cacule, linux61-tkg-aster)
                    pattern="${repo_out}/linux*-tkg-*.pkg.tar.zst"
                    for f in $pattern; do
                        [[ -e "$f" ]] || continue
                        [[ "$f" == *-tkg-alk-* ]] && continue
                        if [[ -n "$variant" ]]; then
                            [[ "$f" == *"-tkg-${variant}"* ]] || [[ "$f" == *"-${variant}-"* ]] || continue
                        fi
                        _get_version_from_pkgfile "$f"
                        return 0
                    done
                    # If no variant filter, take first match
                    if [[ -z "$variant" ]]; then
                        for f in $pattern; do
                            [[ -e "$f" ]] || continue
                            [[ "$f" == *-tkg-alk-* ]] && continue
                            _get_version_from_pkgfile "$f"
                            return 0
                        done
                    fi
                    ;;
                nvidia-all)
                    pattern="${repo_out}/nvidia*-utils-tkg-*.pkg.tar.zst"
                    for f in $pattern; do
                        [[ -e "$f" ]] || continue
                        _get_version_from_pkgfile "$f"
                        return 0
                    done
                    ;;
                wine-tkg-git)
                    pattern="${repo_out}/wine-tkg-*.pkg.tar.zst"
                    for f in $pattern; do
                        [[ -e "$f" ]] || continue
                        _get_version_from_pkgfile "$f"
                        return 0
                    done
                    ;;
                *)
                    for f in "${repo_out}/${pkg}"-*.pkg.tar.zst; do
                        [[ -e "$f" ]] || continue
                        _get_version_from_pkgfile "$f"
                        return 0
                    done
                    ;;
            esac
        done
    done

    echo ""
}

# Get upstream version by running makepkg --printsrcinfo in cloned repo (best-effort, may timeout)
# Requires repo to already be cloned. Returns pkgver-pkgrel from .SRCINFO format.
get_upstream_version() {
    local pkg="$1"
    local cfg_file="$2"
    local pkg_dir="${BUILD_DIR}/${pkg}"
    local build_dir

    [[ -d "$pkg_dir" ]] || return 1

    case "$pkg" in
        wine-tkg-git) build_dir="${pkg_dir}/${pkg}" ;;
        *) build_dir="$pkg_dir" ;;
    esac

    [[ -f "${build_dir}/PKGBUILD" ]] || return 1

    # Copy config for version check (pkgver() may read customization.cfg)
    if [[ -n "$cfg_file" && -f "$cfg_file" ]]; then
        case "$pkg" in
            wine-tkg-git) cp "$cfg_file" "${build_dir}/customization.cfg" ;;
            *) cp "$cfg_file" "${pkg_dir}/customization.cfg" ;;
        esac
    fi

    local srcinfo pkgver pkgrel
    srcinfo=$(timeout 180 bash -c "cd '$build_dir' && makepkg --printsrcinfo" 2>/dev/null) || return 1
    pkgver=$(grep -E '^\s*pkgver\s*=' <<<"$srcinfo" | head -1 | sed -E 's/^[[:space:]]*pkgver[[:space:]]*=[[:space:]]*//')
    pkgrel=$(grep -E '^\s*pkgrel\s*=' <<<"$srcinfo" | head -1 | sed -E 's/^[[:space:]]*pkgrel[[:space:]]*=[[:space:]]*//')
    if [[ -n "$pkgver" ]]; then
        if [[ -n "$pkgrel" ]]; then
            echo "${pkgver}-${pkgrel}"
        else
            echo "$pkgver"
        fi
    fi
}

upstream_greater_than_local() {
    local pkg="$1"
    local variant="$2" # For linux-tkg: aster/themis/yugen - only compare against that variant's package
    local cfg_file="$3"
    local upstream local_ver cmp

    upstream=$(get_upstream_version "$pkg" "$cfg_file") || return 0 # Can't get -> build
    local_ver=$(get_local_version "$pkg" "$variant")

    if [[ -z "$local_ver" ]]; then
        return 0 # No local version -> build
    fi
    if [[ -z "$upstream" ]]; then
        return 0 # Can't get upstream -> build
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

get_source_url() {
    local pkg="$1"
    echo "${GITHUB_BASE}/${pkg}.git"
}

clone_repo() {
    local pkg="$1"
    validate_package_name "$pkg" || return 1

    local url pkg_dir
    url=$(get_source_url "$pkg")
    pkg_dir="${BUILD_DIR}/${pkg}"

    rm -rf "$pkg_dir"
    mkdir -p "$(dirname "$pkg_dir")"

    log_info "Cloning ${pkg} from ${url}"
    git clone "$url" "$pkg_dir" 2>&1 | tee -a "$LOG_FILE"
}

get_build_dir() {
    local pkg="$1"
    local pkg_dir="${BUILD_DIR}/${pkg}"
    if [[ "$pkg" == "wine-tkg-git" ]]; then
        echo "${pkg_dir}/${pkg}"
    else
        echo "$pkg_dir"
    fi
}

apply_config() {
    local pkg="$1"
    local cfg_file="$2"
    local pkg_dir="${BUILD_DIR}/${pkg}"

    if [[ ! -f "$cfg_file" ]]; then
        log_error "Config file not found: $cfg_file"
        return 1
    fi

    case "$pkg" in
        wine-tkg-git)
            cp "$cfg_file" "${pkg_dir}/${pkg}/customization.cfg"
            log_info "Applied config to ${pkg_dir}/${pkg}/customization.cfg"
            ;;
        *)
            cp "$cfg_file" "${pkg_dir}/customization.cfg"
            log_info "Applied config to ${pkg_dir}/customization.cfg"
            ;;
    esac
}

build_package() {
    local pkg="$1"
    local build_dir
    build_dir=$(get_build_dir "$pkg")

    log_info "Building ${pkg} in ${build_dir}"

    if ! (cd "$build_dir" && makepkg --needed --noconfirm --syncdeps --cleanbuild --clean --skippgpcheck --force) 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to build $pkg"
        return 1
    fi

    return 0
}

move_packages_to_repo() {
    local pkg="$1"
    local build_dir
    build_dir=$(get_build_dir "$pkg")

    mkdir -p "$OUTPUT_REPO_DIR"
    find "$build_dir" -maxdepth 1 -name "*.pkg.tar.zst" -exec mv -f {} "$OUTPUT_REPO_DIR/" \; 2>/dev/null || true
}

#######################################
# Repository management
#######################################
update_repo_db() {
    log_info "Updating repository database: ${REPO_NAME}.db"

    if [[ ! -d "$OUTPUT_REPO_DIR" ]]; then
        mkdir -p "$OUTPUT_REPO_DIR"
    fi

    if [[ -f "${OUTPUT_REPO_DIR}/${REPO_NAME}.db.tar.gz" ]]; then
        sudo -u "$REPO_USER" repo-add -n -v \
            "${OUTPUT_REPO_DIR}/${REPO_NAME}.db.tar.gz" \
            "${OUTPUT_REPO_DIR}"/*.pkg.tar.zst 2>&1 | tee -a "$LOG_FILE" || true
    else
        sudo -u "$REPO_USER" repo-add -v \
            "${OUTPUT_REPO_DIR}/${REPO_NAME}.db.tar.gz" \
            "${OUTPUT_REPO_DIR}"/*.pkg.tar.zst 2>&1 | tee -a "$LOG_FILE"
    fi

    log_info "Repository updated at: $OUTPUT_REPO_DIR"
}

#######################################
# Main processing
#######################################
process_linux_tkg() {
    local pkg="linux-tkg"
    log_info "========== Processing: $pkg (3 variants) =========="

    clone_repo "$pkg" || return 1

    local built_any=0
    for cfg_name in "${LINUX_TKG_CONFIGS[@]}"; do
        local cfg_file="${CFG_DIR}/${cfg_name}"
        local variant="${cfg_name#repo-linux-tkg-}"
        variant="${variant%.cfg}"

        if ! upstream_greater_than_local "$pkg" "$variant" "$cfg_file"; then
            log_info "Skipping $pkg ($variant): upstream not newer than local"
            continue
        fi

        log_info "Building $pkg with config: $cfg_name ($variant)"
        apply_config "$pkg" "$cfg_file" || continue

        if build_package "$pkg"; then
            move_packages_to_repo "$pkg"
            SUCCESS_PACKAGES+=("${pkg}-${variant}")
            built_any=1
        else
            FAILED_PACKAGES+=("${pkg}-${variant}")
        fi

        # Re-clone for next variant (build dir is cleaned by makepkg --clean)
        clone_repo "$pkg" || return 1
    done

    [[ $built_any -eq 1 ]]
}

process_standard_pkg() {
    local pkg="$1"
    local cfg_name="${PKG_CONFIG[$pkg]}"
    local cfg_file="${CFG_DIR}/${cfg_name}"

    log_info "========== Processing: $pkg =========="

    clone_repo "$pkg" || return 1

    if ! upstream_greater_than_local "$pkg" "" "$cfg_file"; then
        log_info "Skipping $pkg: upstream not newer than local"
        return 0
    fi

    apply_config "$pkg" "$cfg_file" || return 1

    if build_package "$pkg"; then
        move_packages_to_repo "$pkg"
        SUCCESS_PACKAGES+=("$pkg")
    else
        FAILED_PACKAGES+=("$pkg")
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build Frogging-Family TKG packages and add them to the Tekne repository.
Only downloads/builds when upstream version > version in ${LOCAL_REPO_DIR}.

Packages: linux-tkg (3 configs: aster, themis, yugen), nvidia-all, wine-tkg-git

Options:
  --force       Build all packages regardless of version (ignore version check)
  -h, --help    Show this help.

Environment:
  LOCAL_REPO_DIR    Where to read existing package versions (default: /srv/repo/tekne)
  OUTPUT_REPO_DIR   Where to put built packages (default: /srv/repo/tekne)
  BUILD_DIR         Temporary build directory (default: /tmp/tkg-build-tekne)
  CFG_DIR           Directory containing repo-*.cfg files (default: script directory)

Requires: vercmp (pacman), git, base-devel
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
    log_info "Starting TKG build for Tekne repo"
    log_info "Local repo (version source): $LOCAL_REPO_DIR"
    log_info "Output repo: $OUTPUT_REPO_DIR"
    log_info "Config directory: $CFG_DIR"

    if ! command -v vercmp &>/dev/null; then
        log_error "vercmp is required (pacman). Install: pacman -S pacman"
        exit 1
    fi

    for pkg in "${PACKAGES[@]}"; do
        if [[ $force_build -eq 1 ]]; then
            log_info "Force build: skipping version check for $pkg"
            if [[ "$pkg" == "linux-tkg" ]]; then
                clone_repo "$pkg" || continue
                for cfg_name in "${LINUX_TKG_CONFIGS[@]}"; do
                    local cfg_file="${CFG_DIR}/${cfg_name}"
                    local variant="${cfg_name#repo-linux-tkg-}"
                    variant="${variant%.cfg}"
                    log_info "Building $pkg ($variant)"
                    apply_config "$pkg" "$cfg_file" || continue
                    if build_package "$pkg"; then
                        move_packages_to_repo "$pkg"
                        SUCCESS_PACKAGES+=("${pkg}-${variant}")
                    else
                        FAILED_PACKAGES+=("${pkg}-${variant}")
                    fi
                    clone_repo "$pkg" || continue
                done
            else
                clone_repo "$pkg" || continue
                apply_config "$pkg" "${CFG_DIR}/${PKG_CONFIG[$pkg]}" || continue
                if build_package "$pkg"; then
                    move_packages_to_repo "$pkg"
                    SUCCESS_PACKAGES+=("$pkg")
                else
                    FAILED_PACKAGES+=("$pkg")
                fi
            fi
        else
            if [[ "$pkg" == "linux-tkg" ]]; then
                process_linux_tkg || true
            else
                process_standard_pkg "$pkg" || true
            fi
        fi
    done

    update_repo_db
    log_info "Build process completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
