;;; ecl-org-test.el --- ERT suite for the ecl org module -*- lexical-binding: t; -*-

;;; Commentary:
;; In-process tests of the org handlers and their helpers against temp
;; org files.  The shell surface (client, socket, exit codes) is covered
;; by test/e2e.sh instead.

;;; Code:

(require 'ert)
(require 'ecl-org)

(defvar ecl-org-test--fixture
  "#+TODO: TODO(t!) WAITING(w@) | DONE(d!)

* Projects
** Ship v2
:PROPERTIES:
:Owner: alice
:END:
Body line one.
Body line two.
*** QA
QA body.
** API /v2/payouts endpoint
Endpoint notes.
* Notes
Loose note.
")

(defmacro ecl-org-test--with-file (var &rest body)
  "Bind VAR to a temp org file with the fixture content around BODY."
  (declare (indent 1))
  `(let ((,var (make-temp-file "ecl-org-test-" nil ".org"
                               ecl-org-test--fixture)))
     (unwind-protect
         (progn ,@body)
       (when-let ((b (find-buffer-visiting ,var)))
         (with-current-buffer b (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
       (delete-file ,var))))

(defun ecl-org-test--file-string (file)
  "Return FILE's on-disk content."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

;;; ecl-org--args

(ert-deftest ecl-org-test-args-basic ()
  (should (equal (ecl-org--args '("f" "a" "b") nil 0 "u")
                 '(nil "f" ("a" "b")))))

(ert-deftest ecl-org-test-args-back-peel ()
  (should (equal (ecl-org--args '("f" "a" "b" "N" "V") nil 2 "u")
                 '(nil "f" ("a" "b") "N" "V"))))

(ert-deftest ecl-org-test-args-flags ()
  (should (equal (ecl-org--args '("--x" "f" "a") '(("--x" . boolean)) 0 "u")
                 '((("--x" . t)) "f" ("a"))))
  (should (equal (ecl-org--args '("--sep" "%%" "f" "a") '(("--sep" . value)) 0 "u")
                 '((("--sep" . "%%")) "f" ("a"))))
  (should (equal (ecl-org--args '("--tag" "t1" "--tag" "t2" "f" "a")
                                '(("--tag" . repeat)) 0 "u")
                 '((("--tag" . ("t1" "t2"))) "f" ("a")))))

(ert-deftest ecl-org-test-args-double-dash-terminator ()
  (should (equal (ecl-org--args '("--" "--weird" "a") '(("--x" . boolean)) 0 "u")
                 '(nil "--weird" ("a")))))

(ert-deftest ecl-org-test-args-errors ()
  (should-error (ecl-org--args '("--nope" "f" "a") nil 0 "u"))
  (should-error (ecl-org--args '("--sep") '(("--sep" . value)) 0 "u"))
  (let ((err (should-error (ecl-org--args '("f") nil 0 "usage-here"))))
    (should (string-search "usage-here" (cadr err)))))

(ert-deftest ecl-org-test-args-min-segs-zero ()
  (should (equal (ecl-org--args '("f") nil 0 "u" 0) '(nil "f" nil))))

;;; ecl-org--split-pairs

(ert-deftest ecl-org-test-split-pairs ()
  (should (equal (ecl-org--split-pairs "old\n@@REPLACE@@\nnew\n" "@@REPLACE@@")
                 '(("old" . "new"))))
  (should (equal (ecl-org--split-pairs "a\n@@REPLACE@@\nb\n@@REPLACE@@\nc\n@@REPLACE@@\nd\n"
                                       "@@REPLACE@@")
                 '(("a" . "b") ("c" . "d"))))
  (should (equal (ecl-org--split-pairs "old\n%%\nnew\n" "%%")
                 '(("old" . "new")))))

(ert-deftest ecl-org-test-split-pairs-errors ()
  (should-error (ecl-org--split-pairs "no sentinel here\n" "@@REPLACE@@"))
  (should-error (ecl-org--split-pairs "a\n@@REPLACE@@\nb\n@@REPLACE@@\nc\n" "@@REPLACE@@"))
  (should-error (ecl-org--split-pairs "a\n@@REPLACE@@\nb\n@@REPLACE@@\n\n" "@@REPLACE@@")))

;;; section / content scoping

(ert-deftest ecl-org-test-section-content-only ()
  (ecl-org-test--with-file f
    (let ((s (ecl-org-section f '("Projects" "Ship v2"))))
      (should (string-search ":Owner: alice" s))
      (should (string-search "Body line one." s))
      (should-not (string-search "** Ship v2" s))
      (should-not (string-search "QA body." s))
      (should (string-suffix-p "\n" s)))))

(ert-deftest ecl-org-test-section-subtree ()
  (ecl-org-test--with-file f
    (let ((s (ecl-org-section f '("Projects" "Ship v2") t)))
      (should (string-prefix-p "** Ship v2" s))
      (should (string-search "QA body." s))
      (should (string-suffix-p "\n" s)))))

(ert-deftest ecl-org-test-slash-in-title-is-one-segment ()
  (ecl-org-test--with-file f
    (should (string-search "Endpoint notes."
                           (ecl-org-section f '("Projects" "API /v2/payouts endpoint"))))))

(ert-deftest ecl-org-test-find-olp-progressive-error ()
  (ecl-org-test--with-file f
    (let ((err (should-error (ecl-org-section f '("Projects" "Nope")))))
      (should (string-search "No child" (cadr err)))
      (should (string-search "Projects" (cadr err))))))

(ert-deftest ecl-org-test-find-olp-trailing-hint ()
  (ecl-org-test--with-file f
    (let ((err (should-error
                (ecl-org-set-property f '("Projects" "QA") "Owner" "bob"))))
      (should (string-search "taken as NAME VALUE" (cadr err))))))

;;; append

(ert-deftest ecl-org-test-append-before-first-child ()
  (ecl-org-test--with-file f
    (ecl-org-append-section f '("Projects" "Ship v2") "\nAppended line.")
    (let ((s (ecl-org-section f '("Projects" "Ship v2") t)))
      (should (string-match "Appended line\\..*\\*\\*\\* QA" (replace-regexp-in-string "\n" " " s))))))

(ert-deftest ecl-org-test-append-rejects-heading-payload ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-append-section f '("Notes") "\n*** Sneaky\n"))
      (should (equal before (ecl-org-test--file-string f))))))

;;; replace

(ert-deftest ecl-org-test-replace-single-and-multi ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-replace-section
                    f '("Projects" "Ship v2") '(("Body line one." . "Body 1.")))
                   "1"))
    (should (equal (ecl-org-replace-section
                    f '("Projects" "Ship v2")
                    '(("Body 1." . "First.") ("Body line two." . "Second.")))
                   "1\n1"))
    (should (string-search "Second." (ecl-org-section f '("Projects" "Ship v2"))))))

(ert-deftest ecl-org-test-replace-atomic-on-miss ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-replace-section
                     f '("Projects" "Ship v2")
                     '(("Body line one." . "WOULD APPLY") ("no such text" . "x"))))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-replace-scope-excludes-children ()
  (ecl-org-test--with-file f
    (should-error (ecl-org-replace-section
                   f '("Projects" "Ship v2") '(("QA body." . "nope"))))))

(ert-deftest ecl-org-test-replace-regexp-backref ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-replace-section
                    f '("Projects" "Ship v2")
                    '(("Body line \\(one\\)\\." . "Line \\1!")) t)
                   "1"))
    (should (string-search "Line one!" (ecl-org-section f '("Projects" "Ship v2"))))))

;;; create

(ert-deftest ecl-org-test-create-new-leaf-with-metadata ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-create f '("Projects" "New task")
                                   "TODO" "1:30" '("api") '("Owner=bob") nil nil
                                   "Task body.\n")
                   "created Projects > New task"))
    (let ((s (ecl-org-section f '("Projects" "New task") t)))
      (should (string-search "** TODO New task" s))
      (should (string-search ":api:" s))
      (should (string-search "Task body." s)))
    (should (equal (ecl-org-get-property f '("Projects" "New task") "Owner") "bob"))
    (should (equal (ecl-org-get-effort f '("Projects" "New task")) "1:30"))))

(ert-deftest ecl-org-test-create-parents ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-create f '("Archive" "2026" "Q3") nil nil nil nil t nil "")
                   "created Archive > 2026 > Q3"))
    (should (ecl-org-section f '("Archive" "2026" "Q3")))))

(ert-deftest ecl-org-test-create-invalid-input-leaves-no-heading ()
  "A create that fails validation must not leave a half-created heading."
  (ecl-org-test--with-file f
    (should-error (ecl-org-create f '("Projects" "Bogus task")
                                  "NOSUCHSTATE" nil nil nil nil nil ""))
    (should-error (ecl-org-create f '("Projects" "Bogus task")
                                  nil nil nil '("no-equals-sign") nil nil ""))
    ;; Neither on disk nor in the (still-open) buffer.
    (should-error (ecl-org-section f '("Projects" "Bogus task")))))

(ert-deftest ecl-org-test-create-missing-intermediate-errors ()
  (ecl-org-test--with-file f
    (let ((err (should-error
                (ecl-org-create f '("Nowhere" "Deep" "leaf") nil nil nil nil nil nil ""))))
      (should (string-search "--parents" (cadr err))))))

(ert-deftest ecl-org-test-create-metadata-only-keeps-body ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-create f '("Projects" "Ship v2")
                                   nil nil nil '("Owner=carol") nil nil "")
                   "updated Projects > Ship v2"))
    (let ((s (ecl-org-section f '("Projects" "Ship v2"))))
      (should (string-search "Body line one." s))
      (should (string-search ":Owner:    carol" (or s ""))))))

(ert-deftest ecl-org-test-create-body-replace-preserves-drawer ()
  (ecl-org-test--with-file f
    (ecl-org-create f '("Projects" "Ship v2") nil nil nil nil nil nil "New body.\n")
    (let ((s (ecl-org-section f '("Projects" "Ship v2"))))
      (should (string-search ":Owner: alice" s))
      (should (string-search "New body." s))
      (should-not (string-search "Body line one." s)))))

(ert-deftest ecl-org-test-create-clear-body ()
  (ecl-org-test--with-file f
    (ecl-org-create f '("Projects" "Ship v2") nil nil nil nil nil t "")
    (let ((s (ecl-org-section f '("Projects" "Ship v2"))))
      (should (string-search ":Owner: alice" s))
      (should-not (string-search "Body line one." s)))))

(ert-deftest ecl-org-test-create-empty-property-value-removes ()
  (ecl-org-test--with-file f
    (ecl-org-create f '("Projects" "Ship v2") nil nil nil '("Owner=") nil nil "")
    (should-not (ecl-org-get-property f '("Projects" "Ship v2") "Owner"))))

;;; delete / rename

(ert-deftest ecl-org-test-delete-removes-subtree ()
  (ecl-org-test--with-file f
    (ecl-org-delete f '("Projects" "Ship v2"))
    (should-error (ecl-org-section f '("Projects" "Ship v2")))
    (should (ecl-org-section f '("Projects")))))

(ert-deftest ecl-org-test-rename-preserves-todo-and-tags ()
  (ecl-org-test--with-file f
    (ecl-org-create f '("Projects" "Ship v2") "TODO" nil '("core") nil nil nil "")
    (should (equal (ecl-org-rename f '("Projects" "Ship v2") "Ship v3") "Ship v3"))
    (let ((s (ecl-org-section f '("Projects" "Ship v3") t)))
      (should (string-search "** TODO Ship v3" s))
      (should (string-search ":core:" s)))))

;;; refile

(ert-deftest ecl-org-test-refile-under-sibling ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-refile f '("Projects" "Ship v2") nil '("Notes"))
                   "refiled Projects > Ship v2 -> Notes"))
    (should-error (ecl-org-section f '("Projects" "Ship v2")))
    (let ((o (ecl-org-outline f)))
      (should (string-search "* Notes\n** Ship v2\n*** QA" o)))))

(ert-deftest ecl-org-test-refile-to-top-level ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-refile f '("Projects" "Ship v2"))
                   "refiled Projects > Ship v2 -> top level"))
    (let ((o (ecl-org-outline f)))
      (should (string-search "\n* Ship v2\n** QA" o)))
    (should (ecl-org-section f '("Ship v2")))))

(ert-deftest ecl-org-test-refile-cross-file ()
  (ecl-org-test--with-file f
    (ecl-org-test--with-file g
      (ecl-org-refile f '("Projects" "Ship v2") g '("Notes"))
      (should-error (ecl-org-section f '("Projects" "Ship v2")))
      ;; Both buffers saved: check the files on disk.
      (should-not (string-search "Ship v2" (ecl-org-test--file-string f)))
      (should (string-search "** Ship v2" (ecl-org-test--file-string g))))))

(ert-deftest ecl-org-test-refile-into-self-errors ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-refile f '("Projects") nil '("Projects" "Ship v2")))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-refile-missing-dest-errors ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-refile f '("Notes") nil '("Nowhere")))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-refile-logs-when-configured ()
  (ecl-org-test--with-file f
    (let ((org-log-refile 'time))
      (ecl-org-refile f '("Projects" "Ship v2") nil '("Notes")))
    (should (string-search "Refiled on"
                           (ecl-org-section f '("Notes" "Ship v2"))))))

;;; status / note / effort / property

(ert-deftest ecl-org-test-status-logs-timestamp ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-set-status f '("Projects" "Ship v2") "DONE") "DONE"))
    (should (string-search "State \"DONE\""
                           (ecl-org-section f '("Projects" "Ship v2"))))))

(ert-deftest ecl-org-test-status-note-required-for-at-state ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-set-status f '("Projects" "Ship v2") "WAITING"))
      (should (equal before (ecl-org-test--file-string f))))
    (should (equal (ecl-org-set-status f '("Projects" "Ship v2") "WAITING" "blocked")
                   "WAITING"))
    (should (string-search "blocked" (ecl-org-section f '("Projects" "Ship v2"))))))

(ert-deftest ecl-org-test-status-unknown-state ()
  (ecl-org-test--with-file f
    (should-error (ecl-org-set-status f '("Projects" "Ship v2") "BOGUS"))))

(ert-deftest ecl-org-test-add-note ()
  (ecl-org-test--with-file f
    (should-error (ecl-org-add-note f '("Notes") "  "))
    (ecl-org-add-note f '("Notes") "a note")
    (should (string-search "a note" (ecl-org-section f '("Notes"))))))

(ert-deftest ecl-org-test-effort-set-get-inherit-clear ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-set-effort f '("Projects" "Ship v2") "2:00") "2:00"))
    (should (equal (ecl-org-get-effort f '("Projects" "Ship v2" "QA") t) "2:00"))
    (should-not (ecl-org-get-effort f '("Projects" "Ship v2" "QA")))
    (should-not (ecl-org-set-effort f '("Projects" "Ship v2") ""))))

(ert-deftest ecl-org-test-property-set-get-list ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-set-property f '("Notes") "Owner" "dana") "dana"))
    (should (equal (ecl-org-get-property f '("Notes") "Owner") "dana"))
    (should (string-search "OWNER: dana" (ecl-org-get-properties f '("Notes"))))
    (should-not (ecl-org-set-property f '("Notes") "Owner" ""))
    (should-not (ecl-org-get-property f '("Notes") "Owner"))))

;;; outline / keywords / filetags

(ert-deftest ecl-org-test-outline ()
  (ecl-org-test--with-file f
    (let ((o (ecl-org-outline f)))
      (should (string-search "* Projects" o))
      (should (string-search "*** QA" o)))))

(ert-deftest ecl-org-test-keywords-and-filetags ()
  (ecl-org-test--with-file f
    (should (string-search "WAITING(w@)" (ecl-org-get-todo-keywords f)))
    (should (equal (ecl-org-get-filetags f) ""))
    (ecl-org-set-filetags f "work urgent")
    (should (equal (ecl-org-get-filetags f) ":work:urgent:"))))

;;; tangle

(ert-deftest ecl-org-test-tangle-segments-and-block ()
  (ecl-org-test--with-file f
    (with-current-buffer (find-file-noselect f)
      (goto-char (point-max))
      (insert "* Blocks\n#+name: hello\n#+begin_src text :tangle "
              (file-name-nondirectory f) ".out\nhi\n#+end_src\n")
      (save-buffer))
    (let ((out (concat f ".out")))
      (unwind-protect
          (progn
            (should (ecl-org-tangle f nil '("Blocks")))
            (should (file-exists-p out))
            (delete-file out)
            (should (ecl-org-tangle f "hello" nil))
            (should (file-exists-p out))
            (should-error (ecl-org-tangle f "hello" '("Blocks"))))
        (when (file-exists-p out) (delete-file out))))))

(provide 'ecl-org-test)
;;; ecl-org-test.el ends here
