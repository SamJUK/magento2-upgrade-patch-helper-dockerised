#!/usr/bin/env bash
# End-to-end tests against a real Mage-OS upgrade (MAGEOS_FROM -> MAGEOS_TO) with a
# preference, a plugin and a theme override on files that change between the two.
# Composer runs inside the image under test, so the host needs only Docker and git.
set -uo pipefail

IMAGE_REF="${IMAGE_REF:-upgrade-patch-helper-test:8.3}"
MAGEOS_FROM="${MAGEOS_FROM:-3.5.0}"
MAGEOS_TO="${MAGEOS_TO:-3.6.0}"
TESTS="$(cd "$(dirname "$0")" && pwd)"
CACHE="${CACHE_DIR:-$TESTS/.cache}"
COMPOSER_CACHE="${COMPOSER_CACHE_DIR:-$CACHE/composer}"
FIXTURE="$CACHE/mageos-$MAGEOS_FROM-$MAGEOS_TO"
OVERRIDE=app/design/frontend/Acme/theme/MageOS_RMA/templates/customer/rma/history.phtml
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 (${2:-})"; FAIL=$((FAIL+1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name" "$*"; fi; }
has() { [[ "$2" == *"$1"* ]]; }

as_host_user() {
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e COMPOSER_HOME=/tmp/composer \
    -e COMPOSER_CACHE_DIR=/cache -v "$COMPOSER_CACHE:/cache" "$@"
}

fixture_git() {
  git -C "$FIXTURE" -c user.name=test -c user.email=test@test.local -c commit.gpgSign=false "$@"
}

build_fixture() {
  [[ -f "$FIXTURE/.fixture-ok" ]] && return
  echo "Building Mage-OS $MAGEOS_FROM -> $MAGEOS_TO fixture (cached in $FIXTURE)..."
  rm -rf "$FIXTURE" && mkdir -p "$FIXTURE" "$COMPOSER_CACHE"
  local run=(as_host_user -v "$FIXTURE:/app" -w /app)

  "${run[@]}" --entrypoint composer "$IMAGE_REF" create-project -q --no-progress --ignore-platform-reqs \
    --repository-url=https://repo.mage-os.org/ "mage-os/project-community-edition=$MAGEOS_FROM" . || return 1
  "${run[@]}" --entrypoint php "$IMAGE_REF" -d memory_limit=-1 bin/magento module:enable --all >/dev/null || return 1
  printf '/vendor/\n/generated/\n/var/\n/pub/static/\n/pub/media/\n/dev/\n' >"$FIXTURE/.gitignore"
  git -C "$FIXTURE" init -q -b main
  fixture_git add -A && fixture_git commit -qm "Mage-OS $MAGEOS_FROM"

  cp -R "$TESTS/fixtures/mageos/." "$FIXTURE/"
  mkdir -p "$(dirname "$FIXTURE/$OVERRIDE")"
  cp "$FIXTURE/vendor/mage-os/module-rma/view/frontend/templates/customer/rma/history.phtml" "$FIXTURE/$OVERRIDE"
  sed -i.bak "s/'MageOS_RMA' => 1,/'MageOS_RMA' => 1,\n        'Acme_Upgrade' => 1,/" "$FIXTURE/app/etc/config.php"
  rm "$FIXTURE/app/etc/config.php.bak"
  fixture_git add -A && fixture_git commit -qm "customisations"

  sed -i.bak "s#\(\"mage-os/[a-z-]*\": \)\"$MAGEOS_FROM\"#\1\"$MAGEOS_TO\"#" "$FIXTURE/composer.json"
  rm "$FIXTURE/composer.json.bak"
  "${run[@]}" --entrypoint composer "$IMAGE_REF" update -q -W --no-progress --ignore-platform-reqs || return 1
  fixture_git add -A && fixture_git commit -qm "Mage-OS $MAGEOS_TO"
  touch "$FIXTURE/.fixture-ok"
}

# run <output dir> [docker args...] -- [image args...]
run() {
  local out="$1"; shift
  local docker_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do docker_args+=("$1"); shift; done
  shift
  OUT=""; CODE=0
  OUT="$(docker run --rm -v "$FIXTURE:/project:ro" -v "$out:/output" \
    -v "$COMPOSER_CACHE:/root/.composer/cache" "${docker_args[@]}" "$IMAGE_REF" "$@" 2>&1)" || CODE=$?
}

new_out() { local d; d="$(mktemp -d "$TMP/out.XXXX")"; chmod 777 "$d"; echo "$d"; }

image_php="$(docker run --rm --entrypoint php "$IMAGE_REF" -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;')"

echo "==> error handling"
EMPTY="$TMP/empty"; mkdir -p "$EMPTY/app/etc"; echo '{}' >"$EMPTY/composer.json"; touch "$EMPTY/app/etc/config.php"
OUT="$(docker run --rm -v "$EMPTY:/project:ro" "$IMAGE_REF" --branch main 2>&1)"; CODE=$?
check "not a git repo exits 1" [ "$CODE" = 1 ]
check "not a git repo message" has "not a git repository" "$OUT"

git -C "$EMPTY" init -q -b main
git -C "$EMPTY" -c user.name=t -c user.email=t@t -c commit.gpgSign=false add -A
git -C "$EMPTY" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -qm init
OUT="$(docker run --rm -v "$EMPTY:/project:ro" "$IMAGE_REF" --branch nope 2>&1)"; CODE=$?
check "unknown ref exits 1" [ "$CODE" = 1 ]
check "unknown ref message" has "'nope' not found" "$OUT"

OUT="$(docker run --rm -v "$EMPTY:/project:ro" "$IMAGE_REF" --branch main 2>&1)"; CODE=$?
check "missing vendor/ message" has "vendor not found" "$OUT"

mkdir "$EMPTY/vendor"
OUT="$(docker run --rm -v "$EMPTY:/project:ro" "$IMAGE_REF" --branch main 2>&1)"; CODE=$?
check "failed analysis exits 1" [ "$CODE" = 1 ]
check "failed analysis reported" has "patch-helper failed" "$OUT"
check "no composer.lock warning" has "has no composer.lock" "$OUT"
check "unmounted /output warning" has "not a mounted volume" "$OUT"

OUT="$(docker run --rm "$IMAGE_REF" --branch main --bogus 2>&1)"; CODE=$?
check "unknown flag exits 2" [ "$CODE" = 2 ]

if (( image_php < 83 )); then
  echo ""
  echo "SKIP: Mage-OS $MAGEOS_TO needs PHP 8.3+, image has $image_php"
else
  build_fixture || { echo "Fixture build failed"; exit 1; }

  echo ""
  echo "==> analysis of a real upgrade"
  out="$(new_out)"
  run "$out" -- --branch HEAD~1
  check "exits 0" [ "$CODE" = 0 ]
  check "preference flagged" has "Acme\\Upgrade\\Model\\GetCustomerByToken" "$OUT"
  check "plugin flagged" has "FilterPlugin::afterInlinecssDirective" "$OUT"
  check "template override flagged" has "$OVERRIDE" "$OUT"
  check "dev packages not reported as added" has "--dev)" "$OUT"
  check "patch-helper-output.txt written" [ -s "$out/patch-helper-output.txt" ]
  check "vendor_files_to_check.patch written" [ -s "$out/vendor_files_to_check.patch" ]
  check "vendor.patch written" [ -s "$out/vendor.patch" ]

  echo ""
  echo "==> project files cannot stand in for results"
  out="$(new_out)"
  echo stale >"$out/classmap.json"
  ln -s /proc/self/environ "$FIXTURE/vendor_orig.tar.gz"
  run "$out" -e 'COMPOSER_AUTH={"http-basic":{"example.test":{"username":"CANARY-7f3a","password":"x"}}}' -- --branch HEAD~1
  rm -f "$FIXTURE/vendor_orig.tar.gz"
  check "exits 0" [ "$CODE" = 0 ]
  check "override still flagged" has "$OVERRIDE" "$OUT"
  ! grep -rqa CANARY-7f3a "$out"; check "credentials not copied into /output" [ $? = 0 ]
  check "stale result from an earlier run removed" [ ! -e "$out/classmap.json" ]

  echo ""
  echo "==> output ownership"
  owned="$TMP/owned"; mkdir "$owned"
  run "$owned" -- --branch HEAD~1
  check "exits 0" [ "$CODE" = 0 ]
  check "results owned by the output directory's owner" \
    [ "$(stat -c %u "$owned/vendor.patch" 2>/dev/null || stat -f %u "$owned/vendor.patch")" = "$(id -u)" ]

  echo ""
  echo "==> arguments after -- reach patch-helper"
  out="$(new_out)"
  run "$out" -- --branch HEAD~1 -- --filter=module-rma
  check "exits 0" [ "$CODE" = 0 ]
  check "filter keeps the override" has "$OVERRIDE" "$OUT"
  ! has "FilterPlugin" "$OUT"; check "filter drops the plugin" [ $? = 0 ]

  echo ""
  echo "==> hardened container (read-only, no capabilities, arbitrary uid)"
  out="$(new_out)"
  run "$out" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --user 4242:4242 -- --branch HEAD~1
  check "exits 0" [ "$CODE" = 0 ]
  check "override flagged" has "$OVERRIDE" "$OUT"

  echo ""
  echo "==> GUI files"
  out="$(new_out)"
  run "$out" -- --branch HEAD~1 --gui
  check "exits 0" [ "$CODE" = 0 ]
  check "classmap.json written" [ -s "$out/classmap.json" ]
  check "classmap paths are relative to the project" has '"vendor\/' "$(head -c 300 "$out/classmap.json")"
  check "vendor_orig.tar.gz written" [ -s "$out/vendor_orig.tar.gz" ]

  echo ""
  echo "==> git worktree"
  wt="$TMP/worktree"
  fixture_git worktree add -q --detach "$wt" HEAD
  mkdir "$wt/vendor"
  out="$(new_out)"
  OUT="$(docker run --rm -v "$wt:/project:ro" -v "$FIXTURE/vendor:/project/vendor:ro" -v "$out:/output" \
    "$IMAGE_REF" --branch HEAD~1 2>&1)"; CODE=$?
  check "unmounted main .git exits 1" [ "$CODE" = 1 ]
  check "unmounted main .git explains the fix" has "Also mount the main repository's .git" "$OUT"
  OUT="$(docker run --rm -v "$wt:/project:ro" -v "$FIXTURE/vendor:/project/vendor:ro" -v "$out:/output" \
    -v "$FIXTURE/.git:$FIXTURE/.git:ro" -v "$COMPOSER_CACHE:/root/.composer/cache" \
    "$IMAGE_REF" --branch HEAD~1 2>&1)"; CODE=$?
  check "worktree with main .git mounted exits 0" [ "$CODE" = 0 ]
  check "worktree override flagged" has "$OVERRIDE" "$OUT"
  fixture_git worktree remove --force "$wt"

  echo ""
  echo "==> docker stop ends a run promptly"
  name="uph-e2e-stop-$$"
  docker run -d --name "$name" -v "$FIXTURE:/project:ro" "$IMAGE_REF" --branch HEAD~1 >/dev/null
  sleep 3
  start=$SECONDS
  docker stop -t 30 "$name" >/dev/null
  check "stopped within 5s" [ $((SECONDS - start)) -lt 5 ]
  docker rm -f "$name" >/dev/null 2>&1
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
