;;; workspace-hud.el --- Workspace-status HUD demo for egui-panel -*- lexical-binding: t; -*-

;; Author: emacs-egui-panel
;; Version: 0.1.0
;; Keywords: tools, vc
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Flagship demo for `egui-panel': a small corner card showing the active
;; project's git status — branch, working-tree change count, last commit,
;; and project root.
;;
;; It is intentionally thin: it collects data with `vc-git', builds a plist,
;; and pushes it to the panel.  All the rendering and frame plumbing lives in
;; `egui-panel'.  This is a demo for exploring the panel idea, not a finished
;; product.
;;
;; Usage: M-x workspace-hud-toggle

;;; Code:

(require 'egui-panel)
(require 'vc-git)
(require 'cl-lib)

(defgroup workspace-hud nil
  "Workspace-status HUD demo built on `egui-panel'."
  :group 'tools
  :prefix "workspace-hud-")

(defcustom workspace-hud-debounce 0.5
  "Idle seconds before refreshing after a buffer or window change."
  :type 'number)

(defcustom workspace-hud-width 260
  "Width of the workspace HUD child frame in pixels."
  :type 'integer)

(defcustom workspace-hud-height 230
  "Height of the workspace HUD child frame in pixels."
  :type 'integer)

(defvar workspace-hud--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file, used to locate the bundled WASM assets.")

(defvar workspace-hud--debounce-timer nil)

(defvar workspace-hud-auto-mode nil
  "Non-nil when the workspace HUD manages visibility automatically.")

(defvar workspace-hud--auto-paused nil
  "Non-nil when manual toggle has paused automatic HUD reappearance.")

(defun workspace-hud--asset-dir ()
  "Locate the demo asset directory containing index.html and pkg/."
  (expand-file-name "../examples/workspace-hud/" workspace-hud--dir))

(defun workspace-hud--configure-panel ()
  "Apply workspace HUD settings to the reusable panel."
  (setq egui-panel-width workspace-hud-width
        egui-panel-height workspace-hud-height
        egui-panel-asset-dir (workspace-hud--asset-dir))
  (add-hook 'egui-panel-ready-hook #'workspace-hud-refresh))

;; ---------------------------------------------------------------------------
;; Git collection (via vc-git)
;; ---------------------------------------------------------------------------

(defun workspace-hud--repo-root (&optional dir)
  "Return the git repo root for DIR (or `default-directory'), or nil."
  (let ((default-directory (or dir default-directory)))
    (or (ignore-errors (vc-root-dir))
        (locate-dominating-file default-directory ".git"))))

(defun workspace-hud--git (root &rest args)
  "Run git ARGS in ROOT via vc-git, returning trimmed output or nil."
  (let ((default-directory (file-name-as-directory root)))
    (ignore-errors
      (let ((out (apply #'vc-git--run-command-string nil args)))
        (and out (string-trim out))))))

(defun workspace-hud--branch (root)
  "Return the current branch name in ROOT, or a placeholder."
  (let ((b (workspace-hud--git root "rev-parse" "--abbrev-ref" "HEAD")))
    (if (and b (> (length b) 0)) b "—")))

(defun workspace-hud--upstream-counts (root)
  "Return (AHEAD . BEHIND) for ROOT relative to its upstream, or nil."
  (let ((out (workspace-hud--git root
                                 "rev-list" "--left-right" "--count"
                                 "@{upstream}...HEAD")))
    (when (and out (string-match "\\`\\([0-9]+\\)[[:space:]]+\\([0-9]+\\)\\'" out))
      ;; For @{upstream}...HEAD, git reports upstream-only first, then
      ;; HEAD-only. Display ahead first because it is the local action signal.
      (cons (string-to-number (match-string 2 out))
            (string-to-number (match-string 1 out))))))

(defun workspace-hud--upstream-display (root)
  "Return an ahead/behind display string for ROOT, or an empty string."
  (let ((counts (workspace-hud--upstream-counts root)))
    (if counts
        (workspace-hud--upstream-format counts)
      "")))

(defun workspace-hud--upstream-format (counts)
  "Return an ahead/behind display string for upstream COUNTS."
  (let ((ahead (car counts))
        (behind (cdr counts))
        parts)
    (when (> ahead 0)
      (push (format "↑%d" ahead) parts))
    (when (> behind 0)
      (push (format "↓%d" behind) parts))
    (if parts
        (mapconcat #'identity (nreverse parts) " ")
      "")))

(defun workspace-hud--status-count (root)
  "Return the number of changed paths in ROOT according to git status."
  (let* ((out (workspace-hud--git root "status" "--porcelain"))
         (lines (and out (split-string out "\n" t))))
    (length lines)))

(defun workspace-hud--parse-numstat (out)
  "Return (INSERTIONS . DELETIONS) parsed from git numstat OUT."
  (let ((insertions 0)
        (deletions 0))
    (dolist (line (and out (split-string out "\n" t)))
      (let ((columns (split-string line "\t")))
        (when (>= (length columns) 2)
          (let ((added (nth 0 columns))
                (deleted (nth 1 columns)))
            ;; Binary files are reported as \"-\"; treat those as stat-less and
            ;; let the status-count fallback surface dirty binary/mode-only repos.
            (when (string-match-p "\\`[0-9]+\\'" added)
              (cl-incf insertions (string-to-number added)))
            (when (string-match-p "\\`[0-9]+\\'" deleted)
              (cl-incf deletions (string-to-number deleted)))))))
    (cons insertions deletions)))

(defun workspace-hud--diff-stats (root)
  "Return aggregate unstaged and staged diff stats for ROOT."
  (let* ((unstaged (workspace-hud--parse-numstat
                    (workspace-hud--git root "diff" "--numstat" "--" ".")))
         (staged (workspace-hud--parse-numstat
                  (workspace-hud--git root "diff" "--cached" "--numstat" "--" "."))))
    (cons (+ (car unstaged) (car staged))
          (+ (cdr unstaged) (cdr staged)))))

(defun workspace-hud--changes (root)
  "Return human-readable change stats for ROOT."
  (let* ((stats (workspace-hud--diff-stats root))
         (insertions (car stats))
         (deletions (cdr stats))
         (status-count (workspace-hud--status-count root)))
    (cond
     ((or (> insertions 0) (> deletions 0))
      (format "+%d -%d" insertions deletions))
     ((> status-count 0)
      (format "%d file%s" status-count (if (= status-count 1) "" "s")))
     (t
      "+0 -0"))))

(defun workspace-hud--last-commit (root)
  "Return the short last-commit hash in ROOT, or an empty string."
  (or (workspace-hud--git root "rev-parse" "--short" "HEAD") ""))

;; ---------------------------------------------------------------------------
;; Collect + push
;; ---------------------------------------------------------------------------

(defun workspace-hud--resolve-root ()
  "Resolve the repo root from the buffer the user is actually looking at.
Refreshes fire from idle timers where `current-buffer' is unpredictable.  When
the panel has a parent frame, use that frame's selected window; otherwise use
the selected window in the current frame."
  (let ((buf (if (frame-live-p egui-panel--parent-frame)
                 (window-buffer
                  (frame-selected-window egui-panel--parent-frame))
               (window-buffer (selected-window)))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (workspace-hud--repo-root)))))

(defun workspace-hud-refresh ()
  "Collect workspace/git status and push it to the panel."
  (interactive)
  (let* ((root (workspace-hud--resolve-root))
         (root (and root (directory-file-name (expand-file-name root))))
         (state
          (if root
              (list :branch (workspace-hud--branch root)
                    :upstream (workspace-hud--upstream-display root)
                    :changes (workspace-hud--changes root)
                    :location "Local"
                    :last-commit (workspace-hud--last-commit root)
                    :project-name (file-name-nondirectory root)
                    :project-root root
                    :mcp-online :json-false
                    :units [])
            (list :branch "—" :upstream "" :changes "+0 -0" :location "Local"
                  :last-commit ""
                  :project-name "" :project-root ""
                  :mcp-online :json-false :units []))))
    (if (and workspace-hud-auto-mode
             (or workspace-hud--auto-paused (not root)))
        (egui-panel-hide)
      (egui-panel-push-theme)
      (egui-panel-push-state state))))

;; ---------------------------------------------------------------------------
;; Event-driven triggers
;; ---------------------------------------------------------------------------

(defun workspace-hud--schedule (delay fn)
  "Run FN after DELAY idle seconds, replacing any pending refresh timer."
  (when workspace-hud--debounce-timer
    (cancel-timer workspace-hud--debounce-timer))
  (setq workspace-hud--debounce-timer
        (run-with-idle-timer delay nil fn)))

(defun workspace-hud--sync-auto ()
  "Show the HUD for Git-backed buffers and hide it elsewhere."
  (when workspace-hud-auto-mode
    (if workspace-hud--auto-paused
        (egui-panel-hide)
      (if (workspace-hud--resolve-root)
          (progn
            (workspace-hud--configure-panel)
            (workspace-hud--setup-triggers)
            (if (egui-panel-visible-p)
                (workspace-hud-refresh)
              (egui-panel-show)))
        (egui-panel-hide)))))

(defun workspace-hud--on-change (&rest _)
  "Debounced refresh on buffer/window change."
  (when (or workspace-hud-auto-mode (egui-panel-visible-p))
    (workspace-hud--schedule
     workspace-hud-debounce
     (if workspace-hud-auto-mode
         #'workspace-hud--sync-auto
       #'workspace-hud-refresh))))

(defun workspace-hud--on-save ()
  "Refresh shortly after saving a file."
  (when (or workspace-hud-auto-mode (egui-panel-visible-p))
    (workspace-hud--schedule
     0.1
     (if workspace-hud-auto-mode
         #'workspace-hud--sync-auto
       #'workspace-hud-refresh))))

(defun workspace-hud--setup-triggers ()
  "Register collection triggers."
  (add-hook 'window-buffer-change-functions #'workspace-hud--on-change)
  (add-hook 'window-selection-change-functions #'workspace-hud--on-change)
  (add-hook 'after-save-hook #'workspace-hud--on-save))

(defun workspace-hud--teardown-triggers ()
  "Remove collection triggers."
  (remove-hook 'window-buffer-change-functions #'workspace-hud--on-change)
  (remove-hook 'window-selection-change-functions #'workspace-hud--on-change)
  (remove-hook 'after-save-hook #'workspace-hud--on-save)
  (when workspace-hud--debounce-timer
    (cancel-timer workspace-hud--debounce-timer)
    (setq workspace-hud--debounce-timer nil)))

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

(defun workspace-hud--show-manual ()
  "Show the workspace HUD with manual trigger ownership."
  (setq workspace-hud--auto-paused nil)
  (workspace-hud--configure-panel)
  (workspace-hud--setup-triggers)
  (egui-panel-show))

(defun workspace-hud--hide-manual ()
  "Hide the workspace HUD and release manual trigger ownership."
  (when workspace-hud-auto-mode
    (setq workspace-hud--auto-paused t))
  (egui-panel-hide)
  (unless workspace-hud-auto-mode
    (remove-hook 'egui-panel-ready-hook #'workspace-hud-refresh)
    (workspace-hud--teardown-triggers)))

;;;###autoload
(defun workspace-hud-toggle ()
  "Toggle the workspace-status HUD panel."
  (interactive)
  (if (egui-panel-visible-p)
      (workspace-hud--hide-manual)
    (workspace-hud--show-manual)))

;;;###autoload
(define-minor-mode workspace-hud-auto-mode
  "Automatically show the workspace HUD in Git repos and hide it elsewhere."
  :global t
  :group 'workspace-hud
  (if workspace-hud-auto-mode
      (progn
        (setq workspace-hud--auto-paused nil)
        (workspace-hud--configure-panel)
        (workspace-hud--setup-triggers)
        (workspace-hud--sync-auto))
    (setq workspace-hud--auto-paused nil)
    (egui-panel-hide)
    (remove-hook 'egui-panel-ready-hook #'workspace-hud-refresh)
    (workspace-hud--teardown-triggers)))

(provide 'workspace-hud)
;;; workspace-hud.el ends here
