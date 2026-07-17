;; -*- lexical-binding: t; -*-

;;; Tests for iar-buffer-monitor.el

(require 'ert)
(require 'subr-x)
(require 'cl-lib)

;; Declare special variables so let* creates dynamic bindings
(defvar iar-buffer-warn-size nil)
(defvar iar-buffer-hard-cap nil)
(defvar iar--current-agent-name nil)

;; Load shared iar-utils first (dependency of iar-buffer-monitor)
(load-file (expand-file-name "init.d/shared/iar-utils.el" user-emacs-directory))
;; Load the module under test
(load-file (expand-file-name "init.d/debug/iar-buffer-monitor.el" user-emacs-directory))

(ert-deftest test-buffer-monitor-approx-tokens ()
  "Token estimation should be roughly chars/4."
  (should (= (iar--approx-token-count 0) 0))
  (should (= (iar--approx-token-count 4) 1))
  (should (= (iar--approx-token-count 100) 25))
  (should (= (iar--approx-token-count 1000) 250)))

(ert-deftest test-buffer-monitor-agent-name ()
  "Agent name should fall back to unknown when not set."
  (let ((iar--current-agent-name nil))
    (should (equal (iar--get-agent-name) nil)))
  (let ((iar--current-agent-name "darwin"))
    (should (equal (iar--get-agent-name) "darwin"))))

(ert-deftest test-buffer-monitor-log-path ()
  "Log path should include agent name and be under audit/."
  (let ((iar--current-agent-name "test-agent"))
    (let ((path (iar--buffer-monitor-log-path)))
      (should (string-match-p "audit/test-agent/BUFFER\\.log$" path)))))

(ert-deftest test-buffer-monitor-log ()
  "Log function should write to both audit log and per-agent log."
  (let* ((test-dir (make-temp-file "bufmon-test-" t))
         (test-buf (get-buffer-create " *bufmon-test*"))
         (iar--current-agent-name "test-agent")
         (iar--audit-log-path
          (expand-file-name "audit.log" test-dir))
         (mock-log-path (expand-file-name "BUFFER.log" test-dir)))
    (unwind-protect
        (progn
          (with-current-buffer test-buf
            (insert "Hello, world!"))
          (cl-letf (((symbol-function 'iar--buffer-monitor-log-path)
                     (lambda () mock-log-path)))
            (let ((result (iar--buffer-monitor-log test-buf)))
              (should (plist-get result :chars))
              (should (plist-get result :bytes))
              (should (plist-get result :tokens))
              (should (file-exists-p iar--audit-log-path))
              (let ((content (with-temp-buffer
                               (insert-file-contents iar--audit-log-path)
                               (buffer-string))))
                (should (string-match-p "buffer-monitor" content))
                (should (string-match-p "test-agent" content)))
              (should (file-exists-p mock-log-path))
              (let ((content (with-temp-buffer
                               (insert-file-contents mock-log-path)
                               (buffer-string))))
                (should (string-match-p "buffer-monitor" content))))))
      (when (buffer-live-p test-buf)
        (kill-buffer test-buf))
      (when (file-exists-p test-dir)
        (delete-directory test-dir t)))))

(ert-deftest test-buffer-monitor-warn-threshold ()
  "Warning should trigger when buffer exceeds threshold."
  (let* ((test-buf (get-buffer-create " *bufmon-warn-test*"))
         (iar--current-agent-name "test-agent")
         (iar-buffer-warn-size 10)
         (iar-buffer-hard-cap nil)
         (warnings nil))
    (unwind-protect
        (progn
          (with-current-buffer test-buf
            (insert "This is more than 10 characters"))
          (cl-letf (((symbol-function 'iar--buffer-monitor-log)
                     (lambda (_buf)
                       (list :bytes 50 :chars 50 :tokens 12 :model "test")))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (when (string-match-p "WARNING" fmt)
                        (push (apply #'format fmt args) warnings)))))
            (iar--buffer-monitor-pre-send)
            (should (car warnings))
            (should (string-match-p "WARNING" (car warnings)))))
      (when (buffer-live-p test-buf)
        (kill-buffer test-buf)))))

(ert-deftest test-buffer-monitor-no-warn-under-threshold ()
  "No warning when buffer is under threshold."
  (let* ((test-buf (get-buffer-create " *bufmon-nowarn-test*"))
         (iar--current-agent-name "test-agent")
         (iar-buffer-warn-size 10000)
         (iar-buffer-hard-cap nil)
         (warnings nil))
    (unwind-protect
        (progn
          (with-current-buffer test-buf
            (insert "small"))
          (cl-letf (((symbol-function 'iar--buffer-monitor-log)
                     (lambda (buf)
                       (list :bytes (buffer-size buf)
                             :chars (with-current-buffer buf (point-max))
                             :tokens 1 :model "test")))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (when (string-match-p "WARNING" fmt)
                        (push (apply #'format fmt args) warnings)))))
            (iar--buffer-monitor-pre-send)
            (should-not warnings)))
      (when (buffer-live-p test-buf)
        (kill-buffer test-buf)))))

(ert-deftest test-buffer-monitor-hard-cap-aborts ()
  "Hard cap should signal an error when buffer exceeds cap."
  (let* ((test-buf (get-buffer-create " *bufmon-cap-test*"))
         (iar--current-agent-name "test-agent")
         (iar-buffer-warn-size nil)
         (iar-buffer-hard-cap 10))
    (unwind-protect
        (progn
          (with-current-buffer test-buf
            (insert "This is way more than 10 characters for sure"))
          (cl-letf (((symbol-function 'iar--buffer-monitor-log)
                     (lambda (_buf)
                       (list :bytes 50 :chars 50 :tokens 12 :model "test"))))
            (should-error (iar--buffer-monitor-pre-send)
                          :type 'error)))
      (when (buffer-live-p test-buf)
        (kill-buffer test-buf)))))

(ert-deftest test-buffer-monitor-hard-cap-disabled ()
  "No error when hard cap is nil (disabled) even with large buffer."
  (let* ((test-buf (get-buffer-create " *bufmon-nocap-test*"))
         (iar--current-agent-name "test-agent")
         (iar-buffer-warn-size nil)
         (iar-buffer-hard-cap nil))
    (unwind-protect
        (progn
          (with-current-buffer test-buf
            (insert (make-string 100000 ?x)))
          (cl-letf (((symbol-function 'iar--buffer-monitor-log)
                     (lambda (buf)
                       (list :bytes (buffer-size buf)
                             :chars (with-current-buffer buf (point-max))
                             :tokens 25000 :model "test"))))
            (iar--buffer-monitor-pre-send)))
      (when (buffer-live-p test-buf)
        (kill-buffer test-buf)))))