# zone-pkgbuild

PKGBUILDs for all Zone Linux custom packages.

## Directory Layout

| Directory | Contents |
|---|---|
| `local_pkgbuild/` | Zone-specific packages (fonts, XFCE config, wallpapers, sounds, editors) |
| `core_pkgbuild/` | Core system packages (grub, calamares, release hooks, grub theme) |
| `3rdparty_pkgbuild/` | AUR packages cloned at build time via `get-pkgs.sh` |

## Adding a New Package

1. Create `local_pkgbuild/<pkgname>/PKGBUILD` following the standard `makepkg` PKGBUILD format
2. Build on a Linux host: `cd local_pkgbuild/<pkgname> && makepkg -sc`
3. Move the resulting `.pkg.tar.zst` to `../zone-repo/x86_64/`
4. Run `upd-local.sh` on the Linux build host to update the repo database and push
5. Add the package name to `zone-iso/archiso/packages.x86_64`

## Update Scripts

| Script | Updates |
|---|---|
| `upd-local.sh` | `zone-repo` (local packages) |
| `upd-core.sh` | `zone-core-repo` (core packages) |
| `upd-3party.sh` | `zone-3party-repo` (3rd-party/AUR packages) |

These scripts must be run on a Linux host after building packages with `makepkg`.

## 3rd-Party AUR Packages

The `3rdparty_pkgbuild/aurpackages` file lists 18 AUR packages that are cloned at build
time by `get-pkgs.sh`. After cloning, `auto-build.sh` builds each one.

## BUILD_HOST_REQUIRED Notes

Any PKGBUILD with a `# BUILD_HOST_REQUIRED:` comment requires the following steps on a
Linux build host before the package can be published:

1. Verify `pkgver` against the upstream release page
2. Run `updpkgsums` to regenerate `sha256sums`
3. Run `makepkg -sc` to build and test
4. Run `namcap PKGBUILD` to check for issues

## Notable Changes (2022 → 2026)

- Update scripts updated to `#!/usr/bin/env bash` and `set -euo pipefail`
- `.tkn personal` credential helper removed from update scripts (use standard git auth)
- `zone-calamares` PKGBUILD updated to Calamares 3.3.x (Qt6/KF6 deps)
- `grub` PKGBUILD still at 2.06 — **requires manual update on build host** (pinned git commits must be updated to current grub HEAD)
