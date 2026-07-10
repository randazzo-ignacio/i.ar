;; -*- lexical-binding: t; -*-

;;; Prompt Loader -- Load prompt templates from knowledge/prompts/common/
;;
;; Provides a single function to load prompt template strings from
;; .org files in the common prompts directory.  This separates prompt
;; content from code logic.
;;
;; Prompt files live at knowledge/prompts/common/<name>.org which is
;; mounted inside the container at agents.d/common/<name>.org.
;;
;; Templates may contain format specifiers (%s, %d, etc.) that are
;; applied by the calling code via `format' at runtime.

(require 'subr-x)

(defun my-gptel--load-prompt (name)
  "Load a prompt template from the common prompts directory.
NAME is the prompt file name without extension (e.g., \"darwin_cycle\").
Returns the file content as a string, with trailing whitespace trimmed.
Signals an error if the file is not found."
  (let* ((prompts-dir (expand-file-name "agents.d/common" user-emacs-directory))
         (prompt-path (expand-file-name (format "%s.org" name) prompts-dir)))
    (unless (file-exists-p prompt-path)
      (error "Prompt template '%s' not found at %s" name prompt-path))
    (with-temp-buffer
      (insert-file-contents prompt-path)
      ;; Return the raw content, trimming trailing newline for clean format usage.
      (string-trim-right (buffer-string) "\n"))))

(provide 'prompt_loader)