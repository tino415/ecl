;;; ecl.el --- Allowlisted command tree for the ecl shell client -*- lexical-binding: t; -*-

;; Author: Martin Cernak
;; URL: https://github.com/tino415/ecl
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; ecl (the bin/ecl client of this package) lets shell callers --
;; primarily coding agents -- invoke a curated set of functions in this
;; daemon via `server-eval-at'.  Only what is listed in `ecl-commands'
;; is reachable; entries under :confirm ask y-or-n-p in Emacs first.
;;
;; Modules add themselves with `ecl-register' -- idempotent by name, so
;; each module registers its own group from its use-package :config:
;;   (use-package ecl-org
;;     :after ecl
;;     :config (ecl-register ecl-org-command-group))
;;
;; Entry shapes, at top level and inside any :commands list:
;;   (NAME . FN)                                   plain command
;;   (NAME :fn FN [:help STR] [:usage STR] [:confirm t] [:stdin t])
;;                                                 command with options
;;   (NAME [:help STR] [:confirm t] :commands (ENTRY...))   group
;;
;; FN is any callable; its docstring is the default help text and its
;; arglist becomes the usage line (":usage" overrides it -- useful for
;; `&rest' wrappers that parse their own flags).  :confirm on a group
;; applies to every command beneath it.  Commands must return printable
;; data (strings, lists, numbers) -- the value travels back over the
;; server socket as text.
;;
;; A command flagged :stdin reads the client's piped input: the first
;; dispatch answers (ecl-need-stdin), the client slurps stdin and
;; re-dispatches, and the content is available as `ecl-stdin' (with
;; :stdin t, empty input is a usage error before the command runs;
;; with :stdin 'optional empty input is allowed and reaches the
;; command as "").  Commands without the flag never make the client
;; touch stdin, so they cannot block on an open-but-silent descriptor.
;; `ecl-directory' carries the client's working directory for
;; resolving relative file arguments.

;;; Code:

(define-error 'ecl-denied "ecl call denied")

(defvar ecl-confirm-timeout 60
  "Seconds to wait for a y-or-n-p answer before treating it as a denial.")

(defvar ecl-stdin nil
  "Input piped to the ecl client for the current dispatch, or nil.
Bound by `ecl-dispatch'; non-nil and non-empty inside :stdin commands.")

(defvar ecl-directory nil
  "Working directory of the ecl client for the current dispatch, or nil.
Bound by `ecl-dispatch'; use it to resolve relative file arguments.")

(defvar ecl-commands nil
  "Command tree reachable from the ecl shell client.
Nothing is reachable by default; populate it with `ecl-register' (or
set it directly) from your init file.  See the commentary at the top
of ecl.el for the entry shapes.")

(defun ecl-register (entry)
  "Add or replace ENTRY in `ecl-commands', matched by its name (car).
ENTRY is any of the shapes accepted in `ecl-commands' -- (NAME . FN),
\(NAME :fn ...) or a (NAME ... :commands ...) group.  An existing
entry with the same name is replaced in place (so re-evaluating a
module's registration updates the table instead of shadowing it);
otherwise ENTRY is appended, so registration order is listing order.
Returns ENTRY."
  (let ((cell (assoc (car entry) ecl-commands)))
    (if cell
        (setcdr cell (cdr entry))
      (setq ecl-commands (append ecl-commands (list entry)))))
  entry)

(defun ecl--normalize (entry)
  "Return ENTRY as a plist starting with :name."
  (if (keywordp (car-safe (cdr entry)))
      (append (list :name (car entry)) (cdr entry))
    (list :name (car entry) :fn (cdr entry))))

(defun ecl--doc (plist)
  "Help text for PLIST: explicit :help, else the function's docstring."
  (or (plist-get plist :help)
      (let ((fn (plist-get plist :fn)))
        (and fn (documentation fn)))
      ""))

(defun ecl--doc-line (plist)
  (car (split-string (ecl--doc plist) "\n")))

(defun ecl--group-help (plist table path confirm)
  "Index of TABLE at PATH.  PLIST is the group's own entry, nil at root."
  (let ((prefix (if path (concat "ecl " (string-join path " ")) "ecl"))
        (doc (and plist (ecl--doc-line plist)))
        (lines nil))
    (dolist (entry table)
      (let* ((p (ecl--normalize entry))
             (group (plist-get p :commands))
             (name (concat (plist-get p :name) (if group " ..." ""))))
        (push (format "  %-20s %s%s" name (ecl--doc-line p)
                      (if (or confirm (plist-get p :confirm))
                          "  [asks in Emacs]" ""))
              lines)))
    (concat (format "usage: %s <command> [args...]\n" prefix)
            (and doc (not (string-empty-p doc)) (concat doc "\n"))
            "\n" (string-join (nreverse lines) "\n")
            (format "\n\nRun '%s <command> --help' for details.\n" prefix))))

(defun ecl--command-help (plist path confirm)
  (let* ((fn (plist-get plist :fn))
         (usage (or (plist-get plist :usage)
                    (mapconcat (lambda (a)
                                 (if (memq a '(&optional &rest))
                                     (symbol-name a)
                                   (upcase (symbol-name a))))
                               (help-function-arglist fn t) " "))))
    (concat (format "usage: ecl %s%s\n" (string-join path " ")
                    (if (string-empty-p usage) "" (concat " " usage)))
            (pcase (plist-get plist :stdin)
              ('nil "")
              ('optional "optionally reads input from stdin\n")
              (_ "reads its input from stdin\n"))
            (if confirm "asks for confirmation in Emacs before running\n" "")
            "\n" (ecl--doc plist) "\n")))

(defun ecl--confirm (path args)
  "Prompt y-or-n-p in Emacs; signal `ecl-denied' unless answered y in time."
  (let ((prompt (format "ecl: allow `%s'? "
                        (string-join (append path args) " "))))
    (unless (with-timeout (ecl-confirm-timeout nil)
              ;; Prefer a GUI frame; force a minibuffer prompt (no dialog).
              (let ((frame (or (seq-find (lambda (f) (frame-parameter f 'window-system))
                                         (frame-list))
                               (selected-frame)))
                    (last-nonmenu-event t))
                (with-selected-frame frame
                  (raise-frame frame)
                  (condition-case nil (y-or-n-p prompt) (quit nil)))))
      (signal 'ecl-denied (list "denied or timed out in Emacs")))))

(defun ecl--run (plist args path confirm)
  (if (member "--help" args)
      (list 'ecl-help (ecl--command-help plist path confirm))
    (let* ((fn (plist-get plist :fn))
           (arity (func-arity fn))
           (n (length args)))
      (cond
       ((or (< n (car arity))
            (and (numberp (cdr arity)) (> n (cdr arity))))
        (list 'ecl-error 'usage (ecl--command-help plist path confirm)))
       ;; Ask the client for stdin before confirming, so a confirmed
       ;; command is only ever confirmed once (on the re-dispatch).
       ((and (plist-get plist :stdin) (null ecl-stdin))
        (list 'ecl-need-stdin))
       ((and (eq (plist-get plist :stdin) t) (string-empty-p ecl-stdin))
        (list 'ecl-error 'usage (ecl--command-help plist path confirm)))
       (t
        (when confirm (ecl--confirm path args))
        (list 'ecl-ok (apply fn args)))))))

(defun ecl--dispatch (table args path confirm)
  "Resolve ARGS in TABLE.  PATH is consumed tokens, CONFIRM inherited."
  (let ((entry (assoc (car args) table)))
    (if (null entry)
        (list 'ecl-error 'unknown
              (format "unknown command: %s (see: ecl %s--help)"
                      (string-join (append path (list (car args))) " ")
                      (if path (concat (string-join path " ") " ") "")))
      (let* ((plist (ecl--normalize entry))
             (confirm (or confirm (plist-get plist :confirm)))
             (sub (plist-get plist :commands))
             (path (append path (list (car args))))
             (rest (cdr args)))
        (cond
         ((null sub) (ecl--run plist rest path confirm))
         ((null rest)
          (list 'ecl-error 'usage (ecl--group-help plist sub path confirm)))
         ((equal (car rest) "--help")
          (list 'ecl-help (ecl--group-help plist sub path confirm)))
         (t (ecl--dispatch sub rest path confirm)))))))

(defun ecl-dispatch (args &optional stdin directory)
  "Entry point for the ecl client.  ARGS is the shell argv as strings.
STDIN is input piped to the client (nil when none), DIRECTORY its cwd;
both are exposed to commands as `ecl-stdin' and `ecl-directory'.
Never signals; returns (ecl-ok VALUE), (ecl-help TEXT) or
\(ecl-error KIND MESSAGE)."
  (let ((ecl-stdin stdin)
        (ecl-directory directory))
    (condition-case err
        (cond
         ((null args)
          (list 'ecl-error 'usage (ecl--group-help nil ecl-commands nil nil)))
         ((equal (car args) "--help")
          (list 'ecl-help (ecl--group-help nil ecl-commands nil nil)))
         (t (ecl--dispatch ecl-commands args nil nil)))
      (ecl-denied (list 'ecl-error 'denied (cadr err)))
      (error (list 'ecl-error 'error (error-message-string err))))))

(provide 'ecl)
;;; ecl.el ends here
