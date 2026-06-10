#!/usr/bin/env bash
# Template drift check — run from an overlay checkout.
#
# Compares template-owned paths (everything tracked in upstream/main)
# between origin/main (overlay) and upstream/main (template). Differences
# mean generic changes accumulated in the overlay that were never
# upstreamed — see the template/overlay model in CLAUDE.md.
#
# Intentional overlay modifications of template files are listed in
# .driftignore (one path per line) in the overlay repo.
#
# Output: drifted paths, one per line. Exit 1 if drift found, else 0.
set -euo pipefail
cd "$(dirname "$0")/.."

git fetch -q upstream
git fetch -q origin

tmp_tracked=$(mktemp) tmp_diff=$(mktemp) tmp_ignore=$(mktemp)
trap 'rm -f "$tmp_tracked" "$tmp_diff" "$tmp_ignore"' EXIT

git ls-tree -r --name-only upstream/main | sort > "$tmp_tracked"
git diff --name-only upstream/main origin/main | sort > "$tmp_diff"
if [ -f .driftignore ]; then grep -v '^#' .driftignore | sort > "$tmp_ignore"; else : > "$tmp_ignore"; fi

drift=$(comm -12 "$tmp_tracked" "$tmp_diff" | comm -23 - "$tmp_ignore")

if [ -n "$drift" ]; then
    echo "$drift"
    exit 1
fi
