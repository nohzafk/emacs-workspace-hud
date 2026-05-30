# Workspace HUD Features & Configuration

The workspace HUD anchors a gorgeous floating card at the top-right corner of the parent Emacs frame, showing project metrics and Git repository status at a glance.

## Features

The HUD dynamically renders a clean dashboard with the following metrics:
- **Repository Branch**: Resolves your current working branch.
- **Upstream Divergence**: Displays ahead/behind counts (e.g., `↑2 ↓1`) compared to your configured upstream tracking branch.
- **Working Tree Changes**: Aggregates insertions and deletions (e.g., `+10 -3`). If changes are untracked-only, binary-only, or file-mode-only, it falls back to a clean changed-file counter (e.g. `2 files`).
- **Last Commit**: Shows the short hash of the last commit.
- **Daemons / Sources**: Retains slots for daemon monitoring (such as LSP or Elle MCP status).

## User Configuration

Load the HUD in your `init.el`:

```elisp
(add-to-list 'load-path "/path/to/emacs-workspace-hud/lisp")
(require 'workspace-hud)

;; Configure HUD dimensions and margins:
(setq workspace-hud-width 260
      workspace-hud-height 230
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

## Data Collection Details

Rather than launching external shell wrappers or keeping daemon processes alive, `workspace-hud` leverages Emacs' built-in `vc-git` engine for extremely fast, low-overhead workspace queries.

- **Branch Resolution**: `git rev-parse --abbrev-ref HEAD`
- **Upstream Divergence**: `git rev-list --left-right --count @{upstream}...HEAD`
- **Tracked Stats**: `git diff --numstat -- .` and `git diff --cached --numstat -- .`
- **Untracked fallback**: `git status --porcelain`
- **Last Commit**: `git rev-parse --short HEAD`

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
  "mcp-online": false,
  "units": []
}
```

## Compilation & Verification

Building the egui WASM bundle runs entirely through `just`:

```sh
just setup   # One-time toolchain setup
just wasm    # Compiles renderer to /renderer/pkg/
just test    # Runs HEADLESS Lisp tests
just check   # Runs wasm build + byte-compile + tests
```
