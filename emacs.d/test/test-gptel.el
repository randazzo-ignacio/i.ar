;; -*- lexical-binding: t; -*-

;;; Tests for iar-gptel-setup.el
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
  "gptel-setup should point at a reachable Ollama host.
The host is configured from EMACBOROS_OLLAMA_HOST env var or defaults
to the 3080 server. We verify the host is a non-empty string with a port."
  (let ((host (gptel-backend-host gptel-backend)))
    (should (stringp host))
    (should (> (length host) 0))
    ;; Host should contain a port number (e.g., "192.168.2.69:11434" or "10.66.0.5:11434")
    (should (string-match-p ":[0-9]+\\'" host))))

(provide 'test-gptel)