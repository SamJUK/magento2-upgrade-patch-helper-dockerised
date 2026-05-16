#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${IMAGE_REF:-upgrade-patch-helper-test:8.2}"

echo "==> Smoke test: docker run $IMAGE_REF --help"
docker run --rm "$IMAGE_REF" --help
echo "==> Smoke test passed."
