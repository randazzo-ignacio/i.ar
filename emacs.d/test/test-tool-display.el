;; -*- lexical-binding: t; -*-

;;; Tests for tool_display.el
;; Tests the pre-tool-call display function that inserts "Calling <name>: <args>"
;; text into the chat buffer before tools execute. Uses mock gptel FSM objects.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'gptel-request)

(require 'tool_display)

;;; --- Test helpers ---

(defun test-td--make-fsm (buffer &optional tool-use marker)
  "Create a mock gptel FSM for testing.
BUFFER is a live buffer to insert display text into.
TOOL-USE is a vector of tool-call plists (default: one tool with no result).
MARKER is the tracking marker (default: a marker at point-min of BUFFER)."
  (let* ((fsm (gptel-make-fsm))
         (buf-marker (or marker
                         (with-current-buffer buffer
                           (let ((m (point-min-marker)))
                             (set-marker-insertion-type m nil)
                             m))))
         (info (list :buffer buffer
                     :tool-use (or tool-use
                                   (vector (list :name "read_file"
                                                 :args '(:filepath "/tmp/test.el"))))
                     :tracking-marker buf-marker)))
    (setf (gptel-fsm-info fsm) info)
    fsm))

(defun test-td--buffer-content (buf)
  "Return the plain text content of BUF."
  (with-current-buffer buf
    (buffer-substring-no-properties (point-min) (point-max))))

;;; --- Tests ---

(ert-deftest test-td-displays-tool-call-name ()
  "my-gptel--display-tool-call-pre should insert the tool name into the buffer."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm (current-buffer))))
      (my-gptel--display-tool-call-pre fsm)
      (should (string-match-p "Calling read_file:"
                              (test-td--buffer-content (current-buffer)))))))

(ert-deftest test-td-displays-tool-call-args ()
  "my-gptel--display-tool-call-pre should insert the tool arguments."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm (current-buffer))))
      (my-gptel--display-tool-call-pre fsm)
      (should (string-match-p "filepath"
                              (test-td--buffer-content (current-buffer)))))))

(ert-deftest test-td-filters-out-completed-tools ()
  "Tools with :result set should not be displayed."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm
                (current-buffer)
                (vector (list :name "done_tool" :args nil :result "already done")
                        (list :name "pending_tool" :args nil)))))
      (my-gptel--display-tool-call-pre fsm)
      (let ((content (test-td--buffer-content (current-buffer))))
        (should-not (string-match-p "done_tool" content))
        (should (string-match-p "pending_tool" content))))))

(ert-deftest test-td-no-tool-use-does-nothing ()
  "When there are no tool calls, nothing should be inserted."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm (current-buffer) (vector))))
      (my-gptel--display-tool-call-pre fsm)
      (should (string= "" (test-td--buffer-content (current-buffer)))))))

(ert-deftest test-td-all-tools-completed-does-nothing ()
  "When all tools have results, nothing should be inserted."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm
                (current-buffer)
                (vector (list :name "tool1" :args nil :result "r1")
                        (list :name "tool2" :args nil :result "r2")))))
      (my-gptel--display-tool-call-pre fsm)
      (should (string= "" (test-td--buffer-content (current-buffer)))))))

(ert-deftest test-td-nil-fsm-info-does-nothing ()
  "When FSM info is nil, function should not error."
  (let ((fsm (gptel-make-fsm)))
    (setf (gptel-fsm-info fsm) nil)
    ;; Should not error
    (my-gptel--display-tool-call-pre fsm)))

(ert-deftest test-td-nil-buffer-does-nothing ()
  "When :buffer is nil in info, function should not error."
  (let ((fsm (gptel-make-fsm)))
    (setf (gptel-fsm-info fsm) (list :buffer nil
                                     :tool-use (vector (list :name "foo" :args nil))
                                     :tracking-marker nil))
    ;; Should not error
    (my-gptel--display-tool-call-pre fsm)))

(ert-deftest test-td-nil-marker-falls-back-to-position ()
  "When :tracking-marker is nil, should fall back to :position."
  (with-temp-buffer
    (insert "existing content\n")
    (let* ((pos-marker (point-marker))
           (fsm (gptel-make-fsm)))
      (setf (gptel-fsm-info fsm) (list :buffer (current-buffer)
                                       :tool-use (vector (list :name "test_tool"
                                                               :args nil))
                                       :tracking-marker nil
                                       :position pos-marker))
      (my-gptel--display-tool-call-pre fsm)
      (should (string-match-p "test_tool"
                              (test-td--buffer-content (current-buffer)))))))

(ert-deftest test-td-nil-marker-and-nil-position-does-nothing ()
  "When both :tracking-marker and :position are nil, nothing should be inserted."
  (with-temp-buffer
    (let ((fsm (gptel-make-fsm)))
      (setf (gptel-fsm-info fsm) (list :buffer (current-buffer)
                                       :tool-use (vector (list :name "foo" :args nil))
                                       :tracking-marker nil
                                       :position nil))
      (my-gptel--display-tool-call-pre fsm)
      (should (string= "" (test-td--buffer-content (current-buffer)))))))

(ert-deftest test-td-truncates-long-args ()
  "Arguments longer than 500 chars should be truncated."
  (with-temp-buffer
    (let* ((long-args (make-string 600 ?X))
           (fsm (test-td--make-fsm
                 (current-buffer)
                 (vector (list :name "write_file"
                               :args (list :content long-args))))))
      (my-gptel--display-tool-call-pre fsm)
      (let ((content (test-td--buffer-content (current-buffer))))
        ;; Should contain truncation indicator
        (should (string-match-p "\\.\\.\\.)" content))
        ;; Should NOT contain all 600 X's
        (should-not (string-match-p (make-string 550 ?X) content))))))

(ert-deftest test-td-short-args-not-truncated ()
  "Arguments shorter than 500 chars should not be truncated."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm
                (current-buffer)
                (vector (list :name "read_file"
                              :args '(:filepath "/tmp/test.el"))))))
      (my-gptel--display-tool-call-pre fsm)
      (let ((content (test-td--buffer-content (current-buffer))))
        (should-not (string-match-p "\\.\\.\\.)" content))))))

(ert-deftest test-td-multiple-tool-calls-displayed ()
  "Multiple pending tool calls should all be displayed."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm
                (current-buffer)
                (vector (list :name "tool_a" :args nil)
                        (list :name "tool_b" :args nil)
                        (list :name "tool_c" :args nil :result "done")))))
      (my-gptel--display-tool-call-pre fsm)
      (let ((content (test-td--buffer-content (current-buffer))))
        (should (string-match-p "tool_a" content))
        (should (string-match-p "tool_b" content))
        (should-not (string-match-p "tool_c" content))))))

(ert-deftest test-td-updates-tracking-marker ()
  "After display, the FSM's :tracking-marker should be updated."
  (with-temp-buffer
    (let* ((initial-marker (point-min-marker))
           (fsm (gptel-make-fsm)))
      (setf (gptel-fsm-info fsm) (list :buffer (current-buffer)
                                       :tool-use (vector (list :name "test_tool"
                                                               :args nil))
                                       :tracking-marker initial-marker))
      (my-gptel--display-tool-call-pre fsm)
      (let ((new-marker (plist-get (gptel-fsm-info fsm) :tracking-marker)))
        ;; New marker should be a marker
        (should (markerp new-marker))
        ;; New marker should have insertion type t (advances on insert before)
        (should (marker-insertion-type new-marker))))))

(ert-deftest test-td-display-text-has-gptel-ignore-property ()
  "Display text should be marked with 'gptel 'ignore so it's not sent to LLM."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm (current-buffer))))
      (my-gptel--display-tool-call-pre fsm)
      ;; Check first character has gptel = ignore
      (should (eq (get-text-property (point-min) 'gptel) 'ignore))
      ;; Check last character (before final newline) also has it
      (should (eq (get-text-property (1- (point-max)) 'gptel) 'ignore)))))

(ert-deftest test-td-error-does-not-crash ()
  "Function should catch errors and not propagate them."
  ;; Pass a non-FSM object -- gptel-fsm-p guard prevents entry
  (let ((non-fsm (list 'fake)))
    ;; Should not error
    (my-gptel--display-tool-call-pre non-fsm)))

(ert-deftest test-td-dead-buffer-does-not-crash ()
  "When the buffer is dead, function should not error or log."
  (let* ((buf (generate-new-buffer " test-td-dead"))
         (fsm (test-td--make-fsm buf)))
    (kill-buffer buf)
    ;; Should not error even though buffer is dead
    (my-gptel--display-tool-call-pre fsm)))

(ert-deftest test-td-nil-args-displayed ()
  "Tools with nil args should display 'nil' without error."
  (with-temp-buffer
    (let ((fsm (test-td--make-fsm
                (current-buffer)
                (vector (list :name "no_args_tool" :args nil)))))
      (my-gptel--display-tool-call-pre fsm)
      (let ((content (test-td--buffer-content (current-buffer))))
        (should (string-match-p "no_args_tool" content))
        (should (string-match-p "nil" content))))))

(ert-deftest test-td-advice-registered ()
  "my-gptel--display-tool-call-pre should be registered as advice on gptel--handle-tool-use."
  (should (advice-member-p #'my-gptel--display-tool-call-pre
                            'gptel--handle-tool-use)))

(provide 'test-tool-display)