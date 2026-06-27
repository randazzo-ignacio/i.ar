;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randoso
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


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

;;; --- Configuration ---

(defconst my-gptel--sanitizer-control-patterns
  '(
    ;; ANSI escape sequences (can manipulate terminal output)
    "\x1b\\[[0-9;]*[a-zA-Z]"
    ;; Other control characters (except newline, tab)
    "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]"
    ;; Unicode zero-width characters (can hide instructions)
    "\x200b\x200c\x200d\xfeff"
    ;; Unicode right-to-left override (can reverse text display)
    "\x202e"
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
    "^```tool$"
    "^```json$"
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
      (setq result (replace-regexp-in-string pattern "[REMOVED-TAG]" result)))))

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
              (setq flagged (concat "[INJECTION SUSPECT] " line))
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
      (format "[SANITIZED EXTERNAL DATA — control sequences stripped, injection patterns flagged]\n%s\n[END SANITIZED EXTERNAL DATA]"
              flagged))))

;;; --- Tool wrapper for execute_code_local ---
;; When operating in CTF/external mode, the sanitizer can be applied
;; to the output of execute_code_local before it reaches the AI.
;; This is controlled by a buffer-local flag.

(defvar-local my-gptel--sanitize-exec-output nil
  "When non-nil, output from execute_code_local is sanitized
before being returned to the AI. Enable for CTF/external operations.")

(defun my-gptel--maybe-sanitize-exec-output (output)
  "Conditionally sanitize OUTPUT from execute_code_local.
If `my-gptel--sanitize-exec-output' is non-nil, apply sanitization.
Otherwise return OUTPUT unchanged."
  (if my-gptel--sanitize-exec-output
      (my-gptel--sanitize-external-output output)
    output))

(provide 'output_sanitizer)