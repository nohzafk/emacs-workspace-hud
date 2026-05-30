# Architecture

`emacs-egui-panel` is a standalone framework for showing an egui/WebAssembly renderer inside an Emacs child frame and driving it with JSON from Emacs Lisp.

**Attention Conservation Notice**

For: Contributors changing the panel lifecycle, server, renderer contract, or demo integration

What: Current architecture of the standalone project, not the old `emacs-hypervisor` design

Action: Read this before changing `lisp/egui-panel.el`, `lisp/workspace-hud.el`, or the WASM example

Skip if: You only need the narrative history in `docs/why-xwidget-for-the-hud.md`

## Current Shape

The project has two layers:

- `egui-panel`: reusable Emacs Lisp infrastructure for serving assets, creating the child frame, loading `xwidget-webkit`, and pushing JSON.
- `workspace-hud`: an example interface that collects project/git status and renders it through the panel.

The framework is data-source agnostic. It does not depend on `emacs-hypervisor`, Elle Lisp, an external HTTP server, npm, or a CDN.

```text
Emacs Lisp application
  |
  | sets egui-panel-asset-dir
  | pushes JSON with egui-panel-push-state / egui-panel-push-theme
  v
egui-panel.el
  |
  | make-network-process serves index.html and pkg/*
  | xwidget-webkit loads http://127.0.0.1:<port>/index.html#bg=...&fg=...
  v
Child frame
  |
  v
WebKit + egui WASM renderer
```

## Components

### Reusable Panel

[`lisp/egui-panel.el`](../lisp/egui-panel.el) owns the framework behavior.

It provides:

- A local asset server using `make-network-process`.
- A focusless, undecorated child frame anchored to the selected frame.
- A long-lived `xwidget-webkit` session.
- Theme bootstrap through a URL fragment.
- JSON state and theme pushes through `xwidget-webkit-execute-script`.
- Cleanup for the child frame, xwidget buffer, hooks, and server process.

The asset server binds to `127.0.0.1` on an ephemeral port. It serves files from `egui-panel-asset-dir`, maps `/` to `index.html`, strips query and fragment text, rejects path traversal, and sends `Cache-Control: no-store`.

### Workspace HUD Demo

[`lisp/workspace-hud.el`](../lisp/workspace-hud.el) is the live example application.

It provides:

- `workspace-hud-toggle` as the user entry point.
- Git collection through `vc-git`.
- Project root resolution from the parent frame's selected window.
- Debounced refreshes on buffer/window changes.
- Fast refresh after saving a file.
- A state payload compatible with the example WASM renderer.

This file should stay thin. Its job is to prove the framework and explore the HUD interface, not to absorb generic panel behavior.

### WASM Renderer

[`examples/workspace-hud/src/lib.rs`](../examples/workspace-hud/src/lib.rs) is the egui renderer for the demo.

It exports:

- `start(canvas_id)`: starts the eframe web runner.
- `push_state(json)`: replaces the global HUD state and requests repaint.
- `push_theme(json)`: replaces theme colors and requests repaint.

[`examples/workspace-hud/index.html`](../examples/workspace-hud/index.html) loads the generated `pkg/workspace_hud.js`, starts the canvas, reads initial theme colors from the URL fragment, and exposes:

```javascript
window.hudPushState(json)
window.hudPushTheme(json)
```

Applications can use different global names by setting `egui-panel-push-state-js` and `egui-panel-push-theme-js`.

## State Contract

The example renderer currently expects this JSON shape:

```json
{
  "branch": "main",
  "changes": "0 files",
  "mcp-online": false,
  "units": [],
  "location": "Local",
  "last-commit": "abc1234",
  "project-name": "emacs-egui-panel",
  "project-root": "/path/to/emacs-egui-panel"
}
```

The renderer has defensive fixups for legacy payloads where booleans arrive as `"true"` or `"false"` strings and empty lists arrive as `null`. The standalone demo already pushes native JSON booleans and `[]`.

The theme payload is:

```json
{
  "bg": "#0c0c10",
  "fg": "#e6ebff",
  "font-size": 15.0,
  "surface-bg": "#0c0c10"
}
```

Theme is presentation state. It bypasses any application data model and is pushed directly by `egui-panel`.
`surface-bg` controls the egui surface fill at runtime. When `egui-panel-surface-background` is nil, it follows the Emacs `default` face background.

## Lifecycle

`egui-panel-show` initializes the panel on first use.

1. Verify Emacs has xwidget support.
2. Start the local asset server if needed.
3. Create the child frame if needed.
4. Load `index.html` into a new `xwidget-webkit` session.
5. Restore parent and child window configurations so the xwidget command does not disturb the user's layout.
6. Strip the xwidget buffer's mode line, header line, fringes, and line numbers.
7. Push theme and run `egui-panel-ready-hook`.

`egui-panel-hide` hides the child frame without destroying the session.

`egui-panel-cleanup` destroys the frame, xwidget buffer, hooks, and local server.

## Data Flow

```text
workspace-hud refresh trigger
  |
  | resolve repo root and collect git state
  v
workspace-hud-refresh
  |
  | egui-panel-push-theme
  | egui-panel-push-state
  v
xwidget-webkit-execute-script
  |
  | window.hudPushTheme(json)
  | window.hudPushState(json)
  v
WASM exported push_theme / push_state
  |
  | replace global state
  | request egui repaint
  v
next egui frame renders the card
```

## Design Boundaries

The current framework intentionally supports one panel instance. Multiple independent panel roles may need an instance abstraction later, but the demo does not need that yet.

The current bridge is Emacs-to-WASM only. Click-back from WASM to Emacs was proven in earlier design work but is not implemented in `egui-panel.el` yet.

The local server is in Emacs Lisp because WebKit will not instantiate WebAssembly from `file://` origins. Keeping the server in-process avoids a global listener or external process.

The renderer owns layout and drawing. Emacs owns data collection, frame lifecycle, and when to push state.

## Failure Modes

If Emacs lacks xwidget support, `egui-panel-show` errors before creating a session.

If `egui-panel-asset-dir` is unset or does not contain `index.html` and the generated `pkg/` files, WebKit will load a missing or incomplete app.

If the WASM bundle has not been built, the HTTP server can still start, but the renderer will not load. Run `just wasm` or `wasm-pack build --target web` from `examples/workspace-hud`.

If `git` is unavailable or the active buffer is outside a repo, the workspace HUD falls back to placeholder state instead of failing the panel.
