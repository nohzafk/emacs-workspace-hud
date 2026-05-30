;;; egui-panel.el --- Floating egui/WASM panel in an Emacs child frame -*- lexical-binding: t; -*-

;; Author: emacs-egui-panel
;; Version: 0.1.0
;; Keywords: convenience, frames, tools
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A reusable "push JSON -> render a themable floating egui panel" widget.
;;
;; The panel is a WebAssembly egui application loaded into an `xwidget-webkit'
;; child frame anchored to the top-right corner of the selected frame.  Assets
;; are served from a tiny local HTTP server implemented in Emacs Lisp: WebKit
;; refuses to instantiate WASM from `file://' origins, so a real `http://'
;; origin is required, but we keep that origin entirely in-process — no
;; external binary, no global network listener.
;;
;; This library is data-source agnostic.  It shows a panel and exposes
;; `egui-panel-push-state' / `egui-panel-push-theme'.  An application supplies
;; the WASM bundle (via `egui-panel-asset-dir') and the data to render, and
;; pushes initial state from `egui-panel-ready-hook'.  See the bundled
;; examples/workspace-hud demo.

;;; Code:

(require 'cl-lib)
(require 'xwidget)
(require 'json)
(require 'url-util)

(defgroup egui-panel nil
  "Floating egui/WASM panel rendered in an Emacs child frame."
  :group 'convenience
  :prefix "egui-panel-")

(defcustom egui-panel-width 280
  "Width of the panel child frame in pixels."
  :type 'integer)

(defcustom egui-panel-height 320
  "Height of the panel child frame in pixels."
  :type 'integer)

(defcustom egui-panel-margin-right 19
  "Horizontal offset from the right edge of the parent frame, in pixels."
  :type 'integer)

(defcustom egui-panel-margin-top 60
  "Vertical offset from the top edge of the parent frame, in pixels."
  :type 'integer)

(defcustom egui-panel-surface-background nil
  "Optional panel surface background color sent to the renderer.
When nil, the current `default' face background is used.  Applications can
change this at runtime and call `egui-panel-push-theme' to repaint."
  :type '(choice (const :tag "Use default face background" nil)
                 color))

(defvar egui-panel-asset-dir nil
  "Directory containing the panel assets: an `index.html' and a `pkg/' dir.
An application must set this before showing the panel.")

(defvar egui-panel-push-state-js "hudPushState"
  "Name of the JS global the WASM shell exposes for state pushes.")

(defvar egui-panel-push-theme-js "hudPushTheme"
  "Name of the JS global the WASM shell exposes for theme pushes.")

(defvar egui-panel-ready-hook nil
  "Normal hook run shortly after the panel session becomes ready.
Applications use this to push initial state.  It also runs on each
re-show of an already-initialized panel.")

(defcustom egui-panel-xwidget-buffer-name " *egui-panel-xwidget*"
  "Name for the internal xwidget buffer.
The leading space follows Emacs' hidden-buffer convention, keeping the panel's
xwidget buffer out of normal buffer switchers such as `consult-buffer'."
  :type 'string)

;; Internal state (single panel for now).
(defvar egui-panel--frame nil)
(defvar egui-panel--parent-frame nil)
(defvar egui-panel--session nil)
(defvar egui-panel--httpd-process nil)
(defvar egui-panel--httpd-port nil)
(defvar egui-panel--url nil)

;; ---------------------------------------------------------------------------
;; Local asset HTTP server (pure Elisp)
;; ---------------------------------------------------------------------------

(defun egui-panel--content-type (file)
  "Return the HTTP Content-Type for FILE based on its extension."
  (pcase (downcase (or (file-name-extension file) ""))
    ("html" "text/html; charset=utf-8")
    ("js"   "text/javascript; charset=utf-8")
    ("wasm" "application/wasm")
    ("json" "application/json; charset=utf-8")
    ("css"  "text/css; charset=utf-8")
    (_      "application/octet-stream")))

(defun egui-panel--read-file-bytes (file)
  "Return the raw bytes of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun egui-panel--httpd-send (proc status ctype body)
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

(defun egui-panel--resolve-asset (path)
  "Resolve request PATH to a readable file under `egui-panel-asset-dir', or nil.
Strips any query/fragment, maps \"/\" to index.html, and rejects path
traversal and directories."
  (when egui-panel-asset-dir
    (let* ((clean (car (split-string path "[?#]")))
           (rel (if (member clean '("/" "")) "index.html"
                  (string-remove-prefix "/" clean)))
           (base (file-name-as-directory (expand-file-name egui-panel-asset-dir)))
           (file (expand-file-name rel base)))
      (and (string-prefix-p base file)  ; reject path traversal
           (file-readable-p file)
           (not (file-directory-p file))
           file))))

(defun egui-panel--httpd-respond (proc path)
  "Serve the file referenced by request PATH over connection PROC."
  (let ((file (egui-panel--resolve-asset path)))
    (if file
        (egui-panel--httpd-send proc "200 OK"
                                (egui-panel--content-type file)
                                (egui-panel--read-file-bytes file))
      (egui-panel--httpd-send proc "404 Not Found" "text/plain; charset=utf-8"
                              (string-to-unibyte "404 Not Found")))))

(defun egui-panel--httpd-filter (proc chunk)
  "Accumulate request CHUNK on PROC and respond once headers are complete."
  (let ((buf (concat (process-get proc :egui-panel-request) chunk)))
    (process-put proc :egui-panel-request buf)
    (when (string-match "\r\n\r\n" buf)
      (let* ((request-line (car (split-string buf "\r\n")))
             (fields (split-string request-line " "))
             (method (nth 0 fields))
             (path (or (nth 1 fields) "/")))
        (process-put proc :egui-panel-request "")
        (if (member method '("GET" "HEAD"))
            (egui-panel--httpd-respond proc path)
          (egui-panel--httpd-send proc "405 Method Not Allowed"
                                  "text/plain; charset=utf-8"
                                  (string-to-unibyte "405 Method Not Allowed")))))))

(defun egui-panel--ensure-httpd ()
  "Start the local asset server if needed and set `egui-panel--url'."
  (unless egui-panel-asset-dir
    (error "egui-panel: `egui-panel-asset-dir' is not set"))
  (unless (and egui-panel--httpd-process
               (process-live-p egui-panel--httpd-process))
    (setq egui-panel--httpd-process
          (make-network-process
           :name "egui-panel-httpd"
           :server t
           :host 'local
           :service t
           :family 'ipv4
           :coding 'binary
           :filter #'egui-panel--httpd-filter
           :noquery t))
    (setq egui-panel--httpd-port
          (process-contact egui-panel--httpd-process :service)))
  (setq egui-panel--url
        (format "http://127.0.0.1:%s/index.html" egui-panel--httpd-port)))

;; ---------------------------------------------------------------------------
;; Child frame management
;; ---------------------------------------------------------------------------

(defun egui-panel--reposition-frame ()
  "Lock the panel frame to the top-right corner of the parent frame."
  (when (and (frame-live-p egui-panel--frame)
             (frame-live-p egui-panel--parent-frame))
    (let* ((parent-w (frame-pixel-width egui-panel--parent-frame))
           (target-x (- parent-w egui-panel-width egui-panel-margin-right))
           (target-y egui-panel-margin-top))
      (set-frame-position egui-panel--frame target-x target-y)
      (set-frame-size egui-panel--frame egui-panel-width egui-panel-height t))))

(defun egui-panel--make-frame (parent)
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
            (width . ,(/ egui-panel-width (frame-char-width)))
            (height . ,(/ egui-panel-height (frame-char-height)))
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
    (setq egui-panel--parent-frame parent)
    (setq egui-panel--frame (make-frame frame-params))
    ;; Point the child window at a private throwaway buffer so later xwidget
    ;; cleanup never captures and kills one of the user's real buffers.
    (set-window-buffer (frame-root-window egui-panel--frame)
                       (get-buffer-create " *egui-panel-placeholder*"))
    (egui-panel--reposition-frame)
    egui-panel--frame))

(defun egui-panel--on-parent-resize (&rest _)
  "Realign the panel when the parent frame layout changes."
  (when (and (frame-live-p egui-panel--frame)
             (frame-visible-p egui-panel--frame))
    (egui-panel--reposition-frame)))

(defun egui-panel--on-focus-change ()
  "Keep the panel on top and aligned when the parent frame gains focus."
  (when (and (frame-live-p egui-panel--frame)
             (frame-visible-p egui-panel--frame)
             (frame-live-p egui-panel--parent-frame)
             (eq (frame-focus-state egui-panel--parent-frame) t))
    (raise-frame egui-panel--frame)
    (egui-panel--reposition-frame)))

;; ---------------------------------------------------------------------------
;; State / theme push
;; ---------------------------------------------------------------------------

(defun egui-panel--url-with-theme ()
  "Return the panel URL with the current `default' face colors as a fragment.
The WASM shell reads `#bg=...&fg=...' on load so the first paint matches the
Emacs theme instead of flashing a default."
  (let* ((theme (egui-panel--theme-payload))
         (bg (plist-get theme :bg))
         (fg (plist-get theme :fg))
         (font-size (plist-get theme :font-size))
         (surface-bg (plist-get theme :surface-bg)))
    (if (and egui-panel--url bg fg)
        (format "%s#bg=%s&fg=%s&font-size=%s&surface-bg=%s"
                egui-panel--url
                (url-hexify-string bg)
                (url-hexify-string fg)
                (url-hexify-string (format "%s" (or font-size "")))
                (url-hexify-string (or surface-bg "")))
      egui-panel--url)))

(defun egui-panel--theme-payload ()
  "Return current theme data for the renderer."
  (let* ((bg (face-background 'default nil 'default))
         (fg (face-foreground 'default nil 'default))
         (height (face-attribute 'default :height nil 'default))
         (font-size
          (cond
           ((integerp height) (/ height 10.0))
           ((floatp height)
            (* height (/ (frame-char-height egui-panel--parent-frame) 1.0)))
           (t nil))))
    (list :bg bg
          :fg fg
          :font-size font-size
          :surface-bg (or egui-panel-surface-background bg))))

(defun egui-panel-push-state (state)
  "Push STATE (a plist or alist) as JSON to the panel renderer."
  (when (and egui-panel--session (frame-live-p egui-panel--frame))
    (let* ((json-str (json-encode state))
           (script (format "if (window.%s) { window.%s(%S); }"
                           egui-panel-push-state-js
                           egui-panel-push-state-js json-str)))
      (xwidget-webkit-execute-script egui-panel--session script))))

(defun egui-panel-push-theme ()
  "Push the current `default' face colors to the panel renderer."
  (when (and egui-panel--session (frame-live-p egui-panel--frame))
    (let* ((json-str (json-encode (egui-panel--theme-payload)))
           (script (format "if (window.%s) { window.%s(%S); }"
                           egui-panel-push-theme-js
                           egui-panel-push-theme-js json-str)))
      (xwidget-webkit-execute-script egui-panel--session script))))

;; ---------------------------------------------------------------------------
;; Session lifecycle
;; ---------------------------------------------------------------------------

(defun egui-panel--prepare-xwidget-buffer (buf)
  "Hide BUF from buffer switchers and strip its window chrome."
  (with-current-buffer buf
    (rename-buffer egui-panel-xwidget-buffer-name t)
    (setq-local mode-line-format nil)
    (setq-local header-line-format nil)
    (setq-local display-line-numbers nil)
    (setq-local left-fringe-width 0)
    (setq-local right-fringe-width 0)))

(defun egui-panel--setup-hooks ()
  "Register frame-tracking hooks."
  (add-hook 'window-size-change-functions #'egui-panel--on-parent-resize)
  (add-function :after after-focus-change-function #'egui-panel--on-focus-change)
  (add-hook 'kill-emacs-hook #'egui-panel-cleanup))

(defun egui-panel--remove-hooks ()
  "Tear down frame-tracking hooks."
  (remove-hook 'window-size-change-functions #'egui-panel--on-parent-resize)
  (remove-function after-focus-change-function #'egui-panel--on-focus-change)
  (remove-hook 'kill-emacs-hook #'egui-panel-cleanup))

(defun egui-panel--initialize-session ()
  "Create the child frame and load the WASM panel into an xwidget session."
  (let ((parent (selected-frame)))
    (unless (featurep 'xwidget-internal)
      (error "egui-panel: this Emacs is not built with xwidget support"))
    (egui-panel--ensure-httpd)
    (unless (frame-live-p egui-panel--frame)
      (egui-panel--make-frame parent)
      (egui-panel--setup-hooks))
    (make-frame-visible egui-panel--frame)
    (raise-frame egui-panel--frame)
    (with-selected-frame egui-panel--frame
      (let* ((window (frame-root-window egui-panel--frame))
             (orig-buffer (window-buffer window)))
        (with-selected-window window
          (condition-case err
              (let* ((parent-win-config
                      (with-selected-frame egui-panel--parent-frame
                        (current-window-configuration)))
                     (child-win-config (current-window-configuration))
                     (_ (xwidget-webkit-new-session (egui-panel--url-with-theme)))
                     (session (xwidget-webkit-current-session))
                     (buf (xwidget-buffer session)))
                (with-selected-frame egui-panel--parent-frame
                  (set-window-configuration parent-win-config))
                (set-window-configuration child-win-config)
                (setq egui-panel--session session)
                (egui-panel--prepare-xwidget-buffer buf)
                (set-window-buffer window buf)
                (set-window-dedicated-p window t)
                ;; Only kill our own throwaway placeholder, never a user buffer.
                (when (and orig-buffer (not (eq orig-buffer buf))
                           (buffer-live-p orig-buffer)
                           (string-prefix-p " " (buffer-name orig-buffer)))
                  (kill-buffer orig-buffer))
                (run-with-timer 0.5 nil
                                (lambda ()
                                  (egui-panel-push-theme)
                                  (run-hooks 'egui-panel-ready-hook)))
                (message "egui-panel: panel session ready"))
            (error
             (message "egui-panel: failed to start xwidget session: %S" err)
             (egui-panel-cleanup))))))
    (egui-panel--reposition-frame)))

;; ---------------------------------------------------------------------------
;; Public API
;; ---------------------------------------------------------------------------

;;;###autoload
(defun egui-panel-show ()
  "Show the panel, initializing the session on first use."
  (interactive)
  (if (frame-live-p egui-panel--frame)
      (progn
        (make-frame-visible egui-panel--frame)
        (raise-frame egui-panel--frame)
        (egui-panel--reposition-frame)
        (run-hooks 'egui-panel-ready-hook))
    (egui-panel--initialize-session)))

;;;###autoload
(defun egui-panel-hide ()
  "Hide the panel frame without destroying the session."
  (interactive)
  (when (frame-live-p egui-panel--frame)
    (make-frame-invisible egui-panel--frame)))

;;;###autoload
(defun egui-panel-toggle ()
  "Toggle panel visibility."
  (interactive)
  (if (and (frame-live-p egui-panel--frame)
           (frame-visible-p egui-panel--frame))
      (egui-panel-hide)
    (egui-panel-show)))

(defun egui-panel-visible-p ()
  "Return non-nil when the panel frame is live and visible."
  (and (frame-live-p egui-panel--frame)
       (frame-visible-p egui-panel--frame)))

;;;###autoload
(defun egui-panel-cleanup ()
  "Tear down the panel frame, xwidget session, and asset server."
  (interactive)
  (egui-panel--remove-hooks)
  (when (frame-live-p egui-panel--frame)
    (delete-frame egui-panel--frame)
    (setq egui-panel--frame nil))
  (when egui-panel--session
    (let ((buf (ignore-errors (xwidget-buffer egui-panel--session))))
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions
               (delq 'xwidget-kill-buffer-query-function
                     kill-buffer-query-functions)))
          (kill-buffer buf))))
    (setq egui-panel--session nil))
  (when (and egui-panel--httpd-process
             (process-live-p egui-panel--httpd-process))
    (delete-process egui-panel--httpd-process))
  (setq egui-panel--httpd-process nil
        egui-panel--httpd-port nil
        egui-panel--url nil))

(provide 'egui-panel)
;;; egui-panel.el ends here
