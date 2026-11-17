#!/usr/bin/env bash
set -euo pipefail

COMPARE_BRANCH=""
GUI_MODE=false
VERBOSE=false
MEMORY_LIMIT="-1"
OUTPUT_DIR="/output"
PROJECT_DIR="/project"
PH_ARGS=()
ORIG_ARGS=("$@")

usage() {
  cat <<EOF
Magento 2 Upgrade Patch Helper (Docker)

Usage:
  docker run --rm \\
    -v "\$PWD:/project:ro" \\
    -v "\$PWD/upgrade-output:/output" \\
    samjuk/magento2-upgrade-patch-helper:8.3 --branch origin/production [-- PATCH_HELPER_ARGS]

Flags:
  --branch REF       Required. Git ref to compare against, the version you are
                     upgrading from (origin/production, main, v2.4.6).
                     Must exist in the local repo (run git fetch first).
  --gui              Also write classmap.json and vendor_orig.tar.gz for
                     elgentos/magento2-upgrade-gui
  --show-info        Pass --show-info to patch-helper
  --sort-by-type     Pass --sort-by-type to patch-helper
  --memory-limit N   PHP memory_limit (default: -1)
  --output DIR       Container-side output path (default: /output)
  --verbose          Show composer output
  -- ARGS            Pass the remaining arguments to patch-helper analyse,
                     e.g. -- --vendor-namespaces=Acme --show-ignore

Environment:
  COMPOSER_AUTH      Composer auth JSON (alternative to mounting auth.json)

Volumes:
  /project                    Magento root, read-only is fine
  /output                     Results
  /root/.composer/cache       Composer cache, speeds up repeat runs
  /root/.composer/auth.json   Composer auth for repo.magento.com and private repos

Exit codes: 0 analysis ran, 1 analysis or setup failed, 2 usage error.
EOF
  exit "${1:-0}"
}

die() { echo "Error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)       [[ $# -ge 2 ]] || usage 2; COMPARE_BRANCH="$2"; shift 2 ;;
    --branch=*)     COMPARE_BRANCH="${1#*=}"; shift ;;
    --gui)          GUI_MODE=true; shift ;;
    --show-info)    PH_ARGS+=(--show-info); shift ;;
    --sort-by-type) PH_ARGS+=(--sort-by-type); shift ;;
    --memory-limit) [[ $# -ge 2 ]] || usage 2; MEMORY_LIMIT="$2"; shift 2 ;;
    --output)       [[ $# -ge 2 ]] || usage 2; OUTPUT_DIR="$2"; shift 2 ;;
    --verbose|-v)   VERBOSE=true; shift ;;
    --help|-h)      usage 0 ;;
    --)             shift; PH_ARGS+=("$@"); break ;;
    *) echo "Unknown flag: $1" >&2; usage 2 ;;
  esac
done

[[ -n "$COMPARE_BRANCH" ]] || { echo "Error: --branch is required" >&2; usage 2; }

# Run as whoever owns the output directory, so results are not root-owned on Linux hosts
if [[ "$(id -u)" == 0 && -d "$OUTPUT_DIR" ]]; then
  owner="$(stat -c '%u:%g' "$OUTPUT_DIR")"
  if [[ "${owner%%:*}" != 0 ]]; then
    if [[ -z "${COMPOSER_AUTH:-}" && -r "$COMPOSER_HOME/auth.json" ]]; then
      COMPOSER_AUTH="$(cat "$COMPOSER_HOME/auth.json")"
      export COMPOSER_AUTH
    fi
    # Without CAP_SETUID (--cap-drop ALL) carry on as root
    if su-exec "$owner" true 2>/dev/null; then
      export HOME=/tmp
      exec su-exec "$owner" "$0" "${ORIG_ARGS[@]}"
    fi
  fi
fi

[[ -d "$PROJECT_DIR" ]] || die "$PROJECT_DIR is not mounted. Add -v /path/to/magento:$PROJECT_DIR:ro"
[[ -f "$PROJECT_DIR/composer.json" ]] || die "no composer.json in $PROJECT_DIR, mount the Magento root"
[[ -f "$PROJECT_DIR/app/etc/config.php" ]] || die "no app/etc/config.php in $PROJECT_DIR, mount the Magento root"

if [[ -f "$PROJECT_DIR/.git" ]]; then
  gitdir="$(sed -n 's/^gitdir: //p' "$PROJECT_DIR/.git")"
  [[ -d "$gitdir" ]] || die "$PROJECT_DIR is a git worktree whose git directory is not mounted.
       Also mount the main repository's .git at the same path, read-only:
       -v ${gitdir%/.git/worktrees/*}/.git:${gitdir%/.git/worktrees/*}/.git:ro"
fi
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJECT_DIR is not a git repository"
git -C "$PROJECT_DIR" rev-parse --verify --quiet "$COMPARE_BRANCH^{tree}" >/dev/null \
  || die "'$COMPARE_BRANCH' not found in $PROJECT_DIR (run git fetch on the host if it is a remote branch)"
[[ -d "$PROJECT_DIR/vendor" ]] || die "$PROJECT_DIR/vendor not found, run composer install for the version you are upgrading to"

mkdir -p "$OUTPUT_DIR" 2>/dev/null && [[ -w "$OUTPUT_DIR" ]] \
  || die "cannot write to $OUTPUT_DIR (running as uid $(id -u))"
mountpoint -q "$OUTPUT_DIR" \
  || echo "Warning: $OUTPUT_DIR is not a mounted volume, results will be lost when the container exits" >&2

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

composer_quiet() {
  if [[ "$VERBOSE" == true ]]; then
    composer "$@"
  elif ! composer "$@" >"$WORK/composer.log" 2>&1; then
    tail -n 40 "$WORK/composer.log" >&2
    return 1
  fi
}

step "[1/5] Extracting '$COMPARE_BRANCH'"
mkdir "$WORK/compare"
git -C "$PROJECT_DIR" archive "$COMPARE_BRANCH" | tar -x -C "$WORK/compare"
[[ -f "$WORK/compare/composer.lock" ]] \
  || echo "Warning: '$COMPARE_BRANCH' has no composer.lock, its vendor/ will be resolved fresh and may not match what was deployed" >&2

# Match the project's dev/no-dev install, or every dev package shows up as added
dev_flag=--no-dev
php -r 'exit(empty(json_decode(file_get_contents($argv[1]), true)["dev"]) ? 1 : 0);' \
  "$PROJECT_DIR/vendor/composer/installed.json" 2>/dev/null && dev_flag=--dev

step "[2/5] Installing vendor/ for '$COMPARE_BRANCH' ($dev_flag)"
composer_quiet install -d "$WORK/compare" "$dev_flag" --no-progress --no-scripts --no-plugins \
  --no-autoloader --ignore-platform-reqs \
  || die "composer install failed for '$COMPARE_BRANCH' (private packages need auth.json or COMPOSER_AUTH)"

step "[3/5] Copying project"
mkdir "$WORK/project"
# ponytail: var/, generated/, static and media are rebuilt or unused by the analysis, and can be huge
tar -C "$PROJECT_DIR" -cf - \
  --exclude=./.git --exclude=./app/etc/env.php --exclude=./var --exclude=./generated \
  --exclude=./pub/static --exclude=./pub/media --exclude=node_modules . \
  | tar -xf - -C "$WORK/project"
mv "$WORK/compare/vendor" "$WORK/project/vendor_orig"
rm -rf "$WORK/compare"

step "[4/5] Diffing vendor/"
cd "$WORK/project"
rc=0
diff -urN vendor_orig/ vendor/ >vendor.patch || rc=$?
(( rc <= 1 )) || die "diff failed (exit $rc)"
[[ -s vendor.patch ]] || echo "Warning: vendor/ is identical to '$COMPARE_BRANCH', nothing to analyse" >&2
echo "    vendor.patch: $(grep -c '^diff ' vendor.patch || true) files changed"

php_needs="$(composer check-platform-reqs --lock --no-dev --format=json 2>/dev/null | php -r '
  foreach (json_decode(stream_get_contents(STDIN), true) ?: [] as $r) {
    if ($r["name"] === "php" && $r["status"] === "failed") {
      echo $r["failed_requirement"]["constraint"], " (", $r["failed_requirement"]["source"], ")";
    }
  }' || true)"
[[ -z "$php_needs" ]] \
  || echo "Warning: this image runs PHP $(php -r 'echo PHP_VERSION;'), the project needs php $php_needs. Use the matching image tag." >&2

step "[5/5] Running patch-helper"
rc=0
php -d memory_limit="$MEMORY_LIMIT" /patch-helper/bin/patch-helper.php analyse "${PH_ARGS[@]}" . \
  2>&1 | tee patch-helper-output.txt || rc=$?

if [[ "$GUI_MODE" == true && $rc == 0 ]]; then
  step "Writing GUI files"
  composer_quiet dump-autoload --classmap-authoritative
  # The GUI joins these paths onto the directory it opens, so make them relative to the project root
  # shellcheck disable=SC2016
  php -r '
    $root = getcwd() . "/";
    $map = array_map(
        fn ($f) => str_starts_with($f, $root) ? substr($f, strlen($root)) : $f,
        require "vendor/composer/autoload_classmap.php"
    );
    echo json_encode($map, JSON_INVALID_UTF8_SUBSTITUTE | JSON_THROW_ON_ERROR);' >classmap.json
  tar -czf vendor_orig.tar.gz vendor_orig/
fi

for f in vendor.patch vendor_files_to_check.patch patch-helper-output.txt classmap.json vendor_orig.tar.gz; do
  [[ -f "$f" ]] && cp "$f" "$OUTPUT_DIR/"
done
echo "Results written to $OUTPUT_DIR"

if (( rc != 0 )); then
  echo "Error: patch-helper failed (exit $rc), see patch-helper-output.txt" >&2
  exit 1
fi

if [[ "$GUI_MODE" == true ]]; then
  cat <<EOF

GUI (https://github.com/elgentos/magento2-upgrade-gui/releases):
  1. Copy everything in the output directory into your Magento root
  2. In the Magento root: tar -xzf vendor_orig.tar.gz
  3. Open the Magento root in the app
EOF
fi
