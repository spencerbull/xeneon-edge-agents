set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

fmt:
    cargo fmt --all -- --check

rust:
    cargo test --workspace
    cargo clippy --workspace --all-targets -- -D warnings

qml:
    if [[ -x tests/run-qml-tests ]]; then tests/run-qml-tests; else echo "QML tests not present yet"; fi

integration:
    if [[ -x tests/run-integration-tests ]]; then tests/run-integration-tests; else echo "Integration tests not present yet"; fi

check: fmt rust qml integration
    git -C "{{justfile_directory()}}" diff --check

build:
    cargo build --workspace --release
