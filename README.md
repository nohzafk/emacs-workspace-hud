# emacs-egui-panel

A reusable **"push JSON → render a themable floating egui panel"** widget for
Emacs.

**Attention Conservation Notice**

For: Contributors and users trying the panel or the workspace HUD demo

What: Standalone setup, build, and reuse notes for `emacs-egui-panel`

Action: Read the Development and Run sections before changing code or testing the demo

Skip if: You already know how to load `egui-panel.el` and have rebuilt the WASM bundle

The panel is a [egui](https://github.com/emilk/egui) application compiled to
WebAssembly and rendered inside an `xwidget-webkit` child frame anchored to a
corner of your Emacs frame. Your Emacs Lisp pushes JSON; the panel draws it.

This grew out of the corner HUD experiment in
[emacs-hypervisor](https://github.com/nohzafk/emacs-hypervisor) and was
extracted into a standalone project so the rendering mechanism can be reused
independently of any particular data source.

The current repo does **not** depend on `emacs-hypervisor` or Elle Lisp. The
included workspace HUD is an example interface and testbed for the framework.

## Why a local HTTP server?

WebKit refuses to instantiate WebAssembly from `file://` origins, so the assets
must be served over `http://`. Rather than depend on an external binary or a
global listener, `egui-panel` runs a **tiny HTTP server in pure Emacs Lisp**
(`make-network-process`) bound to `127.0.0.1` on an ephemeral port, serving only
the panel's `index.html` and `pkg/` bundle. No external process, no npm, no CDN.

## Layout

```text
emacs-egui-panel/
├── lisp/
│   ├── egui-panel.el        # the reusable widget (server + child frame + push API)
│   └── workspace-hud.el     # flagship demo: a git/project status card
├── docs/                    # current architecture, demo notes, and design post
├── tests/                   # ERT coverage for the widget and demo collector
└── examples/workspace-hud/  # the egui/WASM renderer for the demo
    ├── src/lib.rs           #   egui app + push_state/push_theme bindings
    ├── index.html           #   HTML shell (canvas + theme bootstrap)
    └── pkg/                 #   wasm-pack output (generated)
```

Start with [`docs/README.md`](docs/README.md) for the current docs map.

## Requirements

- Emacs 29.1+ built **with xwidget support** (`(featurep 'xwidget-internal)`).
- For the demo: `git` and, optionally, the `gh` CLI.
- Project automation: [`just`](https://github.com/casey/just).
- To rebuild the renderer: a Rust toolchain and
  [`wasm-pack`](https://rustwasm.github.io/wasm-pack/).

## Development

Project automation runs through [`just`](https://github.com/casey/just):

```sh
cargo install just  # one-time, if your system package manager does not provide it
just                # list recipes
just test           # run the ERT suite
just wasm           # rebuild the WASM renderer
```

## Build the renderer

```sh
just wasm
# or directly:
cd examples/workspace-hud && wasm-pack build --target web
```

This produces `examples/workspace-hud/pkg/` (`workspace_hud.js` +
`workspace_hud_bg.wasm`).

## Run the demo

```elisp
(add-to-list 'load-path "/path/to/emacs-egui-panel/lisp")
(require 'workspace-hud)
(workspace-hud-toggle)
```

For automatic visibility, enable:

```elisp
(workspace-hud-auto-mode 1)
```

The card appears in the top-right corner and follows the active buffer's git
project, refreshing on buffer switches and saves.  In auto mode it hides when
the selected buffer is outside a Git repo and reappears when you return to one.
If you hide it with `workspace-hud-toggle`, automatic reappearance stays paused
until you toggle it on again.

## Reusing the widget

`egui-panel` is data-source agnostic. To drive your own panel:

```elisp
(require 'egui-panel)
(setq egui-panel-asset-dir "/path/to/your/wasm/bundle/")  ; has index.html + pkg/
(add-hook 'egui-panel-ready-hook
          (lambda () (egui-panel-push-state '(:hello "world"))))
(egui-panel-show)
```

The bundle's HTML shell must expose `window.hudPushState(json)` and
`window.hudPushTheme(json)` (or set `egui-panel-push-state-js` /
`egui-panel-push-theme-js` to your own global names).

## Status

Working standalone framework with an experimental workspace HUD demo. The next
work is refining the HUD interface, expanding the generic panel API where real
uses require it, and deciding how much interactivity should flow back from WASM
to Emacs.
