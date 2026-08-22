#!/bin/bash
set -euo pipefail
makepkg -scf --noconfirm --skippgpcheck
pacman -Qdtq 2>/dev/null | xargs -r sudo pacman -Rns --noconfirm
mkdir -p ../../local-x86_64
mv ./*.pkg.tar.zst ../../local-x86_64/
