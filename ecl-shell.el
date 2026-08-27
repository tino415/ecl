;;; ecl-shell.el --- Human-approved shell commands for ecl -*- lexical-binding: t; -*-

;; Author: Martin Cernak
;; URL: https://github.com/tino415/ecl
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; `ecl shell' lets a shell caller -- primarily a coding agent -- run a
;; command in its own working directory, with the script shown to a
;; human first:
;;
;;   printf 'mix test --only integration' | ecl shell run
;;   # 3
;;   # read it back with: ecl shell wait 3
;;
;; The script lands in an `ecl-shell-mode' buffer (plain sh-mode
;; underneath, so it is font-locked and editable) with the folder it
;; would run in on the header line.  C-c C-c runs *the buffer as it
;; stands*, C-c C-k denies with a reason, killing the buffer denies too.
;;
;; Approval answers with a handle, not with output: the command runs
;; asynchronously in a compilation buffer the human can watch, and the
;; caller reads it back through that handle -- `output' for what has
;; been printed so far, `wait' for the whole of it plus the exit status.
;; The handle is the only way in, so a caller reaches the commands it
;; started and no other buffer in this Emacs.
;;
;; Nothing here has a timeout: the caller gave up when it interrupts the
;; client, and interrupting a `wait' abandons the reading, not the
;; command.  `ecl shell kill' is how you stop the command itself.
;;
;; Register it from your init:
;;   (use-package ecl-shell
;;     :after ecl
;;     :config (ecl-register ecl-shell-command-group))

;;; Code:

(require 'ecl)
(require 'compile)
(require 'sh-script)

(defvar-local ecl-shell--id nil
  "Id of the pending ecl request this buffer decides.")

(defvar-local ecl-shell--decided nil
  "Non-nil once this buffer has answered, so killing it stays quiet.")

(define-derived-mode ecl-shell-mode sh-mode "ecl-shell"
  "Review buffer for a command an ecl client asked this daemon to run.
The buffer is deliberately editable: \\[ecl-shell-approve] runs
whatever it contains at that moment, not what was received, in the
folder named on the header line.  \\[ecl-shell-deny] denies with a
reason.

\\{ecl-shell-mode-map}")

;; Bound after the mode definition so re-loading this file re-applies them.
(define-key ecl-shell-mode-map (kbd "C-c C-c") #'ecl-shell-approve)
(define-key ecl-shell-mode-map (kbd "C-c C-k") #'ecl-shell-deny)

;;; Jobs

(defvar ecl-shell--jobs (make-hash-table :test 'equal)
  "Commands started through `ecl shell run', keyed by handle.
Each value is a plist with :buffer, :process, :command, :directory,
:start (a marker before the first byte of output) and :waiting (ids of
pending requests to answer when the command exits).  Nothing outside
this table is addressable from `ecl shell', which is what holds a
caller to the commands it started itself.")

(defvar ecl-shell--counter 0
  "Source of job handles.
A counter, not `random', so tests observe stable handles.")

(defun ecl-shell--job (handle)
  "Job HANDLE, or signal.  An unknown handle is not a readable buffer."
  (or (gethash handle ecl-shell--jobs)
      (error "No such shell job: %s (see: ecl shell list)" handle)))

(defun ecl-shell--status (job)
  "How JOB stands: \"running\", \"exited N\" or \"signal N\"."
  (let ((process (plist-get job :process)))
    (cond ((process-live-p process) "running")
          ((eq (process-status process) 'signal)
           (format "signal %d" (process-exit-status process)))
          (t (format "exited %d" (process-exit-status process))))))

(defun ecl-shell--text (job)
  "What JOB has printed, without `compilation-mode's own lines.
:start sits after the header and the echoed command; the process mark
sits where the next byte of output would go, which is also where
`compilation-handle-exit' inserts its closing line -- insertion at a
marker does not move it, so the mark stays on the near side of both."
  (let ((buffer (plist-get job :buffer)))
    (unless (buffer-live-p buffer)
      (error "Output buffer for this job is gone"))
    (with-current-buffer buffer
      (buffer-substring-no-properties
       (plist-get job :start)
       (process-mark (plist-get job :process))))))

(defun ecl-shell--result (handle)
  "Dispatch tuple for finished job HANDLE: its output, and how it ended.
A non-zero exit is an error, so a failed command fails the ecl call
that was waiting on it rather than looking like a quiet success."
  (let* ((job (ecl-shell--job handle))
         (process (plist-get job :process))
         (output (ecl-shell--text job)))
    (if (and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
        (list 'ecl-ok output)
      (list 'ecl-error 'error
            (concat output
                    (if (or (string-empty-p output)
                            (string-suffix-p "\n" output))
                        ""
                      "\n")
                    (ecl-shell--status job))))))

(defun ecl-shell--answer (handle)
  "Output of finished job HANDLE, signalling when the command failed."
  (pcase (ecl-shell--result handle)
    (`(ecl-ok ,output) output)
    (`(ecl-error ,_ ,message) (error "%s" message))))

;;; Starting a job

(defun ecl-shell--start (command directory)
  "Run COMMAND in DIRECTORY and return the handle to read it back by.
Every job gets a buffer of its own: reusing one would have
`compilation-start' ask whether to kill the process still in it, and a
question raised while a dispatch runs is an error by design -- see
`ecl--without-prompts'."
  (let* ((handle (number-to-string
                  (setq ecl-shell--counter (1+ ecl-shell--counter))))
         (buffer (ecl-shell--compile command directory
                                     (format "*ecl shell %s*" handle)))
         (process (get-buffer-process buffer)))
    (puthash handle
             (list :buffer buffer
                   :process process
                   :command command
                   :directory directory
                   :start (with-current-buffer buffer
                            (copy-marker (process-mark process)))
                   :waiting nil)
             ecl-shell--jobs)
    (with-current-buffer buffer
      (add-hook 'compilation-finish-functions
                (lambda (&rest _) (ecl-shell--finished handle)) nil t)
      (add-hook 'kill-buffer-hook
                (lambda () (remhash handle ecl-shell--jobs)) nil t))
    handle))

(defun ecl-shell--compile (command directory name)
  "Start COMMAND in DIRECTORY as compilation buffer NAME, where a human is.
`compilation-start' would put the buffer up on whichever frame the
dispatch happened to select, so its own display is suppressed and the
buffer shown on `ecl--user-frame' instead."
  (let ((buffer (with-temp-buffer
                  (setq default-directory directory)
                  (let ((display-buffer-overriding-action
                         '(display-buffer-no-window (allow-no-window . t))))
                    (compilation-start command nil (lambda (_mode) name))))))
    (let ((frame (ecl--user-frame)))
      (with-selected-frame frame
        (raise-frame frame)
        (display-buffer buffer '(display-buffer-pop-up-window))))
    buffer))

(defun ecl-shell--finished (handle)
  "Answer everyone waiting on HANDLE, now that its command has exited."
  (let ((job (gethash handle ecl-shell--jobs)))
    (when job
      (let ((result (ecl-shell--result handle)))
        (dolist (id (plist-get job :waiting))
          (ecl-pending-resolve id result)))
      (puthash handle (plist-put job :waiting nil) ecl-shell--jobs))))

;;; Reading a job back

(defun ecl-shell--wait (handle)
  "Answer with HANDLE's result, now or once it exits.
Waiting is a pending request rather than a blocking read: the daemon is
single-threaded, and a command sitting on the process would stop it
answering anything at all, this module's own `output' included."
  (let ((job (ecl-shell--job handle)))
    (if (not (process-live-p (plist-get job :process)))
        (ecl-shell--answer handle)
      (ecl-pending-start
       (lambda (id)
         (ecl-shell--add-waiter handle id)
         ;; Giving up on reading the output is not giving up on the
         ;; command; `ecl shell kill' is that.
         (lambda () (ecl-shell--drop-waiter handle id)))))))

(defun ecl-shell--add-waiter (handle id)
  (let ((job (ecl-shell--job handle)))
    (puthash handle
             (plist-put job :waiting (cons id (plist-get job :waiting)))
             ecl-shell--jobs)))

(defun ecl-shell--drop-waiter (handle id)
  (let ((job (gethash handle ecl-shell--jobs)))
    (when job
      (puthash handle
               (plist-put job :waiting (delete id (plist-get job :waiting)))
               ecl-shell--jobs))))

(defun ecl-shell--tail (handle from)
  "What HANDLE has printed past character FROM of its output."
  (let ((text (ecl-shell--text (ecl-shell--job handle))))
    (cond ((null from) text)
          ((< from (length text)) (substring text from))
          (t ""))))

(defun ecl-shell--summary (handle job)
  (let ((lines (split-string (plist-get job :command) "\n" t)))
    (format "%-4s %-12s %s%s" handle (ecl-shell--status job)
            (car lines) (if (cdr lines) " ..." ""))))

;;; The review buffer

(defun ecl-shell--directory ()
  "The client's working directory -- the only folder `ecl shell' runs in.
There is no flag to point it elsewhere: the caller chooses the folder
by being in it, the same way every other shell tool works."
  (let ((directory ecl-directory))
    (unless (and directory (file-directory-p directory))
      (error "No usable working directory from the client: %s"
             (or directory "none")))
    (file-name-as-directory directory)))

(defun ecl-shell--header ()
  (substitute-command-keys
   (format " ecl shell %s in %s   \\[ecl-shell-approve] run buffer   \\[ecl-shell-deny] deny"
           ecl-shell--id (abbreviate-file-name default-directory))))

(defun ecl-shell--killed ()
  "Deny the pending request when its buffer goes away undecided."
  (when (and ecl-shell--id (not ecl-shell--decided))
    (ecl-pending-resolve ecl-shell--id
                         (list 'ecl-error 'denied "approval buffer killed"))))

(defun ecl-shell--discard (buffer)
  "Kill BUFFER without answering -- the client is already gone."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (setq ecl-shell--decided t))
    (kill-buffer buffer)))

(defun ecl-shell--review (command directory)
  "Show COMMAND for approval and return the pending marker for the client.
DIRECTORY is where it would run, so it is part of what is being
approved and the buffer says so on its header line."
  (ecl-pending-start
   (lambda (id)
     (let ((buffer (generate-new-buffer (format "*ecl shell approve %s*" id))))
       (with-current-buffer buffer
         (insert command)
         (unless (bolp) (insert "\n"))
         ;; sh-mode narrates its indentation setup; the user asked to see
         ;; a command, not how Emacs got ready to show it.
         (let ((inhibit-message t)) (ecl-shell-mode))
         (setq ecl-shell--id id)
         (setq default-directory directory)
         (set-buffer-modified-p nil)
         (setq header-line-format (ecl-shell--header))
         (goto-char (point-min))
         (add-hook 'kill-buffer-hook #'ecl-shell--killed nil t))
       ;; Put it where a human can see it, without stealing their point.
       (let ((frame (ecl--user-frame)))
         (with-selected-frame frame
           (raise-frame frame)
           (display-buffer buffer '(display-buffer-pop-up-window))))
       (lambda () (ecl-shell--discard buffer))))))

(defun ecl-shell--review-buffers ()
  "List of live review buffers still awaiting a decision."
  (seq-filter (lambda (b)
                (with-current-buffer b
                  (and (derived-mode-p 'ecl-shell-mode)
                       ecl-shell--id
                       (not ecl-shell--decided))))
              (buffer-list)))

;;; Commands

(defun ecl-shell-approve ()
  "Run this buffer in its folder and hand the handle to the waiting client."
  (interactive)
  (unless (derived-mode-p 'ecl-shell-mode)
    (user-error "Not an ecl shell buffer"))
  (let ((command (string-trim (buffer-substring-no-properties
                               (point-min) (point-max)))))
    (when (string-empty-p command)
      (user-error "Nothing to run"))
    (let ((id ecl-shell--id)
          (result (condition-case err
                      (let ((handle (ecl-shell--start command default-directory)))
                        (list 'ecl-ok
                              (format "%s\nread it back with: ecl shell wait %s"
                                      handle handle)))
                    (error (list 'ecl-error 'error (error-message-string err))))))
      (setq ecl-shell--decided t)
      (ecl-pending-resolve id result)
      (kill-buffer))))

(defun ecl-shell-deny (reason)
  "Deny this request with REASON, which is reported to the ecl client."
  (interactive (list (read-string "Deny reason: ")))
  (unless (derived-mode-p 'ecl-shell-mode)
    (user-error "Not an ecl shell buffer"))
  (setq ecl-shell--decided t)
  (ecl-pending-resolve ecl-shell--id
                       (list 'ecl-error 'denied
                             (if (string-blank-p reason)
                                 "denied"
                               (concat "denied: " (string-trim reason)))))
  (kill-buffer))

;;; Registration

(defconst ecl-shell-command-group
  `("shell"
    :help "Run a shell command in the caller's folder, after approval in Emacs."
    :commands
    (("run" :stdin optional
      :usage "[COMMAND...]"
      :fn ,(lambda (&rest args)
             "Run a shell command in the client's working directory.
The command comes from stdin, or from the arguments when it is a
one-liner.  It is shown in an Emacs buffer the user can edit before
running; the call blocks until they approve (C-c C-c) or deny (C-c
C-k), with no timeout.  Exit 3 means denied.

Approval prints a handle and returns straight away -- the command runs
in a compilation buffer the user can watch.  Read it back with `ecl
shell wait HANDLE' for the output and exit status, or `ecl shell output
HANDLE' for what it has printed so far."
             (let ((command (if (and ecl-stdin (not (string-blank-p ecl-stdin)))
                                (string-trim ecl-stdin)
                              (string-join args " "))))
               (when (string-blank-p command)
                 (error "usage: ecl shell run [COMMAND...] (or pipe it in)"))
               (ecl-shell--review command (ecl-shell--directory)))))
     ("wait" :usage "HANDLE"
      :fn ,(lambda (handle)
             "Wait for a job to finish and print everything it wrote.
Blocks with no timeout; interrupting the client abandons the reading,
not the command.  Exit 2 means the command failed, with its output and
the exit status on stderr."
             (ecl-shell--wait handle)))
     ("output" :usage "HANDLE [--from N]"
      :fn ,(lambda (&rest args)
             "Print what a job has written so far, without waiting for it.
--from N skips the first N characters, so a long-running command can be
tailed by passing back the length already read."
             (let ((handle nil) (from nil))
               (while args
                 (let ((arg (pop args)))
                   (cond ((equal arg "--from")
                          (setq from (string-to-number
                                      (or (pop args)
                                          (error "--from needs a number")))))
                         ((null handle) (setq handle arg))
                         (t (error "Unexpected argument: %s" arg)))))
               (unless handle
                 (error "usage: ecl shell output HANDLE [--from N]"))
               (ecl-shell--tail handle from))))
     ("list"
      :fn ,(lambda ()
             "List the jobs started through `ecl shell run': handle, status, command.
A job is listed until its output buffer is killed."
             (let ((lines nil))
               (maphash (lambda (handle job)
                          (push (ecl-shell--summary handle job) lines))
                        ecl-shell--jobs)
               (or (sort lines #'string<) "no shell jobs"))))
     ("kill" :usage "HANDLE"
      :fn ,(lambda (handle)
             "Interrupt a running job.  Its output stays readable afterwards."
             (let ((job (ecl-shell--job handle)))
               (if (not (process-live-p (plist-get job :process)))
                   (format "job %s already %s" handle (ecl-shell--status job))
                 (interrupt-process (plist-get job :process))
                 (format "interrupted job %s" handle)))))))
  "ecl entry for `shell'.  Register it with `ecl-register'.")

(provide 'ecl-shell)
;;; ecl-shell.el ends here
