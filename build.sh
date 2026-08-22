#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/parallel.sh"

usage() {
    cat >&2 <<'EOF'
Usage: ./build.sh [OPTIONS] [TARGET...]

Options:
  --all           Build all package groups (default when no options given)
  --local         Build local_pkgbuild/ packages
  --core          Build core_pkgbuild/ packages
  --3party        Build 3rdparty_pkgbuild/ AUR packages
  --changed       Only packages whose PKGBUILD changed since last stamp
  --jobs N        Parallel jobs (default: nproc)
  --no-sign       Skip GPG signing
  --dry-run       Print build plan without building

TARGET: one or more package dir names (e.g. zone-xfce grub cava)
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
BUILD_LOCAL=0; BUILD_CORE=0; BUILD_3PARTY=0
BUILD_CHANGED=0; DRY_RUN=0
ZONE_JOBS="$(nproc)"; ZONE_NO_SIGN=0
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)     BUILD_LOCAL=1; BUILD_CORE=1; BUILD_3PARTY=1 ;;
        --local)   BUILD_LOCAL=1 ;;
        --core)    BUILD_CORE=1 ;;
        --3party)  BUILD_3PARTY=1 ;;
        --changed) BUILD_CHANGED=1 ;;
        --jobs)    ZONE_JOBS="$2"; shift ;;
        --no-sign) ZONE_NO_SIGN=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        -*)        log_error "Unknown option: $1"; usage; exit 1 ;;
        *)         TARGETS+=("$1") ;;
    esac
    shift
done

# Default to --all when nothing is specified
if [[ ${#TARGETS[@]} -eq 0 && $BUILD_LOCAL -eq 0 && $BUILD_CORE -eq 0 && $BUILD_3PARTY -eq 0 ]]; then
    BUILD_LOCAL=1; BUILD_CORE=1; BUILD_3PARTY=1
fi

export ZONE_JOBS ZONE_NO_SIGN

# ── Dependency loading ────────────────────────────────────────────────────────
declare -gA ZONE_DEPS

load_deps() {
    [[ -f "$SCRIPT_DIR/deps.conf" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
        local pkg="${line%%:*}" deps="${line#*:}"
        pkg="${pkg//[[:space:]]/}"
        deps="${deps# }"
        ZONE_DEPS["$pkg"]="$deps"
    done < "$SCRIPT_DIR/deps.conf"
}
load_deps

# ── Package discovery ─────────────────────────────────────────────────────────
# Emits one PKGBUILD parent dir per line.
# Default maxdepth=3 covers nested packages (e.g. local_pkgbuild/zone-music/stalker-*/PKGBUILD).
discover_group() {
    local base_dir="$1" depth="${2:-3}"
    find "$base_dir" -name PKGBUILD -maxdepth "$depth" 2>/dev/null \
        | sed 's|/PKGBUILD$||' | sort
}

# Populates a nameref array with package dirs for a group, respecting --changed.
collect_group() {
    local base_dir="$1" depth="${2:-2}"
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if [[ $BUILD_CHANGED -eq 1 ]]; then
            needs_rebuild "$dir" || continue
        fi
        echo "$dir"
    done < <(discover_group "$base_dir" "$depth")
}

# ── Collect packages per group ────────────────────────────────────────────────
CORE_PKGS=() LOCAL_PKGS=() PARTY_PKGS=()

if [[ ${#TARGETS[@]} -gt 0 ]]; then
    for target in "${TARGETS[@]}"; do
        found="$(find "$SCRIPT_DIR" -name PKGBUILD -maxdepth 4 2>/dev/null \
                 | grep "/${target}/PKGBUILD$" | sed 's|/PKGBUILD$||' | head -1)"
        if [[ -z "$found" ]]; then
            log_error "Package not found: $target"; exit 1
        fi
        if [[ "$found" == */core_pkgbuild/* ]]; then
            CORE_PKGS+=("$found"); BUILD_CORE=1
        elif [[ "$found" == */local_pkgbuild/* ]]; then
            LOCAL_PKGS+=("$found"); BUILD_LOCAL=1
        else
            PARTY_PKGS+=("$found"); BUILD_3PARTY=1
        fi
    done
else
    [[ $BUILD_CORE -eq 1 ]]  && mapfile -t CORE_PKGS  < <(collect_group "$SCRIPT_DIR/core_pkgbuild")
    [[ $BUILD_LOCAL -eq 1 ]] && mapfile -t LOCAL_PKGS < <(collect_group "$SCRIPT_DIR/local_pkgbuild")
fi

# ── Dry run ───────────────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
    log_info "=== DRY RUN — build plan ==="
    log_info "Jobs: $ZONE_JOBS  Sign: $([[ $ZONE_NO_SIGN -eq 1 ]] && echo no || echo yes)"
    if [[ ${#CORE_PKGS[@]} -gt 0 ]]; then
        log_info "Core (${#CORE_PKGS[@]}):"
        printf '  %s\n' "${CORE_PKGS[@]##*/}" >&2
    fi
    if [[ ${#LOCAL_PKGS[@]} -gt 0 ]]; then
        log_info "Local (${#LOCAL_PKGS[@]}):"
        printf '  %s\n' "${LOCAL_PKGS[@]##*/}" >&2
    fi
    [[ $BUILD_3PARTY -eq 1 ]] && log_info "3rdparty: AUR packages from aurpackages list"
    exit 0
fi

# ── State + staging dirs; cleanup on exit ────────────────────────────────────
STATE_DIR="$(mktemp -d)"
OUT_BASE="$SCRIPT_DIR/out"
trap 'rm -rf "$STATE_DIR" "$SCRIPT_DIR/3rdparty_pkgbuild/3rdparty"' EXIT

# ── Repo publish helper ───────────────────────────────────────────────────────
update_repo() {
    local out_dir="$1" repo_x86_dir="$2" db_name="$3"
    [[ -d "$out_dir" ]] || return 0

    local pkgs=()
    while IFS= read -r f; do pkgs+=("$f"); done < <(
        find "$out_dir" -maxdepth 1 -name '*.pkg.tar.zst' 2>/dev/null
    )
    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    if [[ ! -d "$repo_x86_dir" ]]; then
        log_warn "Repo dir not found: $repo_x86_dir — packages remain in out/"
        return 0
    fi

    log_info "Publishing to $(basename "$(dirname "$repo_x86_dir")")/$(basename "$repo_x86_dir")"
    for f in "${pkgs[@]}"; do
        mv -f "$f" "$repo_x86_dir/"
        repo_add_pkg "$repo_x86_dir/$db_name" "$repo_x86_dir/$(basename "$f")"
    done
    find "$repo_x86_dir" -name '*.old' -delete

    local repo_root
    repo_root="$(realpath "$repo_x86_dir/..")"
    if [[ -d "$repo_root/.git" ]]; then
        git -C "$repo_root" add .
        git -C "$repo_root" commit -m "Update $(basename "$repo_root")" --quiet || true
        git -C "$repo_root" push --quiet || log_warn "git push failed for $(basename "$repo_root")"
    fi
}

# ── Build: core → local → 3party ─────────────────────────────────────────────
ALL_PKGS=()

if [[ ${#CORE_PKGS[@]} -gt 0 ]]; then
    log_info "=== core: ${#CORE_PKGS[@]} pkg(s), $ZONE_JOBS job(s) ==="
    export ZONE_OUT_DIR="$OUT_BASE/core"
    rm -rf "$ZONE_OUT_DIR"; mkdir -p "$ZONE_OUT_DIR"
    run_builds "$STATE_DIR/core" "${CORE_PKGS[@]}"
    ALL_PKGS+=("${CORE_PKGS[@]}")
fi

if [[ ${#LOCAL_PKGS[@]} -gt 0 ]]; then
    log_info "=== local: ${#LOCAL_PKGS[@]} pkg(s), $ZONE_JOBS job(s) ==="
    export ZONE_OUT_DIR="$OUT_BASE/local"
    rm -rf "$ZONE_OUT_DIR"; mkdir -p "$ZONE_OUT_DIR"
    run_builds "$STATE_DIR/local" "${LOCAL_PKGS[@]}"
    ALL_PKGS+=("${LOCAL_PKGS[@]}")
fi

if [[ $BUILD_3PARTY -eq 1 && ${#PARTY_PKGS[@]} -eq 0 ]]; then
    log_info "=== 3party: cloning AUR repos ==="
    (cd "$SCRIPT_DIR/3rdparty_pkgbuild" && rm -rf ./3rdparty && ./get-pkgs.sh)
    mapfile -t PARTY_PKGS < <(collect_group "$SCRIPT_DIR/3rdparty_pkgbuild/3rdparty" 1)
fi

if [[ ${#PARTY_PKGS[@]} -gt 0 ]]; then
    log_info "=== 3party: ${#PARTY_PKGS[@]} pkg(s), $ZONE_JOBS job(s) ==="
    export ZONE_OUT_DIR="$OUT_BASE/3party"
    rm -rf "$ZONE_OUT_DIR"; mkdir -p "$ZONE_OUT_DIR"
    run_builds "$STATE_DIR/3party" "${PARTY_PKGS[@]}"
    ALL_PKGS+=("${PARTY_PKGS[@]}")
fi

if [[ ${#ALL_PKGS[@]} -eq 0 ]]; then
    log_info "Nothing to build."
    exit 0
fi

# ── Orphan cleanup ────────────────────────────────────────────────────────────
pacman -Qdtq 2>/dev/null | xargs -r sudo pacman -Rns --noconfirm || true

# ── Publish ───────────────────────────────────────────────────────────────────
log_info "=== Publishing ==="
[[ $BUILD_CORE -eq 1 ]]   && update_repo "$OUT_BASE/core"   "$SCRIPT_DIR/../zone-core-repo/x86_64"   "zone-core-repo.db.tar.gz"
[[ $BUILD_LOCAL -eq 1 ]]  && update_repo "$OUT_BASE/local"  "$SCRIPT_DIR/../zone-repo/x86_64"        "zone-repo.db.tar.gz"
[[ $BUILD_3PARTY -eq 1 ]] && update_repo "$OUT_BASE/3party" "$SCRIPT_DIR/../zone-3party-repo/x86_64" "zone-3party-repo.db.tar.gz"

# ── Summary ───────────────────────────────────────────────────────────────────
log_info "=== Summary ==="
FINAL_RC=0
[[ ${#CORE_PKGS[@]} -gt 0 ]]  && { print_summary "$STATE_DIR/core"   "${CORE_PKGS[@]}"  || FINAL_RC=1; }
[[ ${#LOCAL_PKGS[@]} -gt 0 ]] && { print_summary "$STATE_DIR/local"  "${LOCAL_PKGS[@]}" || FINAL_RC=1; }
[[ ${#PARTY_PKGS[@]} -gt 0 ]] && { print_summary "$STATE_DIR/3party" "${PARTY_PKGS[@]}" || FINAL_RC=1; }
exit $FINAL_RC
