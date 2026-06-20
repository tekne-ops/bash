#!/bin/bash
# Advisory lock shared by repo-aur.sh and repo-tkg.sh (one build at a time).

acquire_repo_build_lock() {
    local script_name="${1:-$(basename "$0")}"
    local lock_file="${REPO_BUILD_LOCK_FILE:-${OUTPUT_REPO_DIR}/.repo-build.lock}"

    mkdir -p "$(dirname "$lock_file")"
    exec 200>"$lock_file"

    if ! flock -n 200; then
        local holder=""
        holder=$(cat "$lock_file" 2>/dev/null || true)
        if [[ -n "$holder" ]]; then
            log_error "Another repo build is already running: $holder (lock: $lock_file)"
        else
            log_error "Another repo build is already running (repo-aur.sh or repo-tkg.sh; lock: $lock_file)"
        fi
        exit 1
    fi

    printf '%s %s\n' "$$" "$script_name" >&200
}
