;;; a6s-commands.el --- Interactive commands for A6s -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of a6s.el

;;; Commentary:

;; Interactive `M-x'-callable commands that users invoke directly.
;; These wrap `a6s-api-*' asynchronous calls with user prompts,
;; input validation, and buffer rendering.

;;; Code:

(require 'cl-lib)
(require 'a6s-api)
(require 'a6s-ui)

(defvar a6s-daemon-port)
(defvar a6s-daemon-host)

(defvar a6s-commands--known-agents nil
  "Cached list of agents last retrieved from the daemon.")

(defvar a6s-commands--last-artifacts nil
  "Last set of artifacts returned by a refactor/tests/review call.")

;;; Helpers

(defun a6s-commands--ensure-connected ()
  "Signal a `user-error' when not connected to the daemon.  Abort the caller."
  (unless (a6s-api-connected-p)
    (user-error
     "Not connected.  Run M-x a6s-connect (start daemon with `a6s code --daemon')")))

(defun a6s-commands--buffer-language ()
  "Guess the language identifier for the current buffer."
  (let ((name (symbol-name major-mode)))
    (cond
     ((string-match "\\`\\(.*\\)-ts-mode\\'" name) (match-string 1 name))
     ((string-match "\\`\\(.*\\)-mode\\'" name) (match-string 1 name))
     (t "text"))))

(defun a6s-commands--region-or-buffer ()
  "Return the active region string, or the buffer string if no region."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun a6s-commands--file-path ()
  "Return the variable `buffer-file-name' or a placeholder."
  (or (buffer-file-name) (buffer-name)))

;;; Connection commands

;;;###autoload
(defun a6s-connect ()
  "Connect to the local A6s CLI daemon."
  (interactive)
  (message "[a6s] connecting to %s:%d ..."
           a6s-daemon-host a6s-daemon-port)
  (a6s-api-connect
   (lambda (ok err)
     (if ok
         (message "[a6s] connected")
       (message
        "[a6s] connection failed: %s  |  Run `a6s code --daemon' to start the daemon"
        err)))))

;;;###autoload
(defun a6s-disconnect ()
  "Disconnect from the A6s daemon."
  (interactive)
  (a6s-api-disconnect)
  (message "[a6s] disconnected"))

;;;###autoload
(defun a6s-status ()
  "Print current daemon connection status."
  (interactive)
  (message "[a6s] status: %s" (a6s-api-status)))

;;; Agent invocation

;;;###autoload
(defun a6s-invoke-agent (agent task)
  "Invoke AGENT with TASK (both prompted interactively)."
  (interactive
   (progn
     (a6s-commands--ensure-connected)
     (let* ((agents (or a6s-commands--known-agents
                        (list "req-ai" "planner-ai" "architect-ai"
                              "coder-ai" "tester-ai" "debug-ai"
                              "review-ai" "deploy-ai" "maintain-ai"
                              "observe-ai" "incident-ai" "capacity-ai"
                              "backup-ai" "security-ai" "threathunter-ai"
                              "govern-ai" "policy-ai" "tenant-ai"
                              "optimize-ai" "cost-ai" "dba-ai"
                              "billing-ai" "adapt-ai" "evolve-ai"
                              "success-ai"))))
            (agent (completing-read "Agent: " agents nil nil))
            (task (read-string "Task: ")))
       (list agent task))))
  (a6s-commands--ensure-connected)
  (a6s-api-agents-invoke
   agent task nil
   (lambda (result err)
     (if err
         (message "[a6s] invoke failed: %s" err)
       (let ((exec-id (plist-get result :executionId)))
         (message "[a6s] invoked %s: execution=%s" agent exec-id))))))

;;; Code commands

;;;###autoload
(defun a6s-explain-region ()
  "Ask the daemon to explain the current region (or whole buffer)."
  (interactive)
  (a6s-commands--ensure-connected)
  (let ((code (a6s-commands--region-or-buffer))
        (lang (a6s-commands--buffer-language))
        (path (a6s-commands--file-path)))
    (a6s-api-code-explain
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
(defun a6s-refactor-region (instructions)
  "Refactor region with optional INSTRUCTIONS."
  (interactive "sRefactor instructions (optional): ")
  (a6s-commands--ensure-connected)
  (let ((code (a6s-commands--region-or-buffer))
        (lang (a6s-commands--buffer-language))
        (path (a6s-commands--file-path)))
    (a6s-api-code-refactor
     code lang path (if (string-empty-p instructions) nil instructions)
     (lambda (result err)
       (if err
           (message "[a6s] refactor failed: %s" err)
         (setq a6s-commands--last-artifacts result)
         (a6s-ui-show-results result))))))

;;;###autoload
(defun a6s-review-region (review-type)
  "Review region with REVIEW-TYPE (security, performance, quality, all)."
  (interactive
   (list (completing-read "Review type: "
                          '("security" "performance" "quality" "all")
                          nil t "all")))
  (a6s-commands--ensure-connected)
  (let ((code (a6s-commands--region-or-buffer))
        (lang (a6s-commands--buffer-language))
        (path (a6s-commands--file-path)))
    (a6s-api-code-review
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
(defun a6s-generate-tests-region ()
  "Generate test code for the current region."
  (interactive)
  (a6s-commands--ensure-connected)
  (let ((code (a6s-commands--region-or-buffer))
        (lang (a6s-commands--buffer-language))
        (path (a6s-commands--file-path)))
    (a6s-api-code-generate-tests
     code lang path
     (lambda (result err)
       (if err
           (message "[a6s] generate-tests failed: %s" err)
         (setq a6s-commands--last-artifacts result)
         (a6s-ui-show-results result))))))

;;; Artifacts

;;;###autoload
(defun a6s-preview-changes ()
  "Preview currently pending artifacts."
  (interactive)
  (a6s-commands--ensure-connected)
  (if (null a6s-commands--last-artifacts)
      (message "No artifacts to preview")
    (a6s-api-artifacts-preview
     a6s-commands--last-artifacts
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
(defun a6s-apply-artifacts ()
  "Apply the most recently returned artifacts."
  (interactive)
  (a6s-commands--ensure-connected)
  (if (null a6s-commands--last-artifacts)
      (message "No artifacts to apply")
    (when (yes-or-no-p
           (format "Apply %d artifact(s)? "
                   (length a6s-commands--last-artifacts)))
      (a6s-api-artifacts-apply
       a6s-commands--last-artifacts
       (lambda (result err)
         (if err
             (message "[a6s] apply failed: %s" err)
           (message "[a6s] applied=%d skipped=%d"
                    (or (plist-get result :applied) 0)
                    (or (plist-get result :skipped) 0))
           (setq a6s-commands--last-artifacts nil)))))))

;;; Background tasks

;;;###autoload
(defun a6s-list-tasks ()
  "Fetch and show background tasks."
  (interactive)
  (a6s-commands--ensure-connected)
  (a6s-api-background-list
   (lambda (tasks err)
     (if err
         (message "[a6s] list-tasks failed: %s" err)
       (setq a6s-ui--tasks tasks)
       (display-buffer (a6s-ui--render-tasks))))))

;;;###autoload
(defun a6s-cancel-task (task-id)
  "Cancel background task with TASK-ID."
  (interactive "sTask id: ")
  (a6s-commands--ensure-connected)
  (a6s-api-background-cancel
   task-id
   (lambda (_result err)
     (if err
         (message "[a6s] cancel failed: %s" err)
       (message "[a6s] task cancelled: %s" task-id)))))

;;;###autoload
(defun a6s-list-agents ()
  "Fetch and display all available agents in the *A6s Agents* buffer."
  (interactive)
  (a6s-commands--ensure-connected)
  (a6s-api-agents-list
   (lambda (agents err)
     (if err
         (message "[a6s] list-agents failed: %s" err)
       (setq a6s-commands--known-agents
             (mapcar (lambda (a) (plist-get a :name)) agents))
       (let ((buf (get-buffer-create "*A6s Agents*")))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize "A6s Agents\n" 'face 'a6s-ui-header))
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
(defun a6s-execution-status (execution-id)
  "Prompt for EXECUTION-ID and display its current status."
  (interactive "sExecution id: ")
  (a6s-commands--ensure-connected)
  (a6s-api-execution-status
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
(defun a6s-background-launch (agent task)
  "Launch a background TASK under AGENT."
  (interactive
   (progn
     (a6s-commands--ensure-connected)
     (let* ((agents (or a6s-commands--known-agents
                        (list "req-ai" "planner-ai" "architect-ai"
                              "coder-ai" "tester-ai" "debug-ai"
                              "review-ai" "deploy-ai" "maintain-ai"
                              "observe-ai" "incident-ai" "capacity-ai"
                              "backup-ai" "security-ai" "threathunter-ai"
                              "govern-ai" "policy-ai" "tenant-ai"
                              "optimize-ai" "cost-ai" "dba-ai"
                              "billing-ai" "adapt-ai" "evolve-ai"
                              "success-ai"))))
            (agent (completing-read "Agent: " agents nil nil))
            (task (read-string "Task: ")))
       (list agent task))))
  (a6s-commands--ensure-connected)
  (a6s-api-background-launch
   task agent
   (lambda (result err)
     (if err
         (message "[a6s] background-launch failed: %s" err)
       (message "[a6s] launched task=%s"
                (or (plist-get result :taskId) "?"))))))

;;;###autoload
(defun a6s-background-output (task-id)
  "Prompt for TASK-ID and display its output in the *A6s Output* buffer."
  (interactive "sTask id: ")
  (a6s-commands--ensure-connected)
  (a6s-api-background-output
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

;;; Fleet commands

;;;###autoload
(defun a6s-fleet-list (&optional capability)
  "Fetch and display all fleet agents in the *A6s Fleet* buffer.
With a prefix argument, prompt for a CAPABILITY group to filter by."
  (interactive
   (list (when current-prefix-arg
           (let ((cap (read-string "Capability group (leave empty for all): ")))
             (if (string-empty-p (string-trim cap)) nil (string-trim cap))))))
  (a6s-commands--ensure-connected)
  (a6s-api-fleet-list
   (lambda (agents err)
     (if err
         (message "[a6s] fleet-list failed: %s" err)
       (let ((buf (get-buffer-create "*A6s Fleet*")))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize "A6s Fleet Agents\n" 'face 'a6s-ui-header))
             (insert (make-string 72 ?-) "\n")
             (dolist (agent agents)
               (insert (format "  %-16s %-12s %-10s %s\n"
                               (or (plist-get agent :name) "?")
                               (or (plist-get agent :capability) "?")
                               (or (plist-get agent :status) "?")
                               (or (plist-get agent :region) ""))))
             (goto-char (point-min)))
           (special-mode))
         (display-buffer buf))))
   capability))

;;;###autoload
(defun a6s-fleet-status ()
  "Fetch and display fleet-wide status summary in the *A6s Fleet Status* buffer."
  (interactive)
  (a6s-commands--ensure-connected)
  (a6s-api-fleet-status
   (lambda (status err)
     (if err
         (message "[a6s] fleet-status failed: %s" err)
       (let ((buf (get-buffer-create "*A6s Fleet Status*")))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize "A6s Fleet Status\n" 'face 'a6s-ui-header))
             (insert (make-string 40 ?-) "\n")
             (insert (format "  Total    : %s\n" (or (plist-get status :total) 0)))
             (insert (format "  Available: %s\n" (or (plist-get status :available) 0)))
             (insert (format "  Busy     : %s\n" (or (plist-get status :busy) 0)))
             (insert (format "  Offline  : %s\n" (or (plist-get status :offline) 0)))
             (let ((by-cap (plist-get status :byCapability)))
               (when by-cap
                 (insert "\nBy Capability:\n")
                 (cl-loop for (cap info) on by-cap by #'cddr
                          do (insert (format "  %-12s total=%-4s available=%s\n"
                                             cap
                                             (or (plist-get info :total) 0)
                                             (or (plist-get info :available) 0))))))
             (goto-char (point-min)))
           (special-mode))
         (display-buffer buf))))))

;;;###autoload
(defun a6s-fleet-command (target capability agent-type command)
  "Send COMMAND to fleet agent TARGET via CAPABILITY and AGENT-TYPE."
  (interactive
   (progn
     (a6s-commands--ensure-connected)
     (list (read-string "Target: ")
           (completing-read "Capability: "
                            '("BUILD" "OPERATE" "SECURE" "GOVERN" "OPTIMIZE" "EVOLVE")
                            nil t)
           (read-string "Agent type: ")
           (read-string "Command: "))))
  (a6s-commands--ensure-connected)
  (a6s-api-fleet-command
   target capability agent-type command
   (lambda (result err)
     (if err
         (message "[a6s] fleet-command failed: %s" err)
       (message "[a6s] fleet command dispatched: execution=%s"
                (or (plist-get result :executionId) "?"))))))

;;; Workflow commands

;;;###autoload
(defun a6s-workflow-list (&optional domain)
  "Fetch and display available workflow templates in the *A6s Workflows* buffer.
With a prefix argument, prompt for a DOMAIN to filter by."
  (interactive
   (list (when current-prefix-arg
           (let ((d (read-string "Domain (leave empty for all): ")))
             (if (string-empty-p (string-trim d)) nil (string-trim d))))))
  (a6s-commands--ensure-connected)
  (a6s-api-workflows-list
   (lambda (workflows err)
     (if err
         (message "[a6s] workflow-list failed: %s" err)
       (let ((buf (get-buffer-create "*A6s Workflows*")))
         (with-current-buffer buf
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (propertize "A6s Workflow Templates\n" 'face 'a6s-ui-header))
             (insert (make-string 72 ?-) "\n")
             (dolist (wf workflows)
               (insert (format "  %-30s %-12s steps=%-3s %s\n"
                               (or (plist-get wf :id) "?")
                               (or (plist-get wf :pattern) "?")
                               (or (plist-get wf :stepCount) "?")
                               (or (plist-get wf :description) ""))))
             (goto-char (point-min)))
           (special-mode))
         (display-buffer buf))))
   domain))

;;;###autoload
(defun a6s-workflow-run (workflow-id)
  "Prompt for WORKFLOW-ID and run the workflow."
  (interactive
   (progn
     (a6s-commands--ensure-connected)
     (list (read-string "Workflow id: "))))
  (a6s-commands--ensure-connected)
  (a6s-api-workflow-run
   workflow-id
   (lambda (result err)
     (if err
         (message "[a6s] workflow-run failed: %s" err)
       (message "[a6s] workflow started: execution=%s"
                (or (plist-get result :executionId) "?"))))
   nil nil))

;;;###autoload
(defun a6s-workflow-status (execution-id)
  "Prompt for EXECUTION-ID and display current workflow execution status."
  (interactive "sWorkflow execution id: ")
  (a6s-commands--ensure-connected)
  (a6s-api-workflow-status
   execution-id
   (lambda (result err)
     (if err
         (message "[a6s] workflow-status failed: %s" err)
       (message "[a6s] workflow=%s status=%s progress=%s%%"
                (or (plist-get result :workflowId) "?")
                (or (plist-get result :status) "?")
                (or (plist-get result :progress) "?"))))))

;;;###autoload
(defun a6s-workflow-cancel (execution-id)
  "Prompt for EXECUTION-ID and cancel the running workflow."
  (interactive "sWorkflow execution id: ")
  (a6s-commands--ensure-connected)
  (when (yes-or-no-p (format "Cancel workflow execution %s? " execution-id))
    (a6s-api-workflow-cancel
     execution-id
     (lambda (_result err)
       (if err
           (message "[a6s] workflow-cancel failed: %s" err)
         (message "[a6s] workflow cancelled: %s" execution-id))))))

(provide 'a6s-commands)

;;; a6s-commands.el ends here
