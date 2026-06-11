# Limousine — build / publish / run.
#
#   make help            list targets
#   make local-build     build web + native server binary into build/bin
#   make local-run WORKSPACE=/abs/path/foo.wksp
#   make docker-image                build amd64 image (runs local-build first), loaded into your daemon
#   make docker-publish              push to $(IMAGE):$(TAG)
#   make docker-run WORKSPACE=/abs/path/foo.wksp
#
# Overrides:
#   IMAGE      default ghcr.io/pattern-agentic/limousine
#   TAG        default dev (or `latest` for publish)

IMAGE     ?= ghcr.io/pattern-agentic/limousine
TAG       ?= dev
WORKSPACE ?=

DOCKERFILE := docker/Dockerfile
BIN_DIR    := build/bin
WEB_DIR    := build/web
PTY_SO     := build/linux/x64/release/bundle/lib/libflutter_pty.so
DART_SRC   := $(shell find lib bin -name '*.dart' 2>/dev/null)
# Extract `version: X.Y.Z` from pubspec.yaml so both the web bundle and the
# native binary embed it as a compile-time constant via `--dart-define` /
# `--define`. Read via `String.fromEnvironment('LIMOUSINE_VERSION')`.
VERSION    := $(shell awk '/^version:/{print $$2; exit}' pubspec.yaml)

.PHONY: help
help:
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} \
	      /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# -----------------------------------------------------------------------------
# Local (non-docker) build & run
# -----------------------------------------------------------------------------

.PHONY: local-build
local-build: $(BIN_DIR)/limousine-server $(BIN_DIR)/libflutter_pty.so $(BIN_DIR)/limousine-server.sh $(WEB_DIR)/index.html  ## Build web bundle + native server binary into build/bin

$(WEB_DIR)/index.html: $(DART_SRC) pubspec.lock pubspec.yaml
	flutter build web --no-tree-shake-icons --release --dart-define=LIMOUSINE_VERSION=$(VERSION)

$(PTY_SO): pubspec.lock
	flutter build linux --release

$(BIN_DIR)/limousine-server: $(DART_SRC) pubspec.lock pubspec.yaml
	@mkdir -p $(BIN_DIR)
	dart compile exe --define=LIMOUSINE_VERSION=$(VERSION) bin/server.dart -o $(BIN_DIR)/limousine-server

$(BIN_DIR)/libflutter_pty.so: $(PTY_SO)
	@mkdir -p $(BIN_DIR)
	cp $(PTY_SO) $(BIN_DIR)/

$(BIN_DIR)/limousine-server.sh:
	@mkdir -p $(BIN_DIR)
	@printf '#!/bin/sh\nDIR="$$(cd "$$(dirname "$$0")" && pwd)"\nexport LD_LIBRARY_PATH="$$DIR:$${LD_LIBRARY_PATH:-}"\nexec "$$DIR/limousine-server" "$$@"\n' > $(BIN_DIR)/limousine-server.sh
	@chmod +x $(BIN_DIR)/limousine-server.sh

.PHONY: local-run
local-run: local-build  ## Run the locally-built server (use WORKSPACE=/abs/path/foo.wksp)
	@if [ -z "$(WORKSPACE)" ]; then \
		$(BIN_DIR)/limousine-server.sh; \
	else \
		$(BIN_DIR)/limousine-server.sh --workspace "$(WORKSPACE)"; \
	fi

.PHONY: analyze
analyze:  ## dart analyze the whole tree
	dart analyze

.PHONY: clean
clean:  ## Remove build artifacts (build/, .dart_tool/build_runner caches, etc.)
	rm -rf build/

# -----------------------------------------------------------------------------
# Docker image — copies pre-built artifacts; runs local-build first.
# -----------------------------------------------------------------------------

.PHONY: docker-image
docker-image: local-build  ## Build amd64 image, loaded into your local daemon as $(IMAGE):$(TAG)
	docker buildx build \
		--platform linux/amd64 \
		--file $(DOCKERFILE) \
		--tag $(IMAGE):$(TAG) \
		--load \
		.

.PHONY: docker-publish
docker-publish: docker-image  ## Push $(IMAGE):$(TAG) to the registry (requires `docker login ghcr.io`)
	docker push $(IMAGE):$(TAG)

.PHONY: docker-run
docker-run:  ## Run $(IMAGE):$(TAG) via scripts/limousine (use WORKSPACE=/abs/path/foo.wksp)
	@if [ -z "$(WORKSPACE)" ]; then \
		LIMOUSINE_IMAGE=$(IMAGE):$(TAG) scripts/limousine; \
	else \
		LIMOUSINE_IMAGE=$(IMAGE):$(TAG) scripts/limousine "$(WORKSPACE)"; \
	fi

.PHONY: docker-shell
docker-shell:  ## Drop into a bash shell inside the image (handy for verifying baked tooling)
	docker run --rm -it --entrypoint bash $(IMAGE):$(TAG)

.PHONY: docker-pin-check
docker-pin-check:  ## Print pinned tool versions baked into $(IMAGE):$(TAG)
	@docker run --rm --entrypoint sh $(IMAGE):$(TAG) -c '\
		echo "node     $$(node --version)"; \
		echo "npm      $$(npm --version)"; \
		echo "uv       $$(uv --version)"; \
		echo "kubectl  $$(kubectl version --client=true -o yaml | sed -n "s/.*gitVersion: //p" | head -1)"; \
		echo "aws      $$(aws --version)"; \
		echo "docker   $$(docker --version)"; \
		echo "nats     $$(nats --version 2>&1 | head -1)"; \
		echo "dotenv   $$(dotenv --version 2>&1 | head -1)"; \
		echo "git      $$(git --version)"'
