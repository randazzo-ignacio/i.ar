;; -*- lexical-binding: t; -*-

;; Emacboros --- Agent orchestration in Emacs
;; Copyright (C) 2026 Ignacio Agustín Randazzo
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


;; Native Local Code Execution tool definition for gptel
;; Uses asynchronous process execution (make-process + accept-process-output)
;; to keep Emacs responsive while commands run. A generous timeout (3600s)
;; prevents infinite hangs without killing legitimate long-running processes.
;;
;; Output sanitization: When my-gptel--sanitize-exec-output is non-nil
;; (enabled for CTF/external operations), the output is passed through
;; my-gptel--maybe-sanitize-exec-output to strip control sequences and
;; flag prompt injection patterns before returning to the AI.

(require 'output_sanitizer)
(require 'audit_log)

(defun my-gptel--async-shell-command (command &optional timeout)
  "Run COMMAND asynchronously via `make-process', returning output as string.
Uses `accept-process-output' to yield to Emacs' event loop during execution,
keeping the UI responsive. TIMEOUT in seconds (default 3600) kills the process
only on true hangs, not legitimate long-running commands."
  (let* ((timeout (or timeout 3600))
         (buf (generate-new-buffer " *gptel-async-shell*"))
         (start-time (current-time))
         (deadline (time-add start-time (seconds-to-time timeout)))
         (done nil)
         (exit-code nil)
         proc)
    (setq proc
          (make-process
           :name "gptel-async-cmd"
                      :buffer buf
           :command (list shell-file-name "-c" command)
           :sentinel
           (lambda (proc event)
             (when (memq (process-status proc) '(exit signal))
               (setq exit-code (process-exit-status proc))
               (setq done t)))))
    ;; Yield to event loop while process runs; accept-process-output
    ;; allows redisplay, input, and other process output to flow.
    (while (and (not done)
                (process-live-p proc)
                (time-less-p (current-time) deadline))
      (accept-process-output nil 0.1))
    (unwind-protect
        (let ((output (with-current-buffer buf (buffer-string))))
          (cond
           ;; Normal completion
                      (done
            (if (and exit-code (/= exit-code 0))
                (format "Command exited with code %d.\nOutput:\n%s" exit-code output)
              output))
           ;; Timeout: kill process, return partial output
           (t
            (delete-process proc)
            (let ((partial (with-current-buffer buf (buffer-string))))
              (format "[TIMEOUT after %ds — process killed]\n%s" timeout partial)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(add-to-list 'gptel-tools
 (gptel-make-tool
  :name "execute_code_local"
    :description "Execute bash/shell commands in the same container as the Emacs tools (has access to source code). Uses async process execution so Emacs stays responsive. The container is Fedora-based with: bash, dig, nmap, openssl, python3, jq, whois, traceroute, tcpdump, ripgrep (rg), git, curl, find, gawk, sed, grep, gcc, make, tar, gzip, unzip."
  :args (list '(:name "command" :type "string" :description "The bash command to execute. Use bash syntax."))
  :function (lambda (command)
              (condition-case err
                  (let ((result (my-gptel--async-shell-command command)))
                    (my-gptel--audit-log-exec command
                      (if (string-match "Command exited with code \\([0-9]+\\)" result)
                          (string-to-number (match-string 1 result))
                        0))
                    (my-gptel--maybe-sanitize-exec-output result))
                (error (format "Error: Failed to execute command: %s\nDetail: %s"
                               command (error-message-string err)))))))
