#!/bin/bash
set -euo pipefail
makepkg -scf --noconfirm --skippgpcheck
mkdir -p ../../../3rdparty-x86_64
mv ./*.pkg.tar.zst ../../../3rdparty-x86_64/
