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
Second note.
* Snippets
Prose before the block.

#+name: greet
#+begin_src shell :results output
  echo hi
    echo there
,* not a heading
#+end_src

Prose after the block.
")

(defvar ecl-org-test--link-fixture
  "#+TODO: TODO(t!) WAITING(w@) | DONE(d!)

* Links
** [[~/p/CLAUDE.local.md][CLAUDE.local.md]]
Link heading body.
*** TODO pozri si nieco k [[BASP]]
Nested body.
** [[Payout CRU]]
Bare link body.
* Both
** CLAUDE.local.md
Plain body.
** [[~/p/x.md][CLAUDE.local.md]]
Linked body.
* Twins
** [[~/a.md][same]]
First body.
** [[~/b.md][same]]
Second body.
")

(defvar ecl-org-test--private-fixture
  "#+TODO: TODO(t!) WAITING(w@) | DONE(d!)

* Public
Public body.
** Secret :noai:
:PROPERTIES:
:Key: hunter2
:END:
Sensitive body.
*** Deeper
Deeper still.
* Vault :CRYPT:
Encrypted-in-buffer body.

#+name: vault-block
#+begin_src text :tangle vault.out
secret payload
#+end_src
* Open
Open body.

#+name: open-block
#+begin_src text :results output
echo hi
#+end_src
")

(defmacro ecl-org-test--with-content (var content &rest body)
  "Bind VAR to a temp org file holding CONTENT around BODY."
  (declare (indent 2))
  `(let ((,var (make-temp-file "ecl-org-test-" nil ".org" ,content)))
     (unwind-protect
         (progn ,@body)
       (when-let ((b (find-buffer-visiting ,var)))
         (with-current-buffer b (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
       (delete-file ,var))))

(defmacro ecl-org-test--with-file (var &rest body)
  "Bind VAR to a temp org file with the fixture content around BODY."
  (declare (indent 1))
  `(ecl-org-test--with-content ,var ecl-org-test--fixture ,@body))

(defmacro ecl-org-test--with-link-file (var &rest body)
  "Bind VAR to a temp org file with the link-heading fixture around BODY."
  (declare (indent 1))
  `(ecl-org-test--with-content ,var ecl-org-test--link-fixture ,@body))

(defmacro ecl-org-test--with-private-file (var &rest body)
  "Bind VAR to a temp org file with the private-tag fixture around BODY."
  (declare (indent 1))
  `(ecl-org-test--with-content ,var ecl-org-test--private-fixture ,@body))

(defun ecl-org-test--file-string (file)
  "Return FILE's on-disk content."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ecl-org-test--etag-of (text)
  "Pull the etag off the #+ETAG: header of TEXT, the way a caller would."
  (should (string-match "\\`#\\+ETAG: \\([^ \n]+\\)\n" text))
  (match-string 1 text))

(defun ecl-org-test--etag (file segments &optional subtree)
  "The etag `ecl-org-section' hands out for SEGMENTS in FILE."
  (ecl-org-test--etag-of (ecl-org-section file segments subtree t)))

(defun ecl-org-test--block-etag (file name)
  "The etag `ecl-org-block' hands out for the block named NAME in FILE."
  (ecl-org-test--etag-of (ecl-org-block file name nil t)))

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

;;; ecl-org--cut-chunks

(ert-deftest ecl-org-test-cut-chunks ()
  "A lone chunk needs no sentinel; several are split like replace pairs."
  (should (equal (ecl-org--cut-chunks "gone\n" "@@CUT@@") '("gone")))
  (should (equal (ecl-org--cut-chunks "a\n@@CUT@@\nb\n" "@@CUT@@") '("a" "b")))
  (should-error (ecl-org--cut-chunks "a\n@@CUT@@\n\n" "@@CUT@@")))

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

;;; link headings addressed by display text

(ert-deftest ecl-org-test-link-heading-by-description ()
  (ecl-org-test--with-link-file f
    (should (string-search "Link heading body."
                           (ecl-org-section f '("Links" "CLAUDE.local.md"))))))

(ert-deftest ecl-org-test-link-heading-by-raw-title ()
  (ecl-org-test--with-link-file f
    (should (string-search
             "Link heading body."
             (ecl-org-section f '("Links" "[[~/p/CLAUDE.local.md][CLAUDE.local.md]]"))))))

(ert-deftest ecl-org-test-link-heading-without-description ()
  "A bare `[[target]]' displays as its target, so that is what addresses it."
  (ecl-org-test--with-link-file f
    (should (string-search "Bare link body."
                           (ecl-org-section f '("Links" "Payout CRU"))))))

(ert-deftest ecl-org-test-link-inside-longer-title ()
  "The link is stripped in place; the TODO keyword is Org's to strip."
  (ecl-org-test--with-link-file f
    (should (string-search
             "Nested body."
             (ecl-org-section f '("Links" "CLAUDE.local.md" "pozri si nieco k BASP"))))))

(ert-deftest ecl-org-test-link-heading-literal-sibling-wins ()
  "A plain heading keeps the name; its linked sibling wants the raw form."
  (ecl-org-test--with-link-file f
    (should (string-search "Plain body."
                           (ecl-org-section f '("Both" "CLAUDE.local.md"))))
    (should (string-search "Linked body."
                           (ecl-org-section f '("Both" "[[~/p/x.md][CLAUDE.local.md]]"))))))

(ert-deftest ecl-org-test-link-heading-ambiguous-display-errors ()
  (ecl-org-test--with-link-file f
    (let ((err (should-error (ecl-org-section f '("Twins" "same")))))
      (should (string-search "display as" (cadr err)))
      (should (string-search "same" (cadr err))))))

(ert-deftest ecl-org-test-link-heading-unknown-keeps-no-child-error ()
  (ecl-org-test--with-link-file f
    (let ((err (should-error (ecl-org-section f '("Links" "Nope")))))
      (should (string-search "No child" (cadr err)))
      (should (string-search "Links" (cadr err))))))

(ert-deftest ecl-org-test-create-by-description-updates-not-duplicates ()
  "Without this, `create' would not see the link heading and append a twin."
  (ecl-org-test--with-link-file f
    (should (equal (ecl-org-create f '("Links" "CLAUDE.local.md")
                                   nil nil nil '("Owner=alice") nil nil nil)
                   "updated Links > [[~/p/CLAUDE.local.md][CLAUDE.local.md]]"))
    (should (equal "alice"
                   (ecl-org-get-property f '("Links" "CLAUDE.local.md") "Owner")))
    (should (equal 1 (seq-count
                      (lambda (line)
                        (string-suffix-p "[[~/p/CLAUDE.local.md][CLAUDE.local.md]]" line))
                      (split-string (ecl-org-test--file-string f) "\n"))))))

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

;;; cut

(ert-deftest ecl-org-test-cut-removes-text-keeps-the-rest ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-cut-section f '("Notes") '("Loose note.\n")) "1"))
    (let ((s (ecl-org-section f '("Notes"))))
      (should-not (string-search "Loose note." s))
      (should (string-search "Second note." s)))))

(ert-deftest ecl-org-test-cut-atomic-on-miss ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-cut-section
                     f '("Notes") '("Loose note." "no such text")))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-cut-regexp ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-cut-section f '("Notes") '("^Loose .*\n") t) "1"))
    (should-not (string-search "Loose note." (ecl-org-section f '("Notes"))))))

(ert-deftest ecl-org-test-cut-scope-excludes-children ()
  (ecl-org-test--with-file f
    (should-error (ecl-org-cut-section f '("Projects" "Ship v2") '("QA body.")))))

;;; block / set-block

(ert-deftest ecl-org-test-block-body-only ()
  (ecl-org-test--with-file f
    (let ((b (ecl-org-block f "greet")))
      ;; Org's comma escapes belong to the file, not to the body.
      (should (equal b "  echo hi\n    echo there\n* not a heading\n"))
      (should-not (string-search "begin_src" b)))))

(ert-deftest ecl-org-test-set-block-escapes-heading-like-lines ()
  "An unescaped `*' line would end the block and fork the outline."
  (ecl-org-test--with-file f
    (ecl-org-set-block f "greet" "* still not a heading\n#+end_src\n"
                       (ecl-org-test--block-etag f "greet"))
    (should (string-search ",* still not a heading"
                           (ecl-org-test--file-string f)))
    (should (equal (ecl-org-block f "greet")
                   "* still not a heading\n#+end_src\n"))
    (should-not (string-search "* still not a heading" (ecl-org-outline f)))))

(ert-deftest ecl-org-test-block-full ()
  (ecl-org-test--with-file f
    (let ((b (ecl-org-block f "greet" t)))
      (should (string-prefix-p "#+name: greet\n" b))
      (should (string-search ":results output" b))
      (should (string-suffix-p "#+end_src\n" b))
      (should-not (string-search "Prose after" b)))))

(ert-deftest ecl-org-test-block-unknown-name-errors ()
  (ecl-org-test--with-file f
    (let ((err (should-error (ecl-org-block f "nope"))))
      (should (string-search "ecl org blocks" (cadr err))))))

(ert-deftest ecl-org-test-set-block-keeps-neighbours ()
  "The regression this exists for: a whole-body rewrite drops the prose."
  (ecl-org-test--with-file f
    (should (equal (ecl-org-set-block f "greet" "echo replaced\n"
                                      (ecl-org-test--block-etag f "greet"))
                   "updated block greet"))
    (let ((s (ecl-org-section f '("Snippets"))))
      (should (string-search "echo replaced" s))
      (should-not (string-search "echo there" s))
      (should (string-search "#+name: greet" s))
      (should (string-search ":results output" s))
      (should (string-search "Prose before the block." s))
      (should (string-search "Prose after the block." s)))))

(ert-deftest ecl-org-test-set-block-round-trip-is-byte-identical ()
  "Reading a block and writing it back must not re-indent it."
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (ecl-org-set-block f "greet" (ecl-org-block f "greet")
                         (ecl-org-test--block-etag f "greet"))
      (should (equal before (ecl-org-test--file-string f))))))

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
    (ecl-org-create f '("Projects" "Ship v2") nil nil nil nil nil nil "New body.\n"
                    (ecl-org-test--etag f '("Projects" "Ship v2")))
    (let ((s (ecl-org-section f '("Projects" "Ship v2"))))
      (should (string-search ":Owner: alice" s))
      (should (string-search "New body." s))
      (should-not (string-search "Body line one." s)))))

(ert-deftest ecl-org-test-create-clear-body ()
  (ecl-org-test--with-file f
    (ecl-org-create f '("Projects" "Ship v2") nil nil nil nil nil t ""
                    (ecl-org-test--etag f '("Projects" "Ship v2")))
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
    (ecl-org-delete f '("Projects" "Ship v2")
                    (ecl-org-test--etag f '("Projects" "Ship v2") t))
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
    (should (equal (ecl-org-refile f '("Projects" "Ship v2") nil '("Notes")
                                   (ecl-org-test--etag f '("Projects" "Ship v2") t))
                   "refiled Projects > Ship v2 -> Notes"))
    (should-error (ecl-org-section f '("Projects" "Ship v2")))
    (let ((o (ecl-org-outline f)))
      (should (string-search "* Notes\n** Ship v2\n*** QA" o)))))

(ert-deftest ecl-org-test-refile-to-top-level ()
  (ecl-org-test--with-file f
    (should (equal (ecl-org-refile f '("Projects" "Ship v2") nil nil
                                   (ecl-org-test--etag f '("Projects" "Ship v2") t))
                   "refiled Projects > Ship v2 -> top level"))
    (let ((o (ecl-org-outline f)))
      (should (string-search "\n* Ship v2\n** QA" o)))
    (should (ecl-org-section f '("Ship v2")))))

(ert-deftest ecl-org-test-refile-cross-file ()
  (ecl-org-test--with-file f
    (ecl-org-test--with-file g
      (ecl-org-refile f '("Projects" "Ship v2") g '("Notes")
                      (ecl-org-test--etag f '("Projects" "Ship v2") t))
      (should-error (ecl-org-section f '("Projects" "Ship v2")))
      ;; Both buffers saved: check the files on disk.
      (should-not (string-search "Ship v2" (ecl-org-test--file-string f)))
      (should (string-search "** Ship v2" (ecl-org-test--file-string g))))))

(ert-deftest ecl-org-test-refile-into-self-errors ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-refile f '("Projects") nil '("Projects" "Ship v2")
                                    (ecl-org-test--etag f '("Projects") t)))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-refile-missing-dest-errors ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (should-error (ecl-org-refile f '("Notes") nil '("Nowhere")))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-refile-logs-when-configured ()
  (ecl-org-test--with-file f
    (let ((org-log-refile 'time))
      (ecl-org-refile f '("Projects" "Ship v2") nil '("Notes")
                      (ecl-org-test--etag f '("Projects" "Ship v2") t)))
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

;;; private tags

(ert-deftest ecl-org-test-private-heading-refuses-reads ()
  (ecl-org-test--with-private-file f
    (should-error (ecl-org-section f '("Public" "Secret")))
    (should-error (ecl-org-get-properties f '("Public" "Secret")))
    (should-error (ecl-org-get-property f '("Public" "Secret") "Key"))))

(ert-deftest ecl-org-test-private-tag-is-inherited-by-children ()
  (ecl-org-test--with-private-file f
    (should-error (ecl-org-section f '("Public" "Secret" "Deeper")))))

(ert-deftest ecl-org-test-private-heading-refuses-edits-and-writes-nothing ()
  (ecl-org-test--with-private-file f
    (let ((before (ecl-org-test--file-string f))
          (path '("Public" "Secret")))
      (should-error (ecl-org-append-section f path "\nmore\n"))
      (should-error (ecl-org-replace-section f path '(("Sensitive" . "x"))))
      (should-error (ecl-org-cut-section f path '("Sensitive body.")))
      (should-error (ecl-org-set-status f path "DONE"))
      (should-error (ecl-org-add-note f path "a note"))
      (should-error (ecl-org-set-property f path "Key" "leaked"))
      (should-error (ecl-org-rename f path "Renamed"))
      (should-error (ecl-org-delete f path))
      (should-error (ecl-org-create f path nil nil nil nil nil nil "new body"))
      (should (equal (ecl-org-test--file-string f) before)))))

(ert-deftest ecl-org-test-private-child-guards-its-public-parent-subtree ()
  "A public parent must not be usable as a handle on the private child."
  (ecl-org-test--with-private-file f
    (should (string-search "Public body" (ecl-org-section f '("Public"))))
    (should-error (ecl-org-section f '("Public") t))
    (should-error (ecl-org-delete f '("Public")))
    (should-error (ecl-org-refile f '("Public") nil '("Open")))))

(ert-deftest ecl-org-test-private-outline-shows-a-placeholder ()
  (ecl-org-test--with-private-file f
    (let ((o (ecl-org-outline f)))
      (should (string-search "* Public" o))
      (should (string-search "** <hidden :noai:>" o))
      (should (string-search "* <hidden :CRYPT:>" o))
      (should (string-search "* Open" o))
      (should-not (string-search "Secret" o))
      (should-not (string-search "Deeper" o)))))

(ert-deftest ecl-org-test-private-filetags-cover-the-whole-file ()
  (ecl-org-test--with-content f "#+FILETAGS: :noai:\n\n* Anything\nBody.\n"
    (should-error (ecl-org-outline f))
    (should-error (ecl-org-blocks f))
    (should-error (ecl-org-section f '("Anything")))
    (should-error (ecl-org-tangle f nil nil))))

(ert-deftest ecl-org-test-private-blocks-are-hidden-and-unaddressable ()
  (ecl-org-test--with-private-file f
    (let ((listing (ecl-org-blocks f)))
      (should (string-search "open-block" listing))
      (should-not (string-search "vault-block" listing))
      (should-not (string-search "vault.out" listing)))
    (should-error (ecl-org-block f "vault-block"))
    (should-error (ecl-org-set-block f "vault-block" "leaked\n"))
    (should-error (ecl-org-run f "vault-block"))
    (should-error (ecl-org-tangle f "vault-block" nil))
    (should (string-search "echo hi" (ecl-org-block f "open-block")))))

(ert-deftest ecl-org-test-private-heading-refuses-wider-tangle-scopes ()
  (ecl-org-test--with-private-file f
    (should-error (ecl-org-tangle f nil nil))
    (should-error (ecl-org-tangle f nil '("Public")))
    (should-not (ecl-org-tangle f nil '("Open")))))

(ert-deftest ecl-org-test-private-tags-are-a-configurable-case-insensitive-list ()
  (ecl-org-test--with-private-file f
    (should-error (ecl-org-section f '("Vault")))
    (let ((ecl-org-private-tags '("noai")))
      (should (string-search "Encrypted" (ecl-org-section f '("Vault")))))))

(ert-deftest ecl-org-test-public-headings-stay-reachable-and-taggable ()
  "Marking a heading private is still allowed; unmarking it is not."
  (ecl-org-test--with-private-file f
    (should (string-search "Open body" (ecl-org-section f '("Open"))))
    (ecl-org-append-section f '("Open") "\nappended\n")
    (should (string-search "appended" (ecl-org-section f '("Open"))))
    (should (equal (ecl-org-create f '("Open" "Child")
                                   nil nil '("noai") nil nil nil "")
                   "created Open > Child"))
    (should-error (ecl-org-section f '("Open" "Child")))))

;;; ecl-org--buffer  (the file moved underneath the daemon)

(defun ecl-org-test--diverge (file content)
  "Write CONTENT to FILE behind the back of the buffer visiting it.
The recorded modtime is pushed into the past rather than slept past, so
the test does not depend on the filesystem's timestamp granularity."
  (write-region content nil file nil 'silent)
  (with-current-buffer (find-buffer-visiting file)
    (set-visited-file-modtime (time-subtract nil 100))))

(ert-deftest ecl-org-test-buffer-rereads-a-clean-buffer ()
  "Nothing to lose in the buffer, so take what is on disk."
  (ecl-org-test--with-file f
    (should (equal (ecl-org-section f '("Notes")) "Loose note.\nSecond note.\n"))
    (ecl-org-test--diverge f "* Notes\nRewritten on disk.\n")
    (should (equal (ecl-org-section f '("Notes")) "Rewritten on disk.\n"))))

(ert-deftest ecl-org-test-buffer-write-lands-on-the-reread-file ()
  "A write after the reread must build on the disk version, not replace it."
  (ecl-org-test--with-file f
    (ecl-org-section f '("Notes"))
    (ecl-org-test--diverge f "* Notes\nRewritten on disk.\n")
    (ecl-org-append-section f '("Notes") "\nAppended.\n")
    (should (equal (ecl-org-test--file-string f)
                   "* Notes\nRewritten on disk.\n\nAppended.\n"))))

(ert-deftest ecl-org-test-buffer-refuses-when-both-sides-changed ()
  "Two versions and no way to pick: refuse, and leave both where they are.
Reads are refused too -- handing out the buffer would report content that
is not what the next command would edit."
  (ecl-org-test--with-file f
    (ecl-org-section f '("Notes"))
    (with-current-buffer (find-buffer-visiting f)
      (goto-char (point-max))
      (insert "* Unsaved\nstill in Emacs only.\n"))
    (ecl-org-test--diverge f "* Notes\nDisk moved on.\n")
    (dolist (thunk (list (lambda () (ecl-org-section f '("Notes")))
                         (lambda () (ecl-org-outline f))
                         (lambda () (ecl-org-append-section f '("Notes") "\nx\n"))
                         (lambda () (ecl-org-delete f '("Notes")))))
      (should (string-search "unsaved" (cadr (should-error (funcall thunk))))))
    ;; The conflict survives intact, for the user to resolve in Emacs.
    (should (equal (ecl-org-test--file-string f) "* Notes\nDisk moved on.\n"))
    (should (buffer-modified-p (find-buffer-visiting f)))))

;;; etags  (losing each other's work)

(ert-deftest ecl-org-test-etag-tracks-the-text-it-covers ()
  (ecl-org-test--with-file f
    (let ((one (ecl-org-test--etag f '("Notes"))))
      (should (string-prefix-p "content:" one))
      (should (equal one (ecl-org-test--etag f '("Notes"))))
      (ecl-org-append-section f '("Notes") "\nthird note.\n")
      (should-not (equal one (ecl-org-test--etag f '("Notes")))))))

(ert-deftest ecl-org-test-etag-scopes-are-distinct ()
  "A body rewrite and a subtree delete are not the same precondition."
  (ecl-org-test--with-file f
    (let ((content (ecl-org-test--etag f '("Projects" "Ship v2")))
          (subtree (ecl-org-test--etag f '("Projects" "Ship v2") t)))
      (should (string-prefix-p "content:" content))
      (should (string-prefix-p "subtree:" subtree))
      ;; A child changing moves the subtree etag and leaves the content one.
      (ecl-org-append-section f '("Projects" "Ship v2" "QA") "\nmore QA.\n")
      (should (equal content (ecl-org-test--etag f '("Projects" "Ship v2"))))
      (should-not (equal subtree (ecl-org-test--etag f '("Projects" "Ship v2") t))))))

(ert-deftest ecl-org-test-with-etag-does-not-change-the-plain-read ()
  "Pipelines and the block round trip depend on the bare output being bare."
  (ecl-org-test--with-file f
    (should-not (string-search "#+ETAG:" (ecl-org-section f '("Notes"))))
    (should-not (string-search "#+ETAG:" (ecl-org-block f "greet")))
    ;; The tagged form is the header line and then the bare form, verbatim.
    (let ((plain (ecl-org-section f '("Notes")))
          (tagged (ecl-org-section f '("Notes") nil t)))
      (should (string-match "\\`#\\+ETAG: content:[0-9a-f]\\{12\\}\n" tagged))
      (should (equal (substring tagged (match-end 0)) plain)))))

(ert-deftest ecl-org-test-if-match-is-required-for-a-blind-write ()
  (ecl-org-test--with-file f
    (let ((before (ecl-org-test--file-string f)))
      (dolist (thunk
               (list (lambda () (ecl-org-delete f '("Notes")))
                     (lambda () (ecl-org-refile f '("Notes") nil '("Projects")))
                     (lambda () (ecl-org-set-block f "greet" "echo new\n"))
                     (lambda () (ecl-org-create f '("Notes") nil nil nil nil nil
                                                nil "rewritten\n"))))
        (should (string-search "needs --if-match"
                               (cadr (should-error (funcall thunk))))))
      (should (equal before (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-if-match-not-required-when-nothing-is-overwritten ()
  "Metadata overwrites no text, and a new heading has nothing to match."
  (ecl-org-test--with-file f
    (ecl-org-create f '("Projects" "Ship v2") "TODO" "1:00" '("core")
                    '("Owner=bob") nil nil "")
    (should (equal (ecl-org-get-property f '("Projects" "Ship v2") "Owner") "bob"))
    (ecl-org-create f '("Notes" "Fresh") nil nil nil nil t nil "brand new.\n")
    (should (string-search "brand new." (ecl-org-section f '("Notes" "Fresh"))))))

(ert-deftest ecl-org-test-if-match-for-a-heading-that-is-not-there ()
  (ecl-org-test--with-file f
    (should (string-search "--if-match wants one that exists"
                           (cadr (should-error
                                  (ecl-org-create f '("Notes" "Absent") nil nil nil
                                                  nil t nil "x\n" "content:0")))))))

(ert-deftest ecl-org-test-if-match-refuses-a-stale-etag ()
  "The lost update this all exists for."
  (ecl-org-test--with-file f
    (let ((stale (ecl-org-test--etag f '("Notes"))))
      ;; Somebody else gets there first.
      (ecl-org-append-section f '("Notes") "\nfrom another agent.\n")
      (let ((before (ecl-org-test--file-string f)))
        (should (string-search "Changed in Emacs since"
                               (cadr (should-error
                                      (ecl-org-create f '("Notes") nil nil nil nil
                                                      nil nil "mine.\n" stale)))))
        (should (equal before (ecl-org-test--file-string f)))
        (should (string-search "from another agent."
                               (ecl-org-section f '("Notes"))))))))

(ert-deftest ecl-org-test-if-match-refuses-the-wrong-scope ()
  "A content etag says nothing about the children delete would take."
  (ecl-org-test--with-file f
    (let ((err (should-error
                (ecl-org-delete f '("Projects" "Ship v2")
                                (ecl-org-test--etag f '("Projects" "Ship v2"))))))
      (should (string-search "delete checks the subtree" (cadr err)))
      (should (string-search "--subtree --with-etag" (cadr err))))))

(ert-deftest ecl-org-test-if-match-hint-names-the-actual-target ()
  "The message has to be runnable, quoting and all."
  (ecl-org-test--with-file f
    (let ((err (should-error
                (ecl-org-delete f '("Projects" "API /v2/payouts endpoint")))))
      (should (string-search (shell-quote-argument f) (cadr err)))
      (should (string-search (shell-quote-argument "API /v2/payouts endpoint")
                             (cadr err))))))

(ert-deftest ecl-org-test-require-if-match-nil-lifts-it ()
  "The escape hatch for a bulk edit that cannot thread etags through."
  (ecl-org-test--with-file f
    (let ((ecl-org-require-if-match nil))
      (ecl-org-delete f '("Notes"))
      (should-error (ecl-org-section f '("Notes"))))))

(ert-deftest ecl-org-test-require-if-match-nil-still-honours-one ()
  (ecl-org-test--with-file f
    (let* ((ecl-org-require-if-match nil)
           (stale (ecl-org-test--etag f '("Notes") t)))
      (ecl-org-append-section f '("Notes") "\nmeanwhile.\n")
      (should-error (ecl-org-delete f '("Notes") stale))
      (should (ecl-org-section f '("Notes"))))))

(ert-deftest ecl-org-test-private-refusal-comes-before-the-etag ()
  "Otherwise a private heading would answer `needs --if-match', which is a
different thing and invites a retry."
  (ecl-org-test--with-private-file f
    (should (string-search "not available to agents"
                           (cadr (should-error (ecl-org-delete f '("Public"))))))))

;;; ecl-org--save  (whose unsaved work is it)

(ert-deftest ecl-org-test-save-reaches-disk-from-a-clean-buffer ()
  "The ordinary case: git, rg and everything else read the file, not the buffer."
  (ecl-org-test--with-file f
    (ecl-org-append-section f '("Notes") "\nFrom the agent.\n")
    (should (string-search "From the agent." (ecl-org-test--file-string f)))
    (should-not (buffer-modified-p (find-buffer-visiting f)))))

(ert-deftest ecl-org-test-save-leaves-a-buffer-the-user-was-editing ()
  "An edit to one heading must not flush an unfinished edit in another."
  (ecl-org-test--with-file f
    (ecl-org-section f '("Notes"))
    (with-current-buffer (find-buffer-visiting f)
      (goto-char (point-max))
      (insert "* Half-written\nstill thinking.\n"))
    (ecl-org-append-section f '("Notes") "\nFrom the agent.\n")
    ;; Both edits are in the buffer, neither is on disk yet.
    (should (string-search "From the agent." (ecl-org-section f '("Notes"))))
    (should-not (string-search "From the agent." (ecl-org-test--file-string f)))
    (should-not (string-search "Half-written" (ecl-org-test--file-string f)))
    (should (buffer-modified-p (find-buffer-visiting f)))
    ;; The user saves when ready, and gets both.
    (with-current-buffer (find-buffer-visiting f) (save-buffer))
    (should (string-search "From the agent." (ecl-org-test--file-string f)))
    (should (string-search "Half-written" (ecl-org-test--file-string f)))))

(ert-deftest ecl-org-test-save-resumes-once-the-user-has-saved ()
  "Holding off is per command, not a mode the buffer gets stuck in."
  (ecl-org-test--with-file f
    (ecl-org-section f '("Notes"))
    (with-current-buffer (find-buffer-visiting f)
      (goto-char (point-max))
      (insert "* Half-written\nstill thinking.\n")
      (save-buffer))
    (ecl-org-append-section f '("Notes") "\nFrom the agent.\n")
    (should (string-search "From the agent." (ecl-org-test--file-string f)))))

;;; --id addressing

(defvar ecl-org-test--id-fixture
  "#+TODO: TODO(t!) WAITING(w@) | DONE(d!)

* Projects
** Ship v2
:PROPERTIES:
:ID: ship-v2-id
:END:
Body line one.
*** QA
QA body.
* Notes
Loose note.
* Twins
** One
:PROPERTIES:
:ID: shared-id
:END:
First body.
** Two
:PROPERTIES:
:ID: shared-id
:END:
Second body.
* Hidden :noai:
:PROPERTIES:
:ID: hidden-id
:END:
Sensitive body.
")

(defmacro ecl-org-test--with-id-file (var &rest body)
  "Bind VAR to a temp org file with the ID fixture around BODY."
  (declare (indent 1))
  `(ecl-org-test--with-content ,var ecl-org-test--id-fixture ,@body))

(ert-deftest ecl-org-test-args-address-replaces-the-segments ()
  (should (equal (ecl-org--args '("--id" "x" "f") '(("--id" . address)) 0 "u")
                 '((("--id" . "x")) "f" (id . "x"))))
  (should (equal (ecl-org--args '("--id" "x" "f" "N") '(("--id" . address)) 1 "u")
                 '((("--id" . "x")) "f" (id . "x") "N"))))

(ert-deftest ecl-org-test-args-address-and-segments-are-exclusive ()
  "The address stands in for the path; giving both leaves the run ambiguous."
  (let ((err (should-error (ecl-org--args '("--id" "x" "f" "a")
                                          '(("--id" . address)) 0 "usage-here"))))
    (should (string-search "not both" (cadr err)))
    (should (string-search "usage-here" (cadr err))))
  (should-error (ecl-org--args '("f") '(("--id" . address)) 0 "u")))

(ert-deftest ecl-org-test-id-reads-the-same-section-as-the-path ()
  (ecl-org-test--with-id-file f
    (should (equal (ecl-org-section f '(id . "ship-v2-id"))
                   (ecl-org-section f '("Projects" "Ship v2"))))
    (should (string-search "QA body." (ecl-org-section f '(id . "ship-v2-id") t)))))

(ert-deftest ecl-org-test-id-survives-a-rename ()
  "The point of the flag: a title is what a human edits, an ID is not."
  (ecl-org-test--with-id-file f
    (ecl-org-rename f '(id . "ship-v2-id") "Ship v3")
    (should-error (ecl-org-section f '("Projects" "Ship v2")))
    (should (string-search "Body line one."
                           (ecl-org-section f '(id . "ship-v2-id"))))))

(ert-deftest ecl-org-test-id-survives-a-refile ()
  (ecl-org-test--with-id-file f
    (ecl-org-refile f '(id . "ship-v2-id") nil '("Notes")
                    (ecl-org-test--etag f '(id . "ship-v2-id") t))
    (should (string-search "Body line one."
                           (ecl-org-section f '(id . "ship-v2-id"))))
    (should (string-search "Body line one."
                           (ecl-org-section f '("Notes" "Ship v2"))))))

(ert-deftest ecl-org-test-id-writes-reach-the-file ()
  (ecl-org-test--with-id-file f
    (ecl-org-append-section f '(id . "ship-v2-id") "\nAppended.\n")
    (ecl-org-set-property f '(id . "ship-v2-id") "Owner" "alice")
    (let ((on-disk (ecl-org-test--file-string f)))
      (should (string-search "Appended." on-disk))
      (should (string-match-p "^:Owner: +alice$" on-disk)))))

(ert-deftest ecl-org-test-id-that-is-not-there ()
  (ecl-org-test--with-id-file f
    (let ((err (should-error (ecl-org-section f '(id . "no-such-id")))))
      (should (string-search "No heading with ID no-such-id" (cadr err))))))

(ert-deftest ecl-org-test-id-duplicates-are-an-error-not-a-coin-toss ()
  (ecl-org-test--with-id-file f
    (let ((err (should-error (ecl-org-section f '(id . "shared-id")))))
      (should (string-search "Several headings carry ID" (cadr err))))))

(ert-deftest ecl-org-test-id-does-not-reach-a-private-heading ()
  "An ID is a second door to the same heading, not a way around the tag."
  (ecl-org-test--with-id-file f
    (let ((err (should-error (ecl-org-section f '(id . "hidden-id")))))
      (should (string-search "tagged noai" (cadr err))))
    (should-error (ecl-org-heading-id f '("Hidden")))))

(ert-deftest ecl-org-test-id-is-matched-exactly ()
  "Path segments fold case and see past links; an opaque token does neither."
  (ecl-org-test--with-id-file f
    (let ((err (should-error (ecl-org-section f '(id . "SHIP-V2-ID")))))
      (should (string-search "No heading with ID SHIP-V2-ID" (cadr err))))))

(ert-deftest ecl-org-test-id-etag-hint-round-trips ()
  "The hint has to be a call that runs: flags come before FILE."
  (ecl-org-test--with-id-file f
    (let ((hint (ecl-org--section-hint f '(id . "ship-v2-id") "subtree")))
      (should (string-search "--id ship-v2-id" hint))
      (should (string-match-p "--id ship-v2-id .*\\.org\\'" hint)))
    (let ((err (should-error (ecl-org-delete f '(id . "ship-v2-id")))))
      (should (string-search "--id ship-v2-id" (cadr err))))
    (ecl-org-delete f '(id . "ship-v2-id")
                    (ecl-org-test--etag f '(id . "ship-v2-id") t))
    (should-error (ecl-org-section f '(id . "ship-v2-id")))))

(ert-deftest ecl-org-test-id-create-only-ever-updates ()
  (ecl-org-test--with-id-file f
    (should (equal (ecl-org-create f '(id . "ship-v2-id") "TODO" nil nil nil
                                   nil nil "")
                   "updated Projects > Ship v2"))
    (should (string-search "** TODO Ship v2" (ecl-org-test--file-string f)))
    (should-error (ecl-org-create f '(id . "no-such-id") nil nil nil nil
                                  nil nil "body"))
    (let ((err (should-error (ecl-org-create f '(id . "ship-v2-id") nil nil nil nil
                                             t nil "body"))))
      (should (string-search "--parents" (cadr err))))))

(ert-deftest ecl-org-test-id-create-still-wants-an-etag ()
  (ecl-org-test--with-id-file f
    (should-error (ecl-org-create f '(id . "ship-v2-id") nil nil nil nil
                                  nil nil "rewritten"))
    (ecl-org-create f '(id . "ship-v2-id") nil nil nil nil nil nil "rewritten"
                    (ecl-org-test--etag f '(id . "ship-v2-id")))
    (should (string-search "rewritten" (ecl-org-section f '(id . "ship-v2-id"))))))

(ert-deftest ecl-org-test-refile-to-id-names-the-destination ()
  (ecl-org-test--with-id-file f
    (should (equal (ecl-org-refile f '("Notes") nil '(id . "ship-v2-id")
                                   (ecl-org-test--etag f '("Notes") t))
                   "refiled Notes -> Projects > Ship v2"))
    (should (string-search "Loose note."
                           (ecl-org-section f '("Projects" "Ship v2" "Notes"))))))

(ert-deftest ecl-org-test-id-carries-through-status-and-its-logging ()
  "`set-status' resolves twice: once to move the keyword, once to log under it."
  (ecl-org-test--with-id-file f
    (should (equal (ecl-org-set-status f '(id . "ship-v2-id") "DONE") "DONE"))
    (should (string-search "State \"DONE\""
                           (ecl-org-section f '(id . "ship-v2-id"))))
    (should (equal (ecl-org-set-status f '(id . "ship-v2-id") "WAITING" "blocked")
                   "WAITING"))
    (should (string-search "blocked" (ecl-org-section f '(id . "ship-v2-id"))))))

(ert-deftest ecl-org-test-id-scopes-a-tangle ()
  (ecl-org-test--with-id-file f
    (with-current-buffer (find-file-noselect f)
      (goto-char (point-max))
      (insert "* Blocks\n:PROPERTIES:\n:ID: blocks-id\n:END:\n"
              "#+name: hello\n#+begin_src text :tangle "
              (file-name-nondirectory f) ".out\nhi\n#+end_src\n")
      (save-buffer))
    (let ((out (concat f ".out")))
      (unwind-protect
          (progn
            (should (ecl-org-tangle f nil '(id . "blocks-id")))
            (should (file-exists-p out))
            (should-error (ecl-org-tangle f "hello" '(id . "blocks-id"))))
        (when (file-exists-p out) (delete-file out))))))

(ert-deftest ecl-org-test-id-carries-through-attach ()
  (ecl-org-test--with-id-file f
    (let ((org-attach-id-dir (make-temp-file "ecl-org-test-attach-" t))
          (src (make-temp-file "ecl-org-test-source-" nil ".txt" "payload")))
      (unwind-protect
          (progn
            (should (ecl-org-attach f '(id . "ship-v2-id") src))
            (should (equal (ecl-org-attachments f '(id . "ship-v2-id"))
                           (list (file-name-nondirectory src))))
            (should (ecl-org-attach-dir f '(id . "ship-v2-id")))
            (should (equal (ecl-org-attach-dir f '(id . "ship-v2-id"))
                           (ecl-org-attach-dir f '("Projects" "Ship v2")))))
        (delete-file src)
        (delete-directory org-attach-id-dir t)))))

(ert-deftest ecl-org-test-refile-to-id-looks-in-the-destination-file ()
  "The ID is ambiguous in the source file and single in the destination.
Resolving it anywhere but the destination would error instead of moving."
  (ecl-org-test--with-id-file f
    (ecl-org-test--with-content g
        "* Inbox\n:PROPERTIES:\n:ID: shared-id\n:END:\nInbox body.\n"
      (should (equal (ecl-org-refile f '("Notes") g '(id . "shared-id")
                                     (ecl-org-test--etag f '("Notes") t))
                     (format "refiled Notes -> Inbox in %s" g)))
      (should (string-search "** Notes" (ecl-org-test--file-string g)))
      (should-not (string-search "Loose note." (ecl-org-test--file-string f))))))

(ert-deftest ecl-org-test-id-command-reads-and-mints ()
  (ecl-org-test--with-id-file f
    (should (equal (ecl-org-heading-id f '("Projects" "Ship v2")) "ship-v2-id"))
    (let ((err (should-error (ecl-org-heading-id f '("Notes")))))
      (should (string-search "ecl org id --create" (cadr err))))
    (let ((minted (ecl-org-heading-id f '("Notes") t)))
      (should (stringp minted))
      (should (string-search minted (ecl-org-test--file-string f)))
      (should (equal (ecl-org-section f (cons 'id minted))
                     (ecl-org-section f '("Notes")))))))

;;; reload

(ert-deftest ecl-org-test-reload-rebuilds-the-command-table ()
  "Re-loading the module must rebuild its table, not keep the bound one.
As `defvar' these tables survived a reload, so a rebuilt package left the
daemon registering the previous release's commands -- new handlers loaded
but unreachable, and no error anywhere to say so."
  (unwind-protect
      (progn
        (setq ecl-org-commands (cons '("sentinel" . ignore) ecl-org-commands))
        (load "ecl-org" nil t)
        (should-not (assoc "sentinel" ecl-org-commands))
        (should (assoc "cut" ecl-org-commands))
        (should (assoc "set-block" ecl-org-commands)))
    (setq ecl-org-commands (assoc-delete-all "sentinel" ecl-org-commands))))

(provide 'ecl-org-test)
;;; ecl-org-test.el ends here
