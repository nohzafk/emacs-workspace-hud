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
;; The panel serves assets locally from an in-process, pure Emacs Lisp HTTP
;; server and populates the status card with git details (branch, changes, last
;; commit, ahead/behind) and LSP/MCP status for the active project.
;;
;; Usage: M-x workspace-hud-toggle
;; Or for automatic visibility: M-x workspace-hud-auto-mode

;;; Code:

(require 'cl-lib)
(require 'xwidget)
(require 'json)
(require 'url-util)
(require 'vc-git)

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
(defvar workspace-hud--httpd-process nil)
(defvar workspace-hud--httpd-port nil)
(defvar workspace-hud--url nil)
(defvar workspace-hud--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file, used to locate the bundled WASM assets.")
(defvar workspace-hud--debounce-timer nil)
(defvar workspace-hud-auto-mode nil
  "Non-nil when the workspace HUD manages visibility automatically.")
(defvar workspace-hud--auto-paused nil)

(defvar workspace-hud-push-state-js "hudPushState"
  "Name of the JS global the WASM shell exposes for state pushes.")

(defvar workspace-hud-push-theme-js "hudPushTheme"
  "Name of the JS global the WASM shell exposes for theme pushes.")

;; ---------------------------------------------------------------------------
;; Local asset HTTP server (pure Elisp)
;; ---------------------------------------------------------------------------

(defun workspace-hud--asset-dir ()
  "Locate the asset directory containing index.html and pkg/."
  (expand-file-name "../renderer/" workspace-hud--dir))

(defun workspace-hud--content-type (file)
  "Return the HTTP Content-Type for FILE based on its extension."
  (pcase (downcase (or (file-name-extension file) ""))
    ("html" "text/html; charset=utf-8")
    ("js"   "text/javascript; charset=utf-8")
    ("wasm" "application/wasm")
    ("json" "application/json; charset=utf-8")
    ("css"  "text/css; charset=utf-8")
    (_      "application/octet-stream")))

(defun workspace-hud--read-file-bytes (file)
  "Return the raw bytes of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun workspace-hud--httpd-send (proc status ctype body)
  "Send an HTTP response over connection PROC, then half-close it.
STATUS is a status line like \"200 OK\".  BODY must be a unibyte string."
  (when (process-live-p proc)
    (let ((header (encode-coding-string
                   (format (concat "HTTP/1.1 %s\r\n"
                                   "Content-Type: %s\r\n"
                                   "Content-Length: %d\r\n"
                                   "Access-Control-Allow-Origin: *\r\n"
                                   "Cache-Control: no-store\r\n"
                                   "Connection: close\r\n\r\n")
                           status ctype (length body))
                   'utf-8)))
      (process-send-string proc (concat header body))
      (process-send-eof proc))))

(defun workspace-hud--resolve-asset (path)
  "Resolve request PATH to a readable file under the asset directory, or nil.
Strips any query/fragment, maps \"/\" to index.html, and rejects path
traversal and directories."
  (let ((asset-dir (workspace-hud--asset-dir)))
    (when asset-dir
      (let* ((clean (car (split-string path "[?#]")))
             (rel (if (member clean '("/" "")) "index.html"
                    (string-remove-prefix "/" clean)))
             (base (file-name-as-directory (expand-file-name asset-dir)))
             (file (expand-file-name rel base)))
        (and (string-prefix-p base file)  ; reject path traversal
             (file-readable-p file)
             (not (file-directory-p file))
             file)))))

(defun workspace-hud--httpd-respond (proc path)
  "Serve the file referenced by request PATH over connection PROC."
  (let ((file (workspace-hud--resolve-asset path)))
    (if file
        (workspace-hud--httpd-send proc "200 OK"
                                (workspace-hud--content-type file)
                                (workspace-hud--read-file-bytes file))
      (workspace-hud--httpd-send proc "404 Not Found" "text/plain; charset=utf-8"
                              (string-to-unibyte "404 Not Found")))))

(defun workspace-hud--httpd-filter (proc chunk)
  "Accumulate request CHUNK on PROC and respond once headers are complete."
  (let ((buf (concat (process-get proc :workspace-hud-request) chunk)))
    (process-put proc :workspace-hud-request buf)
    (when (string-match "\r\n\r\n" buf)
      (let* ((request-line (car (split-string buf "\r\n")))
             (fields (split-string request-line " "))
             (method (nth 0 fields))
             (path (or (nth 1 fields) "/")))
        (process-put proc :workspace-hud-request "")
        (if (member method '("GET" "HEAD"))
            (workspace-hud--httpd-respond proc path)
          (workspace-hud--httpd-send proc "405 Method Not Allowed"
                                  "text/plain; charset=utf-8"
                                  (string-to-unibyte "405 Method Not Allowed")))))))

(defun workspace-hud--ensure-httpd ()
  "Start the local asset server if needed and set `workspace-hud--url'."
  (unless (and workspace-hud--httpd-process
               (process-live-p workspace-hud--httpd-process))
    (setq workspace-hud--httpd-process
          (make-network-process
           :name "workspace-hud-httpd"
           :server t
           :host 'local
           :service t
           :family 'ipv4
           :coding 'binary
           :filter #'workspace-hud--httpd-filter
           :noquery t))
    (setq workspace-hud--httpd-port
          (process-contact workspace-hud--httpd-process :service)))
  (setq workspace-hud--url
        (format "http://127.0.0.1:%s/index.html" workspace-hud--httpd-port)))

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

(defun workspace-hud--url-with-theme ()
  "Return the panel URL with the current `default' face colors as a fragment.
The WASM shell reads `#bg=...&fg=...' on load so the first paint matches the
Emacs theme instead of flashing a default."
  (let* ((theme (workspace-hud--theme-payload))
         (bg (plist-get theme :bg))
         (fg (plist-get theme :fg))
         (font-size (plist-get theme :font-size))
         (surface-bg (plist-get theme :surface-bg)))
    (if (and workspace-hud--url bg fg)
        (format "%s#bg=%s&fg=%s&font-size=%s&surface-bg=%s"
                workspace-hud--url
                (url-hexify-string bg)
                (url-hexify-string fg)
                (url-hexify-string (format "%s" (or font-size "")))
                (url-hexify-string (or surface-bg "")))
      workspace-hud--url)))

(defun workspace-hud--theme-payload ()
  "Return current theme data for the renderer."
  (let* ((bg (face-background 'default nil 'default))
         (fg (face-foreground 'default nil 'default))
         (height (face-attribute 'default :height nil 'default))
         (font-size
          (cond
           ((integerp height) (/ height 10.0))
           ((floatp height)
            (* height (/ (frame-char-height workspace-hud--parent-frame) 1.0)))
           (t nil))))
    (list :bg bg
          :fg fg
          :font-size font-size
          :surface-bg (or workspace-hud-surface-background bg))))

(defun workspace-hud--push-state (state)
  "Push STATE (a plist or alist) as JSON to the panel renderer."
  (when (and workspace-hud--session (frame-live-p workspace-hud--frame))
    (let* ((json-str (json-encode state))
           (script (format "if (window.%s) { window.%s(%S); }"
                           workspace-hud-push-state-js
                           workspace-hud-push-state-js json-str)))
      (xwidget-webkit-execute-script workspace-hud--session script))))

(defun workspace-hud--push-theme ()
  "Push the current `default' face colors to the panel renderer."
  (when (and workspace-hud--session (frame-live-p workspace-hud--frame))
    (let* ((json-str (json-encode (workspace-hud--theme-payload)))
           (script (format "if (window.%s) { window.%s(%S); }"
                           workspace-hud-push-theme-js
                           workspace-hud-push-theme-js json-str)))
      (xwidget-webkit-execute-script workspace-hud--session script))))

;; ---------------------------------------------------------------------------
;; Session lifecycle
;; ---------------------------------------------------------------------------

(defun workspace-hud--prepare-xwidget-buffer (buf)
  "Hide BUF from buffer switchers and strip its window chrome."
  (with-current-buffer buf
    (rename-buffer workspace-hud-xwidget-buffer-name t)
    (setq-local mode-line-format nil)
    (setq-local header-line-format nil)
    (setq-local display-line-numbers nil)
    (setq-local left-fringe-width 0)
    (setq-local right-fringe-width 0)))

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
  "Create the child frame and load the WASM panel into an xwidget session."
  (let ((parent (selected-frame)))
    (unless (featurep 'xwidget-internal)
      (error "workspace-hud: this Emacs is not built with xwidget support"))
    (workspace-hud--ensure-httpd)
    (unless (frame-live-p workspace-hud--frame)
      (workspace-hud--make-frame parent)
      (workspace-hud--setup-hooks))
    (make-frame-visible workspace-hud--frame)
    (raise-frame workspace-hud--frame)
    (with-selected-frame workspace-hud--frame
      (let* ((window (frame-root-window workspace-hud--frame))
             (orig-buffer (window-buffer window)))
        (with-selected-window window
          (condition-case err
              (let* ((parent-win-config
                      (with-selected-frame workspace-hud--parent-frame
                        (current-window-configuration)))
                     (child-win-config (current-window-configuration))
                     (_ (xwidget-webkit-new-session (workspace-hud--url-with-theme)))
                     (session (xwidget-webkit-current-session))
                     (buf (xwidget-buffer session)))
                (with-selected-frame workspace-hud--parent-frame
                  (set-window-configuration parent-win-config))
                (set-window-configuration child-win-config)
                (setq workspace-hud--session session)
                (workspace-hud--prepare-xwidget-buffer buf)
                (set-window-buffer window buf)
                (set-window-dedicated-p window t)
                (when (and orig-buffer (not (eq orig-buffer buf))
                           (buffer-live-p orig-buffer)
                           (string-prefix-p " " (buffer-name orig-buffer)))
                  (kill-buffer orig-buffer))
                (run-with-timer 0.5 nil
                                (lambda ()
                                  (workspace-hud--push-theme)
                                  (workspace-hud-refresh)))
                (message "workspace-hud: panel session ready"))
            (error
             (message "workspace-hud: failed to start xwidget session: %S" err)
             (workspace-hud-cleanup))))))
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
  "Tear down the HUD frame, xwidget session, and asset server."
  (interactive)
  (workspace-hud--remove-hooks)
  (when (frame-live-p workspace-hud--frame)
    (delete-frame workspace-hud--frame)
    (setq workspace-hud--frame nil))
  (when workspace-hud--session
    (let ((buf (ignore-errors (xwidget-buffer workspace-hud--session))))
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions
               (delq 'xwidget-kill-buffer-query-function
                     kill-buffer-query-functions)))
          (kill-buffer buf))))
    (setq workspace-hud--session nil))
  (when (and workspace-hud--httpd-process
             (process-live-p workspace-hud--httpd-process))
    (delete-process workspace-hud--httpd-process))
  (setq workspace-hud--httpd-process nil
        workspace-hud--httpd-port nil
        workspace-hud--url nil))

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
    (setq workspace-hud--debounce-timer nil)))

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
