;; -*- lexical-binding: t; -*-

;;; Tests for read_roadmap and write_roadmap tools.
;; Tests reading and writing the ROADMAP.org file in the agent's tasks directory.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)
(require 'iar-tool--read-roadmap)
(require 'iar-tool--write-roadmap)

;;; --- Test fixtures ---

(defvar test-roadmap--tmpdir nil
  "Temporary directory for roadmap tool tests.")

(defun test-roadmap--setup ()
  "Create a temporary tasks/ structure with a test agent."
  (setq test-roadmap--tmpdir (make-temp-file "test-roadmap-" :dir-flag))
  (let ((tasks-dir (expand-file-name "tasks" test-roadmap--tmpdir)))
    (make-directory tasks-dir t)
    (let ((agent-dir (expand-file-name "testagent" tasks-dir)))
      (make-directory agent-dir t)
      ;; Create an existing ROADMAP.org
      (with-temp-file (expand-file-name "ROADMAP.org" agent-dir)
        (insert "* Existing Roadmap\n\nOld content here.")))))

(defun test-roadmap--teardown ()
  "Remove the temporary directory."
  (when (and test-roadmap--tmpdir (file-exists-p test-roadmap--tmpdir))
    (delete-directory test-roadmap--tmpdir t)
    (setq test-roadmap--tmpdir nil)))

(defmacro with-roadmap-fixture (&rest body)
  "Execute BODY with a temporary tasks/ directory."
  (declare (indent 0))
  `(let ((old-emacs-dir user-emacs-directory)
         (old-agent-name (and (boundp 'iar--current-agent-name)
                              iar--current-agent-name))
         (old-project (and (boundp 'iar--current-project)
                           iar--current-project)))
     (unwind-protect
         (progn
           (test-roadmap--setup)
           (let ((user-emacs-directory test-roadmap--tmpdir))
             (setq iar--current-agent-name "testagent")
             (setq iar--current-project "testagent")
             ,@body))
       (test-roadmap--teardown)
       (setq user-emacs-directory old-emacs-dir)
       (setq iar--current-agent-name old-agent-name)
       (setq iar--current-project old-project))))

;;; --- read_roadmap tests ---

(ert-deftest test-roadmap-read-existing ()
  "read_roadmap should return the content of an existing ROADMAP.org."
  (with-roadmap-fixture
    (let ((result (iar--tool-read-roadmap)))
      (should (stringp result))
      (should (string-match-p "Existing Roadmap" result))
      (should (string-match-p "Old content here" result)))))

(ert-deftest test-roadmap-read-missing ()
  "read_roadmap should return a message when no roadmap exists."
  (let ((old-emacs-dir user-emacs-directory)
        (old-agent-name (and (boundp 'iar--current-agent-name)
                             iar--current-agent-name))
         (old-project (and (boundp 'iar--current-project)
                           iar--current-project)))
    (unwind-protect
        (progn
          (setq test-roadmap--tmpdir (make-temp-file "test-roadmap-" :dir-flag))
          (make-directory (expand-file-name "tasks/testagent" test-roadmap--tmpdir) t)
          (let ((user-emacs-directory test-roadmap--tmpdir))
            (setq iar--current-agent-name "testagent")
            (setq iar--current-project "testagent")
            (let ((result (iar--tool-read-roadmap)))
              (should (stringp result))
              (should (string-match-p "No roadmap found" result)))))
      (test-roadmap--teardown)
      (setq user-emacs-directory old-emacs-dir)
      (setq iar--current-agent-name old-agent-name)
       (setq iar--current-project old-project))))

;;; --- write_roadmap tests ---

(ert-deftest test-roadmap-write-new ()
  "write_roadmap should create a new ROADMAP.org."
  (let ((old-emacs-dir user-emacs-directory)
        (old-agent-name (and (boundp 'iar--current-agent-name)
                             iar--current-agent-name))
         (old-project (and (boundp 'iar--current-project)
                           iar--current-project)))
    (unwind-protect
        (progn
          (setq test-roadmap--tmpdir (make-temp-file "test-roadmap-" :dir-flag))
          (make-directory (expand-file-name "tasks/testagent" test-roadmap--tmpdir) t)
          (let ((user-emacs-directory test-roadmap--tmpdir))
            (setq iar--current-agent-name "testagent")
            (setq iar--current-project "testagent")
            (let ((result (iar--tool-write-roadmap "* New Roadmap\n\nFresh content.")))
              (should (stringp result))
              (should (string-match-p "Success" result))
              (let ((roadmap-path (expand-file-name "tasks/testagent/ROADMAP.org" test-roadmap--tmpdir)))
                (should (file-exists-p roadmap-path))
                (with-temp-buffer
                  (insert-file-contents roadmap-path)
                  (should (string-match-p "New Roadmap" (buffer-string))))))))
      (test-roadmap--teardown)
      (setq user-emacs-directory old-emacs-dir)
      (setq iar--current-agent-name old-agent-name)
       (setq iar--current-project old-project))))

(ert-deftest test-roadmap-write-overwrite ()
  "write_roadmap should overwrite an existing ROADMAP.org."
  (with-roadmap-fixture
    (let ((result (iar--tool-write-roadmap "* Updated Roadmap\n\nNew content.")))
      (should (stringp result))
      (should (string-match-p "Success" result))
      (let ((roadmap-path (expand-file-name "tasks/testagent/ROADMAP.org" test-roadmap--tmpdir)))
        (with-temp-buffer
          (insert-file-contents roadmap-path)
          (should (string-match-p "Updated Roadmap" (buffer-string)))
          (should-not (string-match-p "Existing Roadmap" (buffer-string))))))))

(provide 'test-roadmap)
;;; test-roadmap.el ends here