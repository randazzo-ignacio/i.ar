;; -*- lexical-binding: t; -*-

(defvar emacboros-gptel-backend)
(defvar emacboros-gptel-default-model)
(defvar my-gptel-fork-path)

;; If a gptel fork path is configured, prepend it to load-path so the
;; fork takes precedence over the ELPA-installed package.  This is used
;; when a fix has been merged upstream but hasn't shipped in an ELPA
;; release yet.  When nil, the ELPA package is used as normal.
(when (and my-gptel-fork-path
           (stringp my-gptel-fork-path)
           (file-directory-p my-gptel-fork-path))
  (message "[gptel] Using fork from %s (overriding ELPA package)" my-gptel-fork-path)
  (add-to-list 'load-path my-gptel-fork-path))

(use-package gptel
  :ensure t
  :config
  (load-file (expand-file-name "metaconfig/gptel.el" user-emacs-directory))
  (setq-default gptel-backend emacboros-gptel-backend)
  (setq-default gptel-model emacboros-gptel-default-model))
(provide 'gptel_setup)
