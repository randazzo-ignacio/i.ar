;; -*- lexical-binding: t; -*-

;;; Tool result truncation for gptel
;;
;; Truncates tool results BEFORE they enter the conversation buffer.
;; This is the key difference from the failed compression module:
;; we intercept the result at the tool function level, not in the
;; buffer after the fact.  gptel never sees the full output -- it
;; only sees the truncated version.
;;
;; Mechanism: `:around' advice on `gptel--process-tool-call'.
;; This function is called by gptel after a tool function returns
;; (sync tools) or after an async tool calls its callback.  The
;; result string is passed as the third argument.  We intercept it,
;; truncate if needed, and pass the truncated version to the
;; original function.
;;
;; Middle-truncation strategy: preserves the start (context, headers,
;; early output) and the end (final results, error messages, tail of
;; logs).  The middle is replaced with a notice showing total size
;; and how much was kept.

(require 'subr-x)

(defvar iar-tool-result-max-chars 10000
  "Maximum characters of tool result output before truncation.
Forward-declared here, owned by parameters.el.")

(defun iar--truncate-tool-result (result)
  "Truncate RESULT string if it exceeds `iar-tool-result-max-chars'.
Uses middle-truncation: preserves first and last halves equally,
replaces the middle with a truncation notice.  Returns RESULT
unchanged if it's under the limit or if truncation is disabled."
  (let ((max-chars (if (boundp 'iar-tool-result-max-chars)
                       iar-tool-result-max-chars
                     10000)))
    (if (or (null max-chars)
            (not (integerp max-chars))
            (<= max-chars 0)
            (null result)
            (not (stringp result))
            (<= (length result) max-chars))
        result
      (let* ((total (length result))
             (keep (/ max-chars 2))
             (head (substring result 0 keep))
             (tail (substring result (- total keep)))
             (notice (format "\n[... truncated: %d total chars, kept first %d and last %d ...]\n"
                             total keep keep)))
        (concat head notice tail)))))

(defun iar--truncate-tool-result-advice (orig-fun fsm tool-spec tool-call result)
  "Around advice on `gptel--process-tool-call'.
Truncates RESULT before it enters the conversation buffer."
  (funcall orig-fun fsm tool-spec tool-call
           (iar--truncate-tool-result result)))

;;;###autoload
(defun iar-tool-result-truncation-setup ()
  "Install tool result truncation advice."
  (advice-add 'gptel--process-tool-call :around
              #'iar--truncate-tool-result-advice))

(iar-tool-result-truncation-setup)

(provide 'iar-tool-result-truncation)