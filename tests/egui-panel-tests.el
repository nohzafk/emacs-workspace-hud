;;; egui-panel-tests.el --- ERT tests for egui-panel -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the reusable widget: content-type mapping, binary-safe file
;; reading, asset path resolution / traversal protection, the theme URL
;; fragment, and an end-to-end loopback fetch against the pure-Elisp server.
;;
;; Run with:
;;   emacs -Q --batch -L lisp -L tests -l tests/egui-panel-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url)
(require 'egui-panel)

(defconst egui-panel-tests--asset-dir
  (expand-file-name "../examples/workspace-hud/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Asset directory used by the integration test.")

;; ---------------------------------------------------------------------------
;; Pure-function unit tests
;; ---------------------------------------------------------------------------

(ert-deftest egui-panel-test-content-type ()
  (should (string-prefix-p "text/html"       (egui-panel--content-type "index.html")))
  (should (string-prefix-p "text/javascript" (egui-panel--content-type "x.JS")))
  (should (equal "application/wasm"          (egui-panel--content-type "x.wasm")))
  (should (string-prefix-p "application/json" (egui-panel--content-type "x.json")))
  (should (string-prefix-p "text/css"        (egui-panel--content-type "x.css")))
  (should (equal "application/octet-stream"  (egui-panel--content-type "x.bin")))
  (should (equal "application/octet-stream"  (egui-panel--content-type "noext"))))

(ert-deftest egui-panel-test-read-file-bytes-is-binary-safe ()
  (let ((f (make-temp-file "egui-panel-bytes")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (with-temp-file f
              (set-buffer-multibyte nil)
              (insert (unibyte-string 0 1 2 255 65))))
          (let ((bytes (egui-panel--read-file-bytes f)))
            (should-not (multibyte-string-p bytes))
            (should (= (length bytes) 5))
            (should (= (aref bytes 3) 255))
            (should (= (aref bytes 4) ?A))))
      (delete-file f))))

(ert-deftest egui-panel-test-resolve-asset ()
  (let ((egui-panel-asset-dir egui-panel-tests--asset-dir))
    ;; Valid requests resolve to a file.
    (should (egui-panel--resolve-asset "/"))
    (should (egui-panel--resolve-asset "/index.html"))
    (should (egui-panel--resolve-asset "/index.html?v=1"))   ; query stripped
    (should (egui-panel--resolve-asset "/index.html#frag"))  ; fragment stripped
    ;; Missing files and directories are rejected.
    (should-not (egui-panel--resolve-asset "/does-not-exist"))
    (should-not (egui-panel--resolve-asset "/pkg"))          ; a directory
    ;; Path traversal is rejected regardless of how it is spelled.
    (should-not (egui-panel--resolve-asset "/../../../etc/passwd"))
    (should-not (egui-panel--resolve-asset "/etc/passwd"))))

(ert-deftest egui-panel-test-resolve-asset-needs-dir ()
  (let ((egui-panel-asset-dir nil))
    (should-not (egui-panel--resolve-asset "/index.html"))))

(ert-deftest egui-panel-test-url-with-theme ()
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#112233"))
            ((symbol-function 'face-foreground) (lambda (&rest _) "#aabbcc"))
            ((symbol-function 'face-attribute)
             (lambda (_face attr &rest _)
               (pcase attr
                 (:height 150)
                 (_ nil)))))
    (let ((egui-panel--url "http://127.0.0.1:9999/index.html")
          (egui-panel-surface-background "#ddeeff"))
      (let ((u (egui-panel--url-with-theme)))
        ;; '#' is hexified to %23 by `url-hexify-string'.
        (should (string-match-p "#bg=%23112233&fg=%23aabbcc" u))
        (should (string-match-p "&font-size=15\\.0" u))
        (should (string-match-p "&surface-bg=%23ddeeff\\'" u))
        (should (string-prefix-p "http://127.0.0.1:9999/index.html#" u))))))

;; ---------------------------------------------------------------------------
;; End-to-end: pure-Elisp asset server over loopback
;; ---------------------------------------------------------------------------

(defun egui-panel-tests--fetch (path)
  "Fetch PATH from the running test server.
Return a plist (:status :content-type :content-length)."
  (let* ((u (format "http://127.0.0.1:%s%s" egui-panel--httpd-port path))
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

(defun egui-panel-tests--assert-fetch (path expect-status expect-ctype)
  "Fetch PATH and assert the status code and Content-Type prefix; return plist."
  (let ((r (egui-panel-tests--fetch path)))
    (should (equal (plist-get r :status) expect-status))
    (should (string-prefix-p expect-ctype (or (plist-get r :content-type) "")))
    r))

(ert-deftest egui-panel-test-httpd-serves-assets ()
  (skip-unless (file-readable-p
                (expand-file-name "pkg/workspace_hud_bg.wasm"
                                  egui-panel-tests--asset-dir)))
  (let ((egui-panel-asset-dir egui-panel-tests--asset-dir))
    (unwind-protect
        (progn
          (egui-panel--ensure-httpd)
          (should (integerp egui-panel--httpd-port))
          (egui-panel-tests--assert-fetch "/" 200 "text/html")
          (egui-panel-tests--assert-fetch "/index.html" 200 "text/html")
          (egui-panel-tests--assert-fetch "/pkg/workspace_hud.js" 200 "text/javascript")
          (let* ((wasm-path (expand-file-name "pkg/workspace_hud_bg.wasm"
                                              egui-panel-asset-dir))
                 (r (egui-panel-tests--assert-fetch "/pkg/workspace_hud_bg.wasm"
                                                    200 "application/wasm")))
            ;; Binary served intact: declared length == file size on disk.
            (should (= (plist-get r :content-length)
                       (file-attribute-size (file-attributes wasm-path)))))
          (egui-panel-tests--assert-fetch "/does-not-exist" 404 "text/plain")
          (egui-panel-tests--assert-fetch "/etc/passwd" 404 "text/plain"))
      (egui-panel-cleanup))
    ;; Cleanup tore the listener down.
    (should-not (and egui-panel--httpd-process
                     (process-live-p egui-panel--httpd-process)))))

(provide 'egui-panel-tests)
;;; egui-panel-tests.el ends here
