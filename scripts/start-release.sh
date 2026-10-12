#!/bin/zsh
# `make release`: starts the Release workflow on GitHub for origin/main and follows it.
#   scripts/start-release.sh [patch|minor|major|X.Y.Z]
# Safe to rerun after a failure; the workflow picks up where the last attempt stopped.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=mason50x/murmur
BUMP=${1:-patch}
die() { print -u2 "error: $*"; exit 1; }
[[ $BUMP == (patch|minor|major|<->.<->.<->) ]] || die "usage: make release [BUMP=patch|minor|major|X.Y.Z]"
command -v gh >/dev/null || die "install the GitHub CLI: brew install gh"
gh auth status -h github.com >/dev/null 2>&1 || die "sign in to GitHub first: gh auth login"
[[ -z $(git status --porcelain) ]] || die "commit your changes first"
[[ $(git branch --show-current) == main ]] || die "switch to main first"

# Release what's on GitHub: catch up with it (e.g. a release commit from an earlier run), and
# refuse to start while there's local work it wouldn't include.
git fetch -q --tags origin main
if ! git merge-base --is-ancestor origin/main HEAD; then
  git merge-base --is-ancestor HEAD origin/main || die "main and origin/main have diverged; sort that out first"
  git merge -q --ff-only origin/main
fi
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "push your commits first (git push)"

runs() { gh run list --repo "$REPO" --workflow release.yml --limit 20 --json databaseId --jq '.[].databaseId'; }
before=(${(f)"$(runs)"})
gh workflow run release.yml --repo "$REPO" --ref main -f bump="$BUMP"
print "Started the Release workflow ($BUMP)."
run=""
for _ in {1..60}; do
  for id in ${(f)"$(runs)"}; do
    (( ${before[(Ie)$id]} )) || { run=$id; break; }
  done
  [[ -n $run ]] && break
  sleep 2
done
[[ -n $run ]] || die "the run didn't show up; see https://github.com/$REPO/actions/workflows/release.yml"
print "Following https://github.com/$REPO/actions/runs/$run (about 5 minutes)"

if [[ -t 1 ]]; then
  gh run watch "$run" --repo "$REPO" --exit-status --interval 10 || failed=1
else
  gh run watch "$run" --repo "$REPO" --exit-status --interval 15 >/dev/null 2>&1 || failed=1
fi
if (( ${failed:-0} )); then
  gh run view "$run" --repo "$REPO" --log-failed 2>/dev/null | cut -f3- | tail -30
  die "the release failed (log above); fix it, push, and run make release again"
fi

git fetch -q --tags origin main
git merge -q --ff-only origin/main 2>/dev/null || print "note: run git pull to get the release commit"
tag=$(gh release view --repo "$REPO" --json tagName --jq .tagName)
print "Published Murmur ${tag#v}: https://github.com/$REPO/releases/tag/$tag"
