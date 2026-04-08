;;; autonoma-commands.el --- Interactive commands for A6s -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of autonoma.el

;;; Commentary:

;; Interactive `M-x'-callable commands that users invoke directly.
;; These wrap `autonoma-api-*' asynchronous calls with user prompts,
;; input validation, and buffer rendering.

;;; Code:

(require 'cl-lib)
(require 'autonoma-api)
(require 'autonoma-ui)

(defvar autonoma-daemon-port)
(defvar autonoma-daemon-host)

(defvar autonoma-commands--known-agents nil
  "Cached list of agents last retrieved from the daemon.")

(defvar autonoma-commands--last-artifacts nil
  "Last set of artifacts returned by a refactor/tests/review call.")

;;; Helpers

(defun autonoma-commands--ensure-connected ()
  "Signal a `user-error' when not connected to the daemon.  Abort the caller."
  (unless (autonoma-api-connected-p)
    (user-error
     "Not connected.  Run M-x autonoma-connect (start daemon with `a6s code --daemon')")))

(defun autonoma-commands--buffer-language ()
  "Guess the language identifier for the current buffer."
  (let ((name (symbol-name major-mode)))
    (cond
     ((string-match "\\`\\(.*\\)-ts-mode\\'" name) (match-string 1 name))
     ((string-match "\\`\\(.*\\)-mode\\'" name) (match-string 1 name))
     (t "text"))))

(defun autonoma-commands--region-or-buffer ()
  "Return the active region string, or the buffer string if no region."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun autonoma-commands--file-path ()
  "Return the variable `buffer-file-name' or a placeholder."
  (or (buffer-file-name) (buffer-name)))

;;; Connection commands

;;;###autoload
(defun autonoma-connect ()
  "Connect to the local A6s CLI daemon."
  (interactive)
  (message "[a6s] connecting to %s:%d ..."
           autonoma-daemon-host autonoma-daemon-port)
  (autonoma-api-connect
   (lambda (ok err)
     (if ok
         (message "[a6s] connected")
       (message
        "[a6s] connection failed: %s  |  Run `a6s code --daemon' to start the daemon"
        err)))))

;;;###autoload
(defun autonoma-disconnect ()
  "Disconnect from the A6s daemon."
  (interactive)
  (autonoma-api-disconnect)
  (message "[a6s] disconnected"))

;;;###autoload
(defun autonoma-status ()
  "Print current daemon connection status."
  (interactive)
  (message "[a6s] status: %s" (autonoma-api-status)))

;;; Agent invocation

;;;###autoload
(defun autonoma-invoke-agent (agent task)
  "Invoke AGENT with TASK (both prompted interactively)."
  (interactive
   (progn
     (autonoma-commands--ensure-connected)
     (let* ((agents (or autonoma-commands--known-agents
                        (list "architect-ai" "coder-ai" "tester-ai"
                              "reviewer-ai" "req-ai")))
            (agent (completing-read "Agent: " agents nil nil))
            (task (read-string "Task: ")))
       (list agent task))))
  (autonoma-commands--ensure-connected)
  (autonoma-api-agents-invoke
   agent task nil
   (lambda (result err)
     (if err
         (message "[a6s] invoke failed: %s" err)
       (let ((exec-id (plist-get result :executionId)))
         (message "[a6s] invoked %s: execution=%s" agent exec-id))))))

;;; Code commands

;;;###autoload
(defun autonoma-explain-region ()
  "Ask the daemon to explain the current region (or whole buffer)."
  (interactive)
  (autonoma-commands--ensure-connected)
  (let ((code (autonoma-commands--region-or-buffer))
        (lang (autonoma-commands--buffer-language))
        (path (autonoma-commands--file-path)))
    (autonoma-api-code-explain
     code lang path
     (lambda (result err)
       (if err
           (message "[a6s] explain failed: %s" err)
         (let ((buf (get-buffer-create "*A6s Explain*")))
           (with-current-buffer buf
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert (or result ""))
               (goto-char (point-min)))
             (special-mode))
           (display-buffer buf)))))))

;;;###autoload
(defun autonoma-refactor-region (instructions)
  "Refactor region with optional INSTRUCTIONS."
  (interactive "sRefactor instructions (optional): ")
  (autonoma-commands--ensure-connected)
  (let ((code (autonoma-commands--region-or-buffer))
        (lang (autonoma-commands--buffer-language))
        (path (autonoma-commands--file-path)))
    (autonoma-api-code-refactor
     code lang path (if (string-empty-p instructions) nil instructions)
     (lambda (result err)
       (if err
           (message "[a6s] refactor failed: %s" err)
         (setq autonoma-commands--last-artifacts result)
         (autonoma-ui-show-results result))))))

;;;###autoload
(defun autonoma-review-region (review-type)
  "Review region with REVIEW-TYPE (security, performance, quality, all)."
  (interactive
   (list (completing-read "Review type: "
                          '("security" "performance" "quality" "all")
                          nil t "all")))
  (autonoma-commands--ensure-connected)
  (let ((code (autonoma-commands--region-or-buffer))
        (lang (autonoma-commands--buffer-language))
        (path (autonoma-commands--file-path)))
    (autonoma-api-code-review
     code lang path review-type
     (lambda (result err)
       (if err
           (message "[a6s] review failed: %s" err)
         (let ((buf (get-buffer-create "*A6s Review*")))
           (with-current-buffer buf
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert (or (plist-get result :summary) "") "\n\n")
               (dolist (issue (plist-get result :issues))
                 (insert (format "[%s] line %s: %s\n"
                                 (or (plist-get issue :severity) "info")
                                 (or (plist-get issue :line) "?")
                                 (or (plist-get issue :message) ""))))
               (goto-char (point-min)))
             (special-mode))
           (display-buffer buf)))))))

;;;###autoload
(defun autonoma-generate-tests-region ()
  "Generate test code for the current region."
  (interactive)
  (autonoma-commands--ensure-connected)
  (let ((code (autonoma-commands--region-or-buffer))
        (lang (autonoma-commands--buffer-language))
        (path (autonoma-commands--file-path)))
    (autonoma-api-code-generate-tests
     code lang path
     (lambda (result err)
       (if err
           (message "[a6s] generate-tests failed: %s" err)
         (setq autonoma-commands--last-artifacts result)
         (autonoma-ui-show-results result))))))

;;; Artifacts

;;;###autoload
(defun autonoma-preview-changes ()
  "Preview currently pending artifacts."
  (interactive)
  (autonoma-commands--ensure-connected)
  (if (null autonoma-commands--last-artifacts)
      (message "No artifacts to preview")
    (autonoma-api-artifacts-preview
     autonoma-commands--last-artifacts
     (lambda (result err)
       (if err
           (message "[a6s] preview failed: %s" err)
         (let ((buf (get-buffer-create "*A6s Preview*")))
           (with-current-buffer buf
             (let ((inhibit-read-only t))
               (erase-buffer)
               (dolist (file (plist-get result :files))
                 (insert (format "[%s] %s\n"
                                 (or (plist-get file :action) "?")
                                 (or (plist-get file :path) "?")))
                 (when (plist-get file :diff)
                   (insert (plist-get file :diff) "\n")))
               (goto-char (point-min)))
             (special-mode))
           (display-buffer buf)))))))

;;;###autoload
(defun autonoma-apply-artifacts ()
  "Apply the most recently returned artifacts."
  (interactive)
  (autonoma-commands--ensure-connected)
  (if (null autonoma-commands--last-artifacts)
      (message "No artifacts to apply")
    (when (yes-or-no-p
           (format "Apply %d artifact(s)? "
                   (length autonoma-commands--last-artifacts)))
      (autonoma-api-artifacts-apply
       autonoma-commands--last-artifacts
       (lambda (result err)
         (if err
             (message "[a6s] apply failed: %s" err)
           (message "[a6s] applied=%d skipped=%d"
                    (or (plist-get result :applied) 0)
                    (or (plist-get result :skipped) 0))
           (setq autonoma-commands--last-artifacts nil)))))))

;;; Background tasks

;;;###autoload
(defun autonoma-list-tasks ()
  "Fetch and show background tasks."
  (interactive)
  (autonoma-commands--ensure-connected)
  (autonoma-api-background-list
   (lambda (tasks err)
     (if err
         (message "[a6s] list-tasks failed: %s" err)
       (setq autonoma-ui--tasks tasks)
       (display-buffer (autonoma-ui--render-tasks))))))

;;;###autoload
(defun autonoma-cancel-task (task-id)
  "Cancel background task with TASK-ID."
  (interactive "sTask id: ")
  (autonoma-commands--ensure-connected)
  (autonoma-api-background-cancel
   task-id
   (lambda (_result err)
     (if err
         (message "[a6s] cancel failed: %s" err)
       (message "[a6s] task cancelled: %s" task-id)))))

;;;###autoload
(defun autonoma-list-agents ()
  "Fetch and display all available agents in the *A6s Agents* buffer."
  (interactive)
  (autonoma-commands--ensure-connected)
  (autonoma-api-agents-list
   (lambda (agents err)
     (if err
         (message "[a6s] list-agents failed: %s" err)
       (setq autonoma-commands--known-agents
             (mapcar (lambda (a) (plist-get a :name)) agents))
       (let ((buf (get-buffer-create "*A6s Agents*")))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize "A6s Agents\n" 'face 'autonoma-ui-header))
             (insert (make-string 60 ?-) "\n")
             (dolist (agent agents)
               (insert (format "  %-12s %-20s %s\n"
                               (or (plist-get agent :id) "?")
                               (or (plist-get agent :name) "?")
                               (or (plist-get agent :description) ""))))
             (goto-char (point-min)))
           (special-mode))
         (display-buffer buf))))))

;;;###autoload
(defun autonoma-execution-status (execution-id)
  "Prompt for EXECUTION-ID and display its current status."
  (interactive "sExecution id: ")
  (autonoma-commands--ensure-connected)
  (autonoma-api-execution-status
   execution-id
   (lambda (result err)
     (if err
         (message "[a6s] execution-status failed: %s" err)
       (message "[a6s] execution=%s status=%s phase=%s progress=%s%%"
                (or (plist-get result :executionId) "?")
                (or (plist-get result :status) "?")
                (or (plist-get result :phase) "?")
                (or (plist-get result :progress) "?"))))))

;;;###autoload
(defun autonoma-background-launch (agent task)
  "Launch a background TASK under AGENT."
  (interactive
   (progn
     (autonoma-commands--ensure-connected)
     (let* ((agents (or autonoma-commands--known-agents
                        (list "architect-ai" "coder-ai" "tester-ai"
                              "reviewer-ai" "req-ai")))
            (agent (completing-read "Agent: " agents nil nil))
            (task (read-string "Task: ")))
       (list agent task))))
  (autonoma-commands--ensure-connected)
  (autonoma-api-background-launch
   task agent
   (lambda (result err)
     (if err
         (message "[a6s] background-launch failed: %s" err)
       (message "[a6s] launched task=%s"
                (or (plist-get result :taskId) "?"))))))

;;;###autoload
(defun autonoma-background-output (task-id)
  "Prompt for TASK-ID and display its output in the *A6s Output* buffer."
  (interactive "sTask id: ")
  (autonoma-commands--ensure-connected)
  (autonoma-api-background-output
   task-id
   (lambda (result err)
     (if err
         (message "[a6s] background-output failed: %s" err)
       (let ((buf (get-buffer-create "*A6s Output*")))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (or (plist-get result :output) (format "%s" result) ""))
             (goto-char (point-min)))
           (special-mode))
         (display-buffer buf))))))

(provide 'autonoma-commands)

;;; autonoma-commands.el ends here
