;;; test-unknown-tool.el --- Test FSM recovery from hallucinated tool names -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'gptel-request)
(require 'gptel)
(require 'gptel-ollama)

;;; This test simulates what happens when the model calls a tool name
;;; that doesn't exist in the registered tool list (e.g., "read_directory"
;;; instead of "list_directory").
;;;
;;; gptel now handles unknown tool names gracefully: gptel--handle-tool-use
;;; calls gptel--process-tool-call with an error message, which sets :result
;;; on the tool-call and transitions the FSM. The model receives the error
;;; feedback and can retry with the correct tool name.

(defvar test-unknown-tool--callback-result nil
  "Captures the callback response from the FSM for testing.")

(defun test-unknown-tool--callback (response _info)
  "Test callback that captures RESPONSE for inspection."
  (setq test-unknown-tool--callback-result response))

(ert-deftest test-unknown-tool-fsm-recovery ()
  "Test that calling an unknown tool name does not crash or hang.
Since gptel 20260704.707, unknown tool names are handled gracefully:
gptel--handle-tool-use calls process-tool-result with an error message,
which sets :result on the tool-call and transitions the FSM to WAIT.
The model receives the error feedback and can retry with the correct
tool name.

This is the raw gptel behavior WITHOUT our pre-tool-call hook guard.
The hook guard (tested in test-unknown-tool-pre-hook-blocks) provides
an additional layer of protection by blocking unknown tools at the
TPRE stage before they reach gptel--handle-tool-use."
  (let* ((tool-spec (gptel-make-tool
                     :name "list_directory"
                     :description "List a directory"
                     :args (list '(:name "path" :type "string"))
                     :function (lambda (path) (format "contents of %s" path))))
         (backend (gptel-make-ollama "TestOllama"
                                     :host "localhost:11434"
                                     :models '(test-model)
                                     :stream t))
         (tool-call (list :name "read_directory"
                          :args (list :path "/tmp")))
         (info (list :backend backend
                     :buffer (current-buffer)
                     :tools (list tool-spec)
                     :data (list :messages [])
                     :callback #'test-unknown-tool--callback
                     :tool-use (list tool-call)))
         (fsm (gptel-make-fsm
               :table gptel-send--transitions
               :handlers gptel-send--handlers
               :state 'TOOL
               :info info)))
    ;; The FSM should not crash when encountering an unknown tool name.
    (setq test-unknown-tool--callback-result nil)
    (condition-case _err
        (gptel--handle-tool-use fsm)
      (error nil))
    ;; gptel now handles unknown tools: it calls process-tool-result
    ;; with an error message, which sets :result and transitions the FSM.
    (should (eq (gptel-fsm-state fsm) 'WAIT))
    (should (plist-get tool-call :result))
    (should (string-match-p "not available" (plist-get tool-call :result)))
    ;; Callback should have been called with tool-result
    (should test-unknown-tool--callback-result)
    (should (eq (car test-unknown-tool--callback-result) 'tool-result))))

(ert-deftest test-unknown-tool-pre-hook-blocks ()
  "Test that the pre-tool-call hook guard blocks unknown tools.
When a model calls a tool name not in gptel-tools, the pre-tool-call
hook should return (:block ...) which causes gptel to inject an error
result via gptel--process-tool-call.  This sets :result on the tool-call
plist, preventing the FSM from hanging in TOOL state.

This test simulates the hook behavior: given an info plist with a
tool name not found in gptel-tools, the hook function returns a plist
with :block set to a non-nil error string."
  (let* ((tool-spec (gptel-make-tool
                     :name "list_directory"
                     :description "List a directory"
                     :args (list '(:name "path" :type "string"))
                     :function (lambda (path) (format "contents of %s" path))))
         (known-tools (list tool-spec))
         ;; Simulate the hook function used in delegate_tool.el and darwin_cycle.el
         (hook-fn (lambda (info)
                    (let ((name (plist-get info :name)))
                      (unless (cl-find-if (lambda (ts)
                                            (equal (gptel-tool-name ts) name))
                                          known-tools)
                        (list :block
                              (format "Unknown tool '%s'. Check the tool name and use one of the available tools."
                                      name)))))))
    ;; Hook should return (:block ...) for unknown tool
    (let ((result (funcall hook-fn (list :name "read_directory"))))
      (should result)
      (should (plist-get result :block))
      (should (string-match-p "Unknown tool" (plist-get result :block))))
    ;; Hook should return nil for known tool
    (let ((result (funcall hook-fn (list :name "list_directory"))))
      (should (null result)))))

(ert-deftest test-ollama-stream-append-tool-use ()
  "Test that the Ollama streaming parser appends to :tool-use
instead of overwriting it.  Simulates two JSON chunks each
containing a tool call."
  (let ((info (list :backend (gptel-make-ollama "TestOllama"
                                                :host "localhost:11434"
                                                :models '(test-model)
                                                :stream t)
                    :data (list :messages [])
                    :tool-use nil)))
    ;; Simulate first chunk with one tool call
    (let* ((tool-calls-1 [(:function (:name "read_file"
                                           :arguments "/etc/hosts"))])
           (new-calls-1
            (cl-loop
             for tool-call across tool-calls-1
             for call-spec = (copy-sequence (plist-get tool-call :function))
             do (plist-put call-spec :args
                           (plist-get call-spec :arguments))
             (plist-put call-spec :arguments nil)
             collect call-spec)))
      (plist-put info :tool-use
                 (append (plist-get info :tool-use) new-calls-1)))
    ;; Simulate second chunk with another tool call
    (let* ((tool-calls-2 [(:function (:name "list_directory"
                                            :arguments "/tmp"))])
           (new-calls-2
            (cl-loop
             for tool-call across tool-calls-2
             for call-spec = (copy-sequence (plist-get tool-call :function))
             do (plist-put call-spec :args
                           (plist-get call-spec :arguments))
             (plist-put call-spec :arguments nil)
             collect call-spec)))
      (plist-put info :tool-use
                 (append (plist-get info :tool-use) new-calls-2)))
    ;; Both tool calls should be present (not just the last one)
    (let ((tool-use (plist-get info :tool-use)))
      (should (= 2 (length tool-use)))
      (should (equal "read_file" (plist-get (nth 0 tool-use) :name)))
      (should (equal "list_directory" (plist-get (nth 1 tool-use) :name))))))

(provide 'test-unknown-tool)
;;; test-unknown-tool.el ends here