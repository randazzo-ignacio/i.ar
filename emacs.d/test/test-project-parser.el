;; -*- lexical-binding: t; -*-

;;; Tests for iar-project-parser.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Load the module under test
(require 'iar-project-parser)

;; Configs must be loaded for iar-projects-path
(defvar iar-projects-path nil)

(ert-deftest test-project-parser-load-default ()
  "Loading the 'default' project returns correct metadata."
  (let ((p (iar--load-project "default")))
    (should (string= (plist-get p :name) "default"))
    (should (member "iar/" (plist-get p :knowledge)))
    (should (member "infra/" (plist-get p :knowledge)))
    (should (member "user/" (plist-get p :knowledge)))
    (should (member "read_file" (plist-get p :tools)))
    (should (member "delegate" (plist-get p :tools)))
    (should (stringp (plist-get p :objective)))
    (should (> (length (plist-get p :objective)) 0))))

(ert-deftest test-project-parser-load-implementer ()
  "Loading 'implementer' project returns restricted tool set."
  (let ((p (iar--load-project "implementer")))
    (should (string= (plist-get p :name) "implementer"))
    (should (equal (plist-get p :knowledge) '("iar/")))
    (should (member "read_file" (plist-get p :tools)))
    (should (member "write_file" (plist-get p :tools)))
    (should (member "execute_code_local" (plist-get p :tools)))
    ;; Should NOT have delegate, telegram, reload, etc.
    (should-not (member "delegate" (plist-get p :tools)))
    (should-not (member "send_telegram" (plist-get p :tools)))
    (should-not (member "reload_os" (plist-get p :tools)))))

(ert-deftest test-project-parser-load-reviewer ()
  "Loading 'reviewer' project returns minimal read-only tool set."
  (let ((p (iar--load-project "reviewer")))
    (should (string= (plist-get p :name) "reviewer"))
    (should (member "read_file" (plist-get p :tools)))
    (should (member "list_directory" (plist-get p :tools)))
    (should (member "execute_code_local" (plist-get p :tools)))
    ;; Should NOT have write_file, git_commit, delegate
    (should-not (member "write_file" (plist-get p :tools)))
    (should-not (member "git_commit" (plist-get p :tools)))
    (should-not (member "delegate" (plist-get p :tools)))))

(ert-deftest test-project-parser-candidates ()
  "Project candidates returns list of available projects."
  (let ((candidates (iar--project-candidates)))
    (should (consp candidates))
    (should (assoc "default" candidates))
    (should (assoc "implementer" candidates))
    (should (assoc "reviewer" candidates))
    (should (assoc "agent-assistant" candidates))
    (should (assoc "darwin" candidates))
    (should (assoc "gardener" candidates))
    (should (assoc "librarian" candidates))
    (should (assoc "colin" candidates))))

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
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file write_file execute_code_local\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :tools) '("read_file" "write_file" "execute_code_local")))))

(ert-deftest test-project-parser-parse-metadata-objective ()
  "Parse #+OBJECTIVE line correctly."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+TOOLS: read_file\n#+OBJECTIVE: Do the thing.")))
    (should (string= (plist-get meta :objective) "Do the thing."))))

(ert-deftest test-project-parser-parse-metadata-missing-fields ()
  "Missing fields return nil gracefully."
  (let ((meta (iar--parse-project-metadata
               "#+KNOWLEDGE: iar/\n#+OBJECTIVE: Test")))
    (should (equal (plist-get meta :knowledge) '("iar/")))
    (should (null (plist-get meta :tools)))
    (should (string= (plist-get meta :objective) "Test"))))

(ert-deftest test-project-parser-parse-metadata-empty ()
  "Empty content returns all nil."
  (let ((meta (iar--parse-project-metadata "")))
    (should (null (plist-get meta :knowledge)))
    (should (null (plist-get meta :tools)))
    (should (null (plist-get meta :objective)))))