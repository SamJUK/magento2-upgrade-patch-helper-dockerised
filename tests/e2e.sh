#!/usr/bin/env bash
set -uo pipefail

IMAGE_REF="${IMAGE_REF:-upgrade-patch-helper-test:8.2}"
FIXTURES="$(cd "$(dirname "$0")/fixtures" && pwd)"
PASS=0
FAIL=0

FIXTURE_DIR=""
OUTPUT_DIR=""
NOLOCK_DIR=""
NOLOCK_OUT_DIR=""

cleanup() {
  rm -rf "$FIXTURE_DIR" "$OUTPUT_DIR" "$NOLOCK_DIR" "$NOLOCK_OUT_DIR"
}
trap cleanup EXIT

# ── Assertion helpers ─────────────────────────────────────────────────────────

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 — ${2:-}"; FAIL=$((FAIL+1)); }

assert_exit_0()   { [[ "${2:-1}" -eq 0 ]] && pass "$1" || fail "$1" "exit code: ${2}"; }
assert_contains() { echo "${3:-}" | grep -qF "$2" && pass "$1" || fail "$1" "missing: $2"; }
assert_file()     { [[ -f "$2"   ]] && pass "$1" || fail "$1" "not found: $2"; }
assert_nonempty() { [[ -s "$2"   ]] && pass "$1" || fail "$1" "empty: $2"; }

# ── Fixture setup ─────────────────────────────────────────────────────────────

setup_fixture() {
  FIXTURE_DIR="$(mktemp -d)"
  OUTPUT_DIR="$(mktemp -d)"

  git -C "$FIXTURE_DIR" init -b main -q
  git -C "$FIXTURE_DIR" config user.email "test@test.local"
  git -C "$FIXTURE_DIR" config user.name "Test"

  # v1: copy package files, install, commit (no vendor/ — entrypoint reinstalls from lock)
  cp "$FIXTURES/root-composer.json" "$FIXTURE_DIR/composer.json"
  mkdir -p "$FIXTURE_DIR/local-packages"
  cp -r "$FIXTURES/v1/." "$FIXTURE_DIR/local-packages/"

  composer install -d "$FIXTURE_DIR" \
    --no-dev --no-interaction --no-scripts --no-plugins --ignore-platform-reqs --quiet

  git -C "$FIXTURE_DIR" add local-packages composer.json composer.lock
  git -C "$FIXTURE_DIR" commit -q -m "v1"
  OLD_REF="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"

  # v2: update package to new version, install updated vendor, add theme override
  cp -r "$FIXTURES/v2/." "$FIXTURE_DIR/local-packages/"

  composer update magento/module-fake -d "$FIXTURE_DIR" \
    --no-dev --no-interaction --no-scripts --no-plugins --ignore-platform-reqs --quiet

  mkdir -p "$FIXTURE_DIR/app/design/frontend/Custom/theme/Magento_FakeModule/templates"
  cp "$FIXTURES/override/widget.phtml" \
     "$FIXTURE_DIR/app/design/frontend/Custom/theme/Magento_FakeModule/templates/widget.phtml"

  git -C "$FIXTURE_DIR" add -A
  git -C "$FIXTURE_DIR" commit -q -m "v2"
}

run_container() {
  docker run --rm \
    -v "$FIXTURE_DIR:/project:ro" \
    -v "$OUTPUT_DIR:/output" \
    "$IMAGE_REF" "$@"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

echo "Setting up fixture..."
setup_fixture

echo ""
echo "==> basic run"
OUT=""; CODE=0
OUT="$(run_container --branch "$OLD_REF" 2>&1)" || CODE=$?
assert_exit_0   "exits 0"             "$CODE"
assert_contains "step headers present" "[1/5]"  "$OUT"
assert_contains "ends with Done."      "Done."  "$OUT"

echo ""
echo "==> output files"
assert_file     "vendor.patch created"             "$OUTPUT_DIR/vendor.patch"
assert_nonempty "vendor.patch non-empty"           "$OUTPUT_DIR/vendor.patch"
assert_file     "patch-helper-output.txt created"  "$OUTPUT_DIR/patch-helper-output.txt"

echo ""
echo "==> vendor diff content"
grep -q "Widget.php"   "$OUTPUT_DIR/vendor.patch" \
  && pass "diff contains Widget.php"   || fail "diff contains Widget.php"   "not found"
grep -q "widget.phtml" "$OUTPUT_DIR/vendor.patch" \
  && pass "diff contains widget.phtml" || fail "diff contains widget.phtml" "not found"

echo ""
echo "==> GUI mode"
rm -f "$OUTPUT_DIR"/*
OUT=""; CODE=0
OUT="$(run_container --branch "$OLD_REF" --gui 2>&1)" || CODE=$?
assert_exit_0   "--gui exits 0"           "$CODE"
assert_contains "GUI instructions shown"  "GUI instructions" "$OUT"
assert_file     "classmap.json created"   "$OUTPUT_DIR/classmap.json"
assert_file     "vendor.tar.gz created"   "$OUTPUT_DIR/vendor.tar.gz"
assert_nonempty "vendor.tar.gz non-empty" "$OUTPUT_DIR/vendor.tar.gz"

echo ""
echo "==> compare branch without composer.lock"
NOLOCK_DIR="$(mktemp -d)"
NOLOCK_OUT_DIR="$(mktemp -d)"

git -C "$NOLOCK_DIR" init -b main -q
git -C "$NOLOCK_DIR" config user.email "test@test.local"
git -C "$NOLOCK_DIR" config user.name "Test"
cp "$FIXTURES/root-composer.json" "$NOLOCK_DIR/composer.json"
mkdir -p "$NOLOCK_DIR/local-packages"
cp -r "$FIXTURES/v1/." "$NOLOCK_DIR/local-packages/"

# Commit v1 WITHOUT composer.lock — that is what this test exercises
git -C "$NOLOCK_DIR" add local-packages composer.json
git -C "$NOLOCK_DIR" commit -q -m "v1 no lock"
NOLOCK_REF="$(git -C "$NOLOCK_DIR" rev-parse HEAD)"

# Install vendor so /project passes the vendor/ validation check
composer install -d "$NOLOCK_DIR" \
  --no-dev --no-interaction --no-scripts --no-plugins --ignore-platform-reqs --quiet
git -C "$NOLOCK_DIR" add -A
git -C "$NOLOCK_DIR" commit -q -m "v2"

OUT=""; CODE=0
OUT="$(docker run --rm \
  -v "$NOLOCK_DIR:/project:ro" \
  -v "$NOLOCK_OUT_DIR:/output" \
  "$IMAGE_REF" --branch "$NOLOCK_REF" 2>&1)" || CODE=$?
assert_exit_0   "exits 0 without composer.lock"  "$CODE"
assert_contains "no-lock warning printed"         "Warning: compare branch has no composer.lock" "$OUT"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
