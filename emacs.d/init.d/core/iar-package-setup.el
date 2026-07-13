;; -*- lexical-binding: t; -*-

;;; 1. PACKAGE MANAGER SETUP
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))
(provide 'iar-package-setup)
