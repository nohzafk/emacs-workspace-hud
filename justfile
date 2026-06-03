set shell := ["bash", "-euo", "pipefail", "-c"]

emacs := env_var_or_default("EMACS", "emacs")

[group('Default')]
default:
    @just --list

[group('Build')]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v cargo >/dev/null 2>&1; then
      echo "error: cargo/rustup not found — install Rust first: https://rustup.rs" >&2
      exit 1
    fi
    if ! rustup target list --installed 2>/dev/null | grep -q wasm32-unknown-unknown; then
      echo "Installing Rust target: wasm32-unknown-unknown"
      rustup target add wasm32-unknown-unknown
    else
      echo "✓ Rust target wasm32-unknown-unknown"
    fi
    if ! command -v wasm-pack >/dev/null 2>&1; then
      echo "Installing wasm-pack via cargo"
      cargo install wasm-pack
    else
      echo "✓ wasm-pack"
    fi

# Rebuild the demo WASM renderer.
[group('Build')]
wasm:
    cd ui && wasm-pack build --target web --release

# Byte-compile the Lisp as a smoke test.
[group('Test')]
compile:
    {{emacs}} -Q --batch -L lisp -f batch-byte-compile lisp/*.el
    rm -f lisp/*.elc

# Run the ERT test suite (headless).
[group('Test')]
test:
    {{emacs}} -Q --batch -L lisp -L tests \
      -l tests/workspace-hud-tests.el \
      -f ert-run-tests-batch-and-exit

# Build the renderer, byte-compile, then run tests.
[group('Test')]
check: wasm compile test

[group('Build')]
clean:
    rm -f lisp/*.elc tests/*.elc
    rm -rf ui/target
