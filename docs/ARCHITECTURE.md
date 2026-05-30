# Workspace HUD Architecture

`emacs-workspace-hud` is an integrated, highly polished Emacs package that displays a real-time floating status dashboard anchored to the top-right corner of the parent frame. It combines a Rust egui-based frontend compiled to WebAssembly, a pure-Elisp in-process HTTP server, and automatic workspace Git/daemon status collection.

## Architectural Layout

```text
Emacs Process (Lisp)
  │
  ├─► Local Asset Server (make-network-process)
  │     Serves /renderer/index.html & pkg/* over 127.0.0.1:<port>
  │
  ├─► Git / Status Collector (vc-git)
  │     Gathers unstaged/staged files, commits, branch info, daemons
  │
  └─► Child Frame & Window Controller
        Controls the undecorated focusless child frame containing
        an xwidget-webkit browser session
          │
          └─► loads URL: http://127.0.0.1:<port>/index.html#bg=...&fg=...
                │
                └─► WebKit + WebAssembly egui Renderer
                      Exposes JS endpoints:
                        - window.hudPushState(json)
                        - window.hudPushTheme(json)
```

## Key Components

### 1. In-Process Asset Server
WebKit refuses to load and execute WebAssembly files from local `file://` URIs due to browser security constraints. To resolve this without forcing the user to install Node, Docker, or external network binaries, `workspace-hud` spins up a micro-HTTP server in pure Elisp using `make-network-process`.

- Binds exclusively to `127.0.0.1` on a random ephemeral port.
- Serves assets exclusively from the `/renderer` project folder.
- Mitigates security risks by stripping query and fragment paths, validating that paths do not traverse out of the `/renderer` folder, and enforcing a strict `Cache-Control: no-store` header.

### 2. Child Frame Lifecycle Manager
The HUD is visually styled as a floating card but technically instantiated as an Emacs child frame.

- Created as a focusless, undecorated, scrollbar-less child frame.
- Set to `no-accept-focus` and `no-focus-on-map` so that it never disrupts active user keyboard inputs or typing.
- Kept strictly aligned using frame-tracking hooks: `window-size-change-functions` keeps it anchored to the top-right corner on parent resizing, and focus adjustments raise the child frame to stay on top of the parent window context.
- Dedicated window mapping redirects buffers so that closing the session never kills one of the user's primary Lisp buffers.

### 3. Theme Synchronization & Zero-Flash Bootstrapping
To avoid an ugly bright flash when loading the panel inside WebKit, `workspace-hud` synchronizes themes in two ways:

- **Fragment Bootstrapping**: On initial page load, Emacs extracts the `default` face background and foreground colors along with font sizes, encodes them into a URL fragment (e.g. `#bg=%230c0c10&fg=%23e6ebff`), and loads this directly. The HTML shell intercepts this fragment *before* egui initializes, applying colors to the web background instantly.
- **Dynamic Updates**: If the user changes their Emacs theme at runtime, `workspace-hud` serializes the new theme colors and pushes them via `workspace-hud--push-theme` dynamically using WebKit's script engine. Egui intercepts the theme payload and repaints the app instantly.

### 4. Git & Workspace Data Flow
- **Collector**: Emacs uses `vc-git` hooks to parse directory paths and query Git for branch status, insertions, deletions, and commits.
- **Push Bridge**: The gathered data plist is formatted to JSON and pushed programmatically:
  ```elisp
  (xwidget-webkit-execute-script session "window.hudPushState(json_string)")
  ```
- **Renderer**: The exported Rust `push_state` deserializes the JSON string into its internal model, locks a global repaint mutex, and requests a canvas repaint, completing the cycle in microseconds.

## Failure Modes & Resilience

- **No Xwidget Support**: If Emacs was built without xwidgets, an informative error is raised gracefully before any frame or server structures are created.
- **Non-Git Context**: In auto-mode, moving a buffer outside of a Git directory dynamically hides the HUD child frame, releasing window space.
- **Unbuilt WASM Assets**: If `just wasm` has not been run, the HTML shell will load but will output a compilation error to the WebKit console. The server remains stable.
