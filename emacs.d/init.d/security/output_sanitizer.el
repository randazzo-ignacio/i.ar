;; -*- lexical-binding: t; -*-

;;; Output Sanitizer for External/Untrusted Content
;; Strips or neutralizes prompt injection patterns, control sequences,
;; and instruction-like text from data before it enters the AI context.
;;
;; This is a defense-in-depth measure. The primary defense is the
;; PROMPT INJECTION RESISTANCE directives in base_context.org, which
;; teach the AI to treat external content as data. This sanitizer
;; reduces the surface area by removing obvious injection vectors
;; from the raw text.
;;
;; Usage: (my-gptel--sanitize-external-output "raw string from curl/nmap/etc.")
;; Returns a sanitized string with a [SANITIZED EXTERNAL DATA] prefix.

(require 'subr-x)

;; Declared in metaconfig/parameters.el (loaded before init.d modules).
(defvar my-gptel-sanitized-open nil
  "Prefix wrapper for sanitized external data.")
(defvar my-gptel-sanitized-close nil
  "Suffix wrapper for sanitized external data.")
(defvar my-gptel-injection-suspect-prefix nil
  "Prefix added to lines that resemble prompt injection attempts.")
(defvar my-gptel-removed-tag nil
  "Replacement text for neutralized fake system message wrapper tags.")

;;; --- Configuration ---

(defconst my-gptel--sanitizer-control-patterns
  '(
    ;; ANSI escape sequences (can manipulate terminal output)
    "\x1b\\[[0-9;]*[a-zA-Z]"
    ;; Other control characters (except newline, tab)
    "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]"
    ;; Unicode zero-width and invisible characters (can hide instructions)
    ;; Character class matches ANY ONE of these, not all in sequence.
    ;; Without the bracket class, the pattern matched the literal
    ;; multi-character sequence, which never appears in real text --
    ;; so zero-width chars were never actually stripped.
    ;; Includes: ZWSP, ZWNJ, ZWJ, LRM, RLM, WJ, invisible math operators, BOM
    "[\u200b\u200c\u200d\u200e\u200f\u2060\u2061\u2062\u2063\u2064\ufeff]"
    ;; Unicode bidi control characters (can reverse/reorder text display)
    ;; Includes all bidi controls: LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI
    ;; These can be used for Trojan Source attacks to hide instructions.
    "[\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069]"
    )
  "Regex patterns for control sequences and invisible characters to strip.")

(defconst my-gptel--sanitizer-injection-markers
  '(
    ;; Lines that look like system prompt directives
    "^\\* SYSTEM PROMPT"
    "^\\* OPERATIONAL DIRECTIVE"
    "^\\* CRITICAL"
    "^\\* EXECUTION PROTOCOL"
    "^\\* TOOL CALLING PROTOCOL"
    "^\\* PROMPT INJECTION RESISTANCE"
    ;; Fake tool call blocks
    "^```tool\\'"
    "^```json\\'"
    ;; Role-play injection patterns
    "^You are "
    "^Ignore \\(all \\)?\\(previous \\|prior \\)?instructions"
    "^Ignore \\(the \\)?above"
    "^Disregard \\(all \\)?\\(previous \\|prior \\)?instructions"
    "^Forget \\(everything \\|all \\)?\\(previous \\|prior \\)?"
    "^As an? \\(AI\\|assistant\\|language model\\)"
    "^I am \\(now\\|actually\\) "
    ;; Command injection patterns
    "^Execute the following"
    "^Run this command"
    "^Please run:"
    "^System: "
    "^Admin: "
    "^Operator: "
    "^Override: "
    ;; Persistence injection
    "^Remember \\(this\\|the following\\)"
    "^Save \\(this\\|the following\\) \\(to\\|in\\|for\\)"
    "^Write \\(this\\|the following\\) to"
    "^Store \\(this\\|the following\\)"
    )
  "Regex patterns for lines that resemble prompt injection attempts.
These lines are NOT removed (that would destroy evidence) but are
prefixed with [INJECTION SUSPECT] to warn the AI.")

(defconst my-gptel--sanitizer-wrapper-patterns
  '(
    ;; Fake system message wrappers — match <system>, </system>, <?system?>, etc.
    "</?\\??system\\??>"
    "</?\\??instructions\\??>"
    "</?\\??prompt\\??>"
    "</?\\??directive\\??>"
    ;; Bracketed fake headers
    "\\[SYSTEM\\]"
    "\\[ADMIN\\]"
    "\\[OVERRIDE\\]"
    "\\[INSTRUCTIONS\\]"
    )
  "Regex patterns for XML-like or bracketed wrapper tags used to
fake system messages. These are neutralized by replacing with
[REMOVED-TAG].")

;;; --- Sanitization Functions ---

(defun my-gptel--strip-control-chars (text)
  "Remove ANSI escape sequences and control characters from TEXT."
  (let ((result text))
    (dolist (pattern my-gptel--sanitizer-control-patterns result)
      (setq result (replace-regexp-in-string pattern "" result)))))

(defun my-gptel--neutralize-wrapper-tags (text)
  "Replace fake system message wrapper tags in TEXT with [REMOVED-TAG]."
  (let ((result text))
    (dolist (pattern my-gptel--sanitizer-wrapper-patterns result)
      (setq result (replace-regexp-in-string pattern my-gptel-removed-tag result)))))

(defun my-gptel--flag-injection-lines (text)
  "Prefix lines that resemble prompt injection with [INJECTION SUSPECT].
Does not remove the lines — they may contain useful data. But the
prefix warns the AI to treat them as data, not instructions."
  (let ((lines (split-string text "\n"))
        (result nil))
    (dolist (line lines)
      (let ((flagged line)
            (matched nil))
        (dolist (pattern my-gptel--sanitizer-injection-markers)
          (unless matched
            (when (string-match-p pattern line)
              (setq flagged (concat my-gptel-injection-suspect-prefix " " line))
              (setq matched t))))
        (push flagged result)))
    (mapconcat #'identity (nreverse result) "\n")))

(defun my-gptel--sanitize-external-output (text)
  "Sanitize TEXT from external/untrusted sources.
1. Strips ANSI escape sequences and control characters.
2. Neutralizes fake system message wrapper tags.
3. Flags lines that resemble prompt injection attempts.
4. Wraps the result in a [SANITIZED EXTERNAL DATA] envelope.

Returns the sanitized string."
  (if (or (null text) (string-empty-p text))
      ""
    (let* ((cleaned (my-gptel--strip-control-chars text))
           (neutralized (my-gptel--neutralize-wrapper-tags cleaned))
           (flagged (my-gptel--flag-injection-lines neutralized)))
      (format "%s\n%s\n%s"
              my-gptel-sanitized-open
              flagged
              my-gptel-sanitized-close))))

;;; --- Tool wrapper for execute_code_local ---
;; When operating in CTF/external mode, the sanitizer can be applied
;; to the output of execute_code_local before it reaches the AI.
;; This is controlled by a buffer-local flag.

(defvar-local my-gptel--sanitize-exec-output nil
  "When non-nil, output from execute_code_local is sanitized
before being returned to the AI. Enable for CTF/external operations.
The flag is captured at call time in code_tools.el (not read in the
sentinel) because process sentinels run in an unpredictable buffer
context. code_tools.el calls `my-gptel--sanitize-external-output'
directly using the captured value.")

(provide 'output_sanitizer)
