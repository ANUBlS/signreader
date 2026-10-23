#!/usr/bin/env bash
# Create or update a GitHub release in place (no delete/recreate race).
# Usage: publish_release.sh TAG "Title" notes.md file1 [file2 ...]
# Needs: GH_TOKEN, a checkout of the repo, permissions: contents: write.
set -euo pipefail

TAG="$1"; TITLE="$2"; NOTES="$3"; shift 3

# Point the tag at the current commit
git tag -f "$TAG" "$GITHUB_SHA"
git push -f origin "refs/tags/$TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES" --prerelease
else
  gh release create "$TAG" --title "$TITLE" --notes-file "$NOTES" --prerelease --verify-tag
fi

# Remove assets that are no longer part of this release, then upload/replace the new ones
keep=" $(for f in "$@"; do printf '%s ' "$(basename "$f")"; done)"
gh release view "$TAG" --json assets --jq '.assets[].name' | while read -r name; do
  case "$keep" in *" $name "*) ;; *) gh release delete-asset "$TAG" "$name" --yes || true ;; esac
done
gh release upload "$TAG" "$@" --clobber

echo "Published $TAG with: $*"
