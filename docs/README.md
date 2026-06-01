# Emacs Workspace HUD Documentation

Current documentation for the consolidated `emacs-workspace-hud` package and its Rust WebAssembly renderer.

## Current Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) explains the internal mechanics: the pure-Elisp asset server process, child-frame/xwidget layout management, JSON serialization, and WASM renderer lifecycle.
- [`WORKSPACE-HUD.md`](WORKSPACE-HUD.md) explains the features, customization options (sizes, margins, backgrounds), Git VC extraction logic, and auto-mode scheduling.

## Package Layout Map

The unified codebase consists of the following components:

- [`../lisp/workspace-hud.el`](../lisp/workspace-hud.el): The single core Emacs Lisp package (server, frame, Git collector, and health collector).
- [`../ui/`](../ui/): The egui Rust and WASM renderer code.
- [`../tests/workspace-hud-tests.el`](../tests/workspace-hud-tests.el): The comprehensive unit and integration ERT test suite.

## Documentation Guidelines

- Always document functions and options using the `workspace-hud-` namespace.
- Keep the design clean, premium, and focused exclusively on the Emacs Workspace HUD.
