;; -*- lexical-binding: t; -*-

(defvar iar-gptel-backend)
(defvar iar-gptel-default-model)
(defvar iar-fork-path)

;; If a gptel fork path is configured, prepend it to load-path so the
;; fork takes precedence over the ELPA-installed package.  This is used
;; when a fix has been merged upstream but hasn't shipped in an ELPA
;; release yet.  When nil, the ELPA package is used as normal.
(when (and iar-fork-path
           (stringp iar-fork-path)
           (file-directory-p iar-fork-path))
  (message "[gptel] Using fork from %s (overriding ELPA package)" iar-fork-path)
  (add-to-list 'load-path iar-fork-path))

(use-package gptel
  :ensure t
  :config
  (load-file (expand-file-name "metaconfig/gptel.el" user-emacs-directory))
  (setq-default gptel-backend iar-gptel-backend)
  (setq-default gptel-model iar-gptel-default-model))
(provide 'iar-gptel-setup)
