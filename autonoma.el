;;; autonoma.el --- Autonoma Code extension: RIGOR agents via local daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; Author: Autonoma Team <support@autonoma.ai>
;; Version: 1.0.0
;; Package-Requires: ((emacs "27.1") (websocket "1.14") (transient "0.4.0"))
;; Keywords: tools, convenience
;; URL: https://github.com/The-Autonoma/autonoma-emacs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Autonoma Code is an Emacs extension that connects to the local Autonoma
;; CLI daemon (`a6s code --daemon') via WebSocket on `ws://localhost:9876/ws'.
;; It provides RIGOR agent invocation, code explanation, refactoring, review,
;; test generation, and background task management directly inside Emacs.
;;
;; The daemon is the only component that talks to the remote orchestrator;
;; this extension never holds API credentials or calls orchestrator endpoints
;; directly.
;;
;; Quick start:
;;
;;   (require 'autonoma)
;;   (autonoma-setup)
;;
;; Then open any buffer and run M-x autonoma-mode, or bind a global key to
;; `autonoma-transient' (default: C-c C-a when autonoma-mode is active).
;;
;; See CLAUDE.md for architecture, protocol conformance, and installation
;; instructions.

;;; Code:

(require 'cl-lib)

;;; Customization

(defgroup autonoma nil
  "Autonoma Code: RIGOR agents via local daemon."
  :group 'tools
  :prefix "autonoma-")

(defcustom autonoma-daemon-port 9876
  "Port on which the Autonoma CLI daemon is listening."
  :type 'integer
  :group 'autonoma)

(defcustom autonoma-daemon-host "localhost"
  "Host on which the Autonoma CLI daemon is listening."
  :type 'string
  :group 'autonoma)

(defcustom autonoma-auto-connect t
  "Whether to automatically connect when `autonoma-mode' is enabled."
  :type 'boolean
  :group 'autonoma)

(defcustom autonoma-telemetry-enabled nil
  "Whether anonymous telemetry is enabled.
First use prompts the user to enable or disable telemetry."
  :type 'boolean
  :group 'autonoma)

(defcustom autonoma-request-timeout 30
  "Per-request timeout in seconds."
  :type 'integer
  :group 'autonoma)

(defcustom autonoma-connect-timeout 5
  "WebSocket connect timeout in seconds."
  :type 'integer
  :group 'autonoma)

(defcustom autonoma-max-input-length 10000
  "Maximum length of user input sent to the daemon."
  :type 'integer
  :group 'autonoma)

(defcustom autonoma-max-reconnect-attempts 5
  "Maximum number of reconnect attempts before giving up."
  :type 'integer
  :group 'autonoma)

(defvar autonoma--telemetry-prompted nil
  "Non-nil after the telemetry prompt has been shown at least once.")

;;;###autoload
(defun autonoma-setup ()
  "Initialize the Autonoma Code extension.
Sets up autoloads and prompts for telemetry preference on first run."
  (interactive)
  (unless autonoma--telemetry-prompted
    (setq autonoma--telemetry-prompted t)
    (when (and (not autonoma-telemetry-enabled)
               (called-interactively-p 'any))
      (when (y-or-n-p "Enable anonymous Autonoma telemetry? ")
        (setq autonoma-telemetry-enabled t)
        (customize-save-variable 'autonoma-telemetry-enabled t))))
  (message "Autonoma Code ready. Use M-x autonoma-connect or enable autonoma-mode."))

;; Autoloads for all interactive entry points (real definitions live in
;; sibling files, loaded on demand).

;;;###autoload
(autoload 'autonoma-mode "autonoma-ui" "Autonoma minor mode." t)
;;;###autoload
(autoload 'autonoma-connect "autonoma-commands" "Connect to Autonoma daemon." t)
;;;###autoload
(autoload 'autonoma-disconnect "autonoma-commands" "Disconnect from Autonoma daemon." t)
;;;###autoload
(autoload 'autonoma-invoke-agent "autonoma-commands" "Invoke an Autonoma agent." t)
;;;###autoload
(autoload 'autonoma-explain-region "autonoma-commands" "Explain region with Autonoma." t)
;;;###autoload
(autoload 'autonoma-refactor-region "autonoma-commands" "Refactor region with Autonoma." t)
;;;###autoload
(autoload 'autonoma-review-region "autonoma-commands" "Review region with Autonoma." t)
;;;###autoload
(autoload 'autonoma-generate-tests-region "autonoma-commands" "Generate tests for region." t)
;;;###autoload
(autoload 'autonoma-preview-changes "autonoma-commands" "Preview pending artifacts." t)
;;;###autoload
(autoload 'autonoma-apply-artifacts "autonoma-commands" "Apply pending artifacts." t)
;;;###autoload
(autoload 'autonoma-cancel-task "autonoma-commands" "Cancel a background task." t)
;;;###autoload
(autoload 'autonoma-list-tasks "autonoma-commands" "List background tasks." t)
;;;###autoload
(autoload 'autonoma-status "autonoma-commands" "Show Autonoma connection status." t)
;;;###autoload
(autoload 'autonoma-transient "autonoma-ui" "Open Autonoma transient menu." t)

(provide 'autonoma)

;;; autonoma.el ends here
