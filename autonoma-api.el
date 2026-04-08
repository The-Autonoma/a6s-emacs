;;; autonoma-api.el --- WebSocket client for Autonoma daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of autonoma.el

;;; Commentary:

;; WebSocket client for communicating with the local Autonoma CLI daemon
;; at ws://localhost:9876/ws.  Implements all 13 daemon protocol methods
;; from tools/cli/docs/DAEMON-PROTOCOL.md, event subscription, timeouts,
;; and reconnect-with-backoff.
;;
;; The client is the ONLY component that talks to the daemon.  All user-
;; facing code calls through the public `autonoma-api-*' functions below.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'websocket)

(defvar autonoma-daemon-port)
(defvar autonoma-daemon-host)
(defvar autonoma-request-timeout)
(defvar autonoma-connect-timeout)
(defvar autonoma-max-input-length)
(defvar autonoma-max-reconnect-attempts)

;;; Internal state

(defvar autonoma-api--ws nil
  "Active WebSocket connection (or nil when disconnected).")

(defvar autonoma-api--connected nil
  "Non-nil when the WebSocket reports connected.")

(defvar autonoma-api--connecting nil
  "Non-nil while a connect attempt is in flight.")

(defvar autonoma-api--request-counter 0
  "Monotonically increasing request counter.")

(defvar autonoma-api--pending-requests (make-hash-table :test 'equal)
  "Hash table mapping request id -> plist(:callback :timer :sync-result).")

(defvar autonoma-api--event-handlers (make-hash-table :test 'equal)
  "Hash table mapping event name -> list of handler functions.")

(defvar autonoma-api--reconnect-attempts 0
  "Number of reconnect attempts since last successful connect.")

(defvar autonoma-api--reconnect-timer nil
  "Timer scheduled for the next reconnect attempt.")

(defvar autonoma-api--status 'disconnected
  "One of `disconnected', `connecting', or `connected'.")

;;; Errors

(define-error 'autonoma-api-error "Autonoma API error")
(define-error 'autonoma-api-not-connected
  "Not connected to Autonoma daemon" 'autonoma-api-error)
(define-error 'autonoma-api-timeout "Request timed out" 'autonoma-api-error)
(define-error 'autonoma-api-invalid-input "Invalid input" 'autonoma-api-error)

;;; Input validation

(defun autonoma-api--validate-string (value field-name)
  "Trim VALUE, ensure non-empty and <= max length.  FIELD-NAME used in errors."
  (unless (stringp value)
    (signal 'autonoma-api-invalid-input
            (list (format "%s must be a string" field-name))))
  (let ((trimmed (string-trim value)))
    (when (string-empty-p trimmed)
      (signal 'autonoma-api-invalid-input
              (list (format "%s must not be empty" field-name))))
    (when (> (length trimmed) autonoma-max-input-length)
      (signal 'autonoma-api-invalid-input
              (list (format "%s exceeds maximum length of %d characters"
                            field-name autonoma-max-input-length))))
    trimmed))

;;; Event emitter

(defun autonoma-api-on (event handler)
  "Register HANDLER to be called with data for EVENT."
  (let ((handlers (gethash event autonoma-api--event-handlers)))
    (puthash event (cons handler handlers) autonoma-api--event-handlers)))

(defun autonoma-api-off (event handler)
  "Remove HANDLER from EVENT subscribers."
  (let ((handlers (gethash event autonoma-api--event-handlers)))
    (puthash event (delq handler handlers) autonoma-api--event-handlers)))

(defun autonoma-api--emit (event data)
  "Invoke all handlers for EVENT with DATA."
  (dolist (handler (gethash event autonoma-api--event-handlers))
    (condition-case err
        (funcall handler data)
      (error
       (message "[autonoma] event handler error for %s: %s"
                event (error-message-string err))))))

;;; Status

(defun autonoma-api-status ()
  "Return current status symbol: connected, connecting, or disconnected."
  autonoma-api--status)

(defun autonoma-api-connected-p ()
  "Return non-nil when the daemon connection is open."
  autonoma-api--connected)

(defun autonoma-api--set-status (status)
  "Set STATUS and emit status.update event."
  (setq autonoma-api--status status)
  (autonoma-api--emit "status.update" status))

;;; Message handling

(defun autonoma-api--handle-frame (_ws frame)
  "Handle incoming WebSocket FRAME."
  (let ((payload (websocket-frame-text frame)))
    (condition-case err
        (let* ((json-object-type 'plist)
               (json-array-type 'list)
               (json-key-type 'keyword)
               (message (json-read-from-string payload)))
          (autonoma-api--dispatch-message message))
      (error
       (message "[autonoma] failed to parse frame: %s"
                (error-message-string err))))))

(defun autonoma-api--dispatch-message (message)
  "Route MESSAGE to either a pending request callback or event handlers."
  (let ((id (plist-get message :id))
        (type (plist-get message :type)))
    (cond
     ;; Response to a pending request
     ((and id (gethash id autonoma-api--pending-requests))
      (let* ((entry (gethash id autonoma-api--pending-requests))
             (callback (plist-get entry :callback))
             (timer (plist-get entry :timer))
             (error-msg (plist-get message :error))
             (result (plist-get message :result)))
        (when timer (cancel-timer timer))
        (remhash id autonoma-api--pending-requests)
        (when callback
          (funcall callback result error-msg))))
     ;; Event
     (type
      (autonoma-api--emit type (or (plist-get message :data) message)))
     (t
      (message "[autonoma] unknown message (no id/type): %S" message)))))

;;; Connection

(defun autonoma-api--url ()
  "Return the daemon WebSocket URL."
  (format "ws://%s:%d/ws" autonoma-daemon-host autonoma-daemon-port))

(defun autonoma-api-connect (&optional callback)
  "Connect to the Autonoma daemon.
CALLBACK, if provided, is called with (ok-p error-message)."
  (cond
   (autonoma-api--connecting
    (when callback (funcall callback nil "Already connecting")))
   (autonoma-api--connected
    (when callback (funcall callback t nil)))
   (t
    (autonoma-api--connect-internal callback))))

(defun autonoma-api--connect-internal (callback)
  "Open a fresh WebSocket.  CALLBACK receives (ok-p error-message)."
  (setq autonoma-api--connecting t)
  (autonoma-api--set-status 'connecting)
  (let ((url (autonoma-api--url))
        (connect-done nil))
    (condition-case err
        (setq autonoma-api--ws
              (websocket-open
               url
               :on-open
               (lambda (_ws)
                 (setq connect-done t
                       autonoma-api--connecting nil
                       autonoma-api--connected t
                       autonoma-api--reconnect-attempts 0)
                 (autonoma-api--set-status 'connected)
                 (autonoma-api--emit "connected" nil)
                 (when callback (funcall callback t nil)))
               :on-message #'autonoma-api--handle-frame
               :on-close
               (lambda (_ws)
                 (setq autonoma-api--connected nil
                       autonoma-api--connecting nil
                       autonoma-api--ws nil)
                 (autonoma-api--set-status 'disconnected)
                 (autonoma-api--emit "disconnected" nil)
                 (autonoma-api--fail-all-pending "Connection closed")
                 (unless connect-done
                   (when callback (funcall callback nil "Connection closed"))))
               :on-error
               (lambda (_ws _type err2)
                 (setq autonoma-api--connecting nil)
                 (unless connect-done
                   (when callback
                     (funcall callback nil
                              (format "WebSocket error: %S" err2)))))))
      (error
       (setq autonoma-api--connecting nil)
       (autonoma-api--set-status 'disconnected)
       (when callback
         (funcall callback nil (error-message-string err)))))
    ;; Connect timeout
    (run-at-time
     autonoma-connect-timeout nil
     (lambda ()
       (when (and autonoma-api--connecting (not connect-done))
         (setq autonoma-api--connecting nil)
         (autonoma-api--set-status 'disconnected)
         (when autonoma-api--ws
           (ignore-errors (websocket-close autonoma-api--ws))
           (setq autonoma-api--ws nil))
         (when callback
           (funcall callback nil "Connection timeout")))))))

(defun autonoma-api-disconnect ()
  "Close the WebSocket connection and cancel pending reconnects."
  (when autonoma-api--reconnect-timer
    (cancel-timer autonoma-api--reconnect-timer)
    (setq autonoma-api--reconnect-timer nil))
  (setq autonoma-api--reconnect-attempts autonoma-max-reconnect-attempts)
  (when autonoma-api--ws
    (ignore-errors (websocket-close autonoma-api--ws))
    (setq autonoma-api--ws nil))
  (setq autonoma-api--connected nil
        autonoma-api--connecting nil)
  (autonoma-api--set-status 'disconnected)
  (autonoma-api--fail-all-pending "Disconnected"))

(defun autonoma-api--fail-all-pending (reason)
  "Reject all in-flight requests with REASON."
  (maphash
   (lambda (_id entry)
     (let ((callback (plist-get entry :callback))
           (timer (plist-get entry :timer)))
       (when timer (cancel-timer timer))
       (when callback (funcall callback nil reason))))
   autonoma-api--pending-requests)
  (clrhash autonoma-api--pending-requests))

(defun autonoma-api-reconnect-with-backoff ()
  "Attempt to reconnect with exponential backoff (1s -> 16s, max 5 attempts)."
  (if (>= autonoma-api--reconnect-attempts autonoma-max-reconnect-attempts)
      (message "[autonoma] giving up after %d reconnect attempts"
               autonoma-api--reconnect-attempts)
    (autonoma-api--schedule-reconnect)))

(defun autonoma-api--schedule-reconnect ()
  "Schedule a single reconnect attempt after computed backoff."
  (let* ((attempt autonoma-api--reconnect-attempts)
         (delay (min 16 (expt 2 attempt))))
    (cl-incf autonoma-api--reconnect-attempts)
    (message "[autonoma] reconnecting in %ds (attempt %d/%d)"
             delay (1+ attempt) autonoma-max-reconnect-attempts)
    (setq autonoma-api--reconnect-timer
          (run-at-time
           delay nil
           (lambda ()
             (setq autonoma-api--reconnect-timer nil)
             (autonoma-api-connect
              (lambda (ok err)
                (unless ok
                  (message "[autonoma] reconnect failed: %s" err)
                  (autonoma-api-reconnect-with-backoff)))))))))

;;; Request/response

(defun autonoma-api--next-id ()
  "Generate next monotonic request id."
  (format "req_%d" (cl-incf autonoma-api--request-counter)))

(defun autonoma-api--send-request (method params callback)
  "Send request METHOD with PARAMS.  Invoke CALLBACK with (result error)."
  (unless autonoma-api--connected
    (signal 'autonoma-api-not-connected
            (list "Not connected to Autonoma daemon")))
  (let* ((id (autonoma-api--next-id))
         (message (list :id id :method method :params (or params (list))))
         (timer
          (run-at-time
           autonoma-request-timeout nil
           (lambda ()
             (when (gethash id autonoma-api--pending-requests)
               (remhash id autonoma-api--pending-requests)
               (when callback
                 (funcall callback nil "Request timeout")))))))
    (puthash id (list :callback callback :timer timer)
             autonoma-api--pending-requests)
    (condition-case err
        (websocket-send-text autonoma-api--ws (json-encode message))
      (error
       (remhash id autonoma-api--pending-requests)
       (cancel-timer timer)
       (when callback
         (funcall callback nil (error-message-string err)))))
    id))

(defun autonoma-api--request-sync (method params)
  "Synchronously send request METHOD/PARAMS and return result or signal error."
  (let ((done nil) (ret-result nil) (ret-error nil)
        (deadline (+ (float-time) autonoma-request-timeout 2)))
    (autonoma-api--send-request
     method params
     (lambda (result err)
       (setq done t ret-result result ret-error err)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless done
      (signal 'autonoma-api-timeout (list "Synchronous request timed out")))
    (when ret-error
      (signal 'autonoma-api-error (list ret-error)))
    ret-result))

;;; Public API methods (all 13 from DAEMON-PROTOCOL.md)

(defun autonoma-api-agents-list (callback)
  "Asynchronously list agents; CALLBACK receives (agents err)."
  (autonoma-api--send-request "agents.list" nil callback))

(defun autonoma-api-agents-invoke (agent-type task context callback)
  "Invoke AGENT-TYPE with TASK (string) and CONTEXT (alist/plist or nil).
CALLBACK receives (result err) where result contains :executionId."
  (let ((a (autonoma-api--validate-string agent-type "agentType"))
        (tt (autonoma-api--validate-string task "task")))
    (autonoma-api--send-request
     "agents.invoke"
     (list :agentType a :task tt :context (or context (list)))
     callback)))

(defun autonoma-api-execution-status (execution-id callback)
  "Get status for EXECUTION-ID; CALLBACK receives (result err)."
  (let ((id (autonoma-api--validate-string execution-id "executionId")))
    (autonoma-api--send-request
     "execution.status" (list :executionId id) callback)))

(defun autonoma-api-background-list (callback)
  "List background tasks; CALLBACK receives (tasks err)."
  (autonoma-api--send-request "background.list" nil callback))

(defun autonoma-api-background-launch (task agent-type callback)
  "Launch TASK under AGENT-TYPE; CALLBACK receives (result err)."
  (let ((a (autonoma-api--validate-string agent-type "agentType"))
        (tt (autonoma-api--validate-string task "task")))
    (autonoma-api--send-request
     "background.launch"
     (list :task tt :agentType a) callback)))

(defun autonoma-api-background-cancel (task-id callback)
  "Cancel TASK-ID; CALLBACK receives (result err)."
  (let ((id (autonoma-api--validate-string task-id "taskId")))
    (autonoma-api--send-request
     "background.cancel" (list :taskId id) callback)))

(defun autonoma-api-background-output (task-id callback)
  "Get output of TASK-ID; CALLBACK receives (output err)."
  (let ((id (autonoma-api--validate-string task-id "taskId")))
    (autonoma-api--send-request
     "background.output" (list :taskId id) callback)))

(defun autonoma-api-artifacts-preview (artifacts callback)
  "Preview ARTIFACTS; CALLBACK receives (result err)."
  (autonoma-api--send-request
   "artifacts.preview" (list :artifacts artifacts) callback))

(defun autonoma-api-artifacts-apply (artifacts callback)
  "Apply ARTIFACTS; CALLBACK receives (result err)."
  (autonoma-api--send-request
   "artifacts.apply" (list :artifacts artifacts) callback))

(defun autonoma-api-code-explain (code language file-path callback)
  "Explain CODE in LANGUAGE at FILE-PATH; CALLBACK receives (markdown err)."
  (let ((c (autonoma-api--validate-string code "code"))
        (l (autonoma-api--validate-string language "language"))
        (p (autonoma-api--validate-string file-path "filePath")))
    (autonoma-api--send-request
     "code.explain" (list :code c :language l :filePath p) callback)))

(defun autonoma-api-code-refactor (code language file-path instructions callback)
  "Refactor CODE (LANGUAGE, FILE-PATH) with INSTRUCTIONS; CALLBACK(result err)."
  (let* ((c (autonoma-api--validate-string code "code"))
         (l (autonoma-api--validate-string language "language"))
         (p (autonoma-api--validate-string file-path "filePath"))
         (params (list :code c :language l :filePath p)))
    (when (and instructions (not (string-empty-p (string-trim instructions))))
      (setq params (append params
                           (list :instructions
                                 (autonoma-api--validate-string
                                  instructions "instructions")))))
    (autonoma-api--send-request "code.refactor" params callback)))

(defun autonoma-api-code-generate-tests (code language file-path callback)
  "Generate test for CODE (LANGUAGE, FILE-PATH); CALLBACK(artifacts err)."
  (let ((c (autonoma-api--validate-string code "code"))
        (l (autonoma-api--validate-string language "language"))
        (p (autonoma-api--validate-string file-path "filePath")))
    (autonoma-api--send-request
     "code.generateTests" (list :code c :language l :filePath p) callback)))

(defun autonoma-api-code-review (code language file-path review-type callback)
  "Review CODE (LANGUAGE, FILE-PATH) for REVIEW-TYPE; CALLBACK(result err)."
  (let ((c (autonoma-api--validate-string code "code"))
        (l (autonoma-api--validate-string language "language"))
        (p (autonoma-api--validate-string file-path "filePath"))
        (r (autonoma-api--validate-string review-type "reviewType")))
    (autonoma-api--send-request
     "code.review"
     (list :code c :language l :filePath p :reviewType r) callback)))

(provide 'autonoma-api)

;;; autonoma-api.el ends here
