;;; autonoma-ui.el --- UI layer for A6s -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of autonoma.el

;;; Commentary:

;; UI components: minor mode with modeline indicator, transient menu,
;; RIGOR phase progress buffer, background tasks buffer, and results
;; buffer with apply/discard artifact actions.

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'autonoma-api)

(declare-function autonoma-connect "autonoma-commands")
(declare-function autonoma-list-agents "autonoma-commands")
(declare-function autonoma-execution-status "autonoma-commands")
(declare-function autonoma-background-launch "autonoma-commands")
(declare-function autonoma-background-output "autonoma-commands")

;;; Faces

(defface autonoma-ui-connected
  '((t (:foreground "#22c55e" :weight bold)))
  "Face for connected status."
  :group 'autonoma)

(defface autonoma-ui-connecting
  '((t (:foreground "#f59e0b" :weight bold)))
  "Face for connecting status."
  :group 'autonoma)

(defface autonoma-ui-disconnected
  '((t (:foreground "#ef4444" :weight bold)))
  "Face for disconnected status."
  :group 'autonoma)

(defface autonoma-ui-header
  '((t (:inherit header-line :weight bold)))
  "Face for buffer headers."
  :group 'autonoma)

(defface autonoma-ui-phase-running
  '((t (:foreground "#3b82f6" :weight bold)))
  "Face for running phase."
  :group 'autonoma)

(defface autonoma-ui-phase-completed
  '((t (:foreground "#22c55e")))
  "Face for completed phase."
  :group 'autonoma)

(defface autonoma-ui-phase-failed
  '((t (:foreground "#ef4444")))
  "Face for failed phase."
  :group 'autonoma)

(defface autonoma-ui-phase-pending
  '((t (:foreground "#6b7280")))
  "Face for pending phase."
  :group 'autonoma)

;;; Modeline

(defvar autonoma-ui--modeline-string ""
  "Mode-line indicator string, updated by status events.")

(put 'autonoma-ui--modeline-string 'risky-local-variable t)

(defun autonoma-ui--update-modeline (&optional _status)
  "Recompute the modeline lighter based on current API status."
  (let* ((status (autonoma-api-status))
         (face (pcase status
                 ('connected 'autonoma-ui-connected)
                 ('connecting 'autonoma-ui-connecting)
                 (_ 'autonoma-ui-disconnected)))
         (label (pcase status
                  ('connected "●")
                  ('connecting "◐")
                  (_ "○"))))
    (setq autonoma-ui--modeline-string
          (concat " " (propertize (format "A6s:%s" label)
                                  'face face
                                  'help-echo
                                  (format "A6s: %s" status)))))
  (force-mode-line-update t))

;;; RIGOR phase buffer

(defvar autonoma-ui--current-execution-id nil
  "Execution id for the currently displayed RIGOR run.")

(defvar autonoma-ui--phase-state nil
  "Alist of (phase-name . plist(:status :progress)) for current run.")

(defconst autonoma-ui--rigor-buffer "*A6s RIGOR*"
  "Name of the RIGOR progress buffer.")

(defun autonoma-ui--ensure-rigor-buffer ()
  "Return the RIGOR buffer, creating it if needed."
  (or (get-buffer autonoma-ui--rigor-buffer)
      (let ((buf (get-buffer-create autonoma-ui--rigor-buffer)))
        (with-current-buffer buf
          (autonoma-rigor-mode))
        buf)))

(defun autonoma-ui--render-rigor ()
  "Re-render the RIGOR progress buffer."
  (let ((buf (autonoma-ui--ensure-rigor-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "A6s RIGOR Execution\n"
                            'face 'autonoma-ui-header))
        (insert (make-string 40 ?-) "\n")
        (insert (format "Execution: %s\n\n"
                        (or autonoma-ui--current-execution-id "(none)")))
        (dolist (phase '("research" "inspect" "generate" "optimize" "review"))
          (let* ((entry (assoc phase autonoma-ui--phase-state))
                 (status (or (plist-get (cdr entry) :status) "pending"))
                 (progress (or (plist-get (cdr entry) :progress) 0))
                 (face (pcase status
                         ("running" 'autonoma-ui-phase-running)
                         ("completed" 'autonoma-ui-phase-completed)
                         ("failed" 'autonoma-ui-phase-failed)
                         (_ 'autonoma-ui-phase-pending))))
            (insert (propertize (format "  %-10s  %-10s  %3d%%\n"
                                        phase status progress)
                                'face face))))))))

(defun autonoma-ui--on-phase-update (data)
  "Handle phase update event DATA (plist)."
  (let ((exec-id (plist-get data :executionId))
        (phase (plist-get data :phase))
        (status (plist-get data :status))
        (progress (plist-get data :progress)))
    (setq autonoma-ui--current-execution-id exec-id)
    (setf (alist-get phase autonoma-ui--phase-state nil nil #'equal)
          (list :status status :progress (or progress 0)))
    (autonoma-ui--render-rigor)))

(defun autonoma-ui--on-execution-complete (data)
  "Handle execution.complete event DATA."
  (let ((status (plist-get data :status))
        (artifacts (plist-get data :artifacts)))
    (message "[a6s] execution complete: %s" status)
    (when artifacts
      (autonoma-ui-show-results artifacts))))

(define-derived-mode autonoma-rigor-mode special-mode "A6s-RIGOR"
  "Major mode for the A6s RIGOR progress buffer."
  (setq buffer-read-only t))

;;; Tasks buffer

(defvar autonoma-ui--tasks nil
  "Cached list of background tasks.")

(defconst autonoma-ui--tasks-buffer "*A6s Tasks*"
  "Name of the tasks buffer.")

(defun autonoma-ui--render-tasks ()
  "Render the tasks buffer from `autonoma-ui--tasks'."
  (let ((buf (get-buffer-create autonoma-ui--tasks-buffer)))
    (with-current-buffer buf
      (autonoma-tasks-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "A6s Background Tasks\n"
                            'face 'autonoma-ui-header))
        (insert (make-string 60 ?-) "\n")
        (if (null autonoma-ui--tasks)
            (insert "(no tasks)\n")
          (dolist (task autonoma-ui--tasks)
            (insert (format "  [%s] %-20s  %s  %d%%\n"
                            (or (plist-get task :id) "?")
                            (or (plist-get task :agentType) "?")
                            (or (plist-get task :status) "?")
                            (or (plist-get task :progress) 0)))
            (insert (format "    %s\n"
                            (or (plist-get task :task) "")))))))
    buf))

(defun autonoma-ui--on-task-update (_data)
  "Refresh tasks buffer on task.update event."
  (when (get-buffer autonoma-ui--tasks-buffer)
    (autonoma-api-background-list
     (lambda (tasks _err)
       (when tasks
         (setq autonoma-ui--tasks tasks)
         (autonoma-ui--render-tasks))))))

(define-derived-mode autonoma-tasks-mode special-mode "A6s-Tasks"
  "Major mode for the A6s tasks buffer."
  (setq buffer-read-only t))

;;; Results buffer with artifact apply/discard

(defvar autonoma-ui--pending-artifacts nil
  "List of artifacts pending apply/discard in the results buffer.")

(defconst autonoma-ui--results-buffer "*A6s Results*"
  "Name of the results buffer.")

(defun autonoma-ui-show-results (artifacts)
  "Display ARTIFACTS in the results buffer with apply/discard actions."
  (setq autonoma-ui--pending-artifacts artifacts)
  (let ((buf (get-buffer-create autonoma-ui--results-buffer)))
    (with-current-buffer buf
      (autonoma-results-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "A6s Results\n" 'face 'autonoma-ui-header))
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

(defun autonoma-ui-apply-pending ()
  "Apply the pending artifacts via daemon."
  (interactive)
  (if (null autonoma-ui--pending-artifacts)
      (message "No pending artifacts")
    (autonoma-api-artifacts-apply
     autonoma-ui--pending-artifacts
     (lambda (result err)
       (if err
           (message "[a6s] apply failed: %s" err)
         (message "[a6s] applied=%d skipped=%d errors=%d"
                  (or (plist-get result :applied) 0)
                  (or (plist-get result :skipped) 0)
                  (length (plist-get result :errors))))
       (setq autonoma-ui--pending-artifacts nil)))))

(defun autonoma-ui-discard-pending ()
  "Discard pending artifacts without applying."
  (interactive)
  (setq autonoma-ui--pending-artifacts nil)
  (when (get-buffer autonoma-ui--results-buffer)
    (kill-buffer autonoma-ui--results-buffer))
  (message "Discarded pending artifacts"))

(defvar autonoma-results-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'autonoma-ui-apply-pending)
    (define-key map (kbd "d") #'autonoma-ui-discard-pending)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `autonoma-results-mode'.")

(define-derived-mode autonoma-results-mode special-mode "A6s-Results"
  "Major mode for A6s results buffer."
  (setq buffer-read-only t))

;;; Transient menu

;;;###autoload
(transient-define-prefix autonoma-transient ()
  "A6s main menu."
  ["Connection"
   ("c" "Connect" autonoma-connect)
   ("d" "Disconnect" autonoma-disconnect)
   ("s" "Status" autonoma-status)]
  ["Agents"
   ("i" "Invoke agent" autonoma-invoke-agent)
   ("a" "List agents" autonoma-list-agents)
   ("S" "Execution status" autonoma-execution-status)
   ("l" "List tasks" autonoma-list-tasks)
   ("b" "Background launch" autonoma-background-launch)
   ("o" "Task output" autonoma-background-output)
   ("x" "Cancel task" autonoma-cancel-task)]
  ["Code (on region)"
   ("e" "Explain" autonoma-explain-region)
   ("r" "Refactor" autonoma-refactor-region)
   ("v" "Review" autonoma-review-region)
   ("t" "Generate tests" autonoma-generate-tests-region)]
  ["Artifacts"
   ("p" "Preview pending" autonoma-preview-changes)
   ("A" "Apply pending" autonoma-apply-artifacts)
   ("q" "Quit" transient-quit-one)])

;;; Minor mode

(defvar autonoma-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'autonoma-transient)
    map)
  "Keymap for `autonoma-mode'.")

(defun autonoma-ui--register-handlers ()
  "Subscribe event handlers so the UI can refresh itself."
  (autonoma-api-on "status.update" #'autonoma-ui--update-modeline)
  (autonoma-api-on "connected" #'autonoma-ui--update-modeline)
  (autonoma-api-on "disconnected" #'autonoma-ui--update-modeline)
  (autonoma-api-on "phase.update" #'autonoma-ui--on-phase-update)
  (autonoma-api-on "task.update" #'autonoma-ui--on-task-update)
  (autonoma-api-on "execution.complete" #'autonoma-ui--on-execution-complete))

(defun autonoma-ui--unregister-handlers ()
  "Unregister event handlers."
  (autonoma-api-off "status.update" #'autonoma-ui--update-modeline)
  (autonoma-api-off "connected" #'autonoma-ui--update-modeline)
  (autonoma-api-off "disconnected" #'autonoma-ui--update-modeline)
  (autonoma-api-off "phase.update" #'autonoma-ui--on-phase-update)
  (autonoma-api-off "task.update" #'autonoma-ui--on-task-update)
  (autonoma-api-off "execution.complete" #'autonoma-ui--on-execution-complete))

;;;###autoload
(define-minor-mode autonoma-mode
  "Minor mode for the A6s extension.

When enabled, shows a daemon connection indicator in the modeline,
binds \\[autonoma-transient] to the A6s transient menu, and (if
`autonoma-auto-connect' is non-nil) connects to the local daemon.

\\{autonoma-mode-map}"
  :lighter autonoma-ui--modeline-string
  :keymap autonoma-mode-map
  :group 'autonoma
  (if autonoma-mode
      (progn
        (autonoma-ui--register-handlers)
        (autonoma-ui--update-modeline)
        (when (and (boundp 'autonoma-auto-connect)
                   autonoma-auto-connect
                   (not (autonoma-api-connected-p)))
          (require 'autonoma-commands)
          (autonoma-connect)))
    (autonoma-ui--unregister-handlers)))

(provide 'autonoma-ui)

;;; autonoma-ui.el ends here
