;; -*- lexical-binding: t; -*-

;;; Tests for iar-project-parser.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-project-parser)

(defvar iar-projects-path nil)

(ert-deftest test-project-parser-load-iar ()
  "Loading the 'iar' project returns correct metadata."
  (let ((p (iar--load-project "iar")))
    (should (string= (plist-get p :name) "iar"))
    (should (member "iar/" (plist-get p :knowledge)))
    (should (member "read_file" (plist-get p :tools)))
    (should (stringp (plist-get p :objective)))
    (should (> (length (plist-get p :objective)) 0))))

(ert-deftest test-project-parser-load-implementer ()
  "Loading 'implementer' project returns restricted tool set."
  (let ((p (iar--load-project "implementer")))
    (should (string= (plist-get p :name) "implementer"))
    (should (member "read_file" (plist-get p :tools)))
    (should-not (member "delegate" (plist-get p :tools)))))

(ert-deftest test-project-parser-load-reviewer ()
  "Loading 'reviewer' project returns minimal read-only tool set."
  (let ((p (iar--load-project "reviewer")))
    (should (member "read_file" (plist-get p :tools)))
    (should-not (member "write_file" (plist-get p :tools)))))

(ert-deftest test-project-parser-candidates ()
  "Project candidates returns list of available projects."
  (let ((candidates (iar--project-candidates)))
    (should (consp candidates))
    (should (assoc "iar" candidates))
    (should-not (assoc "default" candidates))))

(ert-deftest test-project-parser-not-found ()
  "Loading a non-existent project signals an error."
  (should-error (iar--load-project "nonexistent-project-xyz")))

(ert-deftest test-project-parser-parse-metadata-knowledge ()
  "Parse #+KNOWLEDGE line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/ infra/ user/\n#+TOOLS: read_file\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :knowledge) '("iar/" "infra/" "user/")))))

(ert-deftest test-project-parser-parse-metadata-tools ()
  "Parse #+TOOLS line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file write_file\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :tools) '("read_file" "write_file")))))

(ert-deftest test-project-parser-parse-metadata-objective ()
  "Parse #+OBJECTIVE line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+OBJECTIVE: Do the thing.")))
    (should (string= (plist-get meta :objective) "Do the thing."))))

(ert-deftest test-project-parser-parse-metadata-mounts ()
  "Parse #+MOUNTS line with :rw and :ro suffixes."
  (let ((meta (iar--parse-project-metadata
               "#+MOUNTS: /path/a:rw /path/b:ro /path/c\n#+OBJECTIVE: Test")))
    (let ((mounts (plist-get meta :mounts)))
      (should (equal (cdr (assoc "/path/a" mounts)) "rw"))
      (should (equal (cdr (assoc "/path/b" mounts)) "ro"))
      ;; No suffix defaults to rw
      (should (equal (cdr (assoc "/path/c" mounts)) "rw")))))

(ert-deftest test-project-parser-parse-mount-entry ()
  "Parse individual mount entries."
  (should (equal (iar--parse-mount-entry "/path:rw") '("/path" . "rw")))
  (should (equal (iar--parse-mount-entry "/path:ro") '("/path" . "ro")))
  (should (equal (iar--parse-mount-entry "/path") '("/path" . "rw"))))

(ert-deftest test-project-parser-parse-metadata-missing-fields ()
  "Missing fields return nil gracefully."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+OBJECTIVE: Test")))
    (should (null (plist-get meta :tools)))
    (should (null (plist-get meta :mounts)))))

(ert-deftest test-project-parser-parse-metadata-empty ()
  "Empty content returns all nil."
  (let ((meta (iar--parse-project-metadata "")))
    (should (null (plist-get meta :knowledge)))
    (should (null (plist-get meta :tools)))
    (should (null (plist-get meta :mounts)))
    (should (null (plist-get meta :objective)))))

(ert-deftest test-project-parser-create-project ()
  "Creating a new project writes a file and returns parsed metadata."
  (let* ((tmp-dir (make-temp-file "test-project-create-" :dir-flag))
         (user-emacs-directory tmp-dir)
         (iar-personalization-path tmp-dir)
         (iar-projects-path "projects"))
    (unwind-protect
        (let ((result (iar--create-project "test-new")))
          (should (string= (plist-get result :name) "test-new"))
          (should (file-exists-p (expand-file-name "projects/test-new.org" tmp-dir)))
          (should (member "read_file" (plist-get result :tools)))
          (should (null (plist-get result :mounts))))
      (delete-directory tmp-dir t))))

(ert-deftest test-project-parser-load-or-create-existing ()
  "load-or-create returns existing project without creating a new file."
  (let ((result (iar--load-or-create-project "iar")))
    (should (string= (plist-get result :name) "iar"))))

(provide 'test-project-parser)