# zone-pkgbuild

PKGBUILDs for all Zone Linux custom packages, with a unified parallel build system.

## Directory Layout

| Directory | Contents |
|---|---|
| `local_pkgbuild/` | Zone-specific packages (fonts, XFCE config, wallpapers, sounds, editors) |
| `core_pkgbuild/` | Core system packages (grub, calamares, release hooks, grub theme) |
| `3rdparty_pkgbuild/` | AUR packages cloned at build time via `get-pkgs.sh` |
| `lib/` | Shared build library (`common.sh`, `parallel.sh`) |

## Building Packages

All building is done from the `zone-pkgbuild/` root on a Linux build host.

### Common Usage

```bash
./build.sh              # build + publish all groups (default)
./build.sh --all        # same as above
./build.sh --core       # core packages only
./build.sh --local      # local packages only
./build.sh --3party     # AUR packages only
./build.sh --changed    # only packages whose PKGBUILD changed since last build
./build.sh --jobs 4     # override parallel job count (default: nproc)
./build.sh --no-sign    # skip GPG signing
./build.sh --dry-run    # print build plan without building
./build.sh zone-xfce grub  # build specific packages by name
```

After a successful build, packages are automatically published to the corresponding
repo directory and committed (but NOT pushed — push manually via `zone-manager.sh`).

## Adding a New Package

1. Create `local_pkgbuild/<pkgname>/PKGBUILD`
2. Create `local_pkgbuild/<pkgname>/build.sh` (for standalone use)
3. Run `./build.sh <pkgname>` on a Linux host to build and publish
4. Add the package name to `zone-iso/archiso/packages.x86_64`

## 3rd-Party AUR Packages

`3rdparty_pkgbuild/aurpackages` lists 18 AUR packages. `get-pkgs.sh` clones them
into `3rdparty_pkgbuild/3rdparty/` at build time. `build.sh --3party` handles this
automatically.

To add a new AUR package, append its name to `aurpackages`.

## Build Library (`lib/`)

| File | Purpose |
|---|---|
| `lib/common.sh` | `build_pkg`, `repo_add_pkg`, `sign_pkg`, `stamp_success`, `needs_rebuild` |
| `lib/parallel.sh` | `run_builds` (FIFO semaphore), `print_summary` |

### Incremental Builds (`--changed`)

Each successful `build_pkg` call writes a `.build-stamp` (sha256 of PKGBUILD) into the
package directory. `--changed` skips packages whose PKGBUILD matches the stamp.

### Inter-Package Dependencies (`deps.conf`)

`deps.conf` declares build-order constraints within a group. The current audit found no
constraints — all packages are independent. Add entries when a package requires another
from the same group to be built first:

```
zone-meta : zone-base zone-theme
```

## Updating Calamares

```bash
./zone-manager.sh manage calamares
```

Fetches the latest release from GitHub, updates `pkgver` and `pkgrel=1` in the
PKGBUILD, and runs `updpkgsums`.

## Notable Changes (2022 → 2026)

- Replaced `update-all.sh` + `upd-*.sh` with unified `build.sh` (parallel, incremental)
- Build library extracted to `lib/common.sh` and `lib/parallel.sh`
- `zone-calamares` updated to Calamares 3.3.x (Qt6/KF6 deps)
- `grub` PKGBUILD still at 2.06 — **requires manual update on build host**
- `paru`/`yay` orphan cleanup replaced with pure `pacman` equivalent
