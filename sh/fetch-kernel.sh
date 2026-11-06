#!/usr/bin/env bash
# Find/download the latest successful `mainline` branch kernel artifact so the
# rootfs builder can install its modules into the image.
set -euo pipefail

REPO="${REPO:-farmeixx/msm8953-albus-mainline}"
ARTIFACT="${ARTIFACT:-albus-mainline}"
WORKFLOW="${WORKFLOW:-mainline.yml}"
BRANCH="${BRANCH:-mainline}"
OUT="${OUT_DIR:-$PWD/.work/kernel}"

command -v gh >/dev/null || { echo 'gh CLI required to fetch the kernel artifact' >&2; exit 1; }

run_id="$(gh run list \
  --repo "$REPO" \
  --workflow "$WORKFLOW" \
  --branch "$BRANCH" \
  --status success \
  --limit 1 \
  --json databaseId --jq '.[0].databaseId')"
[ -n "$run_id" ] || { echo "no successful $WORKFLOW run found in $REPO" >&2; exit 1; }

echo "using kernel artifact from run $run_id"
rm -rf "$OUT"
mkdir -p "$OUT"
gh run download "$run_id" --repo "$REPO" --name "$ARTIFACT" --dir "$OUT"

test -s "$OUT/modules.tar.gz" || { echo 'kernel artifact missing modules.tar.gz' >&2; exit 1; }
test -s "$OUT/kernel-release.txt" || { echo 'kernel artifact missing kernel-release.txt' >&2; exit 1; }
echo "kernel release: $(cat "$OUT/kernel-release.txt")"
