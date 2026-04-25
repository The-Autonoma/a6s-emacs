;;; a6s.el --- A6s: intelligent multi-agent orchestration via local daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma

;; Author: Autonoma <support@theautonoma.io>
;; Maintainer: Autonoma <support@theautonoma.io>
;; Version: 2.0.0
;; Package-Requires: ((emacs "27.1") (websocket "1.14") (transient "0.4.0"))
;; Keywords: tools, convenience
;; URL: https://github.com/The-Autonoma/a6s-emacs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A6s is an Emacs extension that connects to the local A6s CLI daemon
;; (`a6s code --daemon') via WebSocket on `ws://localhost:9876/ws'.
;; It provides intelligent multi-agent orchestration: RIGOR agent invocation,
;; code explanation, refactoring, review, test generation, and background
;; task management directly inside Emacs.
;;
;; The daemon is the only component that talks to the remote orchestrator;
;; this extension never holds API credentials or calls orchestrator endpoints
;; directly.
;;
;; Quick start:
;;
;;   (require 'a6s)
;;   (a6s-setup)
;;
;; Then open any buffer and run M-x a6s-mode, or bind a global key to
;; `a6s-transient' (default: C-c C-a when a6s-mode is active).
;;
;; See CLAUDE.md for architecture, protocol conformance, and installation
;; instructions.

;;; Code:

(require 'cl-lib)

;;; Customization

(defgroup a6s nil
  "A6s: intelligent multi-agent orchestration via local daemon."
  :group 'tools
  :prefix "a6s-")

(defcustom a6s-daemon-port 9876
  "Port on which the A6s CLI daemon is listening."
  :type 'integer
  :group 'a6s)

(defcustom a6s-daemon-host "localhost"
  "Host on which the A6s CLI daemon is listening."
  :type 'string
  :group 'a6s)

(defcustom a6s-auto-connect t
  "Whether to automatically connect when `a6s-mode' is enabled."
  :type 'boolean
  :group 'a6s)

(defcustom a6s-telemetry-enabled t
  "Whether anonymous telemetry is enabled.
Set to nil to opt out.  Telemetry helps improve the A6s experience
and performance.  No code content or filenames are transmitted."
  :type 'boolean
  :group 'a6s)

(defcustom a6s-request-timeout 30
  "Per-request timeout in seconds."
  :type 'integer
  :group 'a6s)

(defcustom a6s-connect-timeout 5
  "WebSocket connect timeout in seconds."
  :type 'integer
  :group 'a6s)

(defcustom a6s-max-input-length 10000
  "Maximum length of user input sent to the daemon."
  :type 'integer
  :group 'a6s)

(defcustom a6s-max-reconnect-attempts 5
  "Maximum number of reconnect attempts before giving up."
  :type 'integer
  :group 'a6s)

;;;###autoload
(defun a6s-setup ()
  "Initialize the A6s extension.
Telemetry is enabled by default.  To opt out, set
`a6s-telemetry-enabled' to nil in your init file."
  (interactive)
  (message "A6s ready. Use M-x a6s-connect or enable a6s-mode."))

;; Autoloads for all interactive entry points (real definitions live in
;; sibling files, loaded on demand).

;;;###autoload
(autoload 'a6s-mode "a6s-ui" "A6s minor mode." t)
;;;###autoload
(autoload 'a6s-connect "a6s-commands" "Connect to A6s daemon." t)
;;;###autoload
(autoload 'a6s-disconnect "a6s-commands" "Disconnect from A6s daemon." t)
;;;###autoload
(autoload 'a6s-invoke-agent "a6s-commands" "Invoke an A6s agent." t)
;;;###autoload
(autoload 'a6s-explain-region "a6s-commands" "Explain region with A6s." t)
;;;###autoload
(autoload 'a6s-refactor-region "a6s-commands" "Refactor region with A6s." t)
;;;###autoload
(autoload 'a6s-review-region "a6s-commands" "Review region with A6s." t)
;;;###autoload
(autoload 'a6s-generate-tests-region "a6s-commands" "Generate tests for region." t)
;;;###autoload
(autoload 'a6s-preview-changes "a6s-commands" "Preview pending artifacts." t)
;;;###autoload
(autoload 'a6s-apply-artifacts "a6s-commands" "Apply pending artifacts." t)
;;;###autoload
(autoload 'a6s-cancel-task "a6s-commands" "Cancel a background task." t)
;;;###autoload
(autoload 'a6s-list-tasks "a6s-commands" "List background tasks." t)
;;;###autoload
(autoload 'a6s-status "a6s-commands" "Show A6s connection status." t)
;;;###autoload
(autoload 'a6s-transient "a6s-ui" "Open A6s transient menu." t)

(require 'a6s-compat)

(provide 'a6s)

;;; a6s.el ends here
