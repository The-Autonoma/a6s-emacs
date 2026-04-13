;;; a6s-compat.el --- Backward compatibility aliases for A6s -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Autonoma AI

;; This file is part of a6s.el

;;; Commentary:

;; Provides `defalias' entries so that users who have `autonoma-*'
;; commands in their init.el continue to work after the rename to `a6s-*'.

;;; Code:

(defalias 'autonoma-setup 'a6s-setup)
(defalias 'autonoma-mode 'a6s-mode)
(defalias 'autonoma-transient 'a6s-transient)
(defalias 'autonoma-invoke-agent 'a6s-invoke-agent)
(defalias 'autonoma-explain 'a6s-explain-region)
(defalias 'autonoma-refactor 'a6s-refactor-region)

(provide 'a6s-compat)

;;; a6s-compat.el ends here
