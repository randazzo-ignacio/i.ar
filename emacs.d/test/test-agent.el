;; -*- lexical-binding: t; -*-

;;; Tests for iar-agent-loader.el (assembly-based)
;; Tests personality discovery, assembly-based loading, and agent name tracking.
;; Updated for the three-axis assembly model (archetype + personality + project).

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-loader)
(require 'iar-prompt-assembly)

;;; --- Profile reading tests ---

(ert-deftest test-agent-read-profile-basic ()
  "iar--read-personality should read a personality file and return content."
  (let ((content (iar--read-personality "mirror")))
    (should (stringp content))
    (should (string-match-p "mirror" content))))

(ert-deftest test-agent-read-profile-expands-includes ()
  "Assembly engine includes base_context in the assembled prompt."
  (let ((result (iar--assemble-prompt "interactive" "mirror" "default")))
    (let ((prompt (plist-get result :prompt)))
      (should (string-match-p "CONTEXT" prompt))
      (should (string-match-p "ARCHETYPE" prompt))
      (should (string-match-p "PERSONALITY" prompt)))))

(ert-deftest test-agent-read-profile-no-includes ()
  "iar--read-personality should work for any personality."
  (let ((content (iar--read-personality "colin")))
    (should (stringp content))
    (should (string-match-p "Colin" content))))

(ert-deftest test-agent-read-profile-missing-file ()
  "iar--read-personality should signal error for missing personality."
  (should-error (iar--read-personality "nonexistent_xyz")))

;;; --- Profile loading tests ---

(ert-deftest test-agent-load-profile-validates-name ()
  "iar--validate-agent-name should reject names with path traversal."
  (condition-case err
      (iar--validate-agent-name "../../etc/passwd")
    (error
     (should (string-match-p "Invalid agent name" (error-message-string err))))
    (:success
     (ert-fail "Expected error for path traversal"))))

(ert-deftest test-agent-load-profile-returns-nil-for-missing ()
  "iar--read-personality should error for nonexistent personality."
  (should-error (iar--read-personality "nonexistent_xyzzy_agent")))

(ert-deftest test-agent-load-profile-finds-real-agent ()
  "iar--read-personality should load a real personality."
  (let ((profile (iar--read-personality "darwin")))
    (should (stringp profile))
    (should (string-match-p "Darwin" profile))))

;;; --- Load agent tests ---

(ert-deftest test-agent-load-agent-creates-agents-dir ()
  "iar-load-agent should handle missing personalities dir gracefully."
  (let ((tmp-dir (make-temp-file "test-agent-createdir-" :dir-flag)))
    (unwind-protect
        (let ((user-emacs-directory tmp-dir))
          (should-not (file-directory-p (expand-file-name "agents.d/personalities" tmp-dir)))
          (condition-case err
              (iar--personality-names)
            (error
             (ert-fail (format "Unexpected error: %s" err))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _choices &rest _rest)
                       "test")))
            (with-temp-buffer
              (text-mode)
              (condition-case err
                  (iar-load-agent)
                (user-error
                 ;; Expected -- no personalities found
                 )
                (error
                 (ert-fail (format "Unexpected error: %s" err)))))))
      (delete-directory tmp-dir t))))

(ert-deftest test-agent-load-agent-discovers-agents ()
  "iar-load-agent should discover personalities from agents.d/personalities/.
Mocks completing-read to select the first personality and verifies assembly."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _rest)
               (car choices))))
    (with-temp-buffer
      (text-mode)
      (iar-load-agent)
      (should (stringp iar--current-agent-name))
      (should (stringp gptel-system-prompt))
      (should (string-match-p "PERSONALITY" gptel-system-prompt))
      (should (string-match-p "ARCHETYPE" gptel-system-prompt)))))

(ert-deftest test-agent-load-agent-enables-gptel-mode ()
  "iar-load-agent should enable gptel-mode if not already active."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _rest)
               (car choices))))
    (with-temp-buffer
      (text-mode)
      (should-not (bound-and-true-p gptel-mode))
      (iar-load-agent)
      (should (bound-and-true-p gptel-mode)))))

(ert-deftest test-agent-load-agent-preserves-existing-gptel-mode ()
  "iar-load-agent should not error when gptel-mode is already active."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt choices &rest _rest)
               (car choices))))
    (with-temp-buffer
      (text-mode)
      (gptel-mode 1)
      (should (bound-and-true-p gptel-mode))
      (iar-load-agent)
      (should (bound-and-true-p gptel-mode)))))

(ert-deftest test-agent-load-agent-filters-invalid-names ()
  "iar--personality-names should only return .org file base names."
  (let ((names (iar--personality-names)))
    (should (listp names))
    (should (member "mirror" names))
    (should (member "darwin" names))
    (should (member "colin" names))
    (should-not (member "mirror.org" names))))

(ert-deftest test-agent-load-agent-errors-no-valid-agents ()
  "iar-load-agent should user-error if no personalities are found."
  (let ((tmp-dir (make-temp-file "test-agent-noagents-" :dir-flag)))
    (unwind-protect
        (let ((user-emacs-directory tmp-dir))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _choices &rest _rest)
                       "test"))))
            (with-temp-buffer
              (text-mode)
              (should-error (iar-load-agent)))))
      (delete-directory tmp-dir t)))

(ert-deftest test-agent-load-agent-keybinding-registered ()
  "C-c a should be bound to iar-load-agent in gptel-mode-map."
  (with-eval-after-load 'gptel
    (should (eq (keymap-lookup gptel-mode-map "C-c a") 'iar-load-agent))))

(provide 'test-agent)