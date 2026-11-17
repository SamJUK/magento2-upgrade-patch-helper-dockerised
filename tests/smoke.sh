#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-upgrade-patch-helper-test:8.3}"
in_image() { docker run --rm --entrypoint "$1" "$IMAGE_REF" "${@:2}"; }

echo "==> --help exits 0"
docker run --rm "$IMAGE_REF" --help >/dev/null

echo "==> no arguments exits 2"
code=0; docker run --rm "$IMAGE_REF" >/dev/null 2>&1 || code=$?
[[ $code == 2 ]] || { echo "FAIL: expected exit 2, got $code"; exit 1; }

echo "==> GNU patch and diff (patch-helper needs patch -F, busybox lacks it)"
[[ "$(in_image patch --version)" == *'GNU patch'* ]]
[[ "$(in_image diff --version)" == *'GNU diffutils'* ]]

echo "==> patch-helper loads"
[[ "$(in_image php /patch-helper/bin/patch-helper.php list)" == *analyse* ]]

echo "==> runs as an arbitrary uid"
docker run --rm --user 4242:4242 "$IMAGE_REF" --help >/dev/null

echo "Smoke test passed."
