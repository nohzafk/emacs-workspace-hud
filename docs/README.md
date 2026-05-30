# emacs-egui-panel Docs

Current documentation for the standalone `emacs-egui-panel` project and its workspace HUD example.

**Attention Conservation Notice**

For: Contributors deciding where to read or edit documentation

What: The docs map after extracting this project from `emacs-hypervisor`

Action: Use the architecture and demo docs for implementation work; use the design post for the project history

Skip if: You only need the quick setup commands in the root README

## Current Docs

[`ARCHITECTURE.md`](ARCHITECTURE.md) explains the standalone framework: the pure-Elisp asset server, child-frame/xwidget lifecycle, JSON push API, and WASM renderer contract.

[`WORKSPACE-HUD.md`](WORKSPACE-HUD.md) explains the example HUD interface. This is the live experiment that exercises the reusable panel framework with project and git status.

[`why-xwidget-for-the-hud.md`](why-xwidget-for-the-hud.md) is a concise post about how the HUD idea moved from broad experiment to the current `xwidget-webkit` architecture.

## Removed From The Current Surface

The old top-level docs described a coupled `emacs-hypervisor` plus Elle actor design. That is no longer the project architecture.

The current project keeps the useful findings from those experiments, but the implementation now lives in:

- [`../lisp/egui-panel.el`](../lisp/egui-panel.el): reusable panel framework
- [`../lisp/workspace-hud.el`](../lisp/workspace-hud.el): workspace HUD demo controller
- [`../examples/workspace-hud/`](../examples/workspace-hud/): Rust/egui WASM renderer
- [`../tests/`](../tests/): ERT tests for framework and demo behavior

## Documentation Rules

Keep current docs focused on the standalone package.

Use current package names: `egui-panel`, `workspace-hud`, and `emacs-egui-panel`.

Only mention `emacs-hypervisor` or Elle Lisp when describing project history.
