;; -*- lexical-binding: t; -*-

;;; Output Sanitizer for External/Untrusted Content
;; Strips control sequences and invisible characters from data before
;; it enters the AI context.
;;
;; This is a defense-in-depth measure. The primary defense is the
;; PROMPT INJECTION RESISTANCE directives in base_context.org, which
;; teach the AI to treat external content as data. This sanitizer
;; reduces the surface area by removing control character vectors
;; (ANSI escapes, zero-width Unicode, bidi controls including Trojan
;; Source attack chars) from raw text.
;;
;; Usage: (iar--sanitize-external-output "raw string from curl/nmap/etc.")
;; Returns a sanitized string with a [SANITIZED EXTERNAL DATA] prefix.

(require 'subr-x)

;; Forward-declared: owned by configs/delimiters.el.
;; Declared here so this module can reference them before configs load.
(defvar iar-sanitized-open nil
  "Prefix wrapper for sanitized external data.")
(defvar iar-sanitized-close nil
  "Suffix wrapper for sanitized external data.")

;;; --- Control character patterns ---

(defconst iar--sanitizer-control-patterns
  '(
    ;; ANSI escape sequences (can manipulate terminal output)
    "\x1b\\[[0-9;]*[a-zA-Z]"
    ;; Other control characters (except newline, tab)
    "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]"
    ;; Unicode zero-width and invisible characters (can hide instructions)
    ;; Includes: ZWSP, ZWNJ, ZWJ, LRM, RLM, WJ, invisible math operators, BOM
    "[\u200b\u200c\u200d\u200e\u200f\u2060\u2061\u2062\u2063\u2064\ufeff]"
    ;; Unicode bidi control characters (can reverse/reorder text display)
    ;; Includes all bidi controls: LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI
    ;; These can be used for Trojan Source attacks to hide instructions.
    "[\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069]"
    )
  "Regex patterns for control sequences and invisible characters to strip.")

;;; --- Sanitization Functions ---

(defun iar--strip-control-chars (text)
  "Remove ANSI escape sequences and control characters from TEXT."
  (let ((result text))
    (dolist (pattern iar--sanitizer-control-patterns result)
      (setq result (replace-regexp-in-string pattern "" result)))))

(defun iar--sanitize-external-output (text)
  "Sanitize TEXT from external/untrusted sources.
1. Strips ANSI escape sequences and control characters.
2. Wraps the result in a [SANITIZED EXTERNAL DATA] envelope.

Returns the sanitized string."
  (if (or (null text) (string-empty-p text))
      ""
    (let ((cleaned (iar--strip-control-chars text)))
      (format "%s\n%s\n%s"
              iar-sanitized-open
              cleaned
              iar-sanitized-close))))

;;; --- Buffer-local flag for execute_code_local ---

(defvar-local iar--sanitize-exec-output nil
  "When non-nil, output from execute_code_local is sanitized
before being returned to the AI. Enable for CTF/external operations.
The flag is captured at call time in execute_code_local.el (not read
in the sentinel) because process sentinels run in an unpredictable
buffer context.")

(provide 'iar-output-sanitizer)