;;; ecl-eval-test.el --- ERT suite for ecl eval -*- lexical-binding: t; -*-

;;; Commentary:
;; In-process tests of the approval buffer: no daemon and no client, the
;; review buffer is driven the way a user would drive it (`ecl-eval-approve',
;; `ecl-eval-deny', kill-buffer) and the verdict is read back through
;; `ecl-poll', which is what the client sees.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecl)
(require 'ecl-eval)

(defvar ecl-eval-test--ran nil
  "Flag set from evaluated fixture code, to prove what did or did not run.")

(defmacro ecl-eval-test--with-request (code &rest body)
  "Dispatch `ecl eval' on CODE and run BODY with the review buffer current.
Binds `id' to the pending request id.  The buffer is killed afterwards."
  (declare (indent 1))
  `(let ((ecl-commands (list ecl-eval-command))
         (ecl--pending (make-hash-table :test 'equal)))
     (pcase (ecl-dispatch '("eval") ,code default-directory)
       (`(ecl-pending ,id)
        (let ((buffer (get-buffer (format "*ecl eval %s*" id))))
          (should buffer)
          (should (memq buffer (ecl-eval--buffers)))
          (unwind-protect
              (with-current-buffer buffer ,@body)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (setq ecl-eval--decided t))
              (kill-buffer buffer)))))
       (other (ert-fail (format "expected a pending request, got: %S" other))))))

;;; Dispatch shape

(ert-deftest ecl-eval-test-dispatch-is-pending-then-polls ()
  "The client is answered immediately and polls until a decision."
  (ecl-eval-test--with-request "(+ 1 2)"
    (should (equal (ecl-poll id) nil))
    (ecl-eval-approve)
    (pcase (ecl-poll id)
      (`(ecl-ok ,text) (should (equal text "=> 3")))
      (other (ert-fail (format "unexpected: %S" other))))
    ;; Answered once: the entry is gone.
    (should (equal (ecl-poll id) nil))))

(ert-deftest ecl-eval-test-code-from-arguments ()
  (let ((ecl-commands (list ecl-eval-command))
        (ecl--pending (make-hash-table :test 'equal)))
    (pcase (ecl-dispatch '("eval" "(+" "2" "3)") "" default-directory)
      (`(ecl-pending ,id)
       (with-current-buffer (format "*ecl eval %s*" id) (ecl-eval-approve))
       (should (equal (ecl-poll id) '(ecl-ok "=> 5"))))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-empty-code-is-an-error ()
  (let ((ecl-commands (list ecl-eval-command)))
    (pcase (ecl-dispatch '("eval") "" default-directory)
      (`(ecl-error error ,msg) (should (string-search "usage: ecl eval" msg)))
      (other (ert-fail (format "unexpected: %S" other))))
    (should-not (ecl-eval--buffers))))

;;; Approval

(ert-deftest ecl-eval-test-approve-captures-messages ()
  (ecl-eval-test--with-request "(message \"side effect\")\n42"
    (ecl-eval-approve)
    (pcase (ecl-poll id)
      (`(ecl-ok ,text)
       (should (string-prefix-p "=> 42" text))
       (should (string-search "--- messages ---" text))
       (should (string-search "side effect" text)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-approve-captures-standard-output ()
  (ecl-eval-test--with-request "(princ \"printed\")"
    (ecl-eval-approve)
    (pcase (ecl-poll id)
      (`(ecl-ok ,text) (should (string-search "printed" text)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-no-messages-section-when-silent ()
  (ecl-eval-test--with-request "(list 1 2)"
    (ecl-eval-approve)
    (should (equal (ecl-poll id) '(ecl-ok "=> (1 2)")))))

(ert-deftest ecl-eval-test-approve-runs-the-edited-buffer ()
  "The point of an editable buffer: a near-miss can be fixed in place."
  (ecl-eval-test--with-request "(+ 1 2)"
    (erase-buffer)
    (insert "(* 6 7)")
    (ecl-eval-approve)
    (should (equal (ecl-poll id) '(ecl-ok "=> 42")))))

;;; Failure paths

(ert-deftest ecl-eval-test-error-is-reported-with-exit-2-kind ()
  (ecl-eval-test--with-request "(error \"kaput\")"
    (ecl-eval-approve)
    (pcase (ecl-poll id)
      (`(ecl-error error ,msg) (should (string-search "kaput" msg)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-error-keeps-earlier-messages ()
  (ecl-eval-test--with-request "(message \"got here\")\n(error \"then kaput\")"
    (ecl-eval-approve)
    (pcase (ecl-poll id)
      (`(ecl-error error ,msg)
       (should (string-search "then kaput" msg))
       (should (string-search "got here" msg)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-unbalanced-code-does-not-run-its-prefix ()
  (ecl-eval-test--with-request "(setq ecl-eval-test--ran t) (list 1"
    (setq ecl-eval-test--ran nil)
    (ecl-eval-approve)
    (pcase (ecl-poll id)
      (`(ecl-error error ,_) (should-not ecl-eval-test--ran))
      (other (ert-fail (format "unexpected: %S" other))))))

;;; Denial

(ert-deftest ecl-eval-test-deny-with-reason ()
  (ecl-eval-test--with-request "(delete-file \"/etc/passwd\")"
    (ecl-eval-deny "use org-tools instead")
    (pcase (ecl-poll id)
      (`(ecl-error denied ,msg)
       (should (equal msg "denied: use org-tools instead")))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-deny-without-reason ()
  (ecl-eval-test--with-request "(ignore)"
    (ecl-eval-deny "  ")
    (should (equal (ecl-poll id) '(ecl-error denied "denied")))))

(ert-deftest ecl-eval-test-killing-the-buffer-denies ()
  "Closing the window must not leave the client waiting forever."
  (ecl-eval-test--with-request "(ignore)"
    (kill-buffer)
    (pcase (ecl-poll id)
      (`(ecl-error denied ,msg) (should (string-search "killed" msg)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-eval-test-cancel-drops-request-and-buffer ()
  "A client that died leaves no review buffer behind."
  (ecl-eval-test--with-request "(ignore)"
    (let ((buffer (current-buffer)))
      (ecl-cancel id)
      (should-not (buffer-live-p buffer))
      (should (equal (ecl-poll id) nil)))))

(ert-deftest ecl-eval-test-decision-after-cancel-is-harmless ()
  (let ((ecl--pending (make-hash-table :test 'equal)))
    (ecl-pending-resolve "no-such-id" '(ecl-ok "ignored"))
    (should (equal (ecl-poll "no-such-id") nil))
    (should (equal (ecl-cancel "no-such-id") nil))))

;;; Buffer presentation

(ert-deftest ecl-eval-test-buffer-is-lisp-and-shows-the-code ()
  (ecl-eval-test--with-request "(let ((x 1))\n(list x))"
    (should (derived-mode-p 'emacs-lisp-mode))
    (should (string-search "(list x)" (buffer-string)))
    (should (string-search "run buffer" header-line-format))
    ;; Indented on arrival, but not marked modified.
    (should-not (buffer-modified-p))))

(provide 'ecl-eval-test)
;;; ecl-eval-test.el ends here
