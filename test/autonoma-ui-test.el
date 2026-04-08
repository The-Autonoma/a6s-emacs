;;; autonoma-ui-test.el --- UI tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for autonoma-ui.el: modeline rendering, minor mode lifecycle,
;; RIGOR buffer, tasks buffer, results buffer with apply/discard actions,
;; and transient menu registration.

;;; Code:

(require 'test-helper)

(ert-deftest autonoma-ui-test-modeline-disconnected ()
  "Modeline shows disconnected marker when client is disconnected."
  (autonoma-test--reset-state)
  (autonoma-ui--update-modeline)
  (should (string-match-p "A6s:" autonoma-ui--modeline-string)))

(ert-deftest autonoma-ui-test-modeline-connected ()
  "Modeline updates when status becomes connected."
  (autonoma-test-with-connection
   (autonoma-ui--update-modeline)
   (should (string-match-p "●" autonoma-ui--modeline-string))))

(ert-deftest autonoma-ui-test-minor-mode-toggle ()
  "Enabling/disabling the minor mode registers handlers idempotently."
  (autonoma-test--reset-state)
  (let ((autonoma-auto-connect nil))
    (with-temp-buffer
      (autonoma-mode 1)
      (should autonoma-mode)
      (autonoma-mode -1)
      (should-not autonoma-mode))))

(ert-deftest autonoma-ui-test-phase-update ()
  "phase.update event updates the RIGOR buffer state."
  (autonoma-test-with-connection
   (autonoma-ui--register-handlers)
   (autonoma-test--deliver-frame
    '(:type "phase.update"
      :data (:executionId "exec-1" :phase "research"
             :status "running" :progress 42)))
   (should (equal autonoma-ui--current-execution-id "exec-1"))
   (let ((entry (assoc "research" autonoma-ui--phase-state)))
     (should (equal (plist-get (cdr entry) :status) "running"))
     (should (= (plist-get (cdr entry) :progress) 42)))
   (should (get-buffer autonoma-ui--rigor-buffer))
   (kill-buffer autonoma-ui--rigor-buffer)))

(ert-deftest autonoma-ui-test-rigor-buffer-renders-all-phases ()
  "RIGOR buffer lists all five phases."
  (autonoma-test--reset-state)
  (autonoma-ui--render-rigor)
  (with-current-buffer autonoma-ui--rigor-buffer
    (dolist (phase '("research" "inspect" "generate" "optimize" "review"))
      (should (save-excursion
                (goto-char (point-min))
                (search-forward phase nil t)))))
  (kill-buffer autonoma-ui--rigor-buffer))

(ert-deftest autonoma-ui-test-tasks-render ()
  "Tasks buffer renders cached tasks."
  (autonoma-test--reset-state)
  (setq autonoma-ui--tasks
        '((:id "t1" :agentType "coder-ai" :status "running"
           :progress 50 :task "refactor foo")))
  (let ((buf (autonoma-ui--render-tasks)))
    (with-current-buffer buf
      (should (save-excursion
                (goto-char (point-min))
                (search-forward "coder-ai" nil t))))
    (kill-buffer buf)))

(ert-deftest autonoma-ui-test-results-show-and-discard ()
  "Results buffer is created with artifacts; discard clears state."
  (autonoma-test--reset-state)
  (autonoma-ui-show-results
   '((:id "a1" :type "file" :path "foo.py"
      :content "print(1)" :language "python")))
  (should (get-buffer autonoma-ui--results-buffer))
  (should autonoma-ui--pending-artifacts)
  (autonoma-ui-discard-pending)
  (should-not autonoma-ui--pending-artifacts)
  (should-not (get-buffer autonoma-ui--results-buffer)))

(ert-deftest autonoma-ui-test-results-apply-empty ()
  "Apply with nothing pending prints message and does not send frame."
  (autonoma-test-with-connection
   (setq autonoma-ui--pending-artifacts nil)
   (autonoma-ui-apply-pending)
   (should-not autonoma-test--mock-sent-messages)))

(ert-deftest autonoma-ui-test-results-apply-sends-frame ()
  "Apply with pending artifacts sends artifacts.apply."
  (autonoma-test-with-connection
   (setq autonoma-ui--pending-artifacts
         '((:path "x" :content "y" :language "text")))
   (autonoma-ui-apply-pending)
   (should (equal (autonoma-test--last-sent-method) "artifacts.apply"))))

(ert-deftest autonoma-ui-test-keymap-has-transient ()
  "autonoma-mode-map binds C-c C-a."
  (should (eq (lookup-key autonoma-mode-map (kbd "C-c C-a"))
              'autonoma-transient)))

(ert-deftest autonoma-ui-test-results-keymap ()
  "Results mode map binds a/d/q."
  (should (eq (lookup-key autonoma-results-mode-map (kbd "a"))
              'autonoma-ui-apply-pending))
  (should (eq (lookup-key autonoma-results-mode-map (kbd "d"))
              'autonoma-ui-discard-pending)))

(ert-deftest autonoma-ui-test-execution-complete-opens-results ()
  "execution.complete with artifacts shows results buffer."
  (autonoma-test-with-connection
   (autonoma-ui--register-handlers)
   (autonoma-test--deliver-frame
    '(:type "execution.complete"
      :data (:executionId "e1" :status "success"
             :phases () :artifacts ((:path "p" :content "c" :language "l")))))
   (should (get-buffer autonoma-ui--results-buffer))
   (kill-buffer autonoma-ui--results-buffer)))

(provide 'autonoma-ui-test)

;;; autonoma-ui-test.el ends here
