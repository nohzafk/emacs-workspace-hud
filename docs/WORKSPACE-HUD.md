# Workspace HUD Features & Configuration

The workspace HUD anchors a gorgeous floating card at the top-right corner of the parent Emacs frame, showing project metrics and Git repository status at a glance.

## Features

The HUD dynamically renders a clean dashboard with two compact sections:

- **Workspace**: Shows project name, current branch, upstream state, and dirty working tree summary.
- **Health**: Shows the current buffer's LSP state and diagnostic counts.

The display is intentionally limited to attention-worthy, contextual, actionable info rather than becoming a second mode line, buffer list, or full dashboard.

## User Configuration

Load the HUD in your `init.el`:

```elisp
(add-to-list 'load-path "/path/to/emacs-workspace-hud/lisp")
(require 'workspace-hud)

;; Configure HUD dimensions and margins:
(setq workspace-hud-width 260
      workspace-hud-margin-right 19
      workspace-hud-margin-top 60)

;; Toggle HUD manually:
(global-set-key (kbd "C-c h") #'workspace-hud-toggle)
```

### Auto-Mode Visibility

To let Emacs manage visibility automatically, enable `workspace-hud-auto-mode`:

```elisp
(workspace-hud-auto-mode 1)
```

Auto-mode hooks into window selection, buffer changes, and file saves. It automatically displays the HUD whenever you focus on a file inside a Git repo, and hides the child frame when you switch to helper buffers outside Git (such as `*scratch*`, `*Help*`, or Dired). 

*Note: If you manually toggle the HUD off while auto-mode is active, automatic reappearance will pause until you explicitly toggle the HUD on again.*

### Small-Frame Auto-Hide

The panel sits over the right edge of the parent frame, so a narrow frame leaves the HUD covering the code. Auto-mode hides the HUD when fewer than `workspace-hud-min-text-columns` columns of text fit beside the panel, and shows it again when the frame grows back:

```elisp
;; Require 100 columns of code beside the panel (default is 80):
(setq workspace-hud-min-text-columns 100)

;; Or never auto-hide on size:
(setq workspace-hud-min-text-columns 0)
```

The threshold is measured in the frame's own character width, so it tracks font-size changes rather than needing one pixel value per display.

## Data Collection Details

Rather than launching external shell wrappers or keeping daemon processes alive, `workspace-hud` leverages Emacs' built-in `vc-git` engine for extremely fast, low-overhead workspace queries.

- **Branch Resolution**: `git rev-parse --abbrev-ref HEAD`
- **Upstream Divergence**: `git rev-list --left-right --count @{upstream}...HEAD`
- **Tracked Stats**: `git diff --numstat -- .` and `git diff --cached --numstat -- .`
- **Untracked fallback**: `git status --porcelain`
- **Last Commit**: `git rev-parse --short HEAD`
- **LSP Status**: Detects active Eglot, lsp-mode, or lsp-bridge clients in the viewed buffer.
- **Diagnostics**: Counts Flycheck diagnostics when Flycheck is active; otherwise counts Flymake diagnostics when available.

### State Serialization

Emacs serializes collected metrics to the following JSON structure before sending it to the WASM runtime:

```json
{
  "branch": "main",
  "upstream": "↑1 ↓2",
  "changes": "+10 -3",
  "location": "Local",
  "last-commit": "abc1234",
  "project-name": "emacs-workspace-hud",
  "project-root": "/Users/randall/projects/emacs-workspace-hud",
  "lsp-status": "online",
  "diagnostic-errors": 0,
  "diagnostic-warnings": 1,
  "diagnostic-notes": 2
}
```

## Compilation & Verification

Building the egui WASM bundle runs entirely through `just`:

```sh
just setup   # One-time toolchain setup
just wasm    # Compiles renderer to /ui/pkg/
just test    # Runs HEADLESS Lisp tests
just check   # Runs wasm build + byte-compile + tests
```
