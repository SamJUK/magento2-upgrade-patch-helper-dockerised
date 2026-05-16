PHP_VERSION ?= 8.2
IMAGE_NAME  ?= upgrade-patch-helper-test
IMAGE_TAG   := $(IMAGE_NAME):$(PHP_VERSION)
.PHONY: build build-all test test-smoke test-e2e push push-all clean help

build: ## Build the test image for PHP_VERSION (default: 8.2)
	docker build --build-arg PHP_VERSION=$(PHP_VERSION) -t $(IMAGE_TAG) src/

build-all: ## Build images for PHP 8.1–8.5
	@for v in 8.1 8.2 8.3 8.4 8.5; do \
	  echo "==> Building PHP $$v"; \
	  docker build --build-arg PHP_VERSION=$$v -t $(IMAGE_NAME):$$v src/; \
	done

test: test-smoke test-e2e ## Run smoke + E2E tests

test-smoke: build ## Smoke test: verify --help runs successfully
	IMAGE_REF=$(IMAGE_TAG) bash tests/smoke.sh

test-e2e: build ## Run E2E tests (local composer path fixtures, no auth needed)
	IMAGE_REF=$(IMAGE_TAG) bash tests/e2e.sh

push: build ## Push PHP_VERSION image to Docker Hub
	docker tag $(IMAGE_TAG) samjuk/magento2-upgrade-patch-helper:$(PHP_VERSION)
	docker push samjuk/magento2-upgrade-patch-helper:$(PHP_VERSION)

push-all: build-all ## Build and push all PHP versions to Docker Hub
	@for v in 8.1 8.2 8.3 8.4 8.5; do \
	  docker tag $(IMAGE_NAME):$$v samjuk/magento2-upgrade-patch-helper:$$v; \
	  docker push samjuk/magento2-upgrade-patch-helper:$$v; \
	done

clean: ## Remove test images
	docker rmi -f $(IMAGE_TAG) 2>/dev/null || true

help: ## Show available targets
	@grep -E '^[a-z][a-z0-9_-]*:.*## ' Makefile | awk -F':.*## ' '{printf "%-20s %s\n", $$1, $$2}'
