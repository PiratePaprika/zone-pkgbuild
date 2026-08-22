#!/bin/bash
set -euo pipefail
makepkg -scf --noconfirm --skippgpcheck
pacman -Qdtq 2>/dev/null | xargs -r sudo pacman -Rns --noconfirm
mkdir -p ../../core-x86_64
mv ./*.pkg.tar.zst ../../core-x86_64/
