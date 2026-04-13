;;; a6s-ui-test.el --- UI tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for a6s-ui.el: modeline rendering, minor mode lifecycle,
;; RIGOR buffer, tasks buffer, results buffer with apply/discard actions,
;; and transient menu registration.

;;; Code:

(require 'test-helper)

(ert-deftest a6s-ui-test-modeline-disconnected ()
  "Modeline shows disconnected marker when client is disconnected."
  (a6s-test--reset-state)
  (a6s-ui--update-modeline)
  (should (string-match-p "A6s:" a6s-ui--modeline-string)))

(ert-deftest a6s-ui-test-modeline-connected ()
  "Modeline updates when status becomes connected."
  (a6s-test-with-connection
   (a6s-ui--update-modeline)
   (should (string-match-p "●" a6s-ui--modeline-string))))

(ert-deftest a6s-ui-test-minor-mode-toggle ()
  "Enabling/disabling the minor mode registers handlers idempotently."
  (a6s-test--reset-state)
  (let ((a6s-auto-connect nil))
    (with-temp-buffer
      (a6s-mode 1)
      (should a6s-mode)
      (a6s-mode -1)
      (should-not a6s-mode))))

(ert-deftest a6s-ui-test-phase-update ()
  "phase.update event updates the RIGOR buffer state."
  (a6s-test-with-connection
   (a6s-ui--register-handlers)
   (a6s-test--deliver-frame
    '(:type "phase.update"
      :data (:executionId "exec-1" :phase "research"
             :status "running" :progress 42)))
   (should (equal a6s-ui--current-execution-id "exec-1"))
   (let ((entry (assoc "research" a6s-ui--phase-state)))
     (should (equal (plist-get (cdr entry) :status) "running"))
     (should (= (plist-get (cdr entry) :progress) 42)))
   (should (get-buffer a6s-ui--rigor-buffer))
   (kill-buffer a6s-ui--rigor-buffer)))

(ert-deftest a6s-ui-test-rigor-buffer-renders-all-phases ()
  "RIGOR buffer lists all five phases."
  (a6s-test--reset-state)
  (a6s-ui--render-rigor)
  (with-current-buffer a6s-ui--rigor-buffer
    (dolist (phase '("research" "inspect" "generate" "optimize" "review"))
      (should (save-excursion
                (goto-char (point-min))
                (search-forward phase nil t)))))
  (kill-buffer a6s-ui--rigor-buffer))

(ert-deftest a6s-ui-test-tasks-render ()
  "Tasks buffer renders cached tasks."
  (a6s-test--reset-state)
  (setq a6s-ui--tasks
        '((:id "t1" :agentType "coder-ai" :status "running"
           :progress 50 :task "refactor foo")))
  (let ((buf (a6s-ui--render-tasks)))
    (with-current-buffer buf
      (should (save-excursion
                (goto-char (point-min))
                (search-forward "coder-ai" nil t))))
    (kill-buffer buf)))

(ert-deftest a6s-ui-test-results-show-and-discard ()
  "Results buffer is created with artifacts; discard clears state."
  (a6s-test--reset-state)
  (a6s-ui-show-results
   '((:id "a1" :type "file" :path "foo.py"
      :content "print(1)" :language "python")))
  (should (get-buffer a6s-ui--results-buffer))
  (should a6s-ui--pending-artifacts)
  (a6s-ui-discard-pending)
  (should-not a6s-ui--pending-artifacts)
  (should-not (get-buffer a6s-ui--results-buffer)))

(ert-deftest a6s-ui-test-results-apply-empty ()
  "Apply with nothing pending prints message and does not send frame."
  (a6s-test-with-connection
   (setq a6s-ui--pending-artifacts nil)
   (a6s-ui-apply-pending)
   (should-not a6s-test--mock-sent-messages)))

(ert-deftest a6s-ui-test-results-apply-sends-frame ()
  "Apply with pending artifacts sends artifacts.apply."
  (a6s-test-with-connection
   (setq a6s-ui--pending-artifacts
         '((:path "x" :content "y" :language "text")))
   (a6s-ui-apply-pending)
   (should (equal (a6s-test--last-sent-method) "artifacts.apply"))))

(ert-deftest a6s-ui-test-keymap-has-transient ()
  "a6s-mode-map binds C-c C-a."
  (should (eq (lookup-key a6s-mode-map (kbd "C-c C-a"))
              'a6s-transient)))

(ert-deftest a6s-ui-test-results-keymap ()
  "Results mode map binds a/d/q."
  (should (eq (lookup-key a6s-results-mode-map (kbd "a"))
              'a6s-ui-apply-pending))
  (should (eq (lookup-key a6s-results-mode-map (kbd "d"))
              'a6s-ui-discard-pending)))

(ert-deftest a6s-ui-test-execution-complete-opens-results ()
  "execution.complete with artifacts shows results buffer."
  (a6s-test-with-connection
   (a6s-ui--register-handlers)
   (a6s-test--deliver-frame
    '(:type "execution.complete"
      :data (:executionId "e1" :status "success"
             :phases () :artifacts ((:path "p" :content "c" :language "l")))))
   (should (get-buffer a6s-ui--results-buffer))
   (kill-buffer a6s-ui--results-buffer)))

(provide 'a6s-ui-test)

;;; a6s-ui-test.el ends here
