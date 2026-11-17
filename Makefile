PHP_VERSION ?= 8.3
IMAGE_NAME  ?= upgrade-patch-helper-test
IMAGE_TAG   := $(IMAGE_NAME):$(PHP_VERSION)
.PHONY: build build-all test test-smoke test-e2e clean help

build: ## Build the test image for PHP_VERSION (default: 8.3)
	docker build --build-arg PHP_VERSION=$(PHP_VERSION) --build-arg PHP_IMAGE=$$(sed -n 's/^FROM //p' src/php/$(PHP_VERSION)/Dockerfile) -t $(IMAGE_TAG) src/

build-all: ## Build images for PHP 8.1–8.5
	@for v in 8.1 8.2 8.3 8.4 8.5; do \
	  echo "==> Building PHP $$v"; \
	  docker build --build-arg PHP_VERSION=$$v --build-arg PHP_IMAGE=$$(sed -n 's/^FROM //p' src/php/$$v/Dockerfile) -t $(IMAGE_NAME):$$v src/; \
	done

test: test-smoke test-e2e ## Run smoke + E2E tests

test-smoke: build ## Smoke test: CLI, GNU patch/diff, patch-helper loads
	IMAGE_REF=$(IMAGE_TAG) bash tests/smoke.sh

test-e2e: build ## Run E2E tests against a real Mage-OS upgrade (needs only Docker and git)
	IMAGE_REF=$(IMAGE_TAG) bash tests/e2e.sh

clean: ## Remove test images and the fixture cache
	docker rmi -f $(IMAGE_TAG) 2>/dev/null || true
	rm -rf tests/.cache

help: ## Show available targets
	@grep -E '^[a-z][a-z0-9_-]*:.*## ' Makefile | awk -F':.*## ' '{printf "%-20s %s\n", $$1, $$2}'
