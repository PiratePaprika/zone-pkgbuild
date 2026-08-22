#!/bin/bash
set -euo pipefail

mv ./local-x86_64/* ../zone-repo/x86_64/

(cd ../zone-repo/x86_64/; repo-add zone-repo.db.tar.gz *.pkg.tar.zst; rm -rf *.old; git add .; git commit -m "Update Local Repository"; git push -u origin master)
