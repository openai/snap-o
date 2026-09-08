#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
  echo 'Usage: publish-docs.sh SITE_DIRECTORY GH_PAGES_CHECKOUT SOURCE_SHA' >&2
  exit 1
fi
site_directory=$(cd "$1" && pwd)
publication_directory=$(cd "$2" && pwd)
source_sha=$3
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git -C "$publication_directory" branch --show-current)" == gh-pages ]]
[[ -z "$(git -C "$publication_directory" status --porcelain)" ]]

# Limit the build artifact to documentation; the branch also owns the update feed.
python3 - "$site_directory" "$publication_directory" <<'PY'
from pathlib import Path
import sys

site, publication = map(Path, sys.argv[1:])
for name in ("index.html", ".nojekyll"):
    if not (site / name).is_file():
        raise SystemExit(f"Missing required documentation file: {name}")
if not (publication / "appcast.xml").is_file():
    raise SystemExit("The gh-pages checkout must contain appcast.xml")
for path in site.rglob("*"):
    relative = path.relative_to(site)
    allowed = (
        relative.parts[0] == "assets"
        or relative == Path(".nojekyll")
        or (len(relative.parts) == 1 and path.suffix == ".html")
    )
    if not allowed or path.is_symlink() or ".git" in relative.parts:
        raise SystemExit(f"Unexpected documentation artifact: {relative}")
    target = publication / relative
    for parent in (target, *target.parents):
        if parent == publication:
            break
        if parent.is_symlink():
            raise SystemExit(f"Refusing to overwrite a published symlink: {relative}")
PY

# No --delete: existing release files and old public URLs must survive publication.
rsync -r --checksum "$site_directory/" "$publication_directory/"
git -C "$publication_directory" add -- .
git -C "$publication_directory" diff --cached --check
if git -C "$publication_directory" diff --cached --quiet; then
  echo 'Published documentation already matches this build.'
  exit 0
fi
git -C "$publication_directory" -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -m "Publish documentation from $source_sha"
# A concurrent release update rejects this push; rerun with a fresh checkout.
git -C "$publication_directory" push origin HEAD:gh-pages
