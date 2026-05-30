# Workspace HUD Demo

The workspace HUD is the current example interface for `emacs-egui-panel`: a floating card that follows the active project and shows git/workspace status.

**Attention Conservation Notice**

For: Contributors working on the HUD experience or using it as a framework example

What: Current behavior, data payload, and development workflow for `workspace-hud`

Action: Keep demo-specific experiments here and move reusable behavior into `egui-panel`

Skip if: You are only changing the generic asset server or child-frame lifecycle

## Purpose

The demo proves that a standalone Emacs Lisp package can push live data into an egui/WASM renderer inside a floating child frame.

It is also where the HUD interface is still being explored. Treat it as a working example and product sketch, not a finished end-user package.

## User Entry Point

```elisp
(add-to-list 'load-path "/path/to/emacs-egui-panel/lisp")
(require 'workspace-hud)
(workspace-hud-toggle)
```

`workspace-hud-toggle` sets `egui-panel-asset-dir`, registers the HUD refresh hook, installs refresh triggers, and calls `egui-panel-show`.

## What It Shows

The current card renders:

- Resolved project root or project name.
- Working tree line stats, falling back to a changed-path count when numstat
  has no line data.
- Local location label.
- Current git branch, plus upstream ahead/behind counts when available.
- Last commit hash.
- MCP and unit fields retained in the renderer schema for experiment continuity.

`mcp-online` is currently always false in the standalone demo. It remains in the schema because the renderer still has a "Sources" section from the original HUD experiment.

## Refresh Behavior

The HUD refreshes when the panel is visible.

`window-buffer-change-functions` and `window-selection-change-functions` schedule a debounced refresh using `workspace-hud-debounce`.

`after-save-hook` schedules a faster refresh so git state updates quickly after file saves.

The root is resolved from the parent frame's selected window, not from `current-buffer`. Timer callbacks often run while the current buffer is the xwidget buffer or minibuffer.

## Data Collection

`workspace-hud` uses `vc-git` instead of shelling out directly through a separate process layer.

It collects:

- `git rev-parse --abbrev-ref HEAD` for branch.
- `git rev-list --left-right --count @{upstream}...HEAD` for upstream
  divergence, displayed on the right side as `↑2 ↓1`.
- `git diff --numstat -- .` and `git diff --cached --numstat -- .` for
  aggregate `+insertions -deletions` stats.
- `git status --porcelain` as a fallback changed-path count for untracked-only,
  binary-only, or mode-only changes.
- `git rev-parse --short HEAD` for last commit.
Non-repo buffers get placeholder state:

```json
{
  "branch": "—",
  "upstream": "",
  "changes": "+0 -0",
  "location": "Local",
  "last-commit": "",
  "project-name": "",
  "project-root": "",
  "mcp-online": false,
  "units": []
}
```

## Renderer Development

Build the renderer:

```sh
just wasm
```

Run the Lisp tests:

```sh
just test
```

Run the full local check:

```sh
just check
```

`check` rebuilds the WASM renderer, byte-compiles the Lisp files, and runs the ERT tests.

## Current Experiment Questions

The demo is the right place to decide:

- Which HUD sections are useful enough to keep.
- Whether the "Sources" section belongs in the standalone demo.
- How compact the card should be.
- Whether click actions should be added.
- Whether multiple panel roles need separate instances.

Do not add project-specific data collection to `egui-panel.el`. Keep `egui-panel` generic and let examples own their payloads.
