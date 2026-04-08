;;; autonoma-commands.el --- Interactive commands for Autonoma Code -*- lexical-binding: t; -*-

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
  "Connect to the local Autonoma CLI daemon."
  (interactive)
  (message "[autonoma] connecting to %s:%d ..."
           autonoma-daemon-host autonoma-daemon-port)
  (autonoma-api-connect
   (lambda (ok err)
     (if ok
         (message "[autonoma] connected")
       (message
        "[autonoma] connection failed: %s  |  Run `a6s code --daemon' to start the daemon"
        err)))))

;;;###autoload
(defun autonoma-disconnect ()
  "Disconnect from the Autonoma daemon."
  (interactive)
  (autonoma-api-disconnect)
  (message "[autonoma] disconnected"))

;;;###autoload
(defun autonoma-status ()
  "Print current daemon connection status."
  (interactive)
  (message "[autonoma] status: %s" (autonoma-api-status)))

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
         (message "[autonoma] invoke failed: %s" err)
       (let ((exec-id (plist-get result :executionId)))
         (message "[autonoma] invoked %s: execution=%s" agent exec-id))))))

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
           (message "[autonoma] explain failed: %s" err)
         (let ((buf (get-buffer-create "*Autonoma Explain*")))
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
           (message "[autonoma] refactor failed: %s" err)
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
           (message "[autonoma] review failed: %s" err)
         (let ((buf (get-buffer-create "*Autonoma Review*")))
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
           (message "[autonoma] generate-tests failed: %s" err)
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
           (message "[autonoma] preview failed: %s" err)
         (let ((buf (get-buffer-create "*Autonoma Preview*")))
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
             (message "[autonoma] apply failed: %s" err)
           (message "[autonoma] applied=%d skipped=%d"
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
         (message "[autonoma] list-tasks failed: %s" err)
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
         (message "[autonoma] cancel failed: %s" err)
       (message "[autonoma] task cancelled: %s" task-id)))))

(provide 'autonoma-commands)

;;; autonoma-commands.el ends here
