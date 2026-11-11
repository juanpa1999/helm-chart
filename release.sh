#!/usr/bin/env bash
# Bumps the version of every chart that changed since the last release, packages it
# into charts/ and regenerates index.yaml (merging, so existing entries stay intact).
#
# "Last release" = last commit that touched index.yaml (override with --since <ref>).
# A chart counts as changed if it differs from that ref, including uncommitted and
# untracked files. If its current version is not packaged yet (you bumped it by hand),
# it is packaged as is instead of bumped again.
#
# Usage: ./release.sh [-b patch|minor|major] [--since <git-ref>] [--dry-run] [chart...]
#   chart...  only consider these charts (default: every dir with a Chart.yaml)
set -euo pipefail

REPO_URL="https://juanpa1999.github.io/helm-chart"
CHARTS_DIR="charts"
BUMP="patch"
SINCE=""
DRY_RUN=false
ONLY=()

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bump)  BUMP="$2"; shift 2 ;;
    --since)    SINCE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  usage ;;
    -*)         echo "Unknown option: $1" >&2; usage 1 ;;
    *)          ONLY+=("${1%/}"); shift ;;
  esac
done

[[ "$BUMP" =~ ^(patch|minor|major)$ ]] || { echo "Invalid bump: $BUMP" >&2; exit 1; }
command -v helm >/dev/null || { echo "helm not found" >&2; exit 1; }

cd "$(dirname "$0")"

if [[ -z "$SINCE" ]]; then
  SINCE=$(git log -1 --format=%H -- index.yaml)
  [[ -n "$SINCE" ]] || { echo "index.yaml has no history, use --since <ref>" >&2; exit 1; }
fi
echo "Comparing against $(git log -1 --format='%h %s' "$SINCE")"

chart_version() { sed -n 's/^version:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$1/Chart.yaml"; }

bump_version() {
  local major minor patch
  IFS=. read -r major minor patch <<<"${1%%[-+]*}"
  case "$BUMP" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

is_changed() {
  ! git diff --quiet "$SINCE" -- "$1" ||
    [[ -n "$(git ls-files --others --exclude-standard -- "$1")" ]]
}

if [[ ${#ONLY[@]} -gt 0 ]]; then
  CANDIDATES=("${ONLY[@]}")
else
  CANDIDATES=()
  for f in */Chart.yaml; do
    d="${f%/Chart.yaml}"
    [[ "$d" == "$CHARTS_DIR" ]] || CANDIDATES+=("$d")
  done
fi

TO_PACKAGE=()
for chart in "${CANDIDATES[@]}"; do
  [[ -f "$chart/Chart.yaml" ]] || { echo "Not a chart: $chart" >&2; exit 1; }
  is_changed "$chart" || continue

  name=$(sed -n 's/^name:[[:space:]]*//p' "$chart/Chart.yaml" | tr -d '"')
  current=$(chart_version "$chart")

  if [[ -f "$CHARTS_DIR/$name-$current.tgz" ]]; then
    next=$(bump_version "$current")
    echo "  $name: $current -> $next"
    if ! $DRY_RUN; then
      sed "s/^version:.*/version: $next/" "$chart/Chart.yaml" >"$chart/Chart.yaml.tmp"
      mv "$chart/Chart.yaml.tmp" "$chart/Chart.yaml"
    fi
  else
    echo "  $name: $current (already bumped, not packaged yet)"
  fi
  TO_PACKAGE+=("$chart")
done

if [[ ${#TO_PACKAGE[@]} -eq 0 ]]; then
  echo "No charts changed since the last release."
  exit 0
fi

if $DRY_RUN; then
  echo "Dry run: nothing written."
  exit 0
fi

helm lint "${TO_PACKAGE[@]}"
helm package "${TO_PACKAGE[@]}" -d "$CHARTS_DIR"
helm repo index . --url "$REPO_URL" --merge index.yaml

echo
echo "Done. Review and publish:"
echo "  git diff --stat"
echo "  git add ${TO_PACKAGE[*]/%//Chart.yaml} $CHARTS_DIR index.yaml"
echo "  git commit -m 'release charts' && git push"
