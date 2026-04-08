;;; autonoma-api-test.el --- API client tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for autonoma-api.el: connection lifecycle, all 13 protocol
;; methods, event dispatch, timeouts, reconnect, input validation.

;;; Code:

(require 'test-helper)

;;; Connection lifecycle

(ert-deftest autonoma-api-test-connect-success ()
  "Connect fires on-open and sets status."
  (autonoma-test--install-mocks)
  (autonoma-test--reset-state)
  (unwind-protect
      (let (ok)
        (autonoma-api-connect (lambda (v _e) (setq ok v)))
        (should ok)
        (should (autonoma-api-connected-p))
        (should (eq (autonoma-api-status) 'connected)))
    (autonoma-test--uninstall-mocks)
    (autonoma-test--reset-state)))

(ert-deftest autonoma-api-test-connect-timeout ()
  "Connect fails with timeout when on-open is never fired."
  (autonoma-test--install-mocks)
  (autonoma-test--reset-state)
  (unwind-protect
      (let ((autonoma-connect-timeout 1) result err-msg)
        (setq autonoma-test--mock-fail-open t)
        (autonoma-api-connect
         (lambda (ok err) (setq result ok err-msg err)))
        (sleep-for 1.2)
        (should-not result)
        (should (string-match-p "timeout" err-msg)))
    (autonoma-test--uninstall-mocks)
    (autonoma-test--reset-state)))

(ert-deftest autonoma-api-test-disconnect ()
  "Disconnect clears state."
  (autonoma-test-with-connection
   (autonoma-api-disconnect)
   (should-not (autonoma-api-connected-p))
   (should (eq (autonoma-api-status) 'disconnected))))

;;; Request/response

(ert-deftest autonoma-api-test-request-sends-envelope ()
  "Sent frame has id, method, params."
  (autonoma-test-with-connection
   (autonoma-api-agents-list (lambda (_r _e) nil))
   (should (equal (autonoma-test--last-sent-method) "agents.list"))
   (should (string-prefix-p "req_" (autonoma-test--last-sent-id)))))

(ert-deftest autonoma-api-test-response-resolves-callback ()
  "Response with matching id triggers callback."
  (autonoma-test-with-connection
   (let (got-result)
     (autonoma-api-agents-list (lambda (r _e) (setq got-result r)))
     (let ((id (autonoma-test--last-sent-id)))
       (autonoma-test--deliver-frame
        `(:id ,id :result ((:id "a" :name "a" :description "" :status "available")))))
     (should got-result))))

(ert-deftest autonoma-api-test-response-error-rejects ()
  "Response with error field surfaces to callback."
  (autonoma-test-with-connection
   (let (got-err)
     (autonoma-api-agents-list (lambda (_r e) (setq got-err e)))
     (let ((id (autonoma-test--last-sent-id)))
       (autonoma-test--deliver-frame
        `(:id ,id :error "boom")))
     (should (equal got-err "boom")))))

(ert-deftest autonoma-api-test-request-timeout ()
  "Request times out after autonoma-request-timeout seconds."
  (autonoma-test-with-connection
   (let ((autonoma-request-timeout 1) err)
     (autonoma-api-agents-list (lambda (_r e) (setq err e)))
     (sleep-for 1.2)
     (should (string-match-p "timeout" err)))))

(ert-deftest autonoma-api-test-not-connected-signals ()
  "Sending a request while disconnected signals an error."
  (autonoma-test--reset-state)
  (should-error (autonoma-api-agents-list (lambda (_r _e) nil))
                :type 'autonoma-api-not-connected))

;;; Event dispatch

(ert-deftest autonoma-api-test-event-emits-to-handlers ()
  "Unsolicited typed messages reach registered handlers."
  (autonoma-test-with-connection
   (let (received)
     (autonoma-api-on "phase.update" (lambda (d) (setq received d)))
     (autonoma-test--deliver-frame
      '(:type "phase.update" :data (:phase "research" :progress 50)))
     (should received)
     (should (equal (plist-get received :phase) "research")))))

(ert-deftest autonoma-api-test-event-off ()
  "autonoma-api-off removes a handler."
  (autonoma-test-with-connection
   (let* ((count 0)
          (h (lambda (_d) (cl-incf count))))
     (autonoma-api-on "x" h)
     (autonoma-test--deliver-frame '(:type "x" :data (:a 1)))
     (autonoma-api-off "x" h)
     (autonoma-test--deliver-frame '(:type "x" :data (:a 2)))
     (should (= count 1)))))

(ert-deftest autonoma-api-test-invalid-json-ignored ()
  "Malformed JSON does not crash the client."
  (autonoma-test-with-connection
   (let ((frame (make-websocket-frame :opcode 'text :payload "not json{")))
     (funcall autonoma-test--mock-on-message
              autonoma-test--mock-ws frame))
   (should (autonoma-api-connected-p))))

;;; Input validation

(ert-deftest autonoma-api-test-reject-empty ()
  "Empty strings rejected."
  (autonoma-test-with-connection
   (should-error (autonoma-api-agents-invoke "" "task" nil #'ignore)
                 :type 'autonoma-api-invalid-input)
   (should-error (autonoma-api-agents-invoke "agent" "" nil #'ignore)
                 :type 'autonoma-api-invalid-input)
   (should-error (autonoma-api-agents-invoke "agent" "   " nil #'ignore)
                 :type 'autonoma-api-invalid-input)))

(ert-deftest autonoma-api-test-reject-too-long ()
  "Inputs over max length are rejected."
  (autonoma-test-with-connection
   (let ((autonoma-max-input-length 10))
     (should-error (autonoma-api-agents-invoke
                    "agent" (make-string 20 ?x) nil #'ignore)
                   :type 'autonoma-api-invalid-input))))

(ert-deftest autonoma-api-test-trim-input ()
  "Input is trimmed before sending."
  (autonoma-test-with-connection
   (autonoma-api-agents-invoke "  agent  " "  task  " nil #'ignore)
   (let ((params (autonoma-test--last-sent-params)))
     (should (equal (plist-get params :agentType) "agent"))
     (should (equal (plist-get params :task) "task")))))

;;; All 13 methods — just verify each sends the right `method' string

(ert-deftest autonoma-api-test-all-methods-send-correct-names ()
  "Each API method sends the correct protocol method name."
  (autonoma-test-with-connection
   (cl-flet ((m () (autonoma-test--last-sent-method)))
     (autonoma-api-agents-list #'ignore)
     (should (equal (m) "agents.list"))

     (autonoma-api-agents-invoke "a" "t" nil #'ignore)
     (should (equal (m) "agents.invoke"))

     (autonoma-api-execution-status "exec1" #'ignore)
     (should (equal (m) "execution.status"))

     (autonoma-api-background-list #'ignore)
     (should (equal (m) "background.list"))

     (autonoma-api-background-launch "t" "a" #'ignore)
     (should (equal (m) "background.launch"))

     (autonoma-api-background-cancel "tid" #'ignore)
     (should (equal (m) "background.cancel"))

     (autonoma-api-background-output "tid" #'ignore)
     (should (equal (m) "background.output"))

     (autonoma-api-artifacts-preview nil #'ignore)
     (should (equal (m) "artifacts.preview"))

     (autonoma-api-artifacts-apply nil #'ignore)
     (should (equal (m) "artifacts.apply"))

     (autonoma-api-code-explain "c" "l" "p" #'ignore)
     (should (equal (m) "code.explain"))

     (autonoma-api-code-refactor "c" "l" "p" nil #'ignore)
     (should (equal (m) "code.refactor"))

     (autonoma-api-code-refactor "c" "l" "p" "clean it" #'ignore)
     (should (equal (m) "code.refactor"))
     (should (equal (plist-get (autonoma-test--last-sent-params) :instructions)
                    "clean it"))

     (autonoma-api-code-generate-tests "c" "l" "p" #'ignore)
     (should (equal (m) "code.generateTests"))

     (autonoma-api-code-review "c" "l" "p" "security" #'ignore)
     (should (equal (m) "code.review")))))

;;; Reconnect

(ert-deftest autonoma-api-test-reconnect-stops-at-max ()
  "Reconnect stops after max attempts."
  (autonoma-test--install-mocks)
  (autonoma-test--reset-state)
  (unwind-protect
      (let ((autonoma-max-reconnect-attempts 2))
        (setq autonoma-api--reconnect-attempts 2)
        (autonoma-api-reconnect-with-backoff)
        (should-not autonoma-api--reconnect-timer))
    (autonoma-test--uninstall-mocks)
    (autonoma-test--reset-state)))

(ert-deftest autonoma-api-test-close-fails-pending ()
  "When connection closes, pending requests are rejected."
  (autonoma-test-with-connection
   (let (err)
     (autonoma-api-agents-list (lambda (_r e) (setq err e)))
     (funcall autonoma-test--mock-on-close autonoma-test--mock-ws)
     (should err))))

(provide 'autonoma-api-test)

;;; autonoma-api-test.el ends here
