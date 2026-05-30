;;; workspace-hud-tests.el --- ERT tests for the workspace-hud -*- lexical-binding: t; -*-

;;; Commentary:

;; Unified test suite for the workspace HUD, covering:
;; 1. HTTP server logic, content-type mapping, binary safety, and path resolution.
;; 2. Loopback HTTP integration tests for serving the compiled WASM renderer.
;; 3. Git collector (via vc-git) against mock repositories.
;; 4. State plist mapping and JSON encoding shapes.
;; 5. Automated mode visibility controls.
;;
;; Run with:
;;   emacs -Q --batch -L lisp -L tests -l tests/workspace-hud-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url)
(require 'workspace-hud)

(defconst workspace-hud-tests--asset-dir
  (expand-file-name "../renderer/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Asset directory used by the integration test.")

;; ---------------------------------------------------------------------------
;; HTTP Server & Path Resolution Unit Tests (from egui-panel)
;; ---------------------------------------------------------------------------

(ert-deftest workspace-hud-test-content-type ()
  (should (string-prefix-p "text/html"       (workspace-hud--content-type "index.html")))
  (should (string-prefix-p "text/javascript" (workspace-hud--content-type "x.JS")))
  (should (equal "application/wasm"          (workspace-hud--content-type "x.wasm")))
  (should (string-prefix-p "application/json" (workspace-hud--content-type "x.json")))
  (should (string-prefix-p "text/css"        (workspace-hud--content-type "x.css")))
  (should (equal "application/octet-stream"  (workspace-hud--content-type "x.bin")))
  (should (equal "application/octet-stream"  (workspace-hud--content-type "noext"))))

(ert-deftest workspace-hud-test-read-file-bytes-is-binary-safe ()
  (let ((f (make-temp-file "workspace-hud-bytes")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (with-temp-file f
              (set-buffer-multibyte nil)
              (insert (unibyte-string 0 1 2 255 65))))
          (let ((bytes (workspace-hud--read-file-bytes f)))
            (should-not (multibyte-string-p bytes))
            (should (= (length bytes) 5))
            (should (= (aref bytes 3) 255))
            (should (= (aref bytes 4) ?A))))
      (delete-file f))))

(ert-deftest workspace-hud-test-resolve-asset ()
  (cl-letf (((symbol-function 'workspace-hud--asset-dir)
             (lambda () workspace-hud-tests--asset-dir)))
    ;; Valid requests resolve to a file.
    (should (workspace-hud--resolve-asset "/"))
    (should (workspace-hud--resolve-asset "/index.html"))
    (should (workspace-hud--resolve-asset "/index.html?v=1"))   ; query stripped
    (should (workspace-hud--resolve-asset "/index.html#frag"))  ; fragment stripped
    ;; Missing files and directories are rejected.
    (should-not (workspace-hud--resolve-asset "/does-not-exist"))
    (should-not (workspace-hud--resolve-asset "/pkg"))          ; a directory
    ;; Path traversal is rejected regardless of how it is spelled.
    (should-not (workspace-hud--resolve-asset "/../../../etc/passwd"))
    (should-not (workspace-hud--resolve-asset "/etc/passwd"))))

(ert-deftest workspace-hud-test-url-with-theme ()
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#112233"))
            ((symbol-function 'face-foreground) (lambda (&rest _) "#aabbcc"))
            ((symbol-function 'face-attribute)
             (lambda (_face attr &rest _)
               (pcase attr
                 (:height 150)
                 (_ nil)))))
    (let ((workspace-hud--url "http://127.0.0.1:9999/index.html")
          (workspace-hud-surface-background "#ddeeff"))
      (let ((u (workspace-hud--url-with-theme)))
        ;; '#' is hexified to %23 by `url-hexify-string'.
        (should (string-match-p "#bg=%23112233&fg=%23aabbcc" u))
        (should (string-match-p "&font-size=15\\.0" u))
        (should (string-match-p "&surface-bg=%23ddeeff\\'" u))
        (should (string-prefix-p "http://127.0.0.1:9999/index.html#" u))))))

(ert-deftest workspace-hud-test-prepare-xwidget-buffer-hides-buffer ()
  (let ((workspace-hud-xwidget-buffer-name
         (generate-new-buffer-name " *workspace-hud-test-xwidget*")))
    (with-temp-buffer
      (workspace-hud--prepare-xwidget-buffer (current-buffer))
      (should (equal (buffer-name) workspace-hud-xwidget-buffer-name))
      (should (string-prefix-p " " (buffer-name)))
      (should-not mode-line-format)
      (should-not header-line-format)
      (should-not display-line-numbers)
      (should (equal left-fringe-width 0))
      (should (equal right-fringe-width 0)))))

;; ---------------------------------------------------------------------------
;; Loopback HTTP integration test
;; ---------------------------------------------------------------------------

(defun workspace-hud-tests--fetch (path)
  "Fetch PATH from the running test server.
Return a plist (:status :content-type :content-length)."
  (let* ((u (format "http://127.0.0.1:%s%s" workspace-hud--httpd-port path))
         (buf (url-retrieve-synchronously u t t 10)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (let* ((status-line (buffer-substring (point) (line-end-position)))
                 (code (when (string-match "HTTP/1\\.[01] \\([0-9]+\\)" status-line)
                         (string-to-number (match-string 1 status-line))))
                 (ctype (progn (goto-char (point-min))
                               (when (re-search-forward "^Content-Type: \\(.*\\)" nil t)
                                 (string-trim (match-string 1)))))
                 (clen (progn (goto-char (point-min))
                              (when (re-search-forward "^Content-Length: \\([0-9]+\\)" nil t)
                                (string-to-number (match-string 1))))))
            (list :status code :content-type ctype :content-length clen)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun workspace-hud-tests--assert-fetch (path expect-status expect-ctype)
  "Fetch PATH and assert the status code and Content-Type prefix; return plist."
  (let ((r (workspace-hud-tests--fetch path)))
    (should (equal (plist-get r :status) expect-status))
    (should (string-prefix-p expect-ctype (or (plist-get r :content-type) "")))
    r))

(ert-deftest workspace-hud-test-httpd-serves-assets ()
  (skip-unless (file-readable-p
                (expand-file-name "pkg/workspace_hud_bg.wasm"
                                  workspace-hud-tests--asset-dir)))
  (cl-letf (((symbol-function 'workspace-hud--asset-dir)
             (lambda () workspace-hud-tests--asset-dir)))
    (unwind-protect
        (progn
          (workspace-hud--ensure-httpd)
          (should (integerp workspace-hud--httpd-port))
          (workspace-hud-tests--assert-fetch "/" 200 "text/html")
          (workspace-hud-tests--assert-fetch "/index.html" 200 "text/html")
          (workspace-hud-tests--assert-fetch "/pkg/workspace_hud.js" 200 "text/javascript")
          (let* ((wasm-path (expand-file-name "pkg/workspace_hud_bg.wasm"
                                              workspace-hud-tests--asset-dir))
                 (r (workspace-hud-tests--assert-fetch "/pkg/workspace_hud_bg.wasm"
                                                    200 "application/wasm")))
            ;; Binary served intact: declared length == file size on disk.
            (should (= (plist-get r :content-length)
                       (file-attribute-size (file-attributes wasm-path)))))
          (workspace-hud-tests--assert-fetch "/does-not-exist" 404 "text/plain")
          (workspace-hud-tests--assert-fetch "/etc/passwd" 404 "text/plain"))
      (workspace-hud-cleanup))
    ;; Cleanup tore the listener down.
    (should-not (and workspace-hud--httpd-process
                     (process-live-p workspace-hud--httpd-process)))))

;; ---------------------------------------------------------------------------
;; Git collection (via vc-git) against throwaway repos
;; ---------------------------------------------------------------------------

(defun workspace-hud-tests--git (root &rest args)
  "Run git ARGS in ROOT, signalling on failure."
  (let ((default-directory (file-name-as-directory root)))
    (unless (zerop (apply #'call-process "git" nil nil nil args))
      (error "git %S failed in %s" args root))))

(defmacro workspace-hud-tests--with-repo (var &rest body)
  "Bind VAR to a fresh temp git repo (branch main, one commit), run BODY, clean up."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "workspace-hud-repo" t))))
     (unwind-protect
         (progn
           (workspace-hud-tests--git ,var "init" "-q" "-b" "main")
           (workspace-hud-tests--git ,var "config" "user.email" "test@example.com")
           (workspace-hud-tests--git ,var "config" "user.name" "Test")
           (workspace-hud-tests--git ,var "config" "commit.gpgsign" "false")
           (with-temp-file (expand-file-name "README.md" ,var) (insert "hi\n"))
           (workspace-hud-tests--git ,var "add" "-A")
           (workspace-hud-tests--git ,var "commit" "-q" "-m" "init")
           ,@body)
       (delete-directory ,var t))))

(ert-deftest workspace-hud-test-clean-repo ()
  (skip-unless (executable-find "git"))
  (workspace-hud-tests--with-repo repo
    (should (equal (workspace-hud--branch repo) "main"))
    (should (equal (workspace-hud--changes repo) "+0 -0"))
    (should (string-match-p "\\`[0-9a-f]\\{7,\\}\\'"
                            (workspace-hud--last-commit repo)))))

(ert-deftest workspace-hud-test-branch-ahead-behind-upstream ()
  (skip-unless (executable-find "git"))
  (workspace-hud-tests--with-repo repo
    (workspace-hud-tests--git repo "checkout" "-q" "-b" "upstream")
    (with-temp-file (expand-file-name "upstream.txt" repo)
      (insert "upstream\n"))
    (workspace-hud-tests--git repo "add" "-A")
    (workspace-hud-tests--git repo "commit" "-q" "-m" "upstream")
    (workspace-hud-tests--git repo "checkout" "-q" "main")
    (with-temp-file (expand-file-name "local.txt" repo)
      (insert "local\n"))
    (workspace-hud-tests--git repo "add" "-A")
    (workspace-hud-tests--git repo "commit" "-q" "-m" "local")
    (workspace-hud-tests--git repo "branch" "--set-upstream-to=upstream" "main")
    (should (equal (workspace-hud--upstream-counts repo) '(1 . 1)))
    (should (equal (workspace-hud--branch repo) "main"))
    (should (equal (workspace-hud--upstream-display repo) "↑1 ↓1"))))

(ert-deftest workspace-hud-test-untracked-only-change-count-fallback ()
  (skip-unless (executable-find "git"))
  (workspace-hud-tests--with-repo repo
    (with-temp-file (expand-file-name "a.txt" repo) (insert "x"))
    (should (equal (workspace-hud--changes repo) "1 file"))
    (with-temp-file (expand-file-name "b.txt" repo) (insert "y"))
    (should (equal (workspace-hud--changes repo) "2 files"))))

(ert-deftest workspace-hud-test-tracked-change-diff-stats ()
  (skip-unless (executable-find "git"))
  (workspace-hud-tests--with-repo repo
    (with-temp-file (expand-file-name "README.md" repo)
      (insert "hi\ntracked\n"))
    (should (equal (workspace-hud--changes repo) "+1 -0"))))

(ert-deftest workspace-hud-test-staged-and-unstaged-diff-stats ()
  (skip-unless (executable-find "git"))
  (workspace-hud-tests--with-repo repo
    (with-temp-file (expand-file-name "README.md" repo)
      (insert "hi\nstaged\n"))
    (workspace-hud-tests--git repo "add" "README.md")
    (with-temp-file (expand-file-name "README.md" repo)
      (insert "hi\nstaged\nunstaged\n"))
    (should (equal (workspace-hud--changes repo) "+2 -0"))))

(ert-deftest workspace-hud-test-repo-root-from-subdir ()
  (skip-unless (executable-find "git"))
  (workspace-hud-tests--with-repo repo
    (let ((sub (expand-file-name "sub/deep/" repo)))
      (make-directory sub t)
      (should (file-equal-p (workspace-hud--repo-root sub) repo)))))

(ert-deftest workspace-hud-test-non-repo-returns-nil ()
  (let ((dir (file-name-as-directory (make-temp-file "workspace-hud-norepo" t))))
    (unwind-protect
        (should-not (workspace-hud--repo-root dir))
      (delete-directory dir t))))

(ert-deftest workspace-hud-test-branch-fallback-empty-repo ()
  (skip-unless (executable-find "git"))
  (let ((repo (file-name-as-directory (make-temp-file "workspace-hud-empty" t))))
    (unwind-protect
        (progn
          (workspace-hud-tests--git repo "init" "-q" "-b" "main")
          ;; No commits yet: branch/last-commit fall back gracefully.
          (should (equal (workspace-hud--branch repo) "—"))
          (should (equal (workspace-hud--last-commit repo) ""))
          (should (equal (workspace-hud--changes repo) "+0 -0")))
      (delete-directory repo t))))

(ert-deftest workspace-hud-test-state-json-shape ()
  "The pushed state encodes to the JSON the WASM renderer expects."
  (let* ((state (list :branch "main" :upstream "↑1" :changes "1 file" :location "Local"
                      :last-commit "abc1234"
                      :project-name "demo" :project-root "/x/demo"
                      :mcp-online :json-false :units []))
         (json (json-encode state))
         (parsed (let ((json-object-type 'alist)
                       (json-array-type 'list))
                   (json-read-from-string json))))
    (should (equal (alist-get 'branch parsed) "main"))
    (should (equal (alist-get 'upstream parsed) "↑1"))
    ;; Hyphenated keys preserved.
    (should (equal (alist-get 'last-commit parsed) "abc1234"))
    ;; Booleans encode as real JSON booleans, not strings.
    (should (eq (alist-get 'mcp-online parsed) :json-false))
    ;; Empty units encodes as [], not null.
    (should (string-match-p "\"units\":\\[\\]" json))))

;; ---------------------------------------------------------------------------
;; Mode / Visibility Mock Tests
;; ---------------------------------------------------------------------------

(ert-deftest workspace-hud-test-toggle-shows-manual ()
  (let (shown setup)
    (cl-letf (((symbol-function 'workspace-hud-visible-p) (lambda () nil))
              ((symbol-function 'workspace-hud-show) (lambda () (setq shown t)))
              ((symbol-function 'workspace-hud--setup-triggers) (lambda () (setq setup t))))
      (workspace-hud-toggle)
      (should-not workspace-hud--auto-paused)
      (should setup)
      (should shown))))

(ert-deftest workspace-hud-test-auto-sync-shows-in-repo ()
  "Auto mode shows the panel when the selected buffer belongs to a repo."
  (let ((workspace-hud-auto-mode t)
        shown
        setup)
    (cl-letf (((symbol-function 'workspace-hud--resolve-root)
               (lambda () "/tmp/repo"))
              ((symbol-function 'workspace-hud-visible-p) (lambda () nil))
              ((symbol-function 'workspace-hud-show) (lambda () (setq shown t)))
              ((symbol-function 'workspace-hud--setup-triggers)
               (lambda () (setq setup t))))
      (workspace-hud--sync-auto)
      (should setup)
      (should shown))))

(ert-deftest workspace-hud-test-auto-sync-refreshes-visible-repo ()
  "Auto mode refreshes instead of recreating an already visible panel."
  (let ((workspace-hud-auto-mode t)
        refreshed
        shown)
    (cl-letf (((symbol-function 'workspace-hud--resolve-root)
               (lambda () "/tmp/repo"))
              ((symbol-function 'workspace-hud-visible-p) (lambda () t))
              ((symbol-function 'workspace-hud-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'workspace-hud-show)
               (lambda () (setq shown t))))
      (workspace-hud--sync-auto)
      (should refreshed)
      (should-not shown))))

(ert-deftest workspace-hud-test-auto-sync-hides-outside-repo ()
  "Auto mode hides the panel when the selected buffer is outside Git."
  (let ((workspace-hud-auto-mode t)
        hidden
        shown)
    (cl-letf (((symbol-function 'workspace-hud--resolve-root)
               (lambda () nil))
              ((symbol-function 'workspace-hud-hide) (lambda () (setq hidden t)))
              ((symbol-function 'workspace-hud-show) (lambda () (setq shown t))))
      (workspace-hud--sync-auto)
      (should hidden)
      (should-not shown))))

(ert-deftest workspace-hud-test-auto-sync-stays-hidden-when-paused ()
  "Manual off pauses auto mode until the user explicitly turns it back on."
  (let ((workspace-hud-auto-mode t)
        (workspace-hud--auto-paused t)
        hidden
        shown
        resolved)
    (cl-letf (((symbol-function 'workspace-hud--resolve-root)
               (lambda ()
                 (setq resolved t)
                 "/tmp/repo"))
              ((symbol-function 'workspace-hud-hide) (lambda () (setq hidden t)))
              ((symbol-function 'workspace-hud-show) (lambda () (setq shown t))))
      (workspace-hud--sync-auto)
      (should hidden)
      (should-not shown)
      (should-not resolved))))

(ert-deftest workspace-hud-test-refresh-hides-outside-repo-in-auto-mode ()
  "Auto refresh hides outside Git instead of pushing placeholder state."
  (let ((workspace-hud-auto-mode t)
        hidden
        pushed
        themed)
    (cl-letf (((symbol-function 'workspace-hud--resolve-root)
               (lambda () nil))
              ((symbol-function 'workspace-hud-hide) (lambda () (setq hidden t)))
              ((symbol-function 'workspace-hud--push-state)
               (lambda (_state) (setq pushed t)))
              ((symbol-function 'workspace-hud--push-theme)
               (lambda () (setq themed t))))
      (workspace-hud-refresh)
      (should hidden)
      (should-not pushed)
      (should-not themed))))

(ert-deftest workspace-hud-test-refresh-hides-when-auto-paused ()
  "Auto refresh respects a manual pause even in a Git repo."
  (let ((workspace-hud-auto-mode t)
        (workspace-hud--auto-paused t)
        hidden
        pushed
        themed)
    (cl-letf (((symbol-function 'workspace-hud--resolve-root)
               (lambda () "/tmp/repo"))
              ((symbol-function 'workspace-hud-hide) (lambda () (setq hidden t)))
              ((symbol-function 'workspace-hud--push-state)
               (lambda (_state) (setq pushed t)))
              ((symbol-function 'workspace-hud--push-theme)
               (lambda () (setq themed t))))
      (workspace-hud-refresh)
      (should hidden)
      (should-not pushed)
      (should-not themed))))

(ert-deftest workspace-hud-test-auto-change-schedules-while-hidden ()
  "Auto mode keeps listening while hidden so it can reappear in Git repos."
  (let ((workspace-hud-auto-mode t)
        (workspace-hud--debounce-timer nil)
        scheduled)
    (cl-letf (((symbol-function 'workspace-hud-visible-p) (lambda () nil))
              ((symbol-function 'run-with-idle-timer)
               (lambda (_delay _repeat fn)
                 (setq scheduled fn)
                 'workspace-hud-test-timer)))
      (workspace-hud--on-change)
      (should (eq scheduled #'workspace-hud--sync-auto)))))

(ert-deftest workspace-hud-test-manual-hide-pauses-auto-mode ()
  "Manual hide prevents auto mode from immediately reopening the HUD."
  (let ((workspace-hud-auto-mode t)
        (workspace-hud--auto-paused nil)
        hidden)
    (cl-letf (((symbol-function 'workspace-hud-hide) (lambda () (setq hidden t))))
      (workspace-hud--hide-manual)
      (should hidden)
      (should workspace-hud--auto-paused))))

(ert-deftest workspace-hud-test-manual-show-clears-auto-pause ()
  "Manual show re-enables automatic HUD visibility."
  (let ((workspace-hud--auto-paused t)
        shown
        setup)
    (cl-letf (((symbol-function 'workspace-hud-show) (lambda () (setq shown t)))
              ((symbol-function 'workspace-hud--setup-triggers)
               (lambda () (setq setup t))))
      (workspace-hud--show-manual)
      (should-not workspace-hud--auto-paused)
      (should setup)
      (should shown))))

(provide 'workspace-hud-tests)
;;; workspace-hud-tests.el ends here
