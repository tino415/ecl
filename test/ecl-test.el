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
