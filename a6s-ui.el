;;; a6s-ui.el --- UI layer for A6s -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of a6s.el

;;; Commentary:

;; UI components: minor mode with modeline indicator, transient menu,
;; RIGOR phase progress buffer, background tasks buffer, and results
;; buffer with apply/discard artifact actions.

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'a6s-api)

(declare-function a6s-connect "a6s-commands")
(declare-function a6s-list-agents "a6s-commands")
(declare-function a6s-execution-status "a6s-commands")
(declare-function a6s-background-launch "a6s-commands")
(declare-function a6s-background-output "a6s-commands")

;;; Faces

(defface a6s-ui-connected
  '((t (:foreground "#22c55e" :weight bold)))
  "Face for connected status."
  :group 'a6s)

(defface a6s-ui-connecting
  '((t (:foreground "#f59e0b" :weight bold)))
  "Face for connecting status."
  :group 'a6s)

(defface a6s-ui-disconnected
  '((t (:foreground "#ef4444" :weight bold)))
  "Face for disconnected status."
  :group 'a6s)

(defface a6s-ui-header
  '((t (:inherit header-line :weight bold)))
  "Face for buffer headers."
  :group 'a6s)

(defface a6s-ui-phase-running
  '((t (:foreground "#3b82f6" :weight bold)))
  "Face for running phase."
  :group 'a6s)

(defface a6s-ui-phase-completed
  '((t (:foreground "#22c55e")))
  "Face for completed phase."
  :group 'a6s)

(defface a6s-ui-phase-failed
  '((t (:foreground "#ef4444")))
  "Face for failed phase."
  :group 'a6s)

(defface a6s-ui-phase-pending
  '((t (:foreground "#6b7280")))
  "Face for pending phase."
  :group 'a6s)

;;; Modeline

(defvar a6s-ui--modeline-string ""
  "Mode-line indicator string, updated by status events.")

(put 'a6s-ui--modeline-string 'risky-local-variable t)

(defun a6s-ui--update-modeline (&optional _status)
  "Recompute the modeline lighter based on current API status."
  (let* ((status (a6s-api-status))
         (face (pcase status
                 ('connected 'a6s-ui-connected)
                 ('connecting 'a6s-ui-connecting)
                 (_ 'a6s-ui-disconnected)))
         (label (pcase status
                  ('connected "●")
                  ('connecting "◐")
                  (_ "○"))))
    (setq a6s-ui--modeline-string
          (concat " " (propertize (format "A6s:%s" label)
                                  'face face
                                  'help-echo
                                  (format "A6s: %s" status)))))
  (force-mode-line-update t))

;;; RIGOR phase buffer

(defvar a6s-ui--current-execution-id nil
  "Execution id for the currently displayed RIGOR run.")

(defvar a6s-ui--phase-state nil
  "Alist of (phase-name . plist(:status :progress)) for current run.")

(defconst a6s-ui--rigor-buffer "*A6s RIGOR*"
  "Name of the RIGOR progress buffer.")

(defun a6s-ui--ensure-rigor-buffer ()
  "Return the RIGOR buffer, creating it if needed."
  (or (get-buffer a6s-ui--rigor-buffer)
      (let ((buf (get-buffer-create a6s-ui--rigor-buffer)))
        (with-current-buffer buf
          (a6s-rigor-mode))
        buf)))

(defun a6s-ui--render-rigor ()
  "Re-render the RIGOR progress buffer."
  (let ((buf (a6s-ui--ensure-rigor-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "A6s RIGOR Execution\n"
                            'face 'a6s-ui-header))
        (insert (make-string 40 ?-) "\n")
        (insert (format "Execution: %s\n\n"
                        (or a6s-ui--current-execution-id "(none)")))
        (dolist (phase '("research" "inspect" "generate" "optimize" "review"))
          (let* ((entry (assoc phase a6s-ui--phase-state))
                 (status (or (plist-get (cdr entry) :status) "pending"))
                 (progress (or (plist-get (cdr entry) :progress) 0))
                 (face (pcase status
                         ("running" 'a6s-ui-phase-running)
                         ("completed" 'a6s-ui-phase-completed)
                         ("failed" 'a6s-ui-phase-failed)
                         (_ 'a6s-ui-phase-pending))))
            (insert (propertize (format "  %-10s  %-10s  %3d%%\n"
                                        phase status progress)
                                'face face))))))))

(defun a6s-ui--on-phase-update (data)
  "Handle phase update event DATA (plist)."
  (let ((exec-id (plist-get data :executionId))
        (phase (plist-get data :phase))
        (status (plist-get data :status))
        (progress (plist-get data :progress)))
    (setq a6s-ui--current-execution-id exec-id)
    (setf (alist-get phase a6s-ui--phase-state nil nil #'equal)
          (list :status status :progress (or progress 0)))
    (a6s-ui--render-rigor)))

(defun a6s-ui--on-execution-complete (data)
  "Handle execution.complete event DATA."
  (let ((status (plist-get data :status))
        (artifacts (plist-get data :artifacts)))
    (message "[a6s] execution complete: %s" status)
    (when artifacts
      (a6s-ui-show-results artifacts))))

(define-derived-mode a6s-rigor-mode special-mode "A6s-RIGOR"
  "Major mode for the A6s RIGOR progress buffer."
  (setq buffer-read-only t))

;;; Tasks buffer

(defvar a6s-ui--tasks nil
  "Cached list of background tasks.")

(defconst a6s-ui--tasks-buffer "*A6s Tasks*"
  "Name of the tasks buffer.")

(defun a6s-ui--render-tasks ()
  "Render the tasks buffer from `a6s-ui--tasks'."
  (let ((buf (get-buffer-create a6s-ui--tasks-buffer)))
    (with-current-buffer buf
      (a6s-tasks-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "A6s Background Tasks\n"
                            'face 'a6s-ui-header))
        (insert (make-string 60 ?-) "\n")
        (if (null a6s-ui--tasks)
            (insert "(no tasks)\n")
          (dolist (task a6s-ui--tasks)
            (insert (format "  [%s] %-20s  %s  %d%%\n"
                            (or (plist-get task :id) "?")
                            (or (plist-get task :agentType) "?")
                            (or (plist-get task :status) "?")
                            (or (plist-get task :progress) 0)))
            (insert (format "    %s\n"
                            (or (plist-get task :task) "")))))))
    buf))

(defun a6s-ui--on-task-update (_data)
  "Refresh tasks buffer on task.update event."
  (when (get-buffer a6s-ui--tasks-buffer)
    (a6s-api-background-list
     (lambda (tasks _err)
       (when tasks
         (setq a6s-ui--tasks tasks)
         (a6s-ui--render-tasks))))))

(define-derived-mode a6s-tasks-mode special-mode "A6s-Tasks"
  "Major mode for the A6s tasks buffer."
  (setq buffer-read-only t))

;;; Results buffer with artifact apply/discard

(defvar a6s-ui--pending-artifacts nil
  "List of artifacts pending apply/discard in the results buffer.")

(defconst a6s-ui--results-buffer "*A6s Results*"
  "Name of the results buffer.")

(defun a6s-ui-show-results (artifacts)
  "Display ARTIFACTS in the results buffer with apply/discard actions."
  (setq a6s-ui--pending-artifacts artifacts)
  (let ((buf (get-buffer-create a6s-ui--results-buffer)))
    (with-current-buffer buf
      (a6s-results-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "A6s Results\n" 'face 'a6s-ui-header))
        (insert (make-string 60 ?-) "\n")
        (insert (format "%d artifact(s). Press [a] apply, [d] discard, [q] quit.\n\n"
                        (length artifacts)))
        (dolist (art artifacts)
          (insert (propertize
                   (format "● %s (%s)\n"
                           (or (plist-get art :path) "<unnamed>")
                           (or (plist-get art :language) "text"))
                   'face 'font-lock-keyword-face))
          (insert (or (plist-get art :content) "") "\n\n"))))
    (display-buffer buf)))

(defun a6s-ui-apply-pending ()
  "Apply the pending artifacts via daemon."
  (interactive)
  (if (null a6s-ui--pending-artifacts)
      (message "No pending artifacts")
    (a6s-api-artifacts-apply
     a6s-ui--pending-artifacts
     (lambda (result err)
       (if err
           (message "[a6s] apply failed: %s" err)
         (message "[a6s] applied=%d skipped=%d errors=%d"
                  (or (plist-get result :applied) 0)
                  (or (plist-get result :skipped) 0)
                  (length (plist-get result :errors))))
       (setq a6s-ui--pending-artifacts nil)))))

(defun a6s-ui-discard-pending ()
  "Discard pending artifacts without applying."
  (interactive)
  (setq a6s-ui--pending-artifacts nil)
  (when (get-buffer a6s-ui--results-buffer)
    (kill-buffer a6s-ui--results-buffer))
  (message "Discarded pending artifacts"))

(defvar a6s-results-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'a6s-ui-apply-pending)
    (define-key map (kbd "d") #'a6s-ui-discard-pending)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `a6s-results-mode'.")

(define-derived-mode a6s-results-mode special-mode "A6s-Results"
  "Major mode for A6s results buffer."
  (setq buffer-read-only t))

;;; Transient menu

;;;###autoload
(transient-define-prefix a6s-transient ()
  "A6s main menu."
  ["Connection"
   ("c" "Connect" a6s-connect)
   ("d" "Disconnect" a6s-disconnect)
   ("s" "Status" a6s-status)]
  ["Agents"
   ("i" "Invoke agent" a6s-invoke-agent)
   ("a" "List agents" a6s-list-agents)
   ("S" "Execution status" a6s-execution-status)
   ("l" "List tasks" a6s-list-tasks)
   ("b" "Background launch" a6s-background-launch)
   ("o" "Task output" a6s-background-output)
   ("x" "Cancel task" a6s-cancel-task)]
  ["Code (on region)"
   ("e" "Explain" a6s-explain-region)
   ("r" "Refactor" a6s-refactor-region)
   ("v" "Review" a6s-review-region)
   ("t" "Generate tests" a6s-generate-tests-region)]
  ["Artifacts"
   ("p" "Preview pending" a6s-preview-changes)
   ("A" "Apply pending" a6s-apply-artifacts)
   ("q" "Quit" transient-quit-one)])

;;; Minor mode

(defvar a6s-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'a6s-transient)
    map)
  "Keymap for `a6s-mode'.")

(defun a6s-ui--register-handlers ()
  "Subscribe event handlers so the UI can refresh itself."
  (a6s-api-on "status.update" #'a6s-ui--update-modeline)
  (a6s-api-on "connected" #'a6s-ui--update-modeline)
  (a6s-api-on "disconnected" #'a6s-ui--update-modeline)
  (a6s-api-on "phase.update" #'a6s-ui--on-phase-update)
  (a6s-api-on "task.update" #'a6s-ui--on-task-update)
  (a6s-api-on "execution.complete" #'a6s-ui--on-execution-complete))

(defun a6s-ui--unregister-handlers ()
  "Unregister event handlers."
  (a6s-api-off "status.update" #'a6s-ui--update-modeline)
  (a6s-api-off "connected" #'a6s-ui--update-modeline)
  (a6s-api-off "disconnected" #'a6s-ui--update-modeline)
  (a6s-api-off "phase.update" #'a6s-ui--on-phase-update)
  (a6s-api-off "task.update" #'a6s-ui--on-task-update)
  (a6s-api-off "execution.complete" #'a6s-ui--on-execution-complete))

;;;###autoload
(define-minor-mode a6s-mode
  "Minor mode for the A6s extension.

When enabled, shows a daemon connection indicator in the modeline,
binds \\[a6s-transient] to the A6s transient menu, and (if
`a6s-auto-connect' is non-nil) connects to the local daemon.

\\{a6s-mode-map}"
  :lighter a6s-ui--modeline-string
  :keymap a6s-mode-map
  :group 'a6s
  (if a6s-mode
      (progn
        (a6s-ui--register-handlers)
        (a6s-ui--update-modeline)
        (when (and (boundp 'a6s-auto-connect)
                   a6s-auto-connect
                   (not (a6s-api-connected-p)))
          (require 'a6s-commands)
          (a6s-connect)))
    (a6s-ui--unregister-handlers)))

(provide 'a6s-ui)

;;; a6s-ui.el ends here
