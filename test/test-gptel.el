;; -*- lexical-binding: t; -*-

;;; Tests for gptel_setup.el
;; Tests that the gptel backend is configured correctly.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(ert-deftest test-gptel-backend-defined ()
  "gptel-setup should define a default gptel-backend."
  (should (boundp 'gptel-backend))
  (should gptel-backend))

(ert-deftest test-gptel-model-defined ()
  "gptel-setup should define a default gptel-model."
  (should (boundp 'gptel-model))
  (should gptel-model))

(ert-deftest test-gptel-backend-is-ollama ()
  "gptel-setup should use an Ollama backend."
  (should (string-match-p "[Oo]llama"
                          (format "%s" (type-of gptel-backend)))))

(ert-deftest test-gptel-backend-host-is-3080 ()
  "gptel-setup should point at the 3080 server."
  (let ((host (gptel-backend-host gptel-backend)))
    (should (stringp host))
    (should (string-match-p "192\\.168\\.2\\.69" host))))

(provide 'test-gptel)