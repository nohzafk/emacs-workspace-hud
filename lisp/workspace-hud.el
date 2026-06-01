;;; workspace-hud.el --- Floating workspace HUD in an Emacs child frame -*- lexical-binding: t; -*-

;; Author: emacs-egui-panel
;; Version: 0.1.0
;; Keywords: convenience, frames, tools, vc
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A modern workspace HUD for Emacs. It anchors a floating status card (rendered
;; in an xwidget-webkit child frame using egui compiled to WebAssembly) to the
;; top-right corner of the selected frame.
;;
;; It registers as an app with the generic emacs-egui framework to serve WASM/HTML
;; assets locally and communicates status with git details and LSP/MCP status.
;;
;; Usage: M-x workspace-hud-toggle
;; Or for automatic visibility: M-x workspace-hud-auto-mode

;;; Code:

(require 'cl-lib)
(require 'xwidget)
(require 'json)
(require 'url-util)
(require 'vc-git)
(require 'filenotify)

(eval-and-compile
  (defvar workspace-hud--dir
    (file-name-directory (or load-file-name
                             (bound-and-true-p byte-compile-current-file)
                             buffer-file-name
                             default-directory))
    "Directory containing workspace-hud lisp files.")

  ;; Ensure emacs-egui is found and loaded.
  (unless (or (featurep 'emacs-egui)
              (locate-library "emacs-egui"))
    (let ((egui-dir (expand-file-name "../emacs-egui/lisp/" workspace-hud--dir)))
      (unless (file-exists-p (expand-file-name "emacs-egui.el" egui-dir))
        (error "workspace-hud: emacs-egui not found on `load-path' and \
no bundled copy under %s. Install emacs-egui, or clone submodules with: \
git submodule update --init --recursive" egui-dir))
      (add-to-list 'load-path egui-dir)))
  (require 'emacs-egui))

;; Version gate
(when (version< emacs-egui-version "0.1.0")
  (error "workspace-hud requires emacs-egui >= 0.1.0, found %s" emacs-egui-version))

;; Register UI directory
(emacs-egui-register-app "workspace-hud"
                         (expand-file-name "../ui/" workspace-hud--dir))

(defgroup workspace-hud nil
  "Floating workspace HUD rendered in an Emacs child frame."
  :group 'tools
  :prefix "workspace-hud-")

(defcustom workspace-hud-width 260
  "Width of the workspace HUD child frame in pixels."
  :type 'integer)

(defcustom workspace-hud-height 230
  "Height of the workspace HUD child frame in pixels."
  :type 'integer)

(defcustom workspace-hud-margin-right 19
  "Horizontal offset from the right edge of the parent frame, in pixels."
  :type 'integer)

(defcustom workspace-hud-margin-top 60
  "Vertical offset from the top edge of the parent frame, in pixels."
  :type 'integer)

(defcustom workspace-hud-debounce 0.5
  "Idle seconds before refreshing after a buffer or window change."
  :type 'number)

(defcustom workspace-hud-surface-background nil
  "Optional panel surface background color sent to the renderer.
When nil, the current `default' face background is used."
  :type '(choice (const :tag "Use default face background" nil)
                 color))

(defcustom workspace-hud-xwidget-buffer-name " *workspace-hud-xwidget*"
  "Name for the internal xwidget buffer.
The leading space follows Emacs' hidden-buffer convention, keeping the panel's
xwidget buffer out of normal buffer switchers such as `consult-buffer'."
  :type 'string)

;; Internal state.
(defvar workspace-hud--frame nil)
(defvar workspace-hud--parent-frame nil)
(defvar workspace-hud--session nil)
(defvar workspace-hud--debounce-timer nil)
(defvar workspace-hud-auto-mode nil
  "Non-nil when the workspace HUD manages visibility automatically.")
(defvar workspace-hud--auto-paused nil)
(defvar workspace-hud--file-watch nil
  "Cons cell of (REPO-ROOT . WATCH-DESCRIPTOR) for the currently watched repository.")

;; ---------------------------------------------------------------------------
;; Child frame management
;; ---------------------------------------------------------------------------

(defun workspace-hud--reposition-frame ()
  "Lock the panel frame to the top-right corner of the parent frame."
  (when (and (frame-live-p workspace-hud--frame)
             (frame-live-p workspace-hud--parent-frame))
    (let* ((parent-w (frame-pixel-width workspace-hud--parent-frame))
           (target-x (- parent-w workspace-hud-width workspace-hud-margin-right))
           (target-y workspace-hud-margin-top))
      (set-frame-position workspace-hud--frame target-x target-y)
      (set-frame-size workspace-hud--frame workspace-hud-width workspace-hud-height t))))

(defun workspace-hud--make-frame (parent)
  "Create the undecorated, focus-less child frame anchored to PARENT."
  (let* ((bg (face-background 'default nil 'default))
         (fg (face-foreground 'default nil 'default))
         (frame-params
          `((parent-frame . ,parent)
            (no-accept-focus . t)
            (no-focus-on-map . t)
            (minibuffer . nil)
            (undecorated . t)
            (visibility . nil)
            (left . 0) (top . 0)
            (width . ,(/ workspace-hud-width (frame-char-width)))
            (height . ,(/ workspace-hud-height (frame-char-height)))
            (internal-border-width . 0)
            (vertical-scroll-bars . nil)
            (horizontal-scroll-bars . nil)
            (left-fringe . 0) (right-fringe . 0)
            (tool-bar-lines . 0) (menu-bar-lines . 0) (tab-bar-lines . 0)
            (background-color . ,bg)
            (foreground-color . ,fg)
            (alpha-background . 0)
            (cursor-type . nil)
            (unsplittable . t)
            (user-size . t) (user-position . t))))
    (setq workspace-hud--parent-frame parent)
    (setq workspace-hud--frame (make-frame frame-params))
    ;; Point the child window at a private throwaway buffer.
    (set-window-buffer (frame-root-window workspace-hud--frame)
                       (get-buffer-create " *workspace-hud-placeholder*"))
    (workspace-hud--reposition-frame)
    workspace-hud--frame))

(defun workspace-hud--on-parent-resize (&rest _)
  "Realign the panel when the parent frame layout changes."
  (when (and (frame-live-p workspace-hud--frame)
             (frame-visible-p workspace-hud--frame))
    (workspace-hud--reposition-frame)))

(defun workspace-hud--on-focus-change ()
  "Keep the panel on top and aligned when the parent frame gains focus."
  (when (and (frame-live-p workspace-hud--frame)
             (frame-visible-p workspace-hud--frame)
             (frame-live-p workspace-hud--parent-frame)
             (eq (frame-focus-state workspace-hud--parent-frame) t))
    (raise-frame workspace-hud--frame)
    (workspace-hud--reposition-frame)))

;; ---------------------------------------------------------------------------
;; State / theme push
;; ---------------------------------------------------------------------------

(defun workspace-hud--push-state (state)
  "Push STATE (a plist or alist) as JSON to the panel renderer via emacs-egui."
  (when workspace-hud--session
    (emacs-egui-send-state workspace-hud--session state)))

(defun workspace-hud--push-theme ()
  "Push the current `default' face colors to the panel renderer via emacs-egui."
  (when workspace-hud--session
    (emacs-egui-send-theme workspace-hud--session)))

;; ---------------------------------------------------------------------------
;; Session lifecycle
;; ---------------------------------------------------------------------------

(defun workspace-hud--setup-hooks ()
  "Register frame-tracking hooks."
  (add-hook 'window-size-change-functions #'workspace-hud--on-parent-resize)
  (add-function :after after-focus-change-function #'workspace-hud--on-focus-change)
  (add-hook 'kill-emacs-hook #'workspace-hud-cleanup))

(defun workspace-hud--remove-hooks ()
  "Tear down frame-tracking hooks."
  (remove-hook 'window-size-change-functions #'workspace-hud--on-parent-resize)
  (remove-function after-focus-change-function #'workspace-hud--on-focus-change)
  (remove-hook 'kill-emacs-hook #'workspace-hud-cleanup))

(defun workspace-hud--initialize-session ()
  "Create the child frame and load the WASM panel into an xwidget session using emacs-egui."
  (let ((parent (selected-frame)))
    (unless (frame-live-p workspace-hud--frame)
      (workspace-hud--make-frame parent)
      (workspace-hud--setup-hooks))
    (make-frame-visible workspace-hud--frame)
    (raise-frame workspace-hud--frame)
    (let* ((session (emacs-egui-create-buffer
                     :app-name "workspace-hud"
                     :buffer-name workspace-hud-xwidget-buffer-name))
           (buf (plist-get session :buffer))
           (window (frame-root-window workspace-hud--frame)))
      (setq workspace-hud--session session)
      (set-window-buffer window buf)
      (set-window-dedicated-p window t)
      (run-with-timer 0.5 nil
                      (lambda ()
                        (emacs-egui-send-theme session)
                        (workspace-hud-refresh)))
      (message "workspace-hud: panel session ready via emacs-egui"))
    (workspace-hud--reposition-frame)))

(defun workspace-hud-show ()
  "Show the HUD, initializing the session on first use."
  (interactive)
  (if (frame-live-p workspace-hud--frame)
      (progn
        (make-frame-visible workspace-hud--frame)
        (raise-frame workspace-hud--frame)
        (workspace-hud--reposition-frame)
        (workspace-hud-refresh))
    (workspace-hud--initialize-session)))

(defun workspace-hud-hide ()
  "Hide the HUD frame without destroying the session."
  (interactive)
  (when (frame-live-p workspace-hud--frame)
    (make-frame-invisible workspace-hud--frame)))

(defun workspace-hud-visible-p ()
  "Return non-nil when the HUD frame is live and visible."
  (and (frame-live-p workspace-hud--frame)
       (frame-visible-p workspace-hud--frame)))

(defun workspace-hud-cleanup ()
  "Tear down the HUD frame, xwidget session, and active watchers."
  (interactive)
  (workspace-hud--update-watch nil)
  (workspace-hud--remove-hooks)
  (when (frame-live-p workspace-hud--frame)
    (delete-frame workspace-hud--frame)
    (setq workspace-hud--frame nil))
  (when workspace-hud--session
    (let ((buf (ignore-errors (plist-get workspace-hud--session :buffer))))
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions
               (delq 'xwidget-kill-buffer-query-function
                     kill-buffer-query-functions)))
          (kill-buffer buf))))
    (setq workspace-hud--session nil)))

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
Refreshes fire from idle timers where `current-buffer' is unpredictable. When
the panel has a parent frame, use that frame's selected window; otherwise use
the selected window in the current frame."
  (let ((buf (if (frame-live-p workspace-hud--parent-frame)
                 (window-buffer
                  (frame-selected-window workspace-hud--parent-frame))
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
    (workspace-hud--update-watch root)
    (if (and workspace-hud-auto-mode
             (or workspace-hud--auto-paused (not root)))
         (workspace-hud-hide)
      (workspace-hud--push-theme)
      (workspace-hud--push-state state))))

;; ---------------------------------------------------------------------------
;; Event-driven triggers
;; ---------------------------------------------------------------------------

(defun workspace-hud--schedule (delay fn)
  "Run FN after DELAY idle seconds, replacing any pending refresh timer."
  (when workspace-hud--debounce-timer
    (cancel-timer workspace-hud--debounce-timer))
  (setq workspace-hud--debounce-timer
        (run-with-idle-timer delay nil fn)))

(defun workspace-hud--watching-supported-p ()
  "Return non-nil if Emacs supports file notifications."
  (and (fboundp 'file-notify-add-watch)
       (boundp 'file-notify--library)
       file-notify--library))

(defun workspace-hud--update-watch (root)
  "Ensure a file watch is active on ROOT's .git directory.
If ROOT is nil, or if it changes, any existing watch is cleanly removed."
  (when (workspace-hud--watching-supported-p)
    (let ((git-dir (and root (expand-file-name ".git" root))))
      ;; 1. If the repository root changed or is nil, cancel the existing watch
      (when (and workspace-hud--file-watch
                 (or (not root)
                     (not (string= (car workspace-hud--file-watch) root))))
        (ignore-errors
          (file-notify-rm-watch (cdr workspace-hud--file-watch)))
        (setq workspace-hud--file-watch nil))
      
      ;; 2. Establish a new watch on the .git directory if none exists
      (when (and git-dir
                 (file-directory-p git-dir)
                 (not workspace-hud--file-watch))
        (let ((watch-desc
               (ignore-errors
                 (file-notify-add-watch
                  git-dir
                  '(change)
                  (lambda (_event)
                    ;; Trigger a debounced refresh
                    (workspace-hud--schedule
                     workspace-hud-debounce
                     (if workspace-hud-auto-mode
                         #'workspace-hud--sync-auto
                       #'workspace-hud-refresh)))))))
          (when watch-desc
            (setq workspace-hud--file-watch (cons root watch-desc))))))))

(defun workspace-hud--sync-auto ()
  "Show the HUD for Git-backed buffers and hide it elsewhere."
  (when workspace-hud-auto-mode
    (if workspace-hud--auto-paused
        (workspace-hud-hide)
      (if (workspace-hud--resolve-root)
          (progn
            (workspace-hud--setup-triggers)
            (if (workspace-hud-visible-p)
                (workspace-hud-refresh)
              (workspace-hud-show)))
        (workspace-hud-hide)))))

(defun workspace-hud--on-change (&rest _)
  "Debounced refresh on buffer/window change."
  (when (or workspace-hud-auto-mode (workspace-hud-visible-p))
    (workspace-hud--schedule
     workspace-hud-debounce
     (if workspace-hud-auto-mode
         #'workspace-hud--sync-auto
       #'workspace-hud-refresh))))

(defun workspace-hud--on-save ()
  "Refresh shortly after saving a file."
  (when (or workspace-hud-auto-mode (workspace-hud-visible-p))
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
    (setq workspace-hud--debounce-timer nil))
  (workspace-hud--update-watch nil))

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

(defun workspace-hud--show-manual ()
  "Show the workspace HUD with manual trigger ownership."
  (setq workspace-hud--auto-paused nil)
  (workspace-hud--setup-triggers)
  (workspace-hud-show))

(defun workspace-hud--hide-manual ()
  "Hide the workspace HUD and release manual trigger ownership."
  (when workspace-hud-auto-mode
    (setq workspace-hud--auto-paused t))
  (workspace-hud-hide)
  (unless workspace-hud-auto-mode
    (workspace-hud--teardown-triggers)))

;;;###autoload
(defun workspace-hud-toggle ()
  "Toggle the workspace-status HUD panel."
  (interactive)
  (if (workspace-hud-visible-p)
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
        (workspace-hud--setup-triggers)
        (workspace-hud--sync-auto))
    (setq workspace-hud--auto-paused nil)
    (workspace-hud-hide)
    (workspace-hud--teardown-triggers)))

(provide 'workspace-hud)
;;; workspace-hud.el ends here
