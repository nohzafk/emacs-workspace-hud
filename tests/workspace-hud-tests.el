;;; workspace-hud-tests.el --- ERT tests for the workspace-hud -*- lexical-binding: t; -*-

;;; Commentary:

;; Unified test suite for the workspace HUD, covering:
;; 1. Git collector (via vc-git) against mock repositories.
;; 2. State plist mapping and JSON encoding shapes.
;; 3. Automated mode visibility controls.
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
  (expand-file-name "../ui/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Asset directory used by the integration test.")

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

(defmacro workspace-hud-tests--with-symbol-values (bindings &rest body)
  "Temporarily bind global symbol-value BINDINGS while running BODY."
  (declare (indent 1))
  (let ((saved (make-symbol "saved")))
    `(let ((,saved
            (list
             ,@(mapcar
                (lambda (binding)
                  (let ((symbol (car binding)))
                    `(list ',symbol
                           (boundp ',symbol)
                           (and (boundp ',symbol)
                                (symbol-value ',symbol)))))
                bindings))))
       (unwind-protect
           (progn
             ,@(mapcar
                (lambda (binding)
                  `(set ',(car binding) ,(cadr binding)))
                bindings)
             ,@body)
         (dolist (entry ,saved)
           (if (cadr entry)
               (set (car entry) (cl-caddr entry))
             (makunbound (car entry))))))))

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

(ert-deftest workspace-hud-test-upstream-synced-display ()
  (should (equal (workspace-hud--upstream-format '(0 . 0)) "synced")))

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
                      :lsp-status "online"
                      :diagnostic-errors 1
                      :diagnostic-warnings 2
                      :diagnostic-notes 3))
         (json (json-encode state))
         (parsed (let ((json-object-type 'alist)
                       (json-array-type 'list))
                   (json-read-from-string json))))
    (should (equal (alist-get 'branch parsed) "main"))
    (should (equal (alist-get 'upstream parsed) "↑1"))
    ;; Hyphenated keys preserved.
    (should (equal (alist-get 'last-commit parsed) "abc1234"))
    (should (equal (alist-get 'lsp-status parsed) "online"))
    (should (= (alist-get 'diagnostic-errors parsed) 1))
    (should (= (alist-get 'diagnostic-warnings parsed) 2))
    (should (= (alist-get 'diagnostic-notes parsed) 3))))

(ert-deftest workspace-hud-test-lsp-status-detects-clients ()
  (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t)))
    (should (equal (workspace-hud--lsp-status) "online")))
  (workspace-hud-tests--with-symbol-values ((lsp-bridge-mode t))
    (cl-letf (((symbol-function 'lsp-bridge-has-lsp-server-p) (lambda () t)))
      (should (equal (workspace-hud--lsp-status) "online"))))
  (workspace-hud-tests--with-symbol-values ((lsp-mode t))
    (should (equal (workspace-hud--lsp-status) "online"))))

(ert-deftest workspace-hud-test-lsp-status-distinguishes-non-code-buffers ()
  (with-temp-buffer
    (text-mode)
    (should (equal (workspace-hud--lsp-status) "n/a")))
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (equal (workspace-hud--lsp-status) "offline"))))

(ert-deftest workspace-hud-test-flycheck-diagnostic-counts ()
  (workspace-hud-tests--with-symbol-values
      ((flycheck-mode t)
       (flycheck-current-errors '(error warning info notice)))
    (cl-letf (((symbol-function 'flycheck-error-level) #'identity))
      (should (equal (workspace-hud--diagnostic-counts)
                     '(:errors 1 :warnings 1 :notes 2))))))

(ert-deftest workspace-hud-test-flymake-diagnostic-counts ()
  (workspace-hud-tests--with-symbol-values
      ((flycheck-mode nil)
       (flymake-mode t))
    (cl-letf (((symbol-function 'flymake-diagnostics)
               (lambda (&rest _) '(error warning note info)))
              ((symbol-function 'flymake-diagnostic-type) #'identity))
      (should (equal (workspace-hud--diagnostic-counts)
                     '(:errors 1 :warnings 1 :notes 2))))))

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

(ert-deftest workspace-hud-test-update-watch-lifecycle ()
  "Test that `workspace-hud--update-watch' starts, switches, and cancels file watches correctly."
  (let (added-watches
        removed-watches
        (workspace-hud--file-watch nil))
    (cl-letf (((symbol-function 'workspace-hud--watching-supported-p) (lambda () t))
              ((symbol-function 'file-directory-p) (lambda (_dir) t))
              ((symbol-function 'file-notify-add-watch)
               (lambda (dir _flags _callback)
                 (let ((desc (make-symbol (concat "watch-desc-" dir))))
                   (push (cons dir desc) added-watches)
                   desc)))
              ((symbol-function 'file-notify-rm-watch)
               (lambda (desc)
                 (push desc removed-watches)
                 t)))
      ;; 1. Update watch on /tmp/repo-a should add a watch
      (workspace-hud--update-watch "/tmp/repo-a")
      (should workspace-hud--file-watch)
      (should (equal (car workspace-hud--file-watch) "/tmp/repo-a"))
      (should (= (length added-watches) 1))
      (should (string-suffix-p ".git" (caar added-watches)))
      
      ;; 2. Update watch with same repo shouldn't add another watch
      (let ((current-desc (cdr workspace-hud--file-watch)))
        (workspace-hud--update-watch "/tmp/repo-a")
        (should (eq (cdr workspace-hud--file-watch) current-desc))
        (should (= (length added-watches) 1)))
      
      ;; 3. Update watch with new repo (/tmp/repo-b) should remove old and add new
      (let ((old-desc (cdr workspace-hud--file-watch)))
        (workspace-hud--update-watch "/tmp/repo-b")
        (should (equal (car workspace-hud--file-watch) "/tmp/repo-b"))
        (should (= (length added-watches) 2))
        (should (member old-desc removed-watches)))
      
      ;; 4. Update watch with nil should remove the watch
      (let ((latest-desc (cdr workspace-hud--file-watch)))
        (workspace-hud--update-watch nil)
        (should-not workspace-hud--file-watch)
        (should (member latest-desc removed-watches))))))

(ert-deftest workspace-hud-test-cleanup-removes-watch ()
  "Test that `workspace-hud-cleanup' and `workspace-hud--teardown-triggers' tear down any active watch."
  (let (removed-watch
        (workspace-hud--file-watch (cons "/tmp/repo" 'mock-desc)))
    (cl-letf (((symbol-function 'workspace-hud--watching-supported-p) (lambda () t))
              ((symbol-function 'file-notify-rm-watch)
               (lambda (desc)
                 (setq removed-watch desc)
                 t))
              ((symbol-function 'workspace-hud--remove-hooks) (lambda () nil))
              ((symbol-function 'delete-frame) (lambda (&rest _) nil)))
      ;; Cleanup should call file-notify-rm-watch
      (workspace-hud-cleanup)
      (should-not workspace-hud--file-watch)
      (should (eq removed-watch 'mock-desc))))
  
  (let (removed-watch
        (workspace-hud--file-watch (cons "/tmp/repo" 'mock-desc)))
    (cl-letf (((symbol-function 'workspace-hud--watching-supported-p) (lambda () t))
              ((symbol-function 'file-notify-rm-watch)
               (lambda (desc)
                 (setq removed-watch desc)
                 t)))
      ;; Teardown triggers should call file-notify-rm-watch
      (workspace-hud--teardown-triggers)
      (should-not workspace-hud--file-watch)
      (should (eq removed-watch 'mock-desc)))))

(provide 'workspace-hud-tests)
;;; workspace-hud-tests.el ends here
