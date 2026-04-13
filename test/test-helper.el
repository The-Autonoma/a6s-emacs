;;; test-helper.el --- Test helpers for a6s.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;;; Commentary:

;; Shared fixtures, mock WebSocket layer, and undercover coverage setup.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Coverage — must be set up before loading package files.
(when (require 'undercover nil t)
  (undercover "a6s.el"
              "a6s-api.el"
              "a6s-ui.el"
              "a6s-commands.el"
              (:report-format 'text)
              (:send-report nil)))

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." dir))
  (add-to-list 'load-path dir))

(require 'websocket)
(require 'a6s)
(require 'a6s-api)
(require 'a6s-ui)
(require 'a6s-commands)

;;; Mock WebSocket

(defvar a6s-test--mock-ws nil
  "The mock websocket object.")

(defvar a6s-test--mock-on-open nil)
(defvar a6s-test--mock-on-message nil)
(defvar a6s-test--mock-on-close nil)
(defvar a6s-test--mock-on-error nil)
(defvar a6s-test--mock-sent-messages nil
  "List of raw JSON strings sent via the mock websocket.")
(defvar a6s-test--mock-open-delay 0
  "Seconds to defer open callback. 0 = synchronous.")
(defvar a6s-test--mock-fail-open nil
  "If non-nil, do not fire on-open — triggers connect timeout.")

(cl-defstruct a6s-test-fake-ws url)

(defun a6s-test--install-mocks ()
  "Replace websocket functions with test doubles."
  (setq a6s-test--mock-sent-messages nil
        a6s-test--mock-fail-open nil
        a6s-test--mock-open-delay 0)
  (advice-add 'websocket-open :override #'a6s-test--mock-open)
  (advice-add 'websocket-send-text :override #'a6s-test--mock-send)
  (advice-add 'websocket-close :override #'a6s-test--mock-close))

(defun a6s-test--uninstall-mocks ()
  "Restore real websocket functions."
  (advice-remove 'websocket-open #'a6s-test--mock-open)
  (advice-remove 'websocket-send-text #'a6s-test--mock-send)
  (advice-remove 'websocket-close #'a6s-test--mock-close))

(defun a6s-test--mock-open (url &rest plist)
  "Mocked `websocket-open' for URL / PLIST."
  (let ((ws (make-a6s-test-fake-ws :url url)))
    (setq a6s-test--mock-ws ws
          a6s-test--mock-on-open (plist-get plist :on-open)
          a6s-test--mock-on-message (plist-get plist :on-message)
          a6s-test--mock-on-close (plist-get plist :on-close)
          a6s-test--mock-on-error (plist-get plist :on-error))
    (unless a6s-test--mock-fail-open
      (if (> a6s-test--mock-open-delay 0)
          (run-at-time a6s-test--mock-open-delay nil
                       (lambda ()
                         (when a6s-test--mock-on-open
                           (funcall a6s-test--mock-on-open ws))))
        (when a6s-test--mock-on-open
          (funcall a6s-test--mock-on-open ws))))
    ws))

(defun a6s-test--mock-send (_ws text)
  "Record TEXT sent via mock websocket."
  (push text a6s-test--mock-sent-messages))

(defun a6s-test--mock-close (_ws)
  "Mocked close."
  (when a6s-test--mock-on-close
    (funcall a6s-test--mock-on-close a6s-test--mock-ws)))

(defun a6s-test--deliver-frame (message)
  "Deliver MESSAGE (an elisp object) to the client as a WebSocket frame."
  (let* ((json (json-encode message))
         (frame (make-websocket-frame :opcode 'text :payload json)))
    (funcall a6s-test--mock-on-message a6s-test--mock-ws frame)))

(defun a6s-test--last-sent-method ()
  "Parse the last sent JSON frame and return its method, or nil if none."
  (when a6s-test--mock-sent-messages
    (let ((json-object-type 'plist) (json-key-type 'keyword)
          (json-array-type 'list))
      (plist-get (json-read-from-string (car a6s-test--mock-sent-messages))
                 :method))))

(defun a6s-test--last-sent-id ()
  "Parse the last sent JSON frame and return its id, or nil if none."
  (when a6s-test--mock-sent-messages
    (let ((json-object-type 'plist) (json-key-type 'keyword)
          (json-array-type 'list))
      (plist-get (json-read-from-string (car a6s-test--mock-sent-messages))
                 :id))))

(defun a6s-test--last-sent-params ()
  "Parse the last sent JSON frame and return its params, or nil if none."
  (when a6s-test--mock-sent-messages
    (let ((json-object-type 'plist) (json-key-type 'keyword)
          (json-array-type 'list))
      (plist-get (json-read-from-string (car a6s-test--mock-sent-messages))
                 :params))))

(defun a6s-test--reset-state ()
  "Reset all A6s client state between tests."
  (setq a6s-api--ws nil
        a6s-api--connected nil
        a6s-api--connecting nil
        a6s-api--request-counter 0
        a6s-api--reconnect-attempts 0
        a6s-api--reconnect-timer nil
        a6s-api--status 'disconnected
        a6s-test--mock-sent-messages nil
        a6s-test--mock-fail-open nil
        a6s-test--mock-open-delay 0
        a6s-ui--current-execution-id nil
        a6s-ui--phase-state nil
        a6s-ui--tasks nil
        a6s-ui--pending-artifacts nil)
  (clrhash a6s-api--pending-requests)
  (clrhash a6s-api--event-handlers))

(defmacro a6s-test-with-connection (&rest body)
  "Install mocks, connect, run BODY, then clean up."
  `(unwind-protect
       (progn
         (a6s-test--install-mocks)
         (a6s-test--reset-state)
         (let (connect-ok)
           (a6s-api-connect (lambda (ok _err) (setq connect-ok ok)))
           (should connect-ok))
         ,@body)
     (a6s-test--uninstall-mocks)
     (a6s-test--reset-state)))

(provide 'test-helper)

;;; test-helper.el ends here
