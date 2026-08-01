set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

fmt:
    cargo fmt --all -- --check

rust:
    cargo test --workspace
    cargo clippy --workspace --all-targets -- -D warnings

shell:
    shellcheck scripts/*.sh scripts/preview tests/*.sh tests/run-integration-tests tests/run-qml-tests

qml:
    if [[ -x tests/run-qml-tests ]]; then tests/run-qml-tests; else echo "QML tests not present yet"; fi

integration:
    if [[ -x tests/run-integration-tests ]]; then tests/run-integration-tests; else echo "Integration tests not present yet"; fi

check: fmt rust shell qml integration
    git diff --check

build:
    cargo build --workspace --release
