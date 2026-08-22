#!/bin/bash
# Shared utilities: logging, build_pkg, repo_add_pkg, sign_pkg, stamp checks.

if [[ -t 2 ]]; then
    _CYN=$'\e[36m' _YEL=$'\e[33m' _RED=$'\e[31m' _GRN=$'\e[32m' _RST=$'\e[0m'
else
    _CYN='' _YEL='' _RED='' _GRN='' _RST=''
fi

log_info()  { printf '%s[%s] %s%s\n'       "$_CYN" "$(date +%H:%M:%S)" "$*" "$_RST" >&2; }
log_warn()  { printf '%s[%s] WARN  %s%s\n' "$_YEL" "$(date +%H:%M:%S)" "$*" "$_RST" >&2; }
log_error() { printf '%s[%s] ERROR %s%s\n' "$_RED" "$(date +%H:%M:%S)" "$*" "$_RST" >&2; }

: "${ZONE_OUT_DIR:=/tmp/zone-out}"
: "${ZONE_NO_SIGN:=0}"

_sleep_ms() {
    sleep "$(( ${1} / 1000 )).$(printf '%03d' $(( ${1} % 1000 )))"
}

# build_pkg <pkgbuild_dir>
# Runs makepkg inside pkgbuild_dir; moves .pkg.tar.zst to ZONE_OUT_DIR.
# Returns 1 on failure — does NOT exit the whole build.
build_pkg() {
    local dir="$1"
    local pkg
    pkg="$(basename "$dir")"
    log_info "Building $pkg"

    local rc=0
    (set -euo pipefail; cd "$dir"; makepkg -scf --noconfirm --skippgpcheck) || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "$pkg: makepkg failed (exit $rc)"
        return 1
    fi

    mkdir -p "$ZONE_OUT_DIR"
    local built=()
    while IFS= read -r f; do built+=("$f"); done < <(
        find "$dir" -maxdepth 1 -name '*.pkg.tar.zst' 2>/dev/null
    )
    if [[ ${#built[@]} -eq 0 ]]; then
        log_error "$pkg: makepkg succeeded but produced no .pkg.tar.zst"
        return 1
    fi
    for f in "${built[@]}"; do
        sign_pkg "$f"
        mv -f "$f" "$ZONE_OUT_DIR/"
    done

    stamp_success "$dir"
    return 0
}

# repo_add_pkg <repo_db_path> <pkg_file>
# Adds pkg_file to a pacman repo db using mkdir-based locking with exponential backoff.
repo_add_pkg() {
    local db_path="$1" pkg_file="$2"
    local lockdir="${db_path}.lock"
    local delay=200
    local attempt

    for attempt in 1 2 3 4 5; do
        if [[ -d "$lockdir" ]]; then
            local age=$(( $(date +%s) - $(stat -c %Y "$lockdir" 2>/dev/null || echo 0) ))
            (( age > 30 )) && rmdir "$lockdir" 2>/dev/null || true
        fi
        if mkdir "$lockdir" 2>/dev/null; then
            repo-add "$db_path" "$pkg_file"
            local rc=$?
            rmdir "$lockdir" 2>/dev/null || true
            return $rc
        fi
        log_warn "repo-add: lock busy, retry $attempt/5 in ${delay}ms"
        _sleep_ms "$delay"
        delay=$(( delay * 2 ))
    done

    log_error "repo-add: failed to acquire lock after 5 retries: $db_path"
    return 1
}

# sign_pkg <pkg_file> — GPG detach-sign; no-op when ZONE_NO_SIGN=1.
# Warns but does NOT fail the build when no GPG key is configured.
sign_pkg() {
    [[ "${ZONE_NO_SIGN:-0}" == "1" ]] && return 0
    if ! gpg --batch --yes --detach-sign --no-armor "$1" 2>/dev/null; then
        log_warn "GPG signing skipped for $(basename "$1") — no secret key (set ZONE_NO_SIGN=1 to suppress)"
    fi
    return 0
}

# stamp_success <pkgbuild_dir> — record sha256 of PKGBUILD in .build-stamp.
stamp_success() {
    sha256sum "$1/PKGBUILD" | awk '{print $1}' > "$1/.build-stamp"
}

# needs_rebuild <pkgbuild_dir> — returns 0 if rebuild needed, 1 if up to date.
needs_rebuild() {
    local stamp="$1/.build-stamp"
    [[ ! -f "$stamp" ]] && return 0
    local cur
    cur="$(sha256sum "$1/PKGBUILD" | awk '{print $1}')"
    [[ "$(cat "$stamp")" != "$cur" ]]
}
