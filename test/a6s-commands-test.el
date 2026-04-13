;;; a6s-commands-test.el --- Command tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for a6s-commands.el: connection guard, region extraction,
;; invocation behavior, input validation surfaces from command layer.

;;; Code:

(require 'test-helper)

(ert-deftest a6s-commands-test-ensure-connected-signals ()
  "Commands refuse to run while disconnected."
  (a6s-test--reset-state)
  (should-error (a6s-commands--ensure-connected) :type 'user-error))

(ert-deftest a6s-commands-test-buffer-language ()
  "Language guess strips -mode / -ts-mode suffix."
  (with-temp-buffer
    (setq-local major-mode 'python-mode)
    (should (equal (a6s-commands--buffer-language) "python"))
    (setq-local major-mode 'typescript-ts-mode)
    (should (equal (a6s-commands--buffer-language) "typescript"))))

(ert-deftest a6s-commands-test-region-or-buffer-no-region ()
  "Without an active region, the whole buffer is returned."
  (with-temp-buffer
    (insert "hello world")
    (should (equal (a6s-commands--region-or-buffer) "hello world"))))

(ert-deftest a6s-commands-test-file-path-fallback ()
  "File path falls back to buffer name when no file."
  (with-temp-buffer
    (rename-buffer "xyz" t)
    (should (equal (a6s-commands--file-path) "xyz"))))

(ert-deftest a6s-commands-test-connect-ok ()
  "a6s-connect dispatches to a6s-api-connect."
  (a6s-test--install-mocks)
  (a6s-test--reset-state)
  (unwind-protect
      (progn
        (a6s-connect)
        (should (a6s-api-connected-p)))
    (a6s-test--uninstall-mocks)
    (a6s-test--reset-state)))

(ert-deftest a6s-commands-test-disconnect ()
  "a6s-disconnect closes connection."
  (a6s-test-with-connection
   (a6s-disconnect)
   (should-not (a6s-api-connected-p))))

(ert-deftest a6s-commands-test-status ()
  "a6s-status runs without error."
  (a6s-test--reset-state)
  (a6s-status))

(ert-deftest a6s-commands-test-invoke-agent-sends-request ()
  "a6s-invoke-agent sends an agents.invoke request."
  (a6s-test-with-connection
   (a6s-invoke-agent "architect-ai" "design a thing")
   (should (equal (a6s-test--last-sent-method) "agents.invoke"))
   (let ((params (a6s-test--last-sent-params)))
     (should (equal (plist-get params :agentType) "architect-ai"))
     (should (equal (plist-get params :task) "design a thing")))))

(ert-deftest a6s-commands-test-explain-region ()
  "a6s-explain-region sends code.explain."
  (a6s-test-with-connection
   (with-temp-buffer
     (insert "def foo(): pass")
     (setq-local major-mode 'python-mode)
     (a6s-explain-region))
   (should (equal (a6s-test--last-sent-method) "code.explain"))))

(ert-deftest a6s-commands-test-review-region ()
  "a6s-review-region sends code.review with reviewType."
  (a6s-test-with-connection
   (with-temp-buffer
     (insert "x = eval(input())")
     (setq-local major-mode 'python-mode)
     (a6s-review-region "security"))
   (should (equal (a6s-test--last-sent-method) "code.review"))
   (should (equal (plist-get (a6s-test--last-sent-params) :reviewType)
                  "security"))))

(ert-deftest a6s-commands-test-generate-tests ()
  "a6s-generate-tests-region sends code.generateTests."
  (a6s-test-with-connection
   (with-temp-buffer
     (insert "function add(a,b){return a+b}")
     (setq-local major-mode 'js-mode)
     (a6s-generate-tests-region))
   (should (equal (a6s-test--last-sent-method) "code.generateTests"))))

(ert-deftest a6s-commands-test-refactor-no-instructions ()
  "Refactor with empty instructions does not include :instructions."
  (a6s-test-with-connection
   (with-temp-buffer
     (insert "x=1")
     (setq-local major-mode 'python-mode)
     (a6s-refactor-region ""))
   (let ((params (a6s-test--last-sent-params)))
     (should-not (plist-get params :instructions)))))

(ert-deftest a6s-commands-test-list-tasks ()
  "a6s-list-tasks sends background.list."
  (a6s-test-with-connection
   (a6s-list-tasks)
   (should (equal (a6s-test--last-sent-method) "background.list"))))

(ert-deftest a6s-commands-test-cancel-task ()
  "a6s-cancel-task sends background.cancel."
  (a6s-test-with-connection
   (a6s-cancel-task "task_1")
   (should (equal (a6s-test--last-sent-method) "background.cancel"))))

(ert-deftest a6s-commands-test-list-agents ()
  "a6s-list-agents sends agents.list."
  (a6s-test-with-connection
   (a6s-list-agents)
   (should (equal (a6s-test--last-sent-method) "agents.list"))))

(ert-deftest a6s-commands-test-execution-status ()
  "a6s-execution-status sends execution.status."
  (a6s-test-with-connection
   (a6s-execution-status "exec_42")
   (should (equal (a6s-test--last-sent-method) "execution.status"))
   (should (equal (plist-get (a6s-test--last-sent-params) :executionId)
                  "exec_42"))))

(ert-deftest a6s-commands-test-background-launch ()
  "a6s-background-launch sends background.launch."
  (a6s-test-with-connection
   (a6s-background-launch "coder-ai" "write tests")
   (should (equal (a6s-test--last-sent-method) "background.launch"))
   (let ((params (a6s-test--last-sent-params)))
     (should (equal (plist-get params :agentType) "coder-ai"))
     (should (equal (plist-get params :task) "write tests")))))

(ert-deftest a6s-commands-test-background-output ()
  "a6s-background-output sends background.output."
  (a6s-test-with-connection
   (a6s-background-output "task_7")
   (should (equal (a6s-test--last-sent-method) "background.output"))
   (should (equal (plist-get (a6s-test--last-sent-params) :taskId)
                  "task_7"))))

(ert-deftest a6s-commands-test-preview-no-artifacts ()
  "Preview with no pending artifacts prints message."
  (a6s-test-with-connection
   (setq a6s-commands--last-artifacts nil)
   (a6s-preview-changes)
   (should-not (equal (a6s-test--last-sent-method) "artifacts.preview"))))

(ert-deftest a6s-commands-test-apply-no-artifacts ()
  "Apply with no pending artifacts prints message."
  (a6s-test-with-connection
   (setq a6s-commands--last-artifacts nil)
   (a6s-apply-artifacts)
   (should-not (equal (a6s-test--last-sent-method) "artifacts.apply"))))

(provide 'a6s-commands-test)

;;; a6s-commands-test.el ends here
