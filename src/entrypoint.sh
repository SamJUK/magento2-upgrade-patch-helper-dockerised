#!/usr/bin/env bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
COMPARE_BRANCH=""
GUI_MODE=false
SHOW_INFO=false
SORT_BY_TYPE=false
MEMORY_LIMIT="-1"
OUTPUT_DIR="/output"
PH_ARGS=""

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Magento 2 Upgrade Patch Helper — Docker wrapper

Usage:
  docker run --rm \\
    -v /path/to/project:/project:ro \\
    -v /path/to/output:/output \\
    upgrade-patch-helper --branch origin/production

Flags:
  --branch REF       Required. Git branch/tag/ref to compare against
                     (e.g. origin/production, main, v2.4.6)
                     Must exist in the local repo (run git fetch first)
  --gui              Generate GUI artifacts: vendor.tar.gz + classmap.json
                     (open output dir in elgentos/magento2-upgrade-gui)
  --show-info        Pass --show-info to patch-helper
  --sort-by-type     Pass --sort-by-type to patch-helper
  --memory-limit N   PHP memory_limit value (default: -1)
  --output DIR       Container-side output path (default: /output)

Environment:
  COMPOSER_AUTH      JSON string for composer authentication
                     (alternative to mounting auth.json)

Volumes:
  /project           Your Magento root — read-only is safe and recommended
  /output            Where results are written
  ~/.composer/cache  Mount for composer cache (speeds up repeated runs)
  ~/.composer/auth.json  Composer auth — mount or use COMPOSER_AUTH env var

EOF
  exit "${1:-0}"
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)       COMPARE_BRANCH="$2"; shift 2 ;;
    --gui)          GUI_MODE=true;       shift   ;;
    --show-info)    SHOW_INFO=true;      shift   ;;
    --sort-by-type) SORT_BY_TYPE=true;   shift   ;;
    --memory-limit) MEMORY_LIMIT="$2";   shift 2 ;;
    --output)       OUTPUT_DIR="$2";     shift 2 ;;
    --help|-h)      usage 0 ;;
    *) echo "Unknown flag: $1" >&2; usage 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -z "$COMPARE_BRANCH" ]] && { echo "Error: --branch is required" >&2; usage 1; }

[[ ! -d "/project" ]] && {
  echo "Error: /project is not mounted. Add -v /path/to/magento:/project:ro" >&2
  exit 1
}
[[ ! -f "/project/composer.json" ]] && {
  echo "Error: no composer.json found in /project" >&2
  exit 1
}
[[ ! -d "/project/.git" ]] && {
  echo "Error: /project is not a git repository" >&2
  echo "       The project must be a git repo so we can extract the compare branch" >&2
  exit 1
}
[[ ! -d "/project/vendor" ]] && {
  echo "Error: /project/vendor not found" >&2
  echo "       Run 'composer install' in your project before running this tool" >&2
  exit 1
}

# Verify the branch/ref exists in the repo before we do any heavy work
if ! git --git-dir=/project/.git rev-parse --verify "$COMPARE_BRANCH^{tree}" &>/dev/null; then
  echo "Error: '$COMPARE_BRANCH' not found in /project git history" >&2
  echo "       Run 'git fetch' in your project if it's a remote ref" >&2
  exit 1
fi

# ── Composer auth ─────────────────────────────────────────────────────────────
if [[ -n "${COMPOSER_AUTH:-}" ]]; then
  mkdir -p /root/.composer
  printf '%s' "$COMPOSER_AUTH" > /root/.composer/auth.json
  chmod 600 /root/.composer/auth.json
fi

# ── Step 1: extract compare branch ────────────────────────────────────────────
echo ""
echo "==> [1/5] Extracting '$COMPARE_BRANCH' into /work/compare..."
rm -rf /work/compare && mkdir -p /work/compare
git --git-dir=/project/.git archive "$COMPARE_BRANCH" | tar x -C /work/compare

[[ ! -f "/work/compare/composer.lock" ]] && {
  echo "Warning: compare branch has no composer.lock — install may resolve differently" >&2
}

# ── Step 2: install compare-branch vendor ─────────────────────────────────────
echo "==> [2/5] Installing compare-branch vendor (from its composer.lock)..."
cd /work/compare
composer install \
  --no-dev \
  --no-interaction \
  --no-scripts \
  --no-plugins \
  --ignore-platform-reqs

# ── Step 3: set up working project directory ──────────────────────────────────
echo "==> [3/5] Setting up working project directory..."
rm -rf /work/project && mkdir -p /work/project

# Copy project without vendor (vendor handled separately below)
(cd /project && tar \
  --exclude='./app/etc/env.php' \
  --exclude='./.git' \
  -cf - .) | tar xf - -C /work/project

# Move compare-branch vendor into place as the baseline
mv /work/compare/vendor /work/project/vendor_orig

# ── Step 4: generate diff and run patch-helper ────────────────────────────────
echo "==> [4/5] Generating vendor diff..."
cd /work/project
diff -urN vendor_orig/ vendor/ > vendor.patch || true   # diff exits 1 when diffs exist
echo "    vendor.patch: $(wc -c < vendor.patch | tr -d ' ') bytes"

echo "==> [4/5] Running patch-helper analysis..."
[[ "$SHOW_INFO" == "true" ]]    && PH_ARGS="$PH_ARGS --show-info"
[[ "$SORT_BY_TYPE" == "true" ]] && PH_ARGS="$PH_ARGS --sort-by-type"

# shellcheck disable=SC2086
if ! php -d memory_limit="$MEMORY_LIMIT" \
  /patch-helper/bin/patch-helper.php analyse \
  $PH_ARGS \
  . \
  | tee patch-helper-output.txt; then
    echo "Warning: patch-helper analysis failed — output may be incomplete" >&2
    echo "         Is /project a valid Magento 2 installation?" >&2
fi

# ── Step 5: GUI artifacts ─────────────────────────────────────────────────────
if [[ "$GUI_MODE" == "true" ]]; then
  echo "==> [5/5] Generating GUI artifacts..."
  cd /work/project

  composer dump --classmap-authoritative --no-interaction 2>&1
  php -r "\$c = require_once 'vendor/composer/autoload_classmap.php'; echo json_encode(\$c);" \
    > classmap.json

  echo "    Compressing vendor/ for GUI (this may take a moment)..."
  tar -czf vendor.tar.gz vendor/
  echo "    vendor.tar.gz: $(du -sh vendor.tar.gz | cut -f1)"
fi

# ── Write output ──────────────────────────────────────────────────────────────
echo ""
echo "==> Writing results to $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"

for f in vendor.patch vendor_files_to_check.patch patch-helper-output.txt classmap.json vendor.tar.gz; do
  if [[ -f "/work/project/$f" ]]; then
    cp "/work/project/$f" "$OUTPUT_DIR/"
    echo "    ✓ $f"
  fi
done

echo ""
echo "Done."

if [[ "$GUI_MODE" == "true" ]]; then
  cat <<EOF

GUI instructions:
  1. Download the Electron app from:
     https://github.com/elgentos/magento2-upgrade-gui/releases
  2. Unpack vendor.tar.gz inside $OUTPUT_DIR:
       cd $OUTPUT_DIR && tar xzf vendor.tar.gz
  3. Open the app and point it to $OUTPUT_DIR

EOF
fi
