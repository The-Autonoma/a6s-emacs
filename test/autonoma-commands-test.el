;;; autonoma-commands-test.el --- Command tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for autonoma-commands.el: connection guard, region extraction,
;; invocation behavior, input validation surfaces from command layer.

;;; Code:

(require 'test-helper)

(ert-deftest autonoma-commands-test-ensure-connected-signals ()
  "Commands refuse to run while disconnected."
  (autonoma-test--reset-state)
  (should-error (autonoma-commands--ensure-connected) :type 'user-error))

(ert-deftest autonoma-commands-test-buffer-language ()
  "Language guess strips -mode / -ts-mode suffix."
  (with-temp-buffer
    (setq-local major-mode 'python-mode)
    (should (equal (autonoma-commands--buffer-language) "python"))
    (setq-local major-mode 'typescript-ts-mode)
    (should (equal (autonoma-commands--buffer-language) "typescript"))))

(ert-deftest autonoma-commands-test-region-or-buffer-no-region ()
  "Without an active region, the whole buffer is returned."
  (with-temp-buffer
    (insert "hello world")
    (should (equal (autonoma-commands--region-or-buffer) "hello world"))))

(ert-deftest autonoma-commands-test-file-path-fallback ()
  "File path falls back to buffer name when no file."
  (with-temp-buffer
    (rename-buffer "xyz" t)
    (should (equal (autonoma-commands--file-path) "xyz"))))

(ert-deftest autonoma-commands-test-connect-ok ()
  "autonoma-connect dispatches to autonoma-api-connect."
  (autonoma-test--install-mocks)
  (autonoma-test--reset-state)
  (unwind-protect
      (progn
        (autonoma-connect)
        (should (autonoma-api-connected-p)))
    (autonoma-test--uninstall-mocks)
    (autonoma-test--reset-state)))

(ert-deftest autonoma-commands-test-disconnect ()
  "autonoma-disconnect closes connection."
  (autonoma-test-with-connection
   (autonoma-disconnect)
   (should-not (autonoma-api-connected-p))))

(ert-deftest autonoma-commands-test-status ()
  "autonoma-status runs without error."
  (autonoma-test--reset-state)
  (autonoma-status))

(ert-deftest autonoma-commands-test-invoke-agent-sends-request ()
  "autonoma-invoke-agent sends an agents.invoke request."
  (autonoma-test-with-connection
   (autonoma-invoke-agent "architect-ai" "design a thing")
   (should (equal (autonoma-test--last-sent-method) "agents.invoke"))
   (let ((params (autonoma-test--last-sent-params)))
     (should (equal (plist-get params :agentType) "architect-ai"))
     (should (equal (plist-get params :task) "design a thing")))))

(ert-deftest autonoma-commands-test-explain-region ()
  "autonoma-explain-region sends code.explain."
  (autonoma-test-with-connection
   (with-temp-buffer
     (insert "def foo(): pass")
     (setq-local major-mode 'python-mode)
     (autonoma-explain-region))
   (should (equal (autonoma-test--last-sent-method) "code.explain"))))

(ert-deftest autonoma-commands-test-review-region ()
  "autonoma-review-region sends code.review with reviewType."
  (autonoma-test-with-connection
   (with-temp-buffer
     (insert "x = eval(input())")
     (setq-local major-mode 'python-mode)
     (autonoma-review-region "security"))
   (should (equal (autonoma-test--last-sent-method) "code.review"))
   (should (equal (plist-get (autonoma-test--last-sent-params) :reviewType)
                  "security"))))

(ert-deftest autonoma-commands-test-generate-tests ()
  "autonoma-generate-tests-region sends code.generateTests."
  (autonoma-test-with-connection
   (with-temp-buffer
     (insert "function add(a,b){return a+b}")
     (setq-local major-mode 'js-mode)
     (autonoma-generate-tests-region))
   (should (equal (autonoma-test--last-sent-method) "code.generateTests"))))

(ert-deftest autonoma-commands-test-refactor-no-instructions ()
  "Refactor with empty instructions does not include :instructions."
  (autonoma-test-with-connection
   (with-temp-buffer
     (insert "x=1")
     (setq-local major-mode 'python-mode)
     (autonoma-refactor-region ""))
   (let ((params (autonoma-test--last-sent-params)))
     (should-not (plist-get params :instructions)))))

(ert-deftest autonoma-commands-test-list-tasks ()
  "autonoma-list-tasks sends background.list."
  (autonoma-test-with-connection
   (autonoma-list-tasks)
   (should (equal (autonoma-test--last-sent-method) "background.list"))))

(ert-deftest autonoma-commands-test-cancel-task ()
  "autonoma-cancel-task sends background.cancel."
  (autonoma-test-with-connection
   (autonoma-cancel-task "task_1")
   (should (equal (autonoma-test--last-sent-method) "background.cancel"))))

(ert-deftest autonoma-commands-test-list-agents ()
  "autonoma-list-agents sends agents.list."
  (autonoma-test-with-connection
   (autonoma-list-agents)
   (should (equal (autonoma-test--last-sent-method) "agents.list"))))

(ert-deftest autonoma-commands-test-execution-status ()
  "autonoma-execution-status sends execution.status."
  (autonoma-test-with-connection
   (autonoma-execution-status "exec_42")
   (should (equal (autonoma-test--last-sent-method) "execution.status"))
   (should (equal (plist-get (autonoma-test--last-sent-params) :executionId)
                  "exec_42"))))

(ert-deftest autonoma-commands-test-background-launch ()
  "autonoma-background-launch sends background.launch."
  (autonoma-test-with-connection
   (autonoma-background-launch "coder-ai" "write tests")
   (should (equal (autonoma-test--last-sent-method) "background.launch"))
   (let ((params (autonoma-test--last-sent-params)))
     (should (equal (plist-get params :agentType) "coder-ai"))
     (should (equal (plist-get params :task) "write tests")))))

(ert-deftest autonoma-commands-test-background-output ()
  "autonoma-background-output sends background.output."
  (autonoma-test-with-connection
   (autonoma-background-output "task_7")
   (should (equal (autonoma-test--last-sent-method) "background.output"))
   (should (equal (plist-get (autonoma-test--last-sent-params) :taskId)
                  "task_7"))))

(ert-deftest autonoma-commands-test-preview-no-artifacts ()
  "Preview with no pending artifacts prints message."
  (autonoma-test-with-connection
   (setq autonoma-commands--last-artifacts nil)
   (autonoma-preview-changes)
   (should-not (equal (autonoma-test--last-sent-method) "artifacts.preview"))))

(ert-deftest autonoma-commands-test-apply-no-artifacts ()
  "Apply with no pending artifacts prints message."
  (autonoma-test-with-connection
   (setq autonoma-commands--last-artifacts nil)
   (autonoma-apply-artifacts)
   (should-not (equal (autonoma-test--last-sent-method) "artifacts.apply"))))

(provide 'autonoma-commands-test)

;;; autonoma-commands-test.el ends here
