;;; test-helper.el --- Test helpers for autonoma.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;;; Commentary:

;; Shared fixtures, mock WebSocket layer, and undercover coverage setup.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Coverage — must be set up before loading package files.
(when (require 'undercover nil t)
  (undercover "autonoma.el"
              "autonoma-api.el"
              "autonoma-ui.el"
              "autonoma-commands.el"
              (:report-format 'text)
              (:send-report nil)))

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." dir))
  (add-to-list 'load-path dir))

(require 'websocket)
(require 'autonoma)
(require 'autonoma-api)
(require 'autonoma-ui)
(require 'autonoma-commands)

;;; Mock WebSocket

(defvar autonoma-test--mock-ws nil
  "The mock websocket object.")

(defvar autonoma-test--mock-on-open nil)
(defvar autonoma-test--mock-on-message nil)
(defvar autonoma-test--mock-on-close nil)
(defvar autonoma-test--mock-on-error nil)
(defvar autonoma-test--mock-sent-messages nil
  "List of raw JSON strings sent via the mock websocket.")
(defvar autonoma-test--mock-open-delay 0
  "Seconds to defer open callback. 0 = synchronous.")
(defvar autonoma-test--mock-fail-open nil
  "If non-nil, do not fire on-open — triggers connect timeout.")

(cl-defstruct autonoma-test-fake-ws url)

(defun autonoma-test--install-mocks ()
  "Replace websocket functions with test doubles."
  (setq autonoma-test--mock-sent-messages nil
        autonoma-test--mock-fail-open nil
        autonoma-test--mock-open-delay 0)
  (advice-add 'websocket-open :override #'autonoma-test--mock-open)
  (advice-add 'websocket-send-text :override #'autonoma-test--mock-send)
  (advice-add 'websocket-close :override #'autonoma-test--mock-close))

(defun autonoma-test--uninstall-mocks ()
  "Restore real websocket functions."
  (advice-remove 'websocket-open #'autonoma-test--mock-open)
  (advice-remove 'websocket-send-text #'autonoma-test--mock-send)
  (advice-remove 'websocket-close #'autonoma-test--mock-close))

(defun autonoma-test--mock-open (url &rest plist)
  "Mocked `websocket-open' for URL / PLIST."
  (let ((ws (make-autonoma-test-fake-ws :url url)))
    (setq autonoma-test--mock-ws ws
          autonoma-test--mock-on-open (plist-get plist :on-open)
          autonoma-test--mock-on-message (plist-get plist :on-message)
          autonoma-test--mock-on-close (plist-get plist :on-close)
          autonoma-test--mock-on-error (plist-get plist :on-error))
    (unless autonoma-test--mock-fail-open
      (if (> autonoma-test--mock-open-delay 0)
          (run-at-time autonoma-test--mock-open-delay nil
                       (lambda ()
                         (when autonoma-test--mock-on-open
                           (funcall autonoma-test--mock-on-open ws))))
        (when autonoma-test--mock-on-open
          (funcall autonoma-test--mock-on-open ws))))
    ws))

(defun autonoma-test--mock-send (_ws text)
  "Record TEXT sent via mock websocket."
  (push text autonoma-test--mock-sent-messages))

(defun autonoma-test--mock-close (_ws)
  "Mocked close."
  (when autonoma-test--mock-on-close
    (funcall autonoma-test--mock-on-close autonoma-test--mock-ws)))

(defun autonoma-test--deliver-frame (message)
  "Deliver MESSAGE (an elisp object) to the client as a WebSocket frame."
  (let* ((json (json-encode message))
         (frame (make-websocket-frame :opcode 'text :payload json)))
    (funcall autonoma-test--mock-on-message autonoma-test--mock-ws frame)))

(defun autonoma-test--last-sent-method ()
  "Parse the last sent JSON frame and return its method, or nil if none."
  (when autonoma-test--mock-sent-messages
    (let ((json-object-type 'plist) (json-key-type 'keyword)
          (json-array-type 'list))
      (plist-get (json-read-from-string (car autonoma-test--mock-sent-messages))
                 :method))))

(defun autonoma-test--last-sent-id ()
  "Parse the last sent JSON frame and return its id, or nil if none."
  (when autonoma-test--mock-sent-messages
    (let ((json-object-type 'plist) (json-key-type 'keyword)
          (json-array-type 'list))
      (plist-get (json-read-from-string (car autonoma-test--mock-sent-messages))
                 :id))))

(defun autonoma-test--last-sent-params ()
  "Parse the last sent JSON frame and return its params, or nil if none."
  (when autonoma-test--mock-sent-messages
    (let ((json-object-type 'plist) (json-key-type 'keyword)
          (json-array-type 'list))
      (plist-get (json-read-from-string (car autonoma-test--mock-sent-messages))
                 :params))))

(defun autonoma-test--reset-state ()
  "Reset all Autonoma client state between tests."
  (setq autonoma-api--ws nil
        autonoma-api--connected nil
        autonoma-api--connecting nil
        autonoma-api--request-counter 0
        autonoma-api--reconnect-attempts 0
        autonoma-api--reconnect-timer nil
        autonoma-api--status 'disconnected
        autonoma-test--mock-sent-messages nil
        autonoma-test--mock-fail-open nil
        autonoma-test--mock-open-delay 0
        autonoma-ui--current-execution-id nil
        autonoma-ui--phase-state nil
        autonoma-ui--tasks nil
        autonoma-ui--pending-artifacts nil)
  (clrhash autonoma-api--pending-requests)
  (clrhash autonoma-api--event-handlers))

(defmacro autonoma-test-with-connection (&rest body)
  "Install mocks, connect, run BODY, then clean up."
  `(unwind-protect
       (progn
         (autonoma-test--install-mocks)
         (autonoma-test--reset-state)
         (let (connect-ok)
           (autonoma-api-connect (lambda (ok _err) (setq connect-ok ok)))
           (should connect-ok))
         ,@body)
     (autonoma-test--uninstall-mocks)
     (autonoma-test--reset-state)))

(provide 'test-helper)

;;; test-helper.el ends here
