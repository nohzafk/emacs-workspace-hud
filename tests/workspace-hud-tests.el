;;; workspace-hud-tests.el --- ERT tests for the workspace-hud demo -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the demo's git collection (via vc-git) against throwaway repos,
;; plus the rendered state plist shape.
;;
;; Run with:
;;   emacs -Q --batch -L lisp -L tests -l tests/workspace-hud-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'workspace-hud)

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

(ert-deftest workspace-hud-test-toggle-applies-demo-frame-size ()
  "The demo owns its frame size instead of inheriting the generic default."
  (let ((workspace-hud-width 301)
        (workspace-hud-height 211)
        (egui-panel-width 1)
        (egui-panel-height 2)
        (egui-panel-asset-dir nil)
        (egui-panel-ready-hook nil)
        shown
        setup)
    (cl-letf (((symbol-function 'egui-panel-visible-p) (lambda () nil))
              ((symbol-function 'egui-panel-show) (lambda () (setq shown t)))
              ((symbol-function 'workspace-hud--setup-triggers)
               (lambda () (setq setup t))))
      (workspace-hud-toggle)
      (should (= egui-panel-width workspace-hud-width))
      (should (= egui-panel-height workspace-hud-height))
      (should (equal egui-panel-asset-dir (workspace-hud--asset-dir)))
      (should (memq #'workspace-hud-refresh egui-panel-ready-hook))
      (should setup)
      (should shown))))

(provide 'workspace-hud-tests)
;;; workspace-hud-tests.el ends here
