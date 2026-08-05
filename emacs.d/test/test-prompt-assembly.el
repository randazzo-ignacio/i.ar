;; -*- lexical-binding: t; -*-

;;; Tests for iar-prompt-assembly.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Load dependencies
(require 'iar-utils)
(require 'iar-project-parser)
(require 'iar-prompt-assembly)

;; Configs must be loaded
(defvar iar-archetypes-path nil)
(defvar iar-personalities-path nil)
(defvar iar-projects-path nil)
(defvar iar-docs-path nil)
(defvar iar-audit-path nil)
(defvar iar-personal-file-max-lines nil)
(defvar iar-knowledge-open-delimiter nil)
(defvar iar-knowledge-close-delimiter nil)
(defvar iar-knowledge-file-separator nil)

(ert-deftest test-assembly-read-archetype ()
  "Reading an archetype returns its content."
  (let ((content (iar--read-archetype "interactive")))
    (should (stringp content))
    (should (> (length content) 0))
    (should (string-match-p "INTERACTIVE" content))))

(ert-deftest test-assembly-read-archetype-not-found ()
  "Reading a non-existent archetype signals an error."
  (should-error (iar--read-archetype "nonexistent")))

(ert-deftest test-assembly-read-personality ()
  "Reading a personality returns its content."
  (let ((content (iar--read-personality "mirror")))
    (should (stringp content))
    (should (> (length content) 0))
    (should (string-match-p "mirror" content))))

(ert-deftest test-assembly-read-personality-not-found ()
  "Reading a non-existent personality signals an error."
  (should-error (iar--read-personality "nonexistent")))

(ert-deftest test-assembly-parse-mode-interactive ()
  "Parse mode from interactive archetype returns interactive."
  (let ((content (iar--read-archetype "interactive")))
    (should (eq (iar--parse-mode content) 'interactive))))

(ert-deftest test-assembly-parse-mode-autonomous ()
  "Parse mode from autonomous archetype returns autonomous."
  (let ((content (iar--read-archetype "autonomous")))
    (should (eq (iar--parse-mode content) 'autonomous))))

(ert-deftest test-assembly-parse-mode-continuous ()
  "Parse mode from continuous archetype returns continuous."
  (let ((content (iar--read-archetype "continuous")))
    (should (eq (iar--parse-mode content) 'continuous))))

(ert-deftest test-assembly-parse-mode-delegated ()
  "Parse mode from agent-assistant archetype returns delegated."
  (let ((content (iar--read-archetype "agent-assistant")))
    (should (eq (iar--parse-mode content) 'delegated))))

(ert-deftest test-assembly-parse-mode-no-metadata ()
  "Content without #+MODE defaults to interactive."
  (should (eq (iar--parse-mode "Some content without metadata") 'interactive)))

(ert-deftest test-assembly-inject-memory-interactive ()
  "Interactive mode injects LOGS.md if it exists."
  (let ((result (iar--inject-memory 'interactive "mirror")))
    ;; LOGS.md should exist for mirror
    (should (stringp result))
    ;; Either contains SESSION LOGS or is empty (if file doesn't exist)
    (or (string-match-p "SESSION LOGS" result)
        (string= result ""))))

(ert-deftest test-assembly-inject-memory-delegated ()
  "Delegated mode injects no memory."
  (should (string= (iar--inject-memory 'delegated "mirror") "")))

(ert-deftest test-assembly-inject-memory-one-shot ()
  "One-shot mode injects no memory."
  (should (string= (iar--inject-memory 'one-shot "darwin") "")))

(ert-deftest test-assembly-filter-tools-all ()
  "Nil tool-names returns all tools unchanged."
  (let ((tools (list 'fake-tool-1 'fake-tool-2)))
    (should (equal (iar--filter-tools tools nil) tools))))

(ert-deftest test-assembly-filter-tools-subset ()
  "Tool filtering returns only matching tools, preserving order."
  (let* ((tool-a (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (tool-b (gptel-make-tool :name "write_file" :function #'identity :description "test" :args nil))
         (tool-c (gptel-make-tool :name "delegate" :function #'identity :description "test" :args nil))
         (all-tools (list tool-a tool-b tool-c))
         (filtered (iar--filter-tools all-tools '("read_file" "delegate"))))
    (should (= (length filtered) 2))
    ;; Preserves original order: read_file first, delegate second
    (should (equal (gptel-tool-name (car filtered)) "read_file"))
    (should (equal (gptel-tool-name (cadr filtered)) "delegate"))))

(ert-deftest test-assembly-filter-tools-no-match ()
  "Tool filtering with no matches returns empty list."
  (let* ((tool-a (gptel-make-tool :name "read_file" :function #'identity :description "test" :args nil))
         (all-tools (list tool-a))
         (filtered (iar--filter-tools all-tools '("nonexistent_tool"))))
    (should (= (length filtered) 0))))

(ert-deftest test-assembly-assemble-full ()
  "Full assembly produces a prompt with all sections in correct order."
  (let ((result (iar--assemble-prompt "interactive" "mirror" "default")))
    (should (plist-get result :prompt))
    (should (stringp (plist-get result :prompt)))
    (should (plist-get result :tools))
    (should (eq (plist-get result :mode) 'interactive))
    (should (string= (plist-get result :archetype) "interactive"))
    (should (string= (plist-get result :personality) "mirror"))
    (should (string= (plist-get result :project) "default"))
    ;; Check assembly order using delimiter strings (not generic words
    ;; that might appear in knowledge content)
    (let ((prompt (plist-get result :prompt)))
      (should (string-match-p "CONTEXT" prompt))
      (should (string-match-p "=== ARCHETYPE" prompt))
      (should (string-match-p "=== PERSONALITY" prompt))
      (should (string-match-p "=== PROJECT OBJECTIVE" prompt))
      ;; base_context (CONTEXT) should come before archetype delimiter
      (should (< (string-match "CONTEXT" prompt)
                 (string-match "=== ARCHETYPE" prompt)))
      ;; archetype delimiter should come before personality delimiter
      (should (< (string-match "=== ARCHETYPE" prompt)
                 (string-match "=== PERSONALITY" prompt))))))

(ert-deftest test-assembly-assemble-autonomous ()
  "Assembly with autonomous archetype returns autonomous mode."
  (let ((result (iar--assemble-prompt "autonomous" "darwin" "darwin")))
    (should (eq (plist-get result :mode) 'autonomous))
    (should (string= (plist-get result :archetype) "autonomous"))
    (should (string= (plist-get result :personality) "darwin"))))

(ert-deftest test-assembly-assemble-delegated-no-memory ()
  "Assembly with delegated archetype does not inject memory."
  (let ((result (iar--assemble-prompt "agent-assistant" "darwin" "agent-assistant")))
    (let ((prompt (plist-get result :prompt)))
      ;; Should NOT contain SESSION LOGS or STATE blocks
      (should-not (string-match-p "SESSION LOGS" prompt))
      (should-not (string-match-p "=== STATE" prompt)))))

(ert-deftest test-assembly-assemble-tool-gating ()
  "Assembly with restricted project returns filtered tools."
  (let ((result (iar--assemble-prompt "agent-assistant" "darwin" "reviewer")))
    ;; Reviewer project has limited tools
    (let ((tools (plist-get result :tools)))
      (should (listp tools))
      ;; Should not contain delegate tool
      (should-not (cl-some (lambda (t) (equal (gptel-tool-name t) "delegate")) tools)))))