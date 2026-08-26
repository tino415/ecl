;;; ecl-test.el --- ERT suite for the ecl framework -*- lexical-binding: t; -*-

;;; Commentary:
;; In-process tests of dispatch, help, arity, stdin handshake, confirm
;; and `ecl-register'.  No daemon involved: `ecl-dispatch' is called
;; directly with a fixture command table.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecl)

(defmacro ecl-test--with-table (&rest body)
  "Run BODY with `ecl-commands' bound to the fixture table."
  `(let ((ecl-commands
          `(("hi" . ,(lambda () "Say hi." "hi"))
            ("echo" . ,(lambda (a &optional b) "Echo args." (concat a (or b ""))))
            ("boom" . ,(lambda () "Always errors." (error "kaput")))
            ("danger" :confirm t
             :fn ,(lambda () "Guarded." "done"))
            ("slurp" :stdin t
             :fn ,(lambda () "Return stdin." ecl-stdin))
            ("maybe" :stdin optional
             :fn ,(lambda () "Return stdin length." (number-to-string (length ecl-stdin))))
            ("ask" . ,(lambda ()
                        "Wait for a human."
                        (ecl-pending-start (lambda (_id) #'ignore))))
            ("prompt-y" . ,(lambda ()
                             "Ask y-or-n-p with nobody there."
                             (if (y-or-n-p "well? ") "yes" "no")))
            ("prompt-yes" . ,(lambda ()
                               "Ask yes-or-no-p with nobody there."
                               (if (yes-or-no-p "well? ") "yes" "no")))
            ("wrapped" :usage "[--x] A B"
             :fn ,(lambda (&rest args) "Wrapper." (string-join args ",")))
            ("grp" :help "A group"
             :commands (("sub" . ,(lambda () "Sub." "sub")))))))
     ,@body))

;;; Dispatch basics

(ert-deftest ecl-test-dispatch-ok ()
  (ecl-test--with-table
   (should (equal (ecl-dispatch '("hi")) '(ecl-ok "hi")))))

(ert-deftest ecl-test-dispatch-args ()
  (ecl-test--with-table
   (should (equal (ecl-dispatch '("echo" "a")) '(ecl-ok "a")))
   (should (equal (ecl-dispatch '("echo" "a" "b")) '(ecl-ok "ab")))))

(ert-deftest ecl-test-unknown-command ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("nope"))
     (`(ecl-error unknown ,msg) (should (string-search "nope" msg)))
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-fn-error-becomes-error-tuple ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("boom"))
     (`(ecl-error error ,msg) (should (string-search "kaput" msg)))
     (other (ert-fail (format "unexpected: %S" other))))))

;;; Prompts
;;
;; The daemon is single-threaded: a command that reaches the minibuffer
;; with no human there stops it answering anything at all, and killing
;; the client does not free it.  These pin the trap that turns the
;; question into an error instead.

(ert-deftest ecl-test-y-or-n-p-in-a-command-errors ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("prompt-y"))
     (`(ecl-error error ,msg) (should (string-search "nothing here can answer" msg)))
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-yes-or-no-p-in-a-command-errors ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("prompt-yes"))
     (`(ecl-error error ,msg) (should (string-search "well?" msg)))
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-prompt-trap-is-scoped-to-the-command ()
  "The trap must not leak past the dispatch that installed it."
  (ecl-test--with-table
   (let ((before (symbol-function 'y-or-n-p)))
     (ecl-dispatch '("prompt-y"))
     (should (eq (symbol-function 'y-or-n-p) before)))))

;;; Help

(ert-deftest ecl-test-root-help ()
  (ecl-test--with-table
   (pcase (ecl-dispatch nil)
     (`(ecl-error usage ,text) (should (string-search "usage: ecl" text)))
     (other (ert-fail (format "unexpected: %S" other))))
   (pcase (ecl-dispatch '("--help"))
     (`(ecl-help ,text) (should (string-search "hi" text)))
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-command-help-from-arglist ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("echo" "--help"))
     (`(ecl-help ,text)
      (should (string-search "usage: ecl echo A &optional B" text))
      (should (string-search "Echo args." text)))
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-usage-key-overrides-arglist ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("wrapped" "--help"))
     (`(ecl-help ,text)
      (should (string-search "usage: ecl wrapped [--x] A B" text))
      (should-not (string-search "&rest" text)))
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-group-help-and-dispatch ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("grp"))
     (`(ecl-error usage ,text) (should (string-search "sub" text)))
     (other (ert-fail (format "unexpected: %S" other))))
   (pcase (ecl-dispatch '("grp" "--help"))
     (`(ecl-help ,text) (should (string-search "A group" text)))
     (other (ert-fail (format "unexpected: %S" other))))
   (should (equal (ecl-dispatch '("grp" "sub")) '(ecl-ok "sub")))))

;;; Arity

(ert-deftest ecl-test-arity-errors ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("echo"))
     (`(ecl-error usage ,_) t)
     (other (ert-fail (format "too few: %S" other))))
   (pcase (ecl-dispatch '("echo" "a" "b" "c"))
     (`(ecl-error usage ,_) t)
     (other (ert-fail (format "too many: %S" other))))))

;;; Stdin handshake

(ert-deftest ecl-test-stdin-handshake ()
  (ecl-test--with-table
   (should (equal (ecl-dispatch '("slurp")) '(ecl-need-stdin)))
   (should (equal (ecl-dispatch '("slurp") "x") '(ecl-ok "x")))))

(ert-deftest ecl-test-stdin-t-rejects-empty ()
  (ecl-test--with-table
   (pcase (ecl-dispatch '("slurp") "")
     (`(ecl-error usage ,_) t)
     (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-stdin-optional-allows-empty ()
  (ecl-test--with-table
   (should (equal (ecl-dispatch '("maybe")) '(ecl-need-stdin)))
   (should (equal (ecl-dispatch '("maybe") "") '(ecl-ok "0")))
   (should (equal (ecl-dispatch '("maybe") "ab") '(ecl-ok "2")))))

;;; Confirm

(ert-deftest ecl-test-confirm-called-and-denial ()
  (ecl-test--with-table
   (let (called)
     (cl-letf (((symbol-function 'ecl--confirm)
                (lambda (path args) (setq called (list path args)) nil)))
       (should (equal (ecl-dispatch '("danger")) '(ecl-ok "done")))
       (should (equal called '(("danger") nil)))))
   (cl-letf (((symbol-function 'ecl--confirm)
              (lambda (_path _args)
                (signal 'ecl-denied '("denied or timed out in Emacs")))))
     (pcase (ecl-dispatch '("danger"))
       (`(ecl-error denied ,_) t)
       (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-test-confirm-is-asked-outside-the-prompt-trap ()
  "The one sanctioned question must still reach the user."
  (ecl-test--with-table
   (let ((trapped 'unset))
     (cl-letf (((symbol-function 'ecl--confirm)
                (lambda (_path _args)
                  (setq trapped (eq (symbol-function 'y-or-n-p)
                                    #'ecl--prompt-trap)))))
       (ecl-dispatch '("danger"))
       (should-not trapped)))))

;;; Pending requests

(ert-deftest ecl-test-pending-marker-passes-through-unwrapped ()
  "A command awaiting a human answers the client, not the value printer."
  (ecl-test--with-table
   (let ((ecl--pending (make-hash-table :test 'equal)))
     (pcase (ecl-dispatch '("ask"))
       (`(ecl-pending ,id)
        (should (equal (ecl-poll id) nil))
        (ecl-pending-resolve id '(ecl-ok "decided"))
        (should (equal (ecl-poll id) '(ecl-ok "decided")))
        ;; Reported once, then forgotten.
        (should (equal (ecl-poll id) nil)))
       (other (ert-fail (format "unexpected: %S" other)))))))

(ert-deftest ecl-test-pending-cancel-runs-teardown ()
  (let ((ecl--pending (make-hash-table :test 'equal))
        (torn-down nil))
    (pcase (ecl-pending-start (lambda (_id) (lambda () (setq torn-down t))))
      (`(ecl-pending ,id)
       (ecl-cancel id)
       (should torn-down)
       (should (equal (ecl-poll id) nil)))
      (other (ert-fail (format "unexpected: %S" other))))))

(ert-deftest ecl-test-pending-setup-failure-leaves-no-entry ()
  "A UI that fails to come up must not strand a request in the table."
  (let ((ecl--pending (make-hash-table :test 'equal)))
    (should-error (ecl-pending-start (lambda (_id) (error "no frame"))))
    (should (zerop (hash-table-count ecl--pending)))))

;;; Directory / stdin exposure

(ert-deftest ecl-test-directory-bound ()
  (let ((ecl-commands
         `(("cwd" . ,(lambda () "Client cwd." ecl-directory)))))
    (should (equal (ecl-dispatch '("cwd") nil "/somewhere/")
                   '(ecl-ok "/somewhere/")))))

;;; ecl-register

(ert-deftest ecl-test-register-appends-in-order ()
  (let ((ecl-commands nil))
    (ecl-register '("a" . ignore))
    (ecl-register '("b" . ignore))
    (should (equal (mapcar #'car ecl-commands) '("a" "b")))))

(ert-deftest ecl-test-register-replaces-by-name-in-place ()
  (let ((ecl-commands nil)
        (fn1 (lambda () "One." 1))
        (fn2 (lambda () "Two." 2)))
    (ecl-register (cons "a" fn1))
    (ecl-register '("b" . ignore))
    (ecl-register (cons "a" fn2))
    (should (equal (mapcar #'car ecl-commands) '("a" "b")))
    (should (eq (cdr (assoc "a" ecl-commands)) fn2))))

(ert-deftest ecl-test-register-returns-entry-and-dispatches ()
  (let ((ecl-commands nil))
    (let ((entry `("hello" . ,(lambda () "Hi." "hello!"))))
      (should (eq (ecl-register entry) entry)))
    (should (equal (ecl-dispatch '("hello")) '(ecl-ok "hello!")))))

(provide 'ecl-test)
;;; ecl-test.el ends here
