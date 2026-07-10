;; -*- lexical-binding: t; -*-

(defvar evil-want-integration)
(defvar evil-want-keybinding)

(declare-function evil-mode "evil" (&optional arg))
(declare-function evil-collection-init "evil-collection" ())

(setq evil-want-integration t)
(setq evil-want-keybinding nil)

(use-package evil
  :ensure t
  :config (evil-mode 1))

(use-package evil-collection
  :after evil
  :ensure t
  :config (evil-collection-init))
(provide 'evil_mode)
