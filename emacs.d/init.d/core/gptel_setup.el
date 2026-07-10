;; -*- lexical-binding: t; -*-

(defvar emacboros-gptel-backend)
(defvar emacboros-gptel-default-model)

(use-package gptel
  :ensure t
  :config
  (load-file (expand-file-name "metaconfig/gptel.el" user-emacs-directory))
  (setq-default gptel-backend emacboros-gptel-backend)
  (setq-default gptel-model emacboros-gptel-default-model))
(provide 'gptel_setup)
