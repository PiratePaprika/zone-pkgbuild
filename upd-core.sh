#!/bin/bash
set -euo pipefail

mv ./core-x86_64/* ../zone-core-repo/x86_64/

(cd ../zone-core-repo/x86_64/; repo-add zone-core-repo.db.tar.gz *.pkg.tar.zst; rm -rf *.old; git add .; git commit -m "Update Core Repository"; git push -u origin master)
