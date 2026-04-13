;;; a6s-api-test.el --- API client tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for a6s-api.el: connection lifecycle, all 13 protocol
;; methods, event dispatch, timeouts, reconnect, input validation.

;;; Code:

(require 'test-helper)

;;; Connection lifecycle

(ert-deftest a6s-api-test-connect-success ()
  "Connect fires on-open and sets status."
  (a6s-test--install-mocks)
  (a6s-test--reset-state)
  (unwind-protect
      (let (ok)
        (a6s-api-connect (lambda (v _e) (setq ok v)))
        (should ok)
        (should (a6s-api-connected-p))
        (should (eq (a6s-api-status) 'connected)))
    (a6s-test--uninstall-mocks)
    (a6s-test--reset-state)))

(ert-deftest a6s-api-test-connect-timeout ()
  "Connect fails with timeout when on-open is never fired."
  (a6s-test--install-mocks)
  (a6s-test--reset-state)
  (unwind-protect
      (let ((a6s-connect-timeout 1) result err-msg)
        (setq a6s-test--mock-fail-open t)
        (a6s-api-connect
         (lambda (ok err) (setq result ok err-msg err)))
        (sleep-for 1.2)
        (should-not result)
        (should (string-match-p "timeout" err-msg)))
    (a6s-test--uninstall-mocks)
    (a6s-test--reset-state)))

(ert-deftest a6s-api-test-disconnect ()
  "Disconnect clears state."
  (a6s-test-with-connection
   (a6s-api-disconnect)
   (should-not (a6s-api-connected-p))
   (should (eq (a6s-api-status) 'disconnected))))

;;; Request/response

(ert-deftest a6s-api-test-request-sends-envelope ()
  "Sent frame has id, method, params."
  (a6s-test-with-connection
   (a6s-api-agents-list (lambda (_r _e) nil))
   (should (equal (a6s-test--last-sent-method) "agents.list"))
   (should (string-prefix-p "req_" (a6s-test--last-sent-id)))))

(ert-deftest a6s-api-test-response-resolves-callback ()
  "Response with matching id triggers callback."
  (a6s-test-with-connection
   (let (got-result)
     (a6s-api-agents-list (lambda (r _e) (setq got-result r)))
     (let ((id (a6s-test--last-sent-id)))
       (a6s-test--deliver-frame
        `(:id ,id :result ((:id "a" :name "a" :description "" :status "available")))))
     (should got-result))))

(ert-deftest a6s-api-test-response-error-rejects ()
  "Response with error field surfaces to callback."
  (a6s-test-with-connection
   (let (got-err)
     (a6s-api-agents-list (lambda (_r e) (setq got-err e)))
     (let ((id (a6s-test--last-sent-id)))
       (a6s-test--deliver-frame
        `(:id ,id :error "boom")))
     (should (equal got-err "boom")))))

(ert-deftest a6s-api-test-request-timeout ()
  "Request times out after a6s-request-timeout seconds."
  (a6s-test-with-connection
   (let ((a6s-request-timeout 1) err)
     (a6s-api-agents-list (lambda (_r e) (setq err e)))
     (sleep-for 1.2)
     (should (string-match-p "timeout" err)))))

(ert-deftest a6s-api-test-not-connected-signals ()
  "Sending a request while disconnected signals an error."
  (a6s-test--reset-state)
  (should-error (a6s-api-agents-list (lambda (_r _e) nil))
                :type 'a6s-api-not-connected))

;;; Event dispatch

(ert-deftest a6s-api-test-event-emits-to-handlers ()
  "Unsolicited typed messages reach registered handlers."
  (a6s-test-with-connection
   (let (received)
     (a6s-api-on "phase.update" (lambda (d) (setq received d)))
     (a6s-test--deliver-frame
      '(:type "phase.update" :data (:phase "research" :progress 50)))
     (should received)
     (should (equal (plist-get received :phase) "research")))))

(ert-deftest a6s-api-test-event-off ()
  "a6s-api-off removes a handler."
  (a6s-test-with-connection
   (let* ((count 0)
          (h (lambda (_d) (cl-incf count))))
     (a6s-api-on "x" h)
     (a6s-test--deliver-frame '(:type "x" :data (:a 1)))
     (a6s-api-off "x" h)
     (a6s-test--deliver-frame '(:type "x" :data (:a 2)))
     (should (= count 1)))))

(ert-deftest a6s-api-test-invalid-json-ignored ()
  "Malformed JSON does not crash the client."
  (a6s-test-with-connection
   (let ((frame (make-websocket-frame :opcode 'text :payload "not json{")))
     (funcall a6s-test--mock-on-message
              a6s-test--mock-ws frame))
   (should (a6s-api-connected-p))))

;;; Input validation

(ert-deftest a6s-api-test-reject-empty ()
  "Empty strings rejected."
  (a6s-test-with-connection
   (should-error (a6s-api-agents-invoke "" "task" nil #'ignore)
                 :type 'a6s-api-invalid-input)
   (should-error (a6s-api-agents-invoke "agent" "" nil #'ignore)
                 :type 'a6s-api-invalid-input)
   (should-error (a6s-api-agents-invoke "agent" "   " nil #'ignore)
                 :type 'a6s-api-invalid-input)))

(ert-deftest a6s-api-test-reject-too-long ()
  "Inputs over max length are rejected."
  (a6s-test-with-connection
   (let ((a6s-max-input-length 10))
     (should-error (a6s-api-agents-invoke
                    "agent" (make-string 20 ?x) nil #'ignore)
                   :type 'a6s-api-invalid-input))))

(ert-deftest a6s-api-test-trim-input ()
  "Input is trimmed before sending."
  (a6s-test-with-connection
   (a6s-api-agents-invoke "  agent  " "  task  " nil #'ignore)
   (let ((params (a6s-test--last-sent-params)))
     (should (equal (plist-get params :agentType) "agent"))
     (should (equal (plist-get params :task) "task")))))

;;; All 13 methods — just verify each sends the right `method' string

(ert-deftest a6s-api-test-all-methods-send-correct-names ()
  "Each API method sends the correct protocol method name."
  (a6s-test-with-connection
   (cl-flet ((m () (a6s-test--last-sent-method)))
     (a6s-api-agents-list #'ignore)
     (should (equal (m) "agents.list"))

     (a6s-api-agents-invoke "a" "t" nil #'ignore)
     (should (equal (m) "agents.invoke"))

     (a6s-api-execution-status "exec1" #'ignore)
     (should (equal (m) "execution.status"))

     (a6s-api-background-list #'ignore)
     (should (equal (m) "background.list"))

     (a6s-api-background-launch "t" "a" #'ignore)
     (should (equal (m) "background.launch"))

     (a6s-api-background-cancel "tid" #'ignore)
     (should (equal (m) "background.cancel"))

     (a6s-api-background-output "tid" #'ignore)
     (should (equal (m) "background.output"))

     (a6s-api-artifacts-preview nil #'ignore)
     (should (equal (m) "artifacts.preview"))

     (a6s-api-artifacts-apply nil #'ignore)
     (should (equal (m) "artifacts.apply"))

     (a6s-api-code-explain "c" "l" "p" #'ignore)
     (should (equal (m) "code.explain"))

     (a6s-api-code-refactor "c" "l" "p" nil #'ignore)
     (should (equal (m) "code.refactor"))

     (a6s-api-code-refactor "c" "l" "p" "clean it" #'ignore)
     (should (equal (m) "code.refactor"))
     (should (equal (plist-get (a6s-test--last-sent-params) :instructions)
                    "clean it"))

     (a6s-api-code-generate-tests "c" "l" "p" #'ignore)
     (should (equal (m) "code.generateTests"))

     (a6s-api-code-review "c" "l" "p" "security" #'ignore)
     (should (equal (m) "code.review")))))

;;; Reconnect

(ert-deftest a6s-api-test-reconnect-stops-at-max ()
  "Reconnect stops after max attempts."
  (a6s-test--install-mocks)
  (a6s-test--reset-state)
  (unwind-protect
      (let ((a6s-max-reconnect-attempts 2))
        (setq a6s-api--reconnect-attempts 2)
        (a6s-api-reconnect-with-backoff)
        (should-not a6s-api--reconnect-timer))
    (a6s-test--uninstall-mocks)
    (a6s-test--reset-state)))

(ert-deftest a6s-api-test-close-fails-pending ()
  "When connection closes, pending requests are rejected."
  (a6s-test-with-connection
   (let (err)
     (a6s-api-agents-list (lambda (_r e) (setq err e)))
     (funcall a6s-test--mock-on-close a6s-test--mock-ws)
     (should err))))

(provide 'a6s-api-test)

;;; a6s-api-test.el ends here
