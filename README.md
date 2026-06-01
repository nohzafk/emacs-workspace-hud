# Emacs Workspace HUD

A modern, highly polished, premium **Workspace Status Heads-Up Display (HUD)** for Emacs. 

It renders a gorgeous floating status card anchored to the top-right corner of your selected Emacs frame. The interface is built in Rust using the [egui](https://github.com/emilk/egui) library, compiled to WebAssembly, and rendered smoothly inside a focusless `xwidget-webkit` child frame.

```text
  +----------------------------------------------------+
  | Emacs Window                                 [HUD] |
  |                                 +----------------+ |
  |                                 | WORKSPACE      | |
  |                                 | project        | |
  |                                 | main    up-to  | |
  |                                 | dirty   +0 -0  | |
  |                                 |                | |
  |                                 | HEALTH         | |
  |                                 | LSP     online | |
  |                                 | Diag    0 err  | |
  |                                 +----------------+ |
  |                                                    |
  |                                                    |
  +----------------------------------------------------+
```

## Information Model

The HUD should show **attention-worthy, contextual, actionable info** without becoming a second mode line, buffer list, or full dashboard.

For the current polish pass, the card is organized around two compact sections:

- **Workspace**: project, branch, upstream state, and dirty working tree summary.
- **Health**: LSP connection state and diagnostics counts.

Test information varies heavily from project to project, so it is intentionally not a first-class section yet. Instead, the HUD should prioritize signals that are commonly useful across most programming workspaces and cheap to collect from Emacs.

## Why a local HTTP server?

WebKit refuses to instantiate WebAssembly from `file://` origins for security reasons, so the assets must be served over an `http://` origin. Rather than relying on external web daemons, global network listeners, npm, or CDN dependencies, this package runs a **tiny HTTP server in pure Emacs Lisp** (`make-network-process`) bound to `127.0.0.1` on an ephemeral port. It serves only the HUD's compiled `index.html` and `pkg/` WASM bundle entirely in-process and securely.

## Repository Layout

```text
emacs-workspace-hud/
├── lisp/
│   └── workspace-hud.el     # Core package: asset server + child frame lifecycle + Git collection
├── ui/                      # The egui/WASM status card renderer
│   ├── src/lib.rs           #   Rust egui app & push bindings
│   ├── index.html           #   HTML bootstrap shell (exposes JS/WASM bridges)
│   └── pkg/                 #   Generated WebAssembly bundle (wasm-pack output)
├── docs/                    # Architectural guidelines and detailed notes
├── tests/                   # ERT test suite covering server, path traversal, Git, and auto modes
└── Cargo.toml               # Workspace configuration
```

## Requirements

- Emacs 29.1+ built **with xwidget support** (`(featurep 'xwidget-internal)`) and standard file notification support (`file-notify`).
- For status collection: `git` installed on your path.
- Project automation: [`just`](https://github.com/casey/just) (optional, but highly recommended).
- To compile the renderer: a Rust toolchain and [`wasm-pack`](https://rustwasm.github.io/wasm-pack/).

## Build the Renderer

Run the automated setup and compile recipes through `just`:

```sh
just setup   # Installs the wasm32 Rust target and wasm-pack if missing
just wasm    # Compiles the Rust renderer into WebAssembly assets
```

If you do not have `just`, you can compile manually:
```sh
cd ui && wasm-pack build --target web
```
This generates the WebAssembly binaries and JS binders inside `ui/pkg/`.

## Running the HUD

To load and open the Workspace HUD in Emacs:

```elisp
(add-to-list 'load-path "/path/to/emacs-egui-panel/lisp")
(require 'workspace-hud)

;; Toggle the HUD manually:
(workspace-hud-toggle)
```

### Automatic Mode

Enable `workspace-hud-auto-mode` to let Emacs manage visibility automatically. The status card will seamlessly appear when you edit files in a Git repository and automatically hide when you move to buffers outside a repository (like dired, help, or scratch):

```elisp
(workspace-hud-auto-mode 1)
```

## How It Works (Data Flow)

1. **Lifecycle Activation**: Calling `workspace-hud-toggle` or changing buffers in auto-mode launches the tiny pure-Elisp HTTP server and maps the xwidget child frame to the top-right corner.
2. **Theme Bootstrapping**: Emacs reads your current active theme colors (background, foreground, and font heights) and passes them to WebKit via a URL fragment (e.g. `#bg=#0c0c10&fg=#e6ebff`) to guarantee a seamless, zero-flash first paint.
3. **Data Collection & Real-Time Watching**: Emacs queries your workspace using `vc-git` to gather project details (staged/unstaged files, commits, ahead/behind statistics). To keep the display perfectly in sync with external terminal actions (such as `git branch`, `git commit`, `git add`, etc.), Emacs establishes a lightweight, non-recursive background watcher on the repository's `.git/` directory, immediately triggering a debounced status refresh on any commit, branch switch, pull, or staging activity.
4. **Programmatic Pushes**: Emacs encodes the workspace state plist to JSON and calls the WebKit bridge `window.hudPushState(json)` dynamically. Egui replaces the state model and requests an immediate repaint, redrawing the canvas in microseconds.
