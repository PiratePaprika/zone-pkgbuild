#!/bin/bash
set -euo pipefail

mv ./3rdparty-x86_64/* ../zone-3party-repo/x86_64/

(cd ../zone-3party-repo/x86_64/; repo-add zone-3party-repo.db.tar.gz *.pkg.tar.zst; rm -rf *.old; git add .; git commit -m "Update 3rd Party Repository"; git push -u origin master)
