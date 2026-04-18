;;; a6s-api.el --- WebSocket client for A6s daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of a6s.el

;;; Commentary:

;; WebSocket client for communicating with the local A6s CLI daemon
;; at ws://localhost:9876/ws.  Implements all 13 daemon protocol methods
;; from tools/cli/docs/DAEMON-PROTOCOL.md, event subscription, timeouts,
;; and reconnect-with-backoff.
;;
;; The client is the ONLY component that talks to the daemon.  All user-
;; facing code calls through the public `a6s-api-*' functions below.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'websocket)

(defvar a6s-daemon-port)
(defvar a6s-daemon-host)
(defvar a6s-request-timeout)
(defvar a6s-connect-timeout)
(defvar a6s-max-input-length)
(defvar a6s-max-reconnect-attempts)

;;; Internal state

(defvar a6s-api--ws nil
  "Active WebSocket connection (or nil when disconnected).")

(defvar a6s-api--connected nil
  "Non-nil when the WebSocket reports connected.")

(defvar a6s-api--connecting nil
  "Non-nil while a connect attempt is in flight.")

(defvar a6s-api--request-counter 0
  "Monotonically increasing request counter.")

(defvar a6s-api--pending-requests (make-hash-table :test 'equal)
  "Hash table mapping request id -> plist(:callback :timer :sync-result).")

(defvar a6s-api--event-handlers (make-hash-table :test 'equal)
  "Hash table mapping event name -> list of handler functions.")

(defvar a6s-api--reconnect-attempts 0
  "Number of reconnect attempts since last successful connect.")

(defvar a6s-api--reconnect-timer nil
  "Timer scheduled for the next reconnect attempt.")

(defvar a6s-api--status 'disconnected
  "One of `disconnected', `connecting', or `connected'.")

;;; Errors

(define-error 'a6s-api-error "A6s API error")
(define-error 'a6s-api-not-connected
  "Not connected to A6s daemon" 'a6s-api-error)
(define-error 'a6s-api-timeout "Request timed out" 'a6s-api-error)
(define-error 'a6s-api-invalid-input "Invalid input" 'a6s-api-error)

;;; Input validation

(defun a6s-api--validate-string (value field-name)
  "Trim VALUE, ensure non-empty and <= max length.  FIELD-NAME used in errors."
  (unless (stringp value)
    (signal 'a6s-api-invalid-input
            (list (format "%s must be a string" field-name))))
  (let ((trimmed (string-trim value)))
    (when (string-empty-p trimmed)
      (signal 'a6s-api-invalid-input
              (list (format "%s must not be empty" field-name))))
    (when (> (length trimmed) a6s-max-input-length)
      (signal 'a6s-api-invalid-input
              (list (format "%s exceeds maximum length of %d characters"
                            field-name a6s-max-input-length))))
    trimmed))

;;; Event emitter

(defun a6s-api-on (event handler)
  "Register HANDLER to be called with data for EVENT."
  (let ((handlers (gethash event a6s-api--event-handlers)))
    (puthash event (cons handler handlers) a6s-api--event-handlers)))

(defun a6s-api-off (event handler)
  "Remove HANDLER from EVENT subscribers."
  (let ((handlers (gethash event a6s-api--event-handlers)))
    (puthash event (delq handler handlers) a6s-api--event-handlers)))

(defun a6s-api--emit (event data)
  "Invoke all handlers for EVENT with DATA."
  (dolist (handler (gethash event a6s-api--event-handlers))
    (condition-case err
        (funcall handler data)
      (error
       (message "[a6s] event handler error for %s: %s"
                event (error-message-string err))))))

;;; Status

(defun a6s-api-status ()
  "Return current status symbol: connected, connecting, or disconnected."
  a6s-api--status)

(defun a6s-api-connected-p ()
  "Return non-nil when the daemon connection is open."
  a6s-api--connected)

(defun a6s-api--set-status (status)
  "Set STATUS and emit status.update event."
  (setq a6s-api--status status)
  (a6s-api--emit "status.update" status))

;;; Message handling

(defun a6s-api--handle-frame (_ws frame)
  "Handle incoming WebSocket FRAME."
  (let ((payload (websocket-frame-text frame)))
    (condition-case err
        (let* ((json-object-type 'plist)
               (json-array-type 'list)
               (json-key-type 'keyword)
               (message (json-read-from-string payload)))
          (a6s-api--dispatch-message message))
      (error
       (message "[a6s] failed to parse frame: %s"
                (error-message-string err))))))

(defun a6s-api--dispatch-message (message)
  "Route MESSAGE to either a pending request callback or event handlers."
  (let ((id (plist-get message :id))
        (type (plist-get message :type)))
    (cond
     ;; Response to a pending request
     ((and id (gethash id a6s-api--pending-requests))
      (let* ((entry (gethash id a6s-api--pending-requests))
             (callback (plist-get entry :callback))
             (timer (plist-get entry :timer))
             (error-msg (plist-get message :error))
             (result (plist-get message :result)))
        (when timer (cancel-timer timer))
        (remhash id a6s-api--pending-requests)
        (when callback
          (funcall callback result error-msg))))
     ;; Event
     (type
      (a6s-api--emit type (or (plist-get message :data) message)))
     (t
      (message "[a6s] unknown message (no id/type): %S" message)))))

;;; Connection

(defun a6s-api--url ()
  "Return the daemon WebSocket URL."
  (format "ws://%s:%d/ws" a6s-daemon-host a6s-daemon-port))

(defun a6s-api-connect (&optional callback)
  "Connect to the A6s daemon.
CALLBACK, if provided, is called with (ok-p error-message)."
  (cond
   (a6s-api--connecting
    (when callback (funcall callback nil "Already connecting")))
   (a6s-api--connected
    (when callback (funcall callback t nil)))
   (t
    (a6s-api--connect-internal callback))))

(defun a6s-api--connect-internal (callback)
  "Open a fresh WebSocket.  CALLBACK receives (ok-p error-message)."
  (setq a6s-api--connecting t)
  (a6s-api--set-status 'connecting)
  (let ((url (a6s-api--url))
        (connect-done nil))
    (condition-case err
        (setq a6s-api--ws
              (websocket-open
               url
               :on-open
               (lambda (_ws)
                 (setq connect-done t
                       a6s-api--connecting nil
                       a6s-api--connected t
                       a6s-api--reconnect-attempts 0)
                 (a6s-api--set-status 'connected)
                 (a6s-api--emit "connected" nil)
                 (when callback (funcall callback t nil)))
               :on-message #'a6s-api--handle-frame
               :on-close
               (lambda (_ws)
                 (setq a6s-api--connected nil
                       a6s-api--connecting nil
                       a6s-api--ws nil)
                 (a6s-api--set-status 'disconnected)
                 (a6s-api--emit "disconnected" nil)
                 (a6s-api--fail-all-pending "Connection closed")
                 (unless connect-done
                   (when callback (funcall callback nil "Connection closed"))))
               :on-error
               (lambda (_ws _type err2)
                 (setq a6s-api--connecting nil)
                 (unless connect-done
                   (when callback
                     (funcall callback nil
                              (format "WebSocket error: %S" err2)))))))
      (error
       (setq a6s-api--connecting nil)
       (a6s-api--set-status 'disconnected)
       (when callback
         (funcall callback nil (error-message-string err)))))
    ;; Connect timeout
    (run-at-time
     a6s-connect-timeout nil
     (lambda ()
       (when (and a6s-api--connecting (not connect-done))
         (setq a6s-api--connecting nil)
         (a6s-api--set-status 'disconnected)
         (when a6s-api--ws
           (ignore-errors (websocket-close a6s-api--ws))
           (setq a6s-api--ws nil))
         (when callback
           (funcall callback nil "Connection timeout")))))))

(defun a6s-api-disconnect ()
  "Close the WebSocket connection and cancel pending reconnects."
  (when a6s-api--reconnect-timer
    (cancel-timer a6s-api--reconnect-timer)
    (setq a6s-api--reconnect-timer nil))
  (setq a6s-api--reconnect-attempts a6s-max-reconnect-attempts)
  (when a6s-api--ws
    (ignore-errors (websocket-close a6s-api--ws))
    (setq a6s-api--ws nil))
  (setq a6s-api--connected nil
        a6s-api--connecting nil)
  (a6s-api--set-status 'disconnected)
  (a6s-api--fail-all-pending "Disconnected"))

(defun a6s-api--fail-all-pending (reason)
  "Reject all in-flight requests with REASON."
  (maphash
   (lambda (_id entry)
     (let ((callback (plist-get entry :callback))
           (timer (plist-get entry :timer)))
       (when timer (cancel-timer timer))
       (when callback (funcall callback nil reason))))
   a6s-api--pending-requests)
  (clrhash a6s-api--pending-requests))

(defun a6s-api-reconnect-with-backoff ()
  "Attempt to reconnect with exponential backoff (1s -> 16s, max 5 attempts)."
  (if (>= a6s-api--reconnect-attempts a6s-max-reconnect-attempts)
      (message "[a6s] giving up after %d reconnect attempts"
               a6s-api--reconnect-attempts)
    (a6s-api--schedule-reconnect)))

(defun a6s-api--schedule-reconnect ()
  "Schedule a single reconnect attempt after computed backoff."
  (let* ((attempt a6s-api--reconnect-attempts)
         (delay (min 16 (expt 2 attempt))))
    (cl-incf a6s-api--reconnect-attempts)
    (message "[a6s] reconnecting in %ds (attempt %d/%d)"
             delay (1+ attempt) a6s-max-reconnect-attempts)
    (setq a6s-api--reconnect-timer
          (run-at-time
           delay nil
           (lambda ()
             (setq a6s-api--reconnect-timer nil)
             (a6s-api-connect
              (lambda (ok err)
                (unless ok
                  (message "[a6s] reconnect failed: %s" err)
                  (a6s-api-reconnect-with-backoff)))))))))

;;; Request/response

(defun a6s-api--next-id ()
  "Generate next monotonic request id."
  (format "req_%d" (cl-incf a6s-api--request-counter)))

(defun a6s-api--send-request (method params callback)
  "Send request METHOD with PARAMS.  Invoke CALLBACK with (result error)."
  (unless a6s-api--connected
    (signal 'a6s-api-not-connected
            (list "Not connected to A6s daemon")))
  (let* ((id (a6s-api--next-id))
         (message (list :id id :method method :params (or params (list))))
         (timer
          (run-at-time
           a6s-request-timeout nil
           (lambda ()
             (when (gethash id a6s-api--pending-requests)
               (remhash id a6s-api--pending-requests)
               (when callback
                 (funcall callback nil "Request timeout")))))))
    (puthash id (list :callback callback :timer timer)
             a6s-api--pending-requests)
    (condition-case err
        (websocket-send-text a6s-api--ws (json-encode message))
      (error
       (remhash id a6s-api--pending-requests)
       (cancel-timer timer)
       (when callback
         (funcall callback nil (error-message-string err)))))
    id))

(defun a6s-api--request-sync (method params)
  "Synchronously send request METHOD/PARAMS and return result or signal error."
  (let ((done nil) (ret-result nil) (ret-error nil)
        (deadline (+ (float-time) a6s-request-timeout 2)))
    (a6s-api--send-request
     method params
     (lambda (result err)
       (setq done t ret-result result ret-error err)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless done
      (signal 'a6s-api-timeout (list "Synchronous request timed out")))
    (when ret-error
      (signal 'a6s-api-error (list ret-error)))
    ret-result))

;;; Public API methods

(defun a6s-api-agents-list (callback)
  "Asynchronously list agents; CALLBACK receives (agents err)."
  (a6s-api--send-request "agents.list" nil callback))

(defun a6s-api-agents-invoke (agent-type task context callback)
  "Invoke AGENT-TYPE with TASK (string) and CONTEXT (alist/plist or nil).
CALLBACK receives (result err) where result contains :executionId."
  (let ((a (a6s-api--validate-string agent-type "agentType"))
        (tt (a6s-api--validate-string task "task")))
    (a6s-api--send-request
     "agents.invoke"
     (list :agentType a :task tt :context (or context (list)))
     callback)))

(defun a6s-api-execution-status (execution-id callback)
  "Get status for EXECUTION-ID; CALLBACK receives (result err)."
  (let ((id (a6s-api--validate-string execution-id "executionId")))
    (a6s-api--send-request
     "execution.status" (list :executionId id) callback)))

(defun a6s-api-background-list (callback)
  "List background tasks; CALLBACK receives (tasks err)."
  (a6s-api--send-request "background.list" nil callback))

(defun a6s-api-background-launch (task agent-type callback)
  "Launch TASK under AGENT-TYPE; CALLBACK receives (result err)."
  (let ((a (a6s-api--validate-string agent-type "agentType"))
        (tt (a6s-api--validate-string task "task")))
    (a6s-api--send-request
     "background.launch"
     (list :task tt :agentType a) callback)))

(defun a6s-api-background-cancel (task-id callback)
  "Cancel TASK-ID; CALLBACK receives (result err)."
  (let ((id (a6s-api--validate-string task-id "taskId")))
    (a6s-api--send-request
     "background.cancel" (list :taskId id) callback)))

(defun a6s-api-background-output (task-id callback)
  "Get output of TASK-ID; CALLBACK receives (output err)."
  (let ((id (a6s-api--validate-string task-id "taskId")))
    (a6s-api--send-request
     "background.output" (list :taskId id) callback)))

(defun a6s-api-artifacts-preview (artifacts callback)
  "Preview ARTIFACTS; CALLBACK receives (result err)."
  (a6s-api--send-request
   "artifacts.preview" (list :artifacts artifacts) callback))

(defun a6s-api-artifacts-apply (artifacts callback)
  "Apply ARTIFACTS; CALLBACK receives (result err)."
  (a6s-api--send-request
   "artifacts.apply" (list :artifacts artifacts) callback))

(defun a6s-api-code-explain (code language file-path callback)
  "Explain CODE in LANGUAGE at FILE-PATH; CALLBACK receives (markdown err)."
  (let ((c (a6s-api--validate-string code "code"))
        (l (a6s-api--validate-string language "language"))
        (p (a6s-api--validate-string file-path "filePath")))
    (a6s-api--send-request
     "code.explain" (list :code c :language l :filePath p) callback)))

(defun a6s-api-code-refactor (code language file-path instructions callback)
  "Refactor CODE (LANGUAGE, FILE-PATH) with INSTRUCTIONS; CALLBACK(result err)."
  (let* ((c (a6s-api--validate-string code "code"))
         (l (a6s-api--validate-string language "language"))
         (p (a6s-api--validate-string file-path "filePath"))
         (params (list :code c :language l :filePath p)))
    (when (and instructions (not (string-empty-p (string-trim instructions))))
      (setq params (append params
                           (list :instructions
                                 (a6s-api--validate-string
                                  instructions "instructions")))))
    (a6s-api--send-request "code.refactor" params callback)))

(defun a6s-api-code-generate-tests (code language file-path callback)
  "Generate test for CODE (LANGUAGE, FILE-PATH); CALLBACK(artifacts err)."
  (let ((c (a6s-api--validate-string code "code"))
        (l (a6s-api--validate-string language "language"))
        (p (a6s-api--validate-string file-path "filePath")))
    (a6s-api--send-request
     "code.generateTests" (list :code c :language l :filePath p) callback)))

(defun a6s-api-code-review (code language file-path review-type callback)
  "Review CODE (LANGUAGE, FILE-PATH) for REVIEW-TYPE; CALLBACK(result err)."
  (let ((c (a6s-api--validate-string code "code"))
        (l (a6s-api--validate-string language "language"))
        (p (a6s-api--validate-string file-path "filePath"))
        (r (a6s-api--validate-string review-type "reviewType")))
    (a6s-api--send-request
     "code.review"
     (list :code c :language l :filePath p :reviewType r) callback)))

(defun a6s-api-workflows-list (callback &optional domain)
  "List available workflow templates; CALLBACK receives (workflows err).
Optional DOMAIN string filters results to a single domain."
  (let ((params (if (and domain (not (string-empty-p domain)))
                    (list :domain domain)
                  nil)))
    (a6s-api--send-request "workflows.list" params callback)))

(defun a6s-api-workflow-run (workflow-id callback &optional input priority)
  "Run workflow WORKFLOW-ID; CALLBACK receives (executionId err).
Optional INPUT plist and PRIORITY string (\"low\", \"normal\", \"high\")."
  (let* ((wid (a6s-api--validate-string workflow-id "workflowId"))
         (params (list :workflowId wid)))
    (when input
      (setq params (append params (list :input input))))
    (when (and priority (not (string-empty-p priority)))
      (setq params (append params (list :priority priority))))
    (a6s-api--send-request "workflows.run" params callback)))

(defun a6s-api-workflow-status (execution-id callback)
  "Get status of workflow execution EXECUTION-ID; CALLBACK receives (result err)."
  (let ((id (a6s-api--validate-string execution-id "executionId")))
    (a6s-api--send-request
     "workflows.status" (list :executionId id) callback)))

(defun a6s-api-workflow-cancel (execution-id callback)
  "Cancel workflow execution EXECUTION-ID; CALLBACK receives (result err)."
  (let ((id (a6s-api--validate-string execution-id "executionId")))
    (a6s-api--send-request
     "workflows.cancel" (list :executionId id) callback)))

(defun a6s-api-fleet-list (callback &optional capability)
  "List fleet agents; CALLBACK receives (agents err).
Optional CAPABILITY string filters to a single capability group."
  (let ((params (if (and capability (not (string-empty-p capability)))
                    (list :capability capability)
                  nil)))
    (a6s-api--send-request "fleet.list" params callback)))

(defun a6s-api-fleet-status (callback)
  "Get fleet-wide status summary; CALLBACK receives (status err)."
  (a6s-api--send-request "fleet.status" nil callback))

(defun a6s-api-fleet-command (target capability agent-type command callback)
  "Send COMMAND to fleet agent TARGET (CAPABILITY/AGENT-TYPE).
CALLBACK receives (executionId err)."
  (let ((tgt (a6s-api--validate-string target "target"))
        (cap (a6s-api--validate-string capability "capability"))
        (at  (a6s-api--validate-string agent-type "agentType"))
        (cmd (a6s-api--validate-string command "command")))
    (a6s-api--send-request
     "fleet.command"
     (list :target tgt :capability cap :agentType at :command cmd)
     callback)))

(provide 'a6s-api)

;;; a6s-api.el ends here
