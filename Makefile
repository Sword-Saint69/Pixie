FLUTTER ?= flutter
CODEGEN ?= flutter_rust_bridge_codegen
CARGO   ?= cargo
DEVICE  ?= linux

.DEFAULT_GOAL := help
.PHONY: help gen test test-rust test-integration analyze build build-cli build-apk clean

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

gen: ## Regenerate Dart bindings from rust/src/api
	$(CODEGEN) generate

test: test-rust test-integration

test-rust:
	$(CARGO) test --manifest-path rust/Cargo.toml

test-integration:
	$(FLUTTER) test integration_test -d $(DEVICE)

analyze:
	$(FLUTTER) analyze
	$(CARGO) clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings

build: ## Release Linux bundle
	$(FLUTTER) build linux --release

build-cli: ## Release CLI binary
	$(CARGO) build --release --manifest-path rust/Cargo.toml --bin gotohp-rs-cli

build-apk: ## Debug APK (JDK 21 required)
	$(FLUTTER) build apk --debug

clean:
	$(FLUTTER) clean
	$(CARGO) clean --manifest-path rust/Cargo.toml
