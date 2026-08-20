;;; ecl-browse-test.el --- ERT suite for ecl browse-url -*- lexical-binding: t; -*-

;;; Commentary:
;; In-process tests: `ecl-dispatch' with `browse-url' stubbed, so the
;; assertions are about what the daemon would have opened -- and about
;; the confirmation standing between the caller and that.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecl)
(require 'ecl-browse)

(defvar ecl-browse-test--opened nil
  "URL the stubbed `browse-url' was last handed.")

(defmacro ecl-browse-test--with-stubs (&rest body)
  "Run BODY with `browse-url' recorded and confirmation answered yes."
  `(let ((ecl-commands (list ecl-browse-command))
         (ecl-browse-test--opened nil))
     (cl-letf (((symbol-function 'browse-url)
                (lambda (url &rest _) (setq ecl-browse-test--opened url)))
               ((symbol-function 'ecl--confirm) #'ignore))
       ,@body)))

;;; Targets

(ert-deftest ecl-browse-test-url-is-passed-through ()
  (ecl-browse-test--with-stubs
   (should (equal (ecl-dispatch '("browse-url" "https://example.org/x?a=1"))
                  '(ecl-ok "browsing https://example.org/x?a=1")))
   (should (equal ecl-browse-test--opened "https://example.org/x?a=1"))))

(ert-deftest ecl-browse-test-non-http-scheme-is-passed-through ()
  "The scheme check is a check for a scheme, not an allowlist of two."
  (ecl-browse-test--with-stubs
   (should (equal (ecl-dispatch '("browse-url" "mailto:someone@example.org"))
                  '(ecl-ok "browsing mailto:someone@example.org")))))

(ert-deftest ecl-browse-test-bare-path-is-an-error ()
  (ecl-browse-test--with-stubs
   (pcase (ecl-dispatch '("browse-url" "report.html") nil
                        temporary-file-directory)
     (`(ecl-error error ,msg) (should (string-search "no scheme" msg)))
     (other (ert-fail (format "unexpected: %S" other))))
   (should-not ecl-browse-test--opened)))

;;; Confirmation

(ert-deftest ecl-browse-test-asks-in-emacs-with-the-target ()
  (let ((ecl-commands (list ecl-browse-command))
        (ecl-browse-test--opened nil)
        (asked nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _) (setq ecl-browse-test--opened url)))
              ((symbol-function 'ecl--confirm)
               (lambda (path args) (setq asked (append path args)))))
      (ecl-dispatch '("browse-url" "https://example.org/"))
      (should (equal asked '("browse-url" "https://example.org/")))
      (should ecl-browse-test--opened))))

(ert-deftest ecl-browse-test-denial-opens-nothing ()
  (let ((ecl-commands (list ecl-browse-command))
        (ecl-browse-test--opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url &rest _) (setq ecl-browse-test--opened url)))
              ((symbol-function 'ecl--confirm)
               (lambda (_path _args) (signal 'ecl-denied '("denied in Emacs")))))
      (pcase (ecl-dispatch '("browse-url" "https://example.org/"))
        (`(ecl-error denied ,_) t)
        (other (ert-fail (format "unexpected: %S" other))))
      (should-not ecl-browse-test--opened))))

;;; Help

(ert-deftest ecl-browse-test-help-announces-the-prompt ()
  (let ((ecl-commands (list ecl-browse-command)))
    (pcase (ecl-dispatch '("browse-url" "--help"))
      (`(ecl-help ,text)
       (should (string-search "usage: ecl browse-url URL" text))
       (should (string-search "asks for confirmation in Emacs" text)))
      (other (ert-fail (format "unexpected: %S" other))))))

;;; Reload

(ert-deftest ecl-browse-test-reload-rebuilds-the-command-entry ()
  "Re-loading the module must rebuild its entry, not keep the bound one."
  (setq ecl-browse-command '("browse-url" :fn ignore))
  (load "ecl-browse" nil t)
  (should-not (equal ecl-browse-command '("browse-url" :fn ignore)))
  (should (equal (car ecl-browse-command) "browse-url"))
  (should (functionp (plist-get (cdr ecl-browse-command) :fn))))

(provide 'ecl-browse-test)
;;; ecl-browse-test.el ends here
