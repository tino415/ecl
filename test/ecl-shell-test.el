;;; ecl-shell-test.el --- ERT suite for ecl shell -*- lexical-binding: t; -*-

;;; Commentary:
;; In-process tests: no daemon and no client.  The review buffer is
;; driven the way a user would drive it (`ecl-shell-approve',
;; `ecl-shell-deny', kill-buffer) and the verdict read back through
;; `ecl-poll', which is what the client sees.
;;
;; Approved commands really run -- they are `echo' and `exit', and a
;; stubbed `compilation-start' would leave the interesting half (what
;; comes out of the buffer, and when) untested.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecl)
(require 'ecl-shell)

(defun ecl-shell-test--cleanup ()
  "Kill every buffer this suite could have left, processes and all."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*ecl shell " (buffer-name buffer))
      (with-current-buffer buffer
        (setq ecl-shell--decided t)
        (let ((process (get-buffer-process buffer)))
          (when process
            (set-process-query-on-exit-flag process nil)
            (delete-process process))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defmacro ecl-shell-test--with-env (&rest body)
  "Run BODY with `ecl shell' the only command and empty pending/job tables."
  (declare (indent 0))
  `(let ((ecl-commands (list ecl-shell-command-group))
         (ecl--pending (make-hash-table :test 'equal))
         (ecl-shell--jobs (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body)
       (ecl-shell-test--cleanup))))

(defmacro ecl-shell-test--with-request (command &rest body)
  "Dispatch `ecl shell run' on COMMAND, run BODY in the review buffer.
Binds `id' to the pending request id."
  (declare (indent 1))
  `(ecl-shell-test--with-env
     (pcase (ecl-dispatch '("shell" "run") ,command temporary-file-directory)
       (`(ecl-pending ,id)
        (let ((buffer (get-buffer (format "*ecl shell approve %s*" id))))
          (should buffer)
          (should (memq buffer (ecl-shell--review-buffers)))
          (with-current-buffer buffer ,@body)))
       (other (ert-fail (format "expected a pending request, got: %S" other))))))

(defun ecl-shell-test--handle (text)
  "The handle out of the reply `ecl shell run' answers with."
  (car (split-string text "\n")))

(defun ecl-shell-test--start (command)
  "Dispatch COMMAND, approve it unread, and return its handle."
  (pcase (ecl-dispatch '("shell" "run") command temporary-file-directory)
    (`(ecl-pending ,id)
     (with-current-buffer (format "*ecl shell approve %s*" id)
       (ecl-shell-approve))
     (pcase (ecl-poll id)
       (`(ecl-ok ,text) (ecl-shell-test--handle text))
       (other (ert-fail (format "approve did not start it: %S" other)))))
    (other (ert-fail (format "unexpected: %S" other)))))

(defun ecl-shell-test--settle (handle)
  "Run the event loop until HANDLE's command has exited and been noticed."
  (let ((process (plist-get (ecl-shell--job handle) :process)))
    (while (process-live-p process)
      (accept-process-output process 0.05))
    ;; The finish hook runs from the sentinel, which may still be queued.
    (dotimes (_ 5) (accept-process-output nil 0.02))))

;;; The review buffer

(ert-deftest ecl-shell-test-review-shows-the-command-and-the-folder ()
  (ecl-shell-test--with-request "grep -r TODO ."
    (should (derived-mode-p 'sh-mode))
    (should (string-search "grep -r TODO ." (buffer-string)))
    (should (equal default-directory temporary-file-directory))
    (should (string-search "run buffer" header-line-format))
    (should-not (buffer-modified-p))))

(ert-deftest ecl-shell-test-command-from-arguments ()
  (ecl-shell-test--with-env
    (pcase (ecl-dispatch '("shell" "run" "echo" "hi") "" temporary-file-directory)
      (`(ecl-pending ,id)
       (with-current-buffer (format "*ecl shell approve %s*" id)
         (should (string-search "echo hi" (buffer-string)))))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-shell-test-empty-command-is-an-error ()
  (ecl-shell-test--with-env
    (pcase (ecl-dispatch '("shell" "run") "  " temporary-file-directory)
      (`(ecl-error error ,msg) (should (string-search "usage: ecl shell run" msg)))
      (other (ert-fail (format "unexpected: %S" other))))
    (should-not (ecl-shell--review-buffers))))

(ert-deftest ecl-shell-test-without-a-client-directory-nothing-is-offered ()
  "The folder is the client's cwd; with no usable one there is nothing to run in."
  (ecl-shell-test--with-env
    (pcase (ecl-dispatch '("shell" "run") "echo hi" nil)
      (`(ecl-error error ,msg) (should (string-search "working directory" msg)))
      (other (ert-fail (format "unexpected: %S" other))))
    (should-not (ecl-shell--review-buffers))))

;;; Approval

(ert-deftest ecl-shell-test-approve-answers-with-a-handle ()
  (ecl-shell-test--with-request "echo hi"
    (should (equal (ecl-poll id) nil))
    (ecl-shell-approve)
    (pcase (ecl-poll id)
      (`(ecl-ok ,text)
       (let ((handle (ecl-shell-test--handle text)))
         (should (gethash handle ecl-shell--jobs))
         (should (string-search "ecl shell wait" text))))
      (other (ert-fail (format "unexpected: %S" other))))
    ;; Answered once: the entry is gone.
    (should (equal (ecl-poll id) nil))))

(ert-deftest ecl-shell-test-approve-runs-the-edited-buffer ()
  "The point of an editable buffer: a near-miss can be fixed in place."
  (ecl-shell-test--with-request "echo wrong"
    (erase-buffer)
    (insert "echo right")
    (ecl-shell-approve)
    (pcase (ecl-poll id)
      (`(ecl-ok ,text)
       (let ((handle (ecl-shell-test--handle text)))
         (ecl-shell-test--settle handle)
         (should (equal (ecl-dispatch (list "shell" "wait" handle))
                        '(ecl-ok "right\n")))))
      (other (ert-fail (format "unexpected: %S" other))))))

;;; Denial

(ert-deftest ecl-shell-test-deny-with-reason-runs-nothing ()
  (ecl-shell-test--with-request "rm -rf /"
    (ecl-shell-deny "not that one")
    (should (equal (ecl-poll id) '(ecl-error denied "denied: not that one")))
    (should (zerop (hash-table-count ecl-shell--jobs)))))

(ert-deftest ecl-shell-test-deny-without-reason ()
  (ecl-shell-test--with-request "true"
    (ecl-shell-deny "  ")
    (should (equal (ecl-poll id) '(ecl-error denied "denied")))))

(ert-deftest ecl-shell-test-killing-the-buffer-denies ()
  "Closing the window must not leave the client waiting forever."
  (ecl-shell-test--with-request "true"
    (kill-buffer)
    (pcase (ecl-poll id)
      (`(ecl-error denied ,msg) (should (string-search "killed" msg)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-shell-test-cancel-drops-request-and-buffer ()
  "A client that died leaves no review buffer behind."
  (ecl-shell-test--with-request "true"
    (let ((buffer (current-buffer)))
      (ecl-cancel id)
      (should-not (buffer-live-p buffer))
      (should (equal (ecl-poll id) nil))
      (should (zerop (hash-table-count ecl-shell--jobs))))))

;;; Reading a job back

(ert-deftest ecl-shell-test-wait-on-a-finished-job-answers-at-once ()
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "echo hi")))
      (ecl-shell-test--settle handle)
      (should (equal (ecl-dispatch (list "shell" "wait" handle))
                     '(ecl-ok "hi\n"))))))

(ert-deftest ecl-shell-test-wait-on-a-running-job-is-pending ()
  "The daemon answers the client immediately and the sentinel decides later."
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "sleep 0.3; echo late")))
      (pcase (ecl-dispatch (list "shell" "wait" handle))
        (`(ecl-pending ,id)
         (should (equal (ecl-poll id) nil))
         (ecl-shell-test--settle handle)
         (should (equal (ecl-poll id) '(ecl-ok "late\n"))))
        (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-shell-test-two-waits-are-both-answered ()
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "sleep 0.3; echo late")))
      (pcase (list (ecl-dispatch (list "shell" "wait" handle))
                   (ecl-dispatch (list "shell" "wait" handle)))
        (`((ecl-pending ,first) (ecl-pending ,second))
         (ecl-shell-test--settle handle)
         (should (equal (ecl-poll first) '(ecl-ok "late\n")))
         (should (equal (ecl-poll second) '(ecl-ok "late\n"))))
        (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-shell-test-cancelled-wait-leaves-the-command-alone ()
  "Giving up on the output is not giving up on the command."
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "sleep 0.3; echo late")))
      (pcase (ecl-dispatch (list "shell" "wait" handle))
        (`(ecl-pending ,id)
         (ecl-cancel id)
         (ecl-shell-test--settle handle)
         (should (equal (ecl-dispatch (list "shell" "wait" handle))
                        '(ecl-ok "late\n"))))
        (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-shell-test-failure-carries-output-and-exit-status ()
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "echo oops; exit 3")))
      (ecl-shell-test--settle handle)
      (pcase (ecl-dispatch (list "shell" "wait" handle))
        (`(ecl-error error ,msg)
         (should (string-search "oops" msg))
         (should (string-search "exited 3" msg)))
        (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-shell-test-output-does-not-wait ()
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "sleep 5")))
      (should (equal (ecl-dispatch (list "shell" "output" handle))
                     '(ecl-ok ""))))))

(ert-deftest ecl-shell-test-output-from-skips-what-was-read ()
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "printf abcdef")))
      (ecl-shell-test--settle handle)
      (should (equal (ecl-dispatch (list "shell" "output" handle))
                     '(ecl-ok "abcdef")))
      (should (equal (ecl-dispatch (list "shell" "output" handle "--from" "3"))
                     '(ecl-ok "def")))
      (should (equal (ecl-dispatch (list "shell" "output" handle "--from" "99"))
                     '(ecl-ok ""))))))

(ert-deftest ecl-shell-test-output-excludes-compilation-mode-own-lines ()
  "The caller asked for the command's output, not for Emacs commentary."
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "echo hi")))
      (ecl-shell-test--settle handle)
      (pcase (ecl-dispatch (list "shell" "output" handle))
        (`(ecl-ok ,text)
         (should (equal text "hi\n"))
         (should-not (string-search "mode: compilation" text))
         (should-not (string-search "Compilation" text)))
        (other (ert-fail (format "unexpected: %S" other)))))))

;;; Reach

(ert-deftest ecl-shell-test-an-unknown-handle-reaches-nothing ()
  "The handle is the containment: there is no way to name another buffer."
  (ecl-shell-test--with-env
    (dolist (args '(("shell" "wait" "nope")
                    ("shell" "output" "nope")
                    ("shell" "kill" "nope")))
      (pcase (ecl-dispatch args)
        (`(ecl-error error ,msg)
         (should (string-search "No such shell job" msg)))
        (other (ert-fail (format "%S: unexpected %S" args other)))))))

(ert-deftest ecl-shell-test-list-covers-what-was-started ()
  (ecl-shell-test--with-env
    (should (equal (ecl-dispatch '("shell" "list")) '(ecl-ok "no shell jobs")))
    (let ((handle (ecl-shell-test--start "echo hi")))
      (pcase (ecl-dispatch '("shell" "list"))
        (`(ecl-ok (,line)) (should (string-prefix-p handle line))
         (should (string-search "echo hi" line)))
        (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-shell-test-kill-stops-a-running-job ()
  (ecl-shell-test--with-env
    (let ((handle (ecl-shell-test--start "sleep 30")))
      (pcase (ecl-dispatch (list "shell" "kill" handle))
        (`(ecl-ok ,msg) (should (string-search handle msg)))
        (other (ert-fail (format "unexpected: %S" other))))
      (ecl-shell-test--settle handle)
      (should-not (process-live-p (plist-get (ecl-shell--job handle) :process))))))

;;; Help

(ert-deftest ecl-shell-test-help-announces-the-approval ()
  (ecl-shell-test--with-env
    (pcase (ecl-dispatch '("shell" "run" "--help"))
      (`(ecl-help ,text)
       (should (string-search "usage: ecl shell run [COMMAND...]" text))
       (should (string-search "optionally reads input from stdin" text))
       (should (string-search "approve" text)))
      (other (ert-fail (format "unexpected: %S" other))))
    (pcase (ecl-dispatch '("shell" "--help"))
      (`(ecl-help ,text)
       (dolist (name '("run" "wait" "output" "list" "kill"))
         (should (string-search name text))))
      (other (ert-fail (format "unexpected: %S" other))))))

;;; Reload

(ert-deftest ecl-shell-test-reload-rebuilds-the-command-entry ()
  "Re-loading the module must rebuild its entry, not keep the bound one."
  (setq ecl-shell-command-group '("shell" :fn ignore))
  (load "ecl-shell" nil t)
  (should-not (equal ecl-shell-command-group '("shell" :fn ignore)))
  (should (equal (car ecl-shell-command-group) "shell"))
  (should (plist-get (cdr ecl-shell-command-group) :commands)))

(provide 'ecl-shell-test)
;;; ecl-shell-test.el ends here
