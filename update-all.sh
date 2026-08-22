#!/bin/bash
set -euo pipefail

# Run from zone-pkgbuild/ on a Linux build host.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOCAL_OUT="$SCRIPT_DIR/local-x86_64"
CORE_OUT="$SCRIPT_DIR/core-x86_64"
PARTY_OUT="$SCRIPT_DIR/3rdparty-x86_64"
ERRLOG="$(mktemp)"
trap 'rm -f "$ERRLOG"' EXIT

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; echo "$*" >> "$ERRLOG"; }

check_calamares_version() {
    local current latest
    current="$(grep -m1 '^pkgver=' core_pkgbuild/zone-calamares/PKGBUILD | cut -d= -f2)"
    latest="$(curl -sf 'https://api.github.com/repos/calamares/calamares/releases/latest' \
        | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')" || true
    if [[ -n "$latest" && "$latest" != "$current" ]]; then
        warn "Calamares $latest available (PKGBUILD: $current) — update pkgver and run updpkgsums first"
    fi
}

build_pkgbuilds() {
    local search_dir="$1" out_dir="$2"
    mkdir -p "$out_dir"
    while IFS= read -r pkgbuild; do
        local dir pkgname
        dir="$(dirname "$pkgbuild")"
        pkgname="$(basename "$dir")"
        log "  $pkgname"
        if (cd "$dir" && makepkg -scf --noconfirm --skippgpcheck); then
            find "$dir" -maxdepth 1 -name '*.pkg.tar.zst' -exec mv -f {} "$out_dir/" \;
        else
            warn "$pkgname: build failed"
        fi
    done < <(find "$search_dir" -name PKGBUILD | sort)
}

publish() {
    local script="$1" out_dir="$2" label="$3"
    if compgen -G "$out_dir/*.pkg.tar.zst" > /dev/null 2>&1; then
        log "Publishing $label..."
        "$script"
    else
        warn "$label: no packages to publish"
    fi
}

# ── Version checks ───────────────────────────────────────────────────────────
log "Checking upstream versions..."
check_calamares_version

# ── AUR / 3rd-party ──────────────────────────────────────────────────────────
log "=== AUR packages ==="
mkdir -p "$PARTY_OUT"
(
    cd "$SCRIPT_DIR/3rdparty_pkgbuild"
    rm -rf ./3rdparty
    ./auto-build.sh
    if [[ -s errors.txt ]]; then
        while IFS= read -r line; do warn "AUR: $line"; done < errors.txt
    fi
)

# ── Local packages ────────────────────────────────────────────────────────────
log "=== Local packages ==="
build_pkgbuilds "local_pkgbuild" "$LOCAL_OUT"

# ── Core packages ─────────────────────────────────────────────────────────────
log "=== Core packages ==="
build_pkgbuilds "core_pkgbuild" "$CORE_OUT"

# ── Publish ───────────────────────────────────────────────────────────────────
log "=== Publishing repos ==="
publish "./upd-local.sh"  "$LOCAL_OUT"  "zone-repo"
publish "./upd-core.sh"   "$CORE_OUT"   "zone-core-repo"
publish "./upd-3party.sh" "$PARTY_OUT"  "zone-3party-repo"

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ -s "$ERRLOG" ]]; then
    printf '\n[%s] Completed with warnings:\n' "$(date +%H:%M:%S)"
    sed 's/^/  - /' "$ERRLOG"
    exit 1
fi

log "All packages updated."
