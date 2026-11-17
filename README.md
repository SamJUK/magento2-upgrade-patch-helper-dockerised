# Magento 2 Upgrade Patch Helper (Docker)

Runs the Magento 2 upgrade patch helper against a Magento project mounted read-only, with nothing to install but Docker.
It lists every preference, plugin, template, layout, DB schema and API customisation that touches a file changed by your upgrade.

The image bundles [convenient/convenient-magento2-upgrade-patch-helper](https://github.com/convenient/convenient-magento2-upgrade-patch-helper), a fork by the original author of [idhlagency/ampersand-magento2-upgrade-patch-helper](https://github.com/idhlagency/ampersand-magento2-upgrade-patch-helper) (formerly AmpersandHQ).
The fork adds Magento 2.4.9+ support and checks for system config, CSP, REST and GraphQL APIs and Hyvä CMS components.
The commit in use is pinned in `src/Dockerfile` and shown by `docker inspect` under the `io.github.patch-helper.ref` label.

## How it works

1. Do the upgrade on your machine: `composer update`, fix conflicts, make sure `vendor/` is installed for the new version.
2. Run the image, pointing `--branch` at the git ref you are upgrading from (for example `origin/production`).
3. The container installs that ref's `vendor/` from its `composer.lock`, diffs it against your current `vendor/` and runs the analysis.

Your project is mounted read-only and all work happens on a copy inside the container.

## Quick start

From your Magento root:

```bash
git fetch origin
mkdir -p upgrade-output

docker run --rm \
  -v "$PWD:/project:ro" \
  -v "$PWD/upgrade-output:/output" \
  -v ~/.composer/cache:/root/.composer/cache \
  -v ~/.composer/auth.json:/root/.composer/auth.json:ro \
  samjuk/magento2-upgrade-patch-helper:8.3 \
  --branch origin/production
```

Results land in `./upgrade-output/`:

| File | What it is |
|------|------------|
| `patch-helper-output.txt` | The table of WARN and INFO items to review |
| `vendor_files_to_check.patch` | The vendor changes behind each item |
| `vendor.patch` | The full vendor diff |

Pick the tag for the PHP version your **target** Magento version runs on.
The run warns if the project's `composer.lock` needs a different PHP version.

## Images

Tags `8.1` to `8.5` for `linux/amd64` and `linux/arm64` (Apple Silicon runs natively), plus `<php>-<release>` on each release, for example `8.3-v1.2.0`.

```bash
docker pull samjuk/magento2-upgrade-patch-helper:8.3
docker pull ghcr.io/samjuk/magento2-upgrade-patch-helper-dockerised:8.3
```

Images are Alpine based, about 60 to 70MB unpacked.
They ship with SBOM and provenance attestations.

## Flags

| Flag | Description |
|------|-------------|
| `--branch REF` | **Required.** Git ref to compare against, the version you are upgrading from |
| `--show-info` | Show INFO items as well as WARN |
| `--sort-by-type` | Sort the table by type |
| `--gui` | Also write files for the GUI (see below) |
| `--memory-limit N` | PHP `memory_limit` (default `-1`) |
| `--output DIR` | Output directory inside the container (default `/output`) |
| `--verbose` | Show composer's output |
| `-- ARGS` | Pass everything after `--` to `patch-helper analyse`, for example `-- --vendor-namespaces=Acme --show-ignore` |

Exit codes: `0` the analysis ran, `1` setup or analysis failed, `2` bad arguments.
WARN items do not change the exit code.

## Composer authentication

Needed for repo.magento.com and private repositories.
Mount your `auth.json` as in the quick start, or pass it as an environment variable:

```bash
-e COMPOSER_AUTH='{"http-basic":{"repo.magento.com":{"username":"KEY","password":"SECRET"}}}'
```

## Git worktrees

A worktree's `.git` is a file pointing at the main repository, so mount the main repository's `.git` at the same absolute path as well:

```bash
docker run --rm \
  -v "$PWD:/project:ro" \
  -v /path/to/main-repo/.git:/path/to/main-repo/.git:ro \
  -v "$PWD/upgrade-output:/output" \
  samjuk/magento2-upgrade-patch-helper:8.3 --branch origin/production
```

The error message prints the exact mount when it is missing.

## File ownership and hardened runs

On Linux the container runs as the owner of the output directory, so results are not owned by root.
Create the output directory before the run, otherwise Docker creates it as root.

It also works as any user, on a read-only filesystem and with no capabilities:

```bash
docker run --rm --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$PWD:/project:ro" -v "$PWD/upgrade-output:/output" \
  samjuk/magento2-upgrade-patch-helper:8.3 --branch origin/production
```

## GUI mode

`--gui` also writes `classmap.json` and `vendor_orig.tar.gz` for [elgentos/magento2-upgrade-gui](https://github.com/elgentos/magento2-upgrade-gui).
The GUI reads your project files, so it opens your Magento root rather than the output directory:

1. Copy everything in the output directory into your Magento root.
2. In the Magento root, run `tar -xzf vendor_orig.tar.gz`.
3. Open the Magento root in the app.

## Development

Requires Docker, git and `make`.

```bash
make test                    # build PHP 8.3, run smoke and E2E tests
make test PHP_VERSION=8.5    # another PHP version
make build-all               # build 8.1 to 8.5
make help
```

`tests/smoke.sh` checks the CLI, that GNU `patch` and `diff` are present and that patch-helper loads.

`tests/e2e.sh` builds a real Mage-OS 3.5.0 to 3.6.0 upgrade with a preference, a plugin and a theme override on files the upgrade changes (`tests/fixtures/mageos/`), then checks each is reported.
It also covers error handling, output ownership, passthrough arguments, a hardened container, GUI files, git worktrees and `docker stop`.
Composer runs inside the image under test and downloads are cached in `tests/.cache/`.
Mage-OS 3.x needs PHP 8.3+, so the PHP 8.1 and 8.2 images run the error-handling tests only.

To move to a newer patch-helper commit, change `PATCH_HELPER_REF` in `src/Dockerfile`.
