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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/repo-build-lock.sh
source "${SCRIPT_DIR}/repo-build-lock.sh"

# 'heroic-games-launcher'
declare -a PACKAGES=(
    'onedrive-abraunegg' 'google-chrome' 'microsoft-edge-stable-bin' 'blesh-git'
    'ocs-url' 'aic94xx-firmware' 'ast-firmware' 'wd719x-firmware' 'upd72020x-fw'
    'laptop-mode-tools-git' 'schedtoold' 'zoom' 'ventoy-bin' 'visual-studio-code-bin'
    'proton-ge-custom-bin' 'teams-for-linux-bin' 'sound-theme-smooth' 'bitwarden-bin'
    'pikaur' 'yubico-authenticator-bin' 'bibata-cursor-theme-bin' 'flat-remix'
    'kora-icon-theme' 'httpfs2-2gbplus' 'ttf-ms-win10-auto' 'libwireplumber-4.0-compat'
    'crossover' 'deezer' 'cursor-bin' 'omnissa-horizon-client' 'lib32-gstreamer'
    'python311' 'edk2-ovmf-fedora'
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

_consider_local_version() {
    local best_ver="$1"
    local candidate="$2"
    local cmp

    [[ -n "$candidate" ]] || return 0
    if [[ -z "$best_ver" ]]; then
        echo "$candidate"
        return 0
    fi
    cmp=$(vercmp "$candidate" "$best_ver" 2>/dev/null) || return 0
    if [[ "$cmp" -gt 0 ]]; then
        echo "$candidate"
    else
        echo "$best_ver"
    fi
}

get_local_version() {
    local pkg="$1"
    local dir="${LOCAL_REPO_DIR}"
    local search_dir f ver best_ver=""

    # Check for packages in LOCAL_REPO_DIR (could be repo/ subdir or flat).
    # Use the highest version found; glob order is lexical (3.8.22 before 3.9.8).
    for search_dir in "$dir" "${dir}/repo" "$OUTPUT_REPO_DIR"; do
        [[ -d "$search_dir" ]] || continue
        for f in "${search_dir}/${pkg}"-*.pkg.tar.zst; do
            [[ -e "$f" ]] || continue
            ver=$(_get_version_from_pkgfile "$f") || continue
            best_ver=$(_consider_local_version "$best_ver" "$ver")
        done
        for f in "${search_dir}"/*"${pkg}"*.pkg.tar.zst; do
            [[ -e "$f" ]] || continue
            [[ "$f" == *"/${pkg}-"* ]] || [[ "$f" == *"/${pkg}"* ]] || continue
            ver=$(_get_version_from_pkgfile "$f") || continue
            best_ver=$(_consider_local_version "$best_ver" "$ver")
        done
    done

    echo "$best_ver"
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
    # Drop older builds of the same package so repo-add and pacman see one version.
    find "$repo_out" -maxdepth 1 -name "${pkg}-*.pkg.tar.zst" -delete
    find "$pkg_dir" -maxdepth 1 -name "*.pkg.tar.zst" -exec mv -f {} "$repo_out/" \; 2>/dev/null || true
}

#######################################
# Repository management
#######################################
_parse_desc_version() {
    local desc="$1"
    awk '$0 == "%VERSION%" { getline; print; exit }' <<<"$desc"
}

_parse_desc_name() {
    local desc="$1"
    awk '$0 == "%NAME%" { getline; print; exit }' <<<"$desc"
}

_get_db_package_version() {
    local pkgname="$1"
    local db_file="$2"
    local entry desc name ver best_ver=""

    [[ -f "$db_file" ]] || return 1

    # Repo db v2: <pkgbase-ver-rel-arch>/desc per package
    while IFS= read -r entry; do
        desc=$(tar -xOf "$db_file" "${entry}/desc" 2>/dev/null) || continue
        name=$(_parse_desc_name "$desc")
        [[ "$name" == "$pkgname" ]] || continue
        ver=$(_parse_desc_version "$desc")
        [[ -n "$ver" ]] || continue
        best_ver=$(_consider_local_version "$best_ver" "$ver")
    done < <(tar -tzf "$db_file" 2>/dev/null | awk -F/ 'NF == 2 && $2 == "desc" { print $1 }')

    if [[ -n "$best_ver" ]]; then
        echo "$best_ver"
        return 0
    fi

    # Repo db v1 fallback: single desc file at archive root
    desc=$(tar -xOf "$db_file" desc 2>/dev/null) || return 1
    name=""
    ver=""
    while IFS= read -r line; do
        case "$line" in
            '%NAME%')
                read -r name
                ;;
            '%VERSION%')
                read -r ver
                if [[ "$name" == "$pkgname" && -n "$ver" ]]; then
                    best_ver=$(_consider_local_version "$best_ver" "$ver")
                fi
                name=""
                ver=""
                ;;
        esac
    done <<<"$desc"

    [[ -n "$best_ver" ]] && echo "$best_ver"
}

# repo-add names db directories {pkgname}-{pkgver}-{pkgrel} (no -x86_64/-any suffix).
_pkgfile_db_entry() {
    local pkgfile="$1"
    local name ver

    name=$(pacman -Qp "$pkgfile" 2>/dev/null | awk '{print $1}') || return 1
    ver=$(pacman -Qp "$pkgfile" 2>/dev/null | awk '{print $2}') || return 1
    echo "${name}-${ver}"
}

_get_db_entry_desc() {
    local entry="$1"
    local db_file="$2"

    tar -xOf "$db_file" "${entry}/desc" 2>/dev/null
}

_get_db_entry_version() {
    local pkgfile="$1"
    local db_file="$2"
    local entry desc

    entry=$(_pkgfile_db_entry "$pkgfile") || return 1
    desc=$(_get_db_entry_desc "$entry" "$db_file") || return 1
    _parse_desc_version "$desc"
}

_get_db_entry_filename() {
    local entry="$1"
    local db_file="$2"
    local desc

    desc=$(_get_db_entry_desc "$entry" "$db_file") || return 1
    awk '$0 == "%FILENAME%" { getline; print; exit }' <<<"$desc"
}

# Remove older .pkg.tar.zst files when multiple versions share a pkgname.
# repo-add only keeps one entry per pkgname; stale files cause false verify failures.
prune_stale_packages() {
    local repo_out="$1"
    local f name ver cmp pruned=0
    declare -A keep_file=()
    declare -A keep_ver=()

    shopt -s nullglob
    for f in "${repo_out}"/*.pkg.tar.zst; do
        name=$(pacman -Qp "$f" 2>/dev/null | awk '{print $1}') || continue
        ver=$(pacman -Qp "$f" 2>/dev/null | awk '{print $2}') || continue
        if [[ -z "${keep_ver[$name]:-}" ]]; then
            keep_ver[$name]=$ver
            keep_file[$name]=$f
            continue
        fi
        cmp=$(vercmp "$ver" "${keep_ver[$name]}" 2>/dev/null) || continue
        if [[ "$cmp" -gt 0 ]]; then
            keep_ver[$name]=$ver
            keep_file[$name]=$f
        fi
    done

    for f in "${repo_out}"/*.pkg.tar.zst; do
        name=$(pacman -Qp "$f" 2>/dev/null | awk '{print $1}') || continue
        if [[ "$f" != "${keep_file[$name]}" ]]; then
            log_info "Pruning stale package file: $(basename "$f")"
            rm -f -- "$f"
            pruned=$((pruned + 1))
        fi
    done
    shopt -u nullglob

    if [[ $pruned -gt 0 ]]; then
        log_info "Pruned $pruned stale package file(s)"
    fi
}

# Compare on-disk .pkg.tar.zst versions with what tekne.db indexes.
log_db_file_mismatches() {
    local repo_out="${OUTPUT_REPO_DIR}"
    local db_final="${repo_out}/${REPO_NAME}.db.tar.gz"
    local f name file_ver db_ver latest mismatches=0

    [[ -f "$db_final" ]] || return 0

    shopt -s nullglob
    for f in "${repo_out}"/*.pkg.tar.zst; do
        name=$(pacman -Qp "$f" 2>/dev/null | awk '{print $1}') || continue
        file_ver=$(pacman -Qp "$f" 2>/dev/null | awk '{print $2}') || continue
        db_ver=$(_get_db_entry_version "$f" "$db_final")
        if [[ -n "$db_ver" && "$file_ver" == "$db_ver" ]]; then
            continue
        fi
        if [[ -z "$db_ver" ]]; then
            latest=$(_get_db_package_version "$name" "$db_final")
            if [[ -n "$latest" ]]; then
                log_warn "Stale package file on disk (not indexed): $(basename "$f") (db has ${name} ${latest})"
            else
                log_warn "DB out of sync: ${name} ${file_ver} on disk but missing from ${REPO_NAME}.db"
            fi
        else
            log_warn "DB out of sync: $(basename "$f") file=${file_ver} db=${db_ver}"
        fi
        mismatches=$((mismatches + 1))
    done
    shopt -u nullglob

    if [[ $mismatches -gt 0 ]]; then
        log_warn "Found $mismatches package file(s) out of sync with ${REPO_NAME}.db; will rebuild database"
    fi
    return 0
}

verify_repo_db() {
    local repo_out="${OUTPUT_REPO_DIR}"
    local db_final="${repo_out}/${REPO_NAME}.db.tar.gz"
    local f file_ver db_ver entry mismatches=0

    shopt -s nullglob
    for f in "${repo_out}"/*.pkg.tar.zst; do
        file_ver=$(pacman -Qp "$f" 2>/dev/null | awk '{print $2}') || continue
        db_ver=$(_get_db_entry_version "$f" "$db_final")
        if [[ -z "$db_ver" ]]; then
            log_error "DB verify failed: $(basename "$f") not indexed in ${REPO_NAME}.db"
            mismatches=$((mismatches + 1))
            continue
        fi
        if [[ "$file_ver" != "$db_ver" ]]; then
            log_error "DB verify failed: $(basename "$f") file=${file_ver} db=${db_ver}"
            mismatches=$((mismatches + 1))
        fi
    done

    while IFS= read -r entry; do
        local db_filename filename
        db_filename=$(_get_db_entry_filename "$entry" "$db_final") || continue
        filename="${repo_out}/${db_filename}"
        if [[ ! -f "$filename" ]]; then
            log_error "DB verify failed: ${db_filename} indexed but missing on disk"
            mismatches=$((mismatches + 1))
        fi
    done < <(tar -tzf "$db_final" 2>/dev/null | awk -F/ 'NF == 2 && $2 == "desc" { print $1 }')
    shopt -u nullglob

    if [[ $mismatches -gt 0 ]]; then
        log_error "Repository database still out of sync with $mismatches package file(s)"
        return 1
    fi
    return 0
}

prepare_repo_for_indexing() {
    local repo_out="$1"
    local f

    shopt -s nullglob
    for f in "${repo_out}"/*.pkg.tar.zst; do
        chmod a+r "$f" 2>/dev/null || true
        if [[ $EUID -eq 0 ]]; then
            chown "$REPO_USER:$REPO_USER" "$f" 2>/dev/null || true
        elif command -v sudo &>/dev/null; then
            sudo chown "$REPO_USER:$REPO_USER" "$f" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
}

run_repo_add() {
    local db_tmp="$1"
    shift
    local -a pkgs=("$@")

    prepare_repo_for_indexing "${OUTPUT_REPO_DIR}"

    if id "$REPO_USER" &>/dev/null && [[ "$(id -un)" != "$REPO_USER" ]]; then
        sudo -u "$REPO_USER" repo-add -v "$db_tmp" "${pkgs[@]}"
    else
        repo-add -v "$db_tmp" "${pkgs[@]}"
    fi
}

update_repo_db() {
    local repo_out="${OUTPUT_REPO_DIR}"
    local db_final="${repo_out}/${REPO_NAME}.db.tar.gz"
    local files_final="${repo_out}/${REPO_NAME}.files.tar.gz"
    local stage_dir db_tmp files_tmp
    local -a pkgs=()

    log_info "Updating repository database: ${REPO_NAME}.db"
    mkdir -p "$repo_out"
    prune_stale_packages "$repo_out"

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
    # Rebuild the db atomically in a staging dir. repo-add requires filenames to
    # end in .db.tar.gz / .files.tar.gz exactly (.new suffix is rejected).
    stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/${REPO_NAME}-db-staging.XXXXXX")
    db_tmp="${stage_dir}/${REPO_NAME}.db.tar.gz"
    files_tmp="${stage_dir}/${REPO_NAME}.files.tar.gz"
    if id "$REPO_USER" &>/dev/null && [[ "$(id -un)" != "$REPO_USER" ]]; then
        chown "$REPO_USER:$REPO_USER" "$stage_dir"
    fi

    # Remove leftovers from earlier broken runs.
    rm -f -- "${repo_out}/${REPO_NAME}.db.tar.gz.new" "${repo_out}/${REPO_NAME}.files.tar.gz.new"

    if ! run_repo_add "$db_tmp" "${pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "repo-add failed; existing ${REPO_NAME}.db left unchanged"
        rm -rf -- "$stage_dir"
        return 1
    fi

    if [[ ! -f "$db_tmp" || ! -f "$files_tmp" ]]; then
        log_error "repo-add did not produce database files"
        rm -rf -- "$stage_dir"
        return 1
    fi

    mv -f -- "$db_tmp" "$db_final"
    mv -f -- "$files_tmp" "$files_final"
    rm -rf -- "$stage_dir"

    # Hardlink aliases for HTTP clients (nginx often rejects symlinks for tekne.db).
    rm -f -- "${repo_out}/${REPO_NAME}.db" "${repo_out}/${REPO_NAME}.files"
    ln -f -- "$db_final" "${repo_out}/${REPO_NAME}.db"
    ln -f -- "$files_final" "${repo_out}/${REPO_NAME}.files"

    log_info "Repository database rebuilt with ${#pkgs[@]} package file(s)"
    if ! verify_repo_db; then
        return 1
    fi
}

#######################################
# Main
#######################################
process_package() {
    local pkg="$1"
    log_info "========== Processing: $pkg =========="

    if ! clone_repo "$pkg"; then
        FAILED_PACKAGES+=("$pkg")
        log_warn "Failed to clone $pkg (continuing...)"
        return 0
    fi

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
  --sync-db     Rebuild ${REPO_NAME}.db from on-disk .pkg.tar.zst files only (no builds)
  -h, --help    Show this help.

Environment:
  LOCAL_REPO_DIR        Where to read existing package versions (default: /var/local/repo/tekne)
  OUTPUT_REPO_DIR       Where to put built packages (default: /var/local/repo/tekne)
  BUILD_DIR             Temporary build directory (default: /tmp/aur-build-tekne)
  REPO_BUILD_LOCK_FILE  Shared lock file for repo-aur.sh / repo-tkg.sh (default: \${OUTPUT_REPO_DIR}/.repo-build.lock)

Requires: jq, vercmp (pacman), git, base-devel
EOF
}

main() {
    local force_build=0
    local sync_db_only=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force_build=1 ;;
            --sync-db) sync_db_only=1 ;;
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
    acquire_repo_build_lock "$(basename "$0")"
    log_info "Starting AUR build for Tekne repo"
    log_info "Local repo (version source): $LOCAL_REPO_DIR"
    log_info "Output repo: $OUTPUT_REPO_DIR"

    if [[ $sync_db_only -eq 1 ]]; then
        log_info "Mode: sync database only (no package builds)"
        log_db_file_mismatches || true
        update_repo_db
        log_info "Database sync completed"
        return 0
    fi

    refresh_mirrorlist
    log_info "Packages: ${#PACKAGES[@]}"
    log_db_file_mismatches || true

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

    if ! update_repo_db; then
        log_error "Failed to update ${REPO_NAME}.db; pacman clients may see stale package versions"
        exit 1
    fi
    log_info "Build process completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
