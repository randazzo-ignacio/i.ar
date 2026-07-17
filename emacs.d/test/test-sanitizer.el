;; -*- lexical-binding: t; -*-

;;; Tests for iar-output-sanitizer.el
;; Tests control character stripping and the full sanitize pipeline.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-output-sanitizer)

;;; --- Control character stripping tests ---

(ert-deftest test-sanitizer-strip-ansi-escape ()
  "iar--strip-control-chars should remove ANSI escape sequences."
  (let ((result (iar--strip-control-chars "\x1b[31mRed Text\x1b[0m")))
    (should (string= result "Red Text"))))

(ert-deftest test-sanitizer-strip-multiple-ansi ()
  "iar--strip-control-chars should remove multiple ANSI sequences."
  (let ((result (iar--strip-control-chars
                 "\x1b[1;32mBold Green\x1b[0m and \x1b[33mYellow\x1b[0m")))
    (should (string= result "Bold Green and Yellow"))))

(ert-deftest test-sanitizer-strip-control-chars-preserves-newlines ()
  "iar--strip-control-chars should preserve newlines and tabs."
  (let ((result (iar--strip-control-chars "line1\nline2\ttabbed")))
    (should (string= result "line1\nline2\ttabbed"))))

(ert-deftest test-sanitizer-strip-control-chars-removes-bell ()
  "iar--strip-control-chars should remove bell and other control chars."
  (let ((result (iar--strip-control-chars "hello\x07world")))
    (should (string= result "helloworld"))))

(ert-deftest test-sanitizer-strip-control-chars-empty-string ()
  "iar--strip-control-chars should handle empty string."
  (should (string= (iar--strip-control-chars "") "")))

(ert-deftest test-sanitizer-strip-control-chars-no-changes ()
  "iar--strip-control-chars should not alter clean text."
  (let ((result (iar--strip-control-chars "Clean text with no control chars.")))
    (should (string= result "Clean text with no control chars."))))

(ert-deftest test-sanitizer-strip-zero-width-space ()
  "iar--strip-control-chars should remove zero-width space (U+200B)."
  (let ((result (iar--strip-control-chars (concat "hello" "\u200b" "world"))))
    (should (string= result "helloworld"))))

(ert-deftest test-sanitizer-strip-zero-width-joiner ()
  "iar--strip-control-chars should remove zero-width joiner (U+200D)."
  (let ((result (iar--strip-control-chars (concat "hello" "\u200d" "world"))))
    (should (string= result "helloworld"))))

(ert-deftest test-sanitizer-strip-bom ()
  "iar--strip-control-chars should remove BOM (U+FEFF)."
  (let ((result (iar--strip-control-chars (concat "\ufeff" "hello"))))
    (should (string= result "hello"))))

(ert-deftest test-sanitizer-strip-rtl-override ()
  "iar--strip-control-chars should remove RTL override (U+202E)."
  (let ((result (iar--strip-control-chars (concat "hello" "\u202e" "world"))))
    (should (string= result "helloworld"))))

(ert-deftest test-sanitizer-strip-ltr-override ()
  "iar--strip-control-chars should remove LTR override (U+202D)."
  (let ((result (iar--strip-control-chars (concat "hello" "\u202d" "world"))))
    (should (string= result "helloworld"))))

(ert-deftest test-sanitizer-strip-bidi-embedding ()
  "iar--strip-control-chars should remove bidi embedding (U+202A, U+202B)."
  (let ((result (iar--strip-control-chars
                 (concat "a" "\u202a" "b" "\u202b" "c"))))
    (should (string= result "abc"))))

(ert-deftest test-sanitizer-strip-bidi-isolate ()
  "iar--strip-control-chars should remove bidi isolate (U+2066, U+2067)."
  (let ((result (iar--strip-control-chars
                 (concat "a" "\u2066" "b" "\u2067" "c"))))
    (should (string= result "abc"))))

(ert-deftest test-sanitizer-strip-lrm-rlm ()
  "iar--strip-control-chars should remove LRM (U+200E) and RLM (U+200F)."
  (let ((result (iar--strip-control-chars
                 (concat "a" "\u200e" "b" "\u200f" "c"))))
    (should (string= result "abc"))))

(ert-deftest test-sanitizer-strip-word-joiner ()
  "iar--strip-control-chars should remove word joiner (U+2060)."
  (let ((result (iar--strip-control-chars (concat "hello" "\u2060" "world"))))
    (should (string= result "helloworld"))))

(ert-deftest test-sanitizer-strip-mixed-zero-width ()
  "iar--strip-control-chars should remove multiple different zero-width chars."
  (let ((result (iar--strip-control-chars
                 (concat "a" "\u200b" "b" "\u200c" "c" "\u200d" "d" "\ufeff" "e"))))
    (should (string= result "abcde"))))

(ert-deftest test-sanitizer-strip-mixed-zero-width-and-bidi ()
  "iar--strip-control-chars should strip both zero-width and bidi chars together."
  (let ((result (iar--strip-control-chars
                 (concat "a" "\u200b" "b" "\u202e" "c" "\u200d" "d" "\u202d" "e"))))
    (should (string= result "abcde"))))

(ert-deftest test-sanitizer-preserves-normal-unicode ()
  "iar--strip-control-chars should not strip legitimate Unicode text."
  (let ((result (iar--strip-control-chars "Japanese \u65e5\u672c\u8a9e cafe \u00e9")))
    (should (string= result "Japanese \u65e5\u672c\u8a9e cafe \u00e9"))))

;;; --- Full sanitize pipeline tests ---

(ert-deftest test-sanitize-external-output-wraps-in-envelope ()
  "iar--sanitize-external-output should wrap result in SANITIZED envelope."
  (let ((result (iar--sanitize-external-output "some data")))
    (should (string-match-p "SANITIZED EXTERNAL DATA" result))
    (should (string-match-p "END SANITIZED" result))))

(ert-deftest test-sanitize-external-output-strips-ansi ()
  "iar--sanitize-external-output should strip ANSI sequences."
  (let ((result (iar--sanitize-external-output "\x1b[31mred text\x1b[0m")))
    (should-not (string-match-p "\x1b" result))
    (should (string-match-p "red text" result))))

(ert-deftest test-sanitize-external-output-empty-string ()
  "iar--sanitize-external-output should return empty string for empty input."
  (should (string= (iar--sanitize-external-output "") "")))

(ert-deftest test-sanitize-external-output-nil ()
  "iar--sanitize-external-output should return empty string for nil input."
  (should (string= (iar--sanitize-external-output nil) "")))

(ert-deftest test-sanitize-external-output-strips-zero-width ()
  "iar--sanitize-external-output should strip zero-width and bidi chars."
  (let ((result (iar--sanitize-external-output
                 (concat "hello" "\u200b" "\u202e" "world"))))
    (should-not (string-match-p "\u200b" result))
    (should-not (string-match-p "\u202e" result))
    (should (string-match-p "helloworld" result))))

(ert-deftest test-sanitize-external-output-combined-attack ()
  "iar--sanitize-external-output should handle combined attack vectors."
  (let ((result (iar--sanitize-external-output
                 (concat "\x1b[32m" "normal data" "\u200b" "\u202e"))))
    ;; ANSI stripped
    (should-not (string-match-p "\x1b" result))
    ;; Zero-width stripped
    (should-not (string-match-p "\u200b" result))
    ;; Bidi stripped
    (should-not (string-match-p "\u202e" result))
    ;; Normal data preserved
    (should (string-match-p "normal data" result))
    ;; Envelope present
    (should (string-match-p "SANITIZED EXTERNAL DATA" result))))

(provide 'test-sanitizer)