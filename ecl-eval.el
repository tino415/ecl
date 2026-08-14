;;; ecl-eval.el --- Human-approved elisp evaluation for ecl -*- lexical-binding: t; -*-

;; Author: Martin Cernak
;; URL: https://github.com/tino415/ecl
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; `ecl eval' lets a shell caller -- primarily a coding agent -- run
;; elisp in this daemon, with the code shown to a human first:
;;
;;   printf '(buffer-list)' | ecl eval
;;   ecl eval '(emacs-version)'
;;
;; The code lands in an `ecl-eval-mode' buffer (plain emacs-lisp-mode
;; underneath, so it is font-locked, indented and editable).  C-c C-c
;; evaluates *the buffer as it stands* -- fixing a near-miss and running
;; it is one keystroke away -- and C-c C-k denies with a reason that
;; travels back to the caller.  Killing the buffer denies too, so a
;; waiting client can always be dismissed by closing the window.
;;
;; Nothing runs unattended: there is no timeout and no auto-approval.
;; The client blocks meanwhile, but the daemon does not -- the dispatch
;; returns immediately via `ecl-pending-start' and the client polls.
;;
;; Register it from your init:
;;   (use-package ecl-eval
;;     :after ecl
;;     :config (ecl-register ecl-eval-command))

;;; Code:

(require 'ecl)
(require 'pp)

(defvar-local ecl-eval--id nil
  "Id of the pending ecl request this buffer decides.")

(defvar-local ecl-eval--decided nil
  "Non-nil once this buffer has answered, so killing it stays quiet.")

(define-derived-mode ecl-eval-mode emacs-lisp-mode "ecl-eval"
  "Review buffer for elisp an ecl client asked this daemon to run.
The buffer is deliberately editable: \\[ecl-eval-approve] evaluates
whatever it contains at that moment, not what was received.
\\[ecl-eval-deny] denies with a reason.

\\{ecl-eval-mode-map}")

;; Bound after the mode definition so re-loading this file re-applies them.
(define-key ecl-eval-mode-map (kbd "C-c C-c") #'ecl-eval-approve)
(define-key ecl-eval-mode-map (kbd "C-c C-k") #'ecl-eval-deny)

;;; Evaluation

(defun ecl-eval--forms (code)
  "Read every top-level form in CODE, in order.
Signals if CODE is unbalanced, rather than silently evaluating the
prefix that happened to parse."
  (with-temp-buffer
    (insert code)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (check-parens)
    (goto-char (point-min))
    (let ((forms nil))
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil))
      (nreverse forms))))

(defun ecl-eval--section (text)
  "Format captured output TEXT as a trailing section, or \"\" if empty."
  (if (string-empty-p text) "" (concat "\n--- messages ---\n" text)))

(defun ecl-eval--evaluate (code)
  "Evaluate CODE and return a dispatch tuple for the waiting client.
On success (ecl-ok TEXT) with the pp-printed value of the last form
plus anything the code sent to `message' or `standard-output'; on
failure (ecl-error error MSG), keeping whatever it managed to print."
  (let* ((log (messages-buffer))
         (mark (with-current-buffer log (point-max)))
         (output (generate-new-buffer " *ecl-eval-output*"))
         (value nil)
         (err nil))
    (unwind-protect
        (progn
          (condition-case e
              (let ((standard-output output))
                (dolist (form (ecl-eval--forms code))
                  (setq value (eval form t))))
            (error (setq err e)))
          (let* ((printed (with-current-buffer output (buffer-string)))
                 (logged (with-current-buffer log
                           (buffer-substring-no-properties
                            (min mark (point-max)) (point-max))))
                 (extra (string-trim (concat printed logged))))
            (if err
                (list 'ecl-error 'error
                      (concat "elisp error: " (error-message-string err)
                              (ecl-eval--section extra)))
              (list 'ecl-ok (concat "=> " (string-trim-right (pp-to-string value))
                                    (ecl-eval--section extra))))))
      (kill-buffer output))))

;;; The review buffer

(defun ecl-eval--header ()
  (substitute-command-keys
   (format " ecl eval %s in %s   \\[ecl-eval-approve] run buffer   \\[ecl-eval-deny] deny"
           ecl-eval--id (abbreviate-file-name default-directory))))

(defun ecl-eval--killed ()
  "Deny the pending request when its buffer goes away undecided."
  (when (and ecl-eval--id (not ecl-eval--decided))
    (ecl-pending-resolve ecl-eval--id
                         (list 'ecl-error 'denied "approval buffer killed"))))

(defun ecl-eval--discard (buffer)
  "Kill BUFFER without answering -- the client is already gone."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (setq ecl-eval--decided t))
    (kill-buffer buffer)))

(defun ecl-eval--review (code directory)
  "Show CODE for approval and return the pending marker for the client.
DIRECTORY is the client's working directory; the buffer -- and hence
the evaluation -- runs there."
  (ecl-pending-start
   (lambda (id)
     (let ((buffer (generate-new-buffer (format "*ecl eval %s*" id))))
       (with-current-buffer buffer
         (insert code)
         (unless (bolp) (insert "\n"))
         (ecl-eval-mode)
         (setq ecl-eval--id id)
         (when (and directory (file-directory-p directory))
           (setq default-directory (file-name-as-directory directory)))
         (ignore-errors (indent-region (point-min) (point-max)))
         (set-buffer-modified-p nil)
         (setq header-line-format (ecl-eval--header))
         (goto-char (point-min))
         (add-hook 'kill-buffer-hook #'ecl-eval--killed nil t))
       ;; Put it where a human can see it, without stealing their point.
       (let ((frame (ecl--user-frame)))
         (with-selected-frame frame
           (raise-frame frame)
           (display-buffer buffer '(display-buffer-pop-up-window))))
       (lambda () (ecl-eval--discard buffer))))))

(defun ecl-eval--buffers ()
  "List of live review buffers still awaiting a decision."
  (seq-filter (lambda (b)
                (with-current-buffer b
                  (and (derived-mode-p 'ecl-eval-mode)
                       ecl-eval--id
                       (not ecl-eval--decided))))
              (buffer-list)))

;;; Commands

(defun ecl-eval-approve ()
  "Evaluate this buffer and hand the result to the waiting ecl client."
  (interactive)
  (unless (derived-mode-p 'ecl-eval-mode)
    (user-error "Not an ecl eval buffer"))
  (let ((id ecl-eval--id)
        (result (ecl-eval--evaluate
                 (buffer-substring-no-properties (point-min) (point-max)))))
    (setq ecl-eval--decided t)
    (ecl-pending-resolve id result)
    (kill-buffer)))

(defun ecl-eval-deny (reason)
  "Deny this request with REASON, which is reported to the ecl client."
  (interactive (list (read-string "Deny reason: ")))
  (unless (derived-mode-p 'ecl-eval-mode)
    (user-error "Not an ecl eval buffer"))
  (setq ecl-eval--decided t)
  (ecl-pending-resolve ecl-eval--id
                       (list 'ecl-error 'denied
                             (if (string-blank-p reason)
                                 "denied"
                               (concat "denied: " (string-trim reason)))))
  (kill-buffer))

;;; Registration

(defconst ecl-eval-command
  `("eval" :stdin optional
    :usage "[CODE...]"
    :fn ,(lambda (&rest args)
           "Evaluate elisp in this daemon, once a human approves it.
Code comes from stdin, or from the arguments when it is a one-liner.
It is shown in an Emacs buffer that the user can edit before running;
the call blocks until they approve (C-c C-c) or deny (C-c C-k), with
no timeout.  Prints the pp-printed value of the last form, followed by
a `--- messages ---' section with anything the code printed or
messaged.  Exit 3 means denied (the reason is on stderr), exit 2 an
error while evaluating.

This is the daemon's own elisp -- to evaluate in a project's REPL use
`ecl project server eval' instead."
           (let ((code (if (and ecl-stdin (not (string-blank-p ecl-stdin)))
                           ecl-stdin
                         (string-join args " "))))
             (when (string-blank-p code)
               (error "usage: ecl eval [CODE...] (or pipe the code in)"))
             (ecl-eval--review code ecl-directory))))
  "ecl entry for `eval'.  Register it with `ecl-register'.")

(provide 'ecl-eval)
;;; ecl-eval.el ends here
