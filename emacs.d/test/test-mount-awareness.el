;; -*- lexical-binding: t; -*-

;;; Tests for iar-mount-awareness.el
;; Tests mount parsing from IAR_EXTRA_MOUNTS env var and
;; prompt string generation.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-mount-awareness)

;;; --- Mount parsing tests ---

(ert-deftest test-mount-parse-nil-returns-nil ()
  "parse-extra-mounts should return nil for nil input."
  (should (null (iar--parse-extra-mounts nil))))

(ert-deftest test-mount-parse-empty-returns-nil ()
  "parse-extra-mounts should return nil for empty string."
  (should (null (iar--parse-extra-mounts ""))))

(ert-deftest test-mount-parse-single-mount ()
  "parse-extra-mounts should parse a single path:mode pair."
  (let ((result (iar--parse-extra-mounts "/data:ro")))
    (should (equal 1 (length result)))
    (should (equal "/data" (car (car result))))
    (should (equal "ro" (cdr (car result))))))

(ert-deftest test-mount-parse-multiple-mounts ()
  "parse-extra-mounts should parse multiple comma-separated pairs."
  (let ((result (iar--parse-extra-mounts "/data:ro,/tmp:rw")))
    (should (equal 2 (length result)))
    (should (equal "/data" (car (nth 0 result))))
    (should (equal "ro" (cdr (nth 0 result))))
    (should (equal "/tmp" (car (nth 1 result))))
    (should (equal "rw" (cdr (nth 1 result))))))

(ert-deftest test-mount-parse-default-mode-is-rw ()
  "parse-extra-mounts should default to rw when mode is omitted."
  (let ((result (iar--parse-extra-mounts "/data")))
    (should (equal 1 (length result)))
    (should (equal "/data" (car (car result))))
    (should (equal "rw" (cdr (car result))))))

(ert-deftest test-mount-parse-skips-empty-entries ()
  "parse-extra-mounts should skip empty entries from trailing commas."
  (let ((result (iar--parse-extra-mounts "/data:ro,")))
    (should (equal 1 (length result)))))

(ert-deftest test-mount-parse-skips-empty-paths ()
  "parse-extra-mounts should skip entries with empty paths."
  (let ((result (iar--parse-extra-mounts "/data:rw")))
    (should (equal 1 (length result)))
    (should (equal "/data" (car (car result))))))

(ert-deftest test-mount-parse-non-string-returns-nil ()
  "parse-extra-mounts should return nil for non-string input."
  (should (null (iar--parse-extra-mounts 42)))
  (should (null (iar--parse-extra-mounts 'foo))))

;;; --- Prompt string tests ---

(ert-deftest test-mount-prompt-string-no-mounts ()
  "iar--extra-mounts-prompt-string should return empty string when no mounts."
  (cl-letf (((symbol-value 'iar--extra-mounts) nil))
    (should (string= "" (iar--extra-mounts-prompt-string)))))

(ert-deftest test-mount-prompt-string-with-mounts ()
  "iar--extra-mounts-prompt-string should return non-empty string with mounts."
  (cl-letf (((symbol-value 'iar--extra-mounts)
             '(("/data" . "ro") ("/tmp" . "rw"))))
    (let ((result (iar--extra-mounts-prompt-string)))
      (should (stringp result))
      (should (> (length result) 0))
      (should (string-match-p "/data" result))
      (should (string-match-p "read-only" result))
      (should (string-match-p "/tmp" result))
      (should (string-match-p "read-write" result)))))

(provide 'test-mount-awareness)