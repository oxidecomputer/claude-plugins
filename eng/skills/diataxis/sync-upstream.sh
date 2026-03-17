#!/usr/bin/env bash
# Sync the diataxis-documentation-framework subtree from upstream and remove
# files the skill doesn't need (Sphinx build config, images, etc.).
#
# Run from the repo root:
#   eng/skills/diataxis/sync-upstream.sh

set -euo pipefail

prefix=eng/skills/diataxis/diataxis-documentation-framework
repo=https://github.com/evildmp/diataxis-documentation-framework.git

# Pull upstream changes
git subtree pull --prefix="$prefix" "$repo" main --squash

# Remove non-RST artifacts
rm -rf "$prefix"/{_static,_templates,images}
rm -f "$prefix"/{*.png,*.py,*.bat,Makefile,make.bat,requirements.txt,spelling_wordlist.txt}

git add -A
if ! git diff --cached --quiet; then
    git commit -m "Remove non-RST files from diataxis subtree update"
fi
