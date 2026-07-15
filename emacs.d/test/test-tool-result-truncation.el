;; -*- lexical-binding: t; -*-

;;; Tests for iar-tool-result-truncation.el

(require 'ert)

;; Load the module directly
(load-file (expand-file-name "init.d/core/iar-tool-result-truncation.el"
                              user-emacs-directory))

(ert-deftest iar-truncate-under-limit ()
  "Result under the limit is returned unchanged."
  (let ((iar-tool-result-max-chars 100))
    (should (string= (iar--truncate-tool-result "short")
                     "short"))))

(ert-deftest iar-truncate-over-limit ()
  "Result over the limit is middle-truncated."
  (let ((iar-tool-result-max-chars 10))
    (let ((result (iar--truncate-tool-result "0123456789ABCDEF")))
      ;; First 5 chars preserved
      (should (string-prefix-p "01234" result))
      ;; Last 5 chars preserved (chars 11-15 of "0123456789ABCDEF")
      (should (string-suffix-p "BCDEF" result))
      ;; Contains truncation notice
      (should (string-match-p "truncated" result))
      ;; Contains total size
      (should (string-match-p "16 total chars" result)))))

(ert-deftest iar-truncate-nil-disabled ()
  "When max-chars is nil, truncation is disabled."
  (let ((iar-tool-result-max-chars nil))
    (let ((long-string (make-string 100000 ?x)))
      (should (string= (iar--truncate-tool-result long-string)
                       long-string)))))

(ert-deftest iar-truncate-nil-result ()
  "Nil result is returned unchanged."
  (let ((iar-tool-result-max-chars 10))
    (should (null (iar--truncate-tool-result nil)))))

(ert-deftest iar-truncate-non-string-result ()
  "Non-string result is returned unchanged."
  (let ((iar-tool-result-max-chars 10))
    (should (eq (iar--truncate-tool-result 42) 42))
    (should (eq (iar--truncate-tool-result 'symbol) 'symbol))))

(ert-deftest iar-truncate-exactly-at-limit ()
  "Result exactly at the limit is not truncated."
  (let ((iar-tool-result-max-chars 10))
    (should (string= (iar--truncate-tool-result "0123456789")
                     "0123456789"))))

(ert-deftest iar-truncate-preserves-head-and-tail ()
  "Truncation preserves the beginning and end of the result."
  (let ((iar-tool-result-max-chars 20)
        (input "HEAD-12345-MIDDLE-STUFF-HERE-67890-TAIL"))
    (let ((result (iar--truncate-tool-result input)))
      ;; First 10 chars preserved
      (should (string-prefix-p "HEAD-12345" result))
      ;; Last 10 chars preserved
      (should (string-suffix-p "67890-TAIL" result))
      ;; Notice in the middle
      (should (string-match-p "truncated" result)))))

(ert-deftest iar-truncate-advice-installed ()
  "Truncation advice should be installed on gptel--process-tool-call."
  (when (fboundp 'gptel--process-tool-call)
    (should (advice-member-p #'iar--truncate-tool-result-advice
                             'gptel--process-tool-call))))

(ert-deftest iar-truncate-notice-format ()
  "Truncation notice contains useful information."
  (let ((iar-tool-result-max-chars 10))
    (let ((result (iar--truncate-tool-result (make-string 100 ?x))))
      ;; Should mention total chars
      (should (string-match-p "100 total chars" result))
      ;; Should mention how much was kept
      (should (string-match-p "kept first 5 and last 5" result)))))

(ert-deftest iar-truncate-negative-max-chars ()
  "Negative max-chars is treated as disabled."
  (let ((iar-tool-result-max-chars -1))
    (should (string= (iar--truncate-tool-result "anything")
                     "anything"))))

(ert-deftest iar-truncate-zero-length-result ()
  "Empty string is returned unchanged."
  (let ((iar-tool-result-max-chars 10))
    (should (string= (iar--truncate-tool-result "") ""))))