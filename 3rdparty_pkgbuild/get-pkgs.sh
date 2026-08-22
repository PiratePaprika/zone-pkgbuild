#!/bin/bash
set -euo pipefail
rm -rf 3rdparty
xargs -P "$(nproc)" -I {} git clone "https://aur.archlinux.org/{}.git" "./3rdparty/{}" < ./aurpackages
xargs -P "$(nproc)" -I {} rm -rf "./3rdparty/{}/.git"    < ./aurpackages
xargs -P "$(nproc)" -I {} cp ./build.sh "./3rdparty/{}/" < ./aurpackages
