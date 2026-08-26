;;; ecl-org.el --- Org file commands for the ecl shell client -*- lexical-binding: t; -*-

;;; Commentary:
;; Org module for ecl: heading-addressed queries and edits on org files,
;; exposed to shell callers (primarily coding agents) as `ecl org ...'.
;;
;; Headings are addressed as positional path segments -- one argument per
;; outline level -- and every path command follows the grammar
;; [--flags] FILE SEG... [FIXED-DATA] (exactly one elastic run; anything
;; optional is a front flag or stdin).  Text edits (append, replace,
;; cut, create body) are scoped to a section's CONTENT -- after the
;; heading line, property drawer included, up to the first child
;; heading; the tree structure is only reachable through its own
;; commands (create, delete, rename, refile, status).
;;
;; Babel blocks are the exception to path addressing: blocks, block,
;; set-block, run and tangle --block take a #+name: instead of an
;; outline path, so they keep working when a section is moved or
;; retitled -- and so one block can be rewritten without touching the
;; prose around it.
;;
;; The four commands that replace a whole region blind -- create with a
;; body, set-block, delete, refile -- take an etag of that region via
;; --if-match, from a read made with --with-etag.  Nothing else needs
;; one: replace and cut already require every OLD to still be there,
;; append and note merge, and the metadata setters touch one scalar.
;;
;; A heading tagged with one of `ecl-org-private-tags' is out of reach of
;; every command here, reads and edits alike, and shows in the outline as
;; <hidden :TAG:>.  That gates this tool path only -- it is not a
;; boundary; anything that can read the file directly still can.
;;
;; Register the command group from your init file:
;;   (use-package ecl-org
;;     :after ecl
;;     :config (ecl-register ecl-org-command-group))

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-attach)
(require 'org-refile)
(require 'org-src)
(require 'ecl)

(defun ecl-org--file (file)
  "Expand FILE against the ecl client's cwd when dispatched via ecl."
  (expand-file-name file (or (bound-and-true-p ecl-directory) default-directory)))

(defvar-local ecl-org--was-dirty nil
  "Whether the buffer already held unsaved changes when a command arrived.
Set by `ecl-org--buffer', read by `ecl-org--save'.")

(defun ecl-org--save ()
  "Write the buffer out, unless the user was already editing it.
Saving is how the file on disk keeps up with these commands -- `git',
`rg' and everything that is not this daemon read that file, not the
buffer.  But a buffer the user had already modified holds work of theirs
that they have not committed to disk yet, and an agent editing one
heading has no business flushing an unfinished edit in another.  So that
buffer keeps the change in memory and the user saves both when ready."
  (unless ecl-org--was-dirty (save-buffer)))

(defun ecl-org--buffer (file)
  "Return the buffer visiting FILE, in step with what is on disk.
Every command here goes through this, so it is the one place that has to
cope with the file having moved underneath the daemon -- a git checkout,
a rebase, another editor.

A buffer holding no unsaved changes is simply reverted: there is nothing
to lose, and the alternative is refusing every command until someone
reverts it by hand.  A buffer that IS modified has two versions of the
file and no way to tell which the user wants, so it is refused untouched
and the conflict stays where it can be resolved -- Emacs will offer the
diff on the next visit.

Left to itself `find-file-noselect' asks instead, which is why this
exists: see `ecl--without-prompts' for what an unanswerable question
does to the daemon."
  (let* ((path (ecl-org--file file))
         (buf (find-buffer-visiting path)))
    (when (and buf (not (with-current-buffer buf
                          (verify-visited-file-modtime))))
      (with-current-buffer buf
        (when (buffer-modified-p)
          (error "%s changed on disk while the Emacs buffer has unsaved \
changes; resolve it in Emacs first" path))
        (revert-buffer t t)))
    (with-current-buffer (or buf (find-file-noselect path t))
      (setq ecl-org--was-dirty (buffer-modified-p))
      (current-buffer))))

(defvar ecl-org-private-tags '("noai" "crypt" "private" "secret")
  "Tags that put a heading out of reach of `ecl org'.
Matched case-insensitively and inherited, so the tag covers the whole
subtree under it, and a #+FILETAGS: entry covers the whole file.  Nothing
here reads or edits such a heading -- only a human working in Emacs does.
`crypt' is in the list because an org-crypt subtree sits decrypted in the
daemon's buffer, which is what these commands read.

This gates the sanctioned tool path, not the file: whoever can run
`cat' on the org file reads it regardless.")

(defun ecl-org--match-private (tags)
  "The first of TAGS that `ecl-org-private-tags' lists, or nil."
  (seq-find (lambda (tag) (member-ignore-case tag ecl-org-private-tags)) tags))

(defun ecl-org--private-tag ()
  "The private tag covering point, or nil; nil above the first heading.
Tag inheritance is forced on rather than read from the daemon's settings,
so an ancestor's tag counts wherever point is."
  (unless (org-before-first-heading-p)
    (let ((org-use-tag-inheritance t)
          (org-tags-exclude-from-inheritance nil))
      (ecl-org--match-private
       (save-excursion (org-back-to-heading t) (org-get-tags))))))

(defun ecl-org--check-private (what)
  "Signal when point is covered by a private tag; WHAT names it to the caller."
  (when-let ((tag (ecl-org--private-tag)))
    (error "%s is tagged %s; not available to agents" what tag)))

(defun ecl-org--check-private-region (beg end what &optional hint)
  "Signal when any heading between BEG and END carries a private tag.
Guards the commands that take a whole subtree or a whole file at once,
where no path is resolved to the private heading itself -- so a public
parent cannot be used to reach a private child.  The heading's title stays
out of the message, since hiding it is the point; HINT is appended for
commands that have a narrower alternative to suggest."
  (save-excursion
    (goto-char beg)
    (unless (org-at-heading-p) (outline-next-heading))
    (while (and (org-at-heading-p) (< (point) end))
      (when-let ((tag (ecl-org--private-tag)))
        (error "%s contains a heading tagged %s; not available to agents%s"
               what tag (or hint "")))
      (outline-next-heading))))

(defun ecl-org--check-private-file (file)
  "Signal when the current buffer's #+FILETAGS: put FILE out of reach.
Headings inherit those tags, so this only has to be called where a command
reaches content without resolving a heading -- outline, blocks, tangle."
  (when-let ((tag (ecl-org--match-private
                   (mapcar #'substring-no-properties org-file-tags))))
    (error "%s is tagged %s; not available to agents" file tag)))

(defun ecl-org--path-label (segments)
  "SEGMENTS as a quoted outline path, for messages."
  (format "%S" (string-join segments " > ")))

(defun ecl-org--args (args spec nback usage &optional min-segs)
  "Parse ARGS as [FLAGS] FILE SEG... BACK-DATA, per the ecl org grammar.
SPEC is an alist of (FLAG . KIND) with KIND one of `boolean', `value' or
`repeat'; flags are consumed from the front until the first non-flag
argument or a literal \"--\".  Of the remaining positionals the first is
FILE, the last NBACK are fixed back data and the middle run is the path
segments (at least MIN-SEGS of them, default 1).  USAGE is the command's
usage line for error messages.  Returns (OPTS FILE SEGMENTS BACK...),
OPTS being an alist keyed by the flag string; a `repeat' flag collects
its values in a list, in order of appearance."
  (let (opts)
    (catch 'positional
      (while args
        (let ((a (car args)))
          (cond
           ((equal a "--") (pop args) (throw 'positional nil))
           ((string-prefix-p "--" a)
            (pcase (cdr (or (assoc a spec)
                            (error "Unknown option %s\nusage: %s" a usage)))
              ('boolean (pop args) (push (cons a t) opts))
              ('value (pop args)
                      (push (cons a (or (pop args)
                                        (error "%s needs a value" a)))
                            opts))
              ('repeat (pop args)
                       (let ((v (or (pop args) (error "%s needs a value" a)))
                             (cell (assoc a opts)))
                         (if cell (setcdr cell (nconc (cdr cell) (list v)))
                           (push (cons a (list v)) opts))))))
           (t (throw 'positional nil))))))
    (let ((min-segs (or min-segs 1)))
      (unless (>= (length args) (+ 1 min-segs nback))
        (error "usage: %s" usage)))
    (let* ((file (pop args))
           (nsegs (- (length args) nback)))
      (append (list (nreverse opts) file (seq-take args nsegs))
              (seq-drop args nsegs)))))

(defun ecl-org--find-olp (segments &optional trailing)
  "Resolve SEGMENTS as an outline path in the current buffer; return position.
Resolution is progressive: on failure the error names the resolved prefix
and the missing child, so a mis-split argv is visible.  TRAILING, when
given, is appended to the error -- callers with fixed back data use it to
show which arguments were NOT taken as path segments.

Every path-addressed command comes through here, so this is also where a
heading tagged with one of `ecl-org-private-tags' is refused; inheritance
means one check at the resolved position covers its ancestors too."
  (let (found pos)
    (dolist (seg segments)
      (let ((path (append found (list seg))))
        (condition-case nil
            (setq pos (org-find-olp path t))
          (error
           (error "No child %S under %s%s"
                  seg
                  (if found (format "\"%s\"" (string-join found " > "))
                    "the top level")
                  (or trailing ""))))
        (setq found path)))
    (when pos
      (save-excursion
        (goto-char pos)
        (ecl-org--check-private (ecl-org--path-label segments))))
    pos))

(defun ecl-org--content-region ()
  "Bounds of the content of the heading at point, as (BEG . END).
Content runs from just after the heading line (planning line and property
drawer included) to the first child heading, or the end of the subtree
when there are no children.  This is the only region text edits touch;
structure has its own commands."
  (save-excursion
    (org-back-to-heading t)
    (let ((beg (min (1+ (line-end-position)) (point-max)))
          (end (save-excursion (org-end-of-subtree t t) (point))))
      (goto-char beg)
      (when (and (outline-next-heading) (< (point) end))
        (setq end (point)))
      (cons beg end))))

(defun ecl-org--subtree-region ()
  "Bounds of the whole subtree at point, as (BEG . END).
Heading line and children included -- what `delete' and `refile' move,
and what `section --subtree' hands out."
  (save-excursion
    (org-back-to-heading t)
    (cons (line-beginning-position)
          (save-excursion (org-end-of-subtree t t) (point)))))

(defun ecl-org--region-text (bounds)
  "Text of BOUNDS, a (BEG . END) pair, newline-terminated.
Reads and etag checks share this, so what was handed out and what is
hashed back cannot drift apart over a missing final newline."
  (let ((text (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (if (string-suffix-p "\n" text) text (concat text "\n"))))

;;; Etags
;;
;; Every dispatch is serialised -- the daemon is single-threaded -- so
;; two commands never interleave.  What they do is lose each other's
;; work: read a section, spend a minute composing, write it back over an
;; edit that arrived meanwhile.  `replace' and `cut' are already immune,
;; since every OLD has to still be there; `append' and `note' merge.  The
;; ones that cannot tell are those that overwrite a whole region blind,
;; and they take an etag of that region instead.

(defvar ecl-org-require-if-match '("create" "set-block" "delete" "refile")
  "Commands that refuse to overwrite a region without --if-match.
These are the ones that replace a whole region rather than a matched
piece of it, so nothing else in them would notice work that arrived
after the caller read it.  Set to nil to lift the requirement -- a
scripted bulk edit that cannot thread etags through, say; a passed
--if-match is still honoured.")

(defun ecl-org--etag (kind text)
  "The KIND etag of TEXT.
KIND names the scope the caller read -- \"content\", \"subtree\" or
\"block\" -- and is carried in the etag so a mis-scoped one can say so
instead of just reporting a mismatch."
  (format "%s:%s" kind (substring (secure-hash 'sha1 text) 0 12)))

(defun ecl-org--check-etag (etag kind current command hint blind)
  "Refuse the write unless ETAG still describes CURRENT.
KIND is the scope ETAG has to cover, COMMAND names the caller in the
message and HINT is the read that hands back a fresh one.  BLIND says
this call would overwrite CURRENT wholesale, which is what makes an etag
necessary; `create' is only blind when it rewrites a body that is
already there.  A missing etag is refused only for a blind call to a
command listed in `ecl-org-require-if-match'."
  (cond
   ((null etag)
    (when (and blind (member command ecl-org-require-if-match))
      (error "%s needs --if-match; read it first:\n  %s" command hint)))
   ((not (string-prefix-p (concat kind ":") etag))
    (error "%s checks the %s; re-read with:\n  %s" command kind hint))
   ((not (equal etag (ecl-org--etag kind current)))
    (error "Changed in Emacs since %s; re-read with:\n  %s" etag hint))))

(defun ecl-org--section-hint (file segments kind)
  "The `section' call that hands back a fresh KIND etag for SEGMENTS."
  (format "ecl org section%s --with-etag %s %s"
          (if (equal kind "subtree") " --subtree" "")
          (shell-quote-argument file)
          (mapconcat #'shell-quote-argument segments " ")))

(defun ecl-org--with-etag (kind text)
  "TEXT with its KIND etag on a header line above it."
  (format "#+ETAG: %s\n%s" (ecl-org--etag kind text) text))

(defun ecl-org-outline (file)
  "Return outline of FILE: one heading per line as `STARS [TODO ]TITLE'.
A subtree tagged with one of `ecl-org-private-tags' collapses to a single
`STARS <hidden :TAG:>' line: neither its title nor its children are
listed, but its place in the tree is, so the gap is not mistaken for an
absence."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (ecl-org--check-private-file file)
     ;; The scanner caches each entry's inherited tags and `org-get-tags'
     ;; hands that cache back, so the inheritance switches have to be on
     ;; around the scan itself, not only inside `ecl-org--private-tag'.
     (let ((org-use-tag-inheritance t)
           (org-tags-exclude-from-inheritance nil)
           lines)
       (org-map-entries
        (lambda ()
          (let* ((c (org-heading-components))
                 (level (nth 0 c))
                 (todo  (nth 2 c))
                 (title (nth 4 c))
                 (private (ecl-org--private-tag)))
            (push (concat (make-string level ?*)
                          (if private
                              (format " <hidden :%s:>" private)
                            (concat (when todo (concat " " todo))
                                    " " title)))
                  lines)
            (when private
              (setq org-map-continue-from
                    (save-excursion (org-end-of-subtree t t) (point)))))))
       (mapconcat #'identity (nreverse lines) "\n")))))

(defun ecl-org-section (file segments &optional subtree with-etag)
  "Return the content of the heading at SEGMENTS in FILE.
By default only the section's own content -- from after the heading line
\(property drawer included) to the first child heading -- i.e. exactly
the region `ecl-org-replace-section' can edit.  With SUBTREE non-nil,
the entire subtree (heading line and children included).  The result
always ends in a newline.

WITH-ETAG puts a `#+ETAG:' line above it, to hand back to --if-match.
It comes with the content rather than from a call of its own so there is
no gap between reading and versioning for an edit to slip through."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (let ((bounds (if subtree
                       (ecl-org--subtree-region)
                     (ecl-org--content-region))))
       ;; A private child would ride out inside its public parent's subtree.
       (when subtree
         (ecl-org--check-private-region (car bounds) (cdr bounds)
                                        (ecl-org--path-label segments)))
       (let ((text (ecl-org--region-text bounds))
             (kind (if subtree "subtree" "content")))
         (if with-etag (ecl-org--with-etag kind text) text))))))

(defun ecl-org-append-section (file segments content)
  "Append CONTENT to the end of the content of the heading at SEGMENTS in FILE.
Inserts before the first child heading (body text only -- CONTENT may not
contain org heading lines; new sub-headings go through `ecl-org-create').
CONTENT should include its own leading newline.  Saves via `ecl-org--save'."
  (when (string-match-p "^\\*+ " content)
    (error "Content contains an org heading line; use `ecl org create' for structure"))
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (goto-char (cdr (ecl-org--content-region)))
     (insert (if (string-suffix-p "\n" content) content (concat content "\n"))))
    (ecl-org--save))
  nil)

(defun ecl-org--goto-block (name file)
  "Move point to the babel src block named NAME (via #+name:) in FILE.
FILE is only used in the error message; the block is looked up in the
current buffer.  Returns the position.

The name-addressed commands (block, set-block, run, tangle --block) all
land here, so this is where a block inside a private subtree is refused."
  (ecl-org--check-private-file file)
  (let ((pos (org-babel-find-named-block name)))
    (unless pos
      (error "No src block named '%s' in %s (see: ecl org blocks)" name file))
    (goto-char pos)
    (ecl-org--check-private (format "block '%s'" name))
    pos))

(defun ecl-org-run (file name)
  "Execute the babel src block named NAME (via #+name:) in FILE.
Return result as string. Inserts #+RESULTS: in buffer and saves.
Bypasses `org-confirm-babel-evaluate'."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (ecl-org--goto-block name file)
     (let* ((org-confirm-babel-evaluate nil)
            (result (org-babel-execute-src-block)))
       (ecl-org--save)
       (format "%s" (or result ""))))))

(defun ecl-org--block-body (el)
  "The body of src block EL, newline-terminated, as `ecl-org-block' hands it out."
  (let ((text (org-element-property :value el)))
    (if (string-suffix-p "\n" text) text (concat text "\n"))))

(defun ecl-org-block (file name &optional full with-etag)
  "Return the body of the babel src block named NAME in FILE.
Body only -- the text between the #+begin_src and #+end_src lines,
verbatim.  With FULL non-nil, the whole block instead: from its #+name:
line through #+end_src.  The result always ends in a newline.  Pure
query; blocks are addressed by name, not by outline path.

WITH-ETAG puts a `#+ETAG:' line above it, for `ecl-org-set-block' to
check.  It covers the body either way, FULL included: the body is what
set-block overwrites, and the header lines it leaves alone have no
business invalidating the write."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (ecl-org--goto-block name file)
     (let* ((el (org-element-at-point))
            (text (if full
                      (buffer-substring-no-properties
                       (org-element-property :begin el)
                       (save-excursion
                         (goto-char (org-element-property :end el))
                         (skip-chars-backward " \t\n")
                         (line-end-position)))
                    (org-element-property :value el))))
       (unless (string-suffix-p "\n" text) (setq text (concat text "\n")))
       (if with-etag
           (concat (format "#+ETAG: %s\n"
                           (ecl-org--etag "block" (ecl-org--block-body el)))
                   text)
         text)))))

(defun ecl-org-set-block (file name body &optional if-match)
  "Replace the body of the babel src block named NAME in FILE with BODY.
Only the body between #+begin_src and #+end_src changes: the #+name:
line, the header arguments and every neighbouring line are left alone --
this is the narrow alternative to rewriting a whole section with
`ecl-org-create'.  BODY keeps its own indentation and is escaped the way
Org stores block content, so it round-trips with `ecl-org-block'.  A
#+RESULTS: drawer left over from an earlier run is not touched.  Saves
the buffer and returns a confirmation string.

IF-MATCH is the block etag from `ecl-org-block', required by default --
the whole body goes, so nothing here would notice an edit that landed
after the caller read it."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (ecl-org--goto-block name file)
     (ecl-org--check-etag if-match "block"
                          (ecl-org--block-body (org-element-at-point))
                          "set-block"
                          (format "ecl org block --with-etag %s %s"
                                  (shell-quote-argument file)
                                  (shell-quote-argument name))
                          t)
     ;; Two Org encodings to undo, both of which would otherwise rewrite
     ;; lines the caller never touched: without `org-src-preserve-indentation'
     ;; the body is re-indented by `org-edit-src-content-indentation', and
     ;; `org-babel-update-block-body' inserts verbatim while `ecl-org-block'
     ;; hands out the *unescaped* body -- so a line starting with `*' or
     ;; `#+' has to get its comma back, or it ends the block.
     (let ((org-src-preserve-indentation t))
       (org-babel-update-block-body
        (org-escape-code-in-string
         (if (string-suffix-p "\n" body) body (concat body "\n")))))
     (ecl-org--save)
     (format "updated block %s" name))))

(defun ecl-org-tangle (file &optional block segments)
  "Tangle src blocks in FILE, returning the list of files written.
With BLOCK, tangle only the src block named BLOCK (via #+name:).
With SEGMENTS (an outline path as a list), tangle every block in that
subtree.  With neither, tangle the whole file.  BLOCK and SEGMENTS are
mutually exclusive.

Tangling writes block bodies out to files, so a scope holding a heading
tagged with one of `ecl-org-private-tags' is refused rather than narrowed
around: what to tangle instead is the caller's call, not ours."
  (when (and block segments)
    (error "Give only one of --block / path segments"))
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (save-restriction
       (let ((hint " (tangle one --block, or a subtree without it)"))
         (cond
          (block
           (ecl-org--goto-block block file)
           (org-babel-tangle '(4)))
          (segments
           (goto-char (ecl-org--find-olp segments))
           (ecl-org--check-private-region
            (point) (save-excursion (org-end-of-subtree t t) (point))
            (ecl-org--path-label segments) hint)
           (org-narrow-to-subtree)
           (org-babel-tangle))
          (t
           (ecl-org--check-private-file file)
           (ecl-org--check-private-region (point-min) (point-max) file hint)
           (org-babel-tangle))))))))

(defun ecl-org-attach (file segments source)
  "Attach SOURCE to the heading at SEGMENTS in FILE, using Org's default method.
SOURCE is resolved against the ecl caller's cwd.  Uses `org-attach-method'
\(a copy by default), tags the heading ATTACH, and saves the file.  Returns
the heading's attachment directory."
  (require 'org-attach)
  (let ((src (ecl-org--file source)))
    (unless (file-exists-p src)
      (error "No such file: %s" source))
    (with-current-buffer (ecl-org--buffer file)
      (org-with-wide-buffer
       (goto-char (ecl-org--find-olp
                   segments (format "; trailing arg taken as SOURCE: %S" source)))
       (save-excursion (org-attach-attach src))
       (ecl-org--save)
       (org-attach-dir)))))

(defun ecl-org-attach-dir (file segments)
  "Return the attachment directory of the heading at SEGMENTS in FILE, or nil.
Pure query: unlike attaching, it neither creates the directory nor
assigns an ID."
  (require 'org-attach)
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (org-attach-dir))))

(defun ecl-org-attachments (file segments)
  "List the filenames attached to the heading at SEGMENTS in FILE.
Returns nil when the heading has no attachment directory."
  (require 'org-attach)
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (let ((dir (org-attach-dir)))
       (and dir (org-attach-file-list dir))))))

(defun ecl-org-blocks (file)
  "List named babel src blocks and #+call: lines in FILE, in document order.
Columns per row: NAME, LANG (\"call:CALLEE\" for a #+call: line), and the
block's resolved :tangle target (or - when it is not tangled).  NAME is
what `ecl org run' and `ecl org tangle --block' address; anonymous blocks
are omitted since they cannot be named on the command line, and so are
blocks under a heading tagged with one of `ecl-org-private-tags' -- the
name and the tangle target say enough on their own."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (ecl-org--check-private-file file)
     (let ((rows
            (org-element-map (org-element-parse-buffer) '(src-block babel-call)
              (lambda (el)
                (when-let ((name (org-element-property :name el))
                           ((not (save-excursion
                                   (goto-char (org-element-property :begin el))
                                   (ecl-org--private-tag)))))
                  (pcase (org-element-type el)
                    ('src-block
                     (let* ((info (org-babel-get-src-block-info 'no-eval el))
                            (tangle (cdr (assq :tangle (nth 2 info)))))
                       (list name
                             (or (nth 0 info) "-")
                             (if (member tangle '(nil "no")) "-"
                               (format "%s" tangle)))))
                    ('babel-call
                     (list name
                           (concat "call:" (org-element-property :call el))
                           "-"))))))))
       (if (null rows) ""
         (let* ((rows (cons '("NAME" "LANG" "TANGLE") rows))
                (wname (apply #'max (mapcar (lambda (r) (length (nth 0 r))) rows)))
                (wlang (apply #'max (mapcar (lambda (r) (length (nth 1 r))) rows))))
           (mapconcat (lambda (r)
                        (concat (string-pad (nth 0 r) wname) "  "
                                (string-pad (nth 1 r) wlang) "  "
                                (nth 2 r)))
                      rows "\n")))))))

(defun ecl-org--split-chunks (content sentinel)
  "Split CONTENT into the chunks separated by SENTINEL lines.
One trailing newline (a heredoc artifact) is stripped from CONTENT first;
SENTINEL must appear on a line of its own.  Emptiness is the caller's
policy -- this only splits."
  (when (string-suffix-p "\n" content)
    (setq content (substring content 0 -1)))
  (split-string content (concat "\n" (regexp-quote sentinel) "\n")))

(defun ecl-org--split-pairs (content sentinel)
  "Split CONTENT on SENTINEL lines into a list of (OLD . NEW) pairs.
Chunks pair up in order (OLD1 NEW1 OLD2 NEW2 ...), so the count must be
even.  An empty OLD or NEW chunk is an error -- removing text has its
own command."
  (let ((chunks (ecl-org--split-chunks content sentinel)))
    (when (= (length chunks) 1)
      (error "Sentinel line %S not found in input" sentinel))
    (when (= 1 (mod (length chunks) 2))
      (error "Input splits into %d chunks; OLD/NEW pairs need an even count"
             (length chunks)))
    (let (pairs)
      (while chunks
        (let ((old (pop chunks)) (new (pop chunks)))
          (when (string-empty-p old)
            (error "Empty OLD chunk (nothing before a sentinel)"))
          (when (string-empty-p new)
            (error "Empty NEW chunk; removing text is `ecl org cut'"))
          (push (cons old new) pairs)))
      (nreverse pairs))))

(defun ecl-org--cut-chunks (content sentinel)
  "Split CONTENT on SENTINEL lines into a list of texts to remove.
A single chunk needs no sentinel at all; an empty chunk is an error, so a
stray sentinel cannot turn into \"remove nothing\"."
  (let ((chunks (ecl-org--split-chunks content sentinel)))
    (dolist (chunk chunks)
      (when (string-empty-p chunk)
        (error "Empty chunk (nothing on one side of a sentinel)")))
    chunks))

(defun ecl-org-replace-section (file segments pairs &optional regexp)
  "Apply PAIRS of (OLD . NEW) replacements to the content at SEGMENTS in FILE.
Scope is the section's content only -- after the heading line (property
drawer included) up to the first child heading; the tree structure is
never touched.  With REGEXP non-nil, each OLD is an Emacs regexp and its
NEW may use \\N backrefs; otherwise literal strings.  Atomic: every OLD
must match or nothing is written.  Returns the per-pair replacement
counts, one per line.  Saves via `ecl-org--save'."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (let* ((bounds (ecl-org--content-region))
            (beg (car bounds)) (end (cdr bounds))
            (text (buffer-substring-no-properties beg end))
            counts)
       (with-temp-buffer
         (insert text)
         (dolist (pair pairs)
           (let ((count (if regexp
                            (replace-regexp-in-region
                             (car pair) (cdr pair) (point-min) (point-max))
                          (replace-string-in-region
                           (car pair) (cdr pair) (point-min) (point-max)))))
             (unless count
               (error "Search string not found in section %S: %s"
                      (string-join segments " > ") (car pair)))
             (push count counts)))
         (setq text (buffer-string)))
       (delete-region beg end)
       (goto-char beg)
       (insert text)
       (ecl-org--save)
       (mapconcat #'number-to-string (nreverse counts) "\n")))))

(defun ecl-org-cut-section (file segments texts &optional regexp)
  "Remove each of TEXTS from the content at SEGMENTS in FILE.
The counterpart of `ecl-org-replace-section' with an empty replacement:
same content-only scope, same atomicity (every text must match or nothing
is written), same REGEXP option.  Returns the per-text removal counts,
one per line.  Saves via `ecl-org--save'."
  (ecl-org-replace-section file segments
                           (mapcar (lambda (text) (cons text "")) texts)
                           regexp))

(defun ecl-org-set-status (file segments state &optional note)
  "Set the TODO STATE of the heading at SEGMENTS in FILE, honoring Org logging.
Drives Org's own logging non-interactively (the `*Org Note*' post-command
hook does not fire under `emacsclient'), so timestamps and state-change notes
are written exactly as Org would, respecting `org-log-into-drawer'.

STATE must be one of the file's TODO keywords.  If entering STATE (or leaving
the current state) is configured to record a note (an `@' flag in `#+TODO:')
and NOTE is nil, signal an error and change nothing.  When NOTE is given it is
recorded for any state that logs.  Returns the new state string."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as STATE: %S" state)))
     (let* ((this  (org-get-todo-state))
            (dolog (or (nth 1 (assoc state org-todo-log-states))
                       (nth 2 (assoc this  org-todo-log-states)))))
       (unless (member state (append org-not-done-keywords org-done-keywords))
         (error "Unknown TODO state %S; file defines: %s" state
                (string-join (append org-not-done-keywords org-done-keywords) " ")))
       (when (and (eq dolog 'note) (null note))
         (error "State %S requires a note; none provided" state))
       ;; Change the keyword with Org's own logging inhibited, so Org does NOT
       ;; defer a note via `post-command-hook' (that hook never fires under
       ;; `emacsclient', and leaving it pending errors the server's post-command
       ;; step).  We then drive `org-store-log-note' ourselves, setting the
       ;; `org-log-note-*' vars directly -- reusing Org's exact formatting and
       ;; honoring `org-log-into-drawer' -- without touching any hook.
       (let ((org-inhibit-logging t))
         (org-todo state))
       (when dolog
         (save-excursion
           (goto-char (ecl-org--find-olp segments))
           ;; `org-store-log-note' restores these at the end; set them so its
           ;; tail (window restore + return-to marker) does not choke on the
           ;; nil values left by skipping the interactive `org-add-log-note'.
           (move-marker org-log-note-marker (point))
           (move-marker org-log-note-return-to (point))
           (setq org-log-note-window-configuration (current-window-configuration)
                 org-log-note-purpose 'state
                 org-log-note-state state
                 org-log-note-previous-state this
                 org-log-note-how dolog
                 org-log-note-extra nil
                 org-log-note-effective-time (org-current-effective-time))
           (let ((b (get-buffer-create " *ecl-org-note*")))
             (unwind-protect
                 (with-current-buffer b
                   (erase-buffer)
                   (when note (insert note))
                   (org-store-log-note))
               (when (buffer-live-p b) (kill-buffer b))))))
       (ecl-org--save)
       state))))

(defun ecl-org-add-note (file segments note)
  "Add a timestamped log NOTE to the heading at SEGMENTS in FILE; save.
Files NOTE into the heading's LOGBOOK drawer exactly as the interactive
`org-add-note' (\\[org-add-log-note], `C-c C-z') would, honoring
`org-log-into-drawer'.  Drives `org-store-log-note' directly because the
interactive `*Org Note*' post-command hook never fires under `emacsclient'
\(same technique as `ecl-org-set-status').  Signal an error and change nothing
if NOTE is blank.  Return a short confirmation string."
  (when (or (null note) (string-blank-p note))
    (error "Note text is empty"))
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as NOTE: %S" note)))
     (move-marker org-log-note-marker (point))
     (move-marker org-log-note-return-to (point))
     (setq org-log-note-window-configuration (current-window-configuration)
           org-log-note-purpose 'note
           org-log-note-state nil
           org-log-note-previous-state nil
           org-log-note-how 'note
           org-log-note-extra nil
           org-log-note-effective-time (org-current-effective-time))
     (let ((b (get-buffer-create " *ecl-org-note*")))
       (unwind-protect
           (with-current-buffer b
             (erase-buffer)
             (insert note)
             (org-store-log-note))
         (when (buffer-live-p b) (kill-buffer b))))
     (ecl-org--save)
     "note added")))

(defun ecl-org-set-effort (file segments effort)
  "Set the Effort property of the heading at SEGMENTS in FILE to EFFORT; save.
EFFORT is an Org effort string such as \"0:30\", \"1:00\" or \"2d\"; an
empty EFFORT removes the property.  Returns the new Effort value, or nil
when cleared."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as EFFORT: %S" effort)))
     (save-excursion
       (if (string-empty-p effort)
           (org-entry-delete (point) org-effort-property)
         (org-set-effort nil effort)))
     (ecl-org--save)
     (org-entry-get (point) org-effort-property))))

(defun ecl-org-get-effort (file segments &optional inherit)
  "Return the Effort property of the heading at SEGMENTS in FILE, or nil.
Reads the heading's own Effort; with INHERIT non-nil, fall back to the
nearest ancestor's Effort when the heading has none.  Pure query."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (org-entry-get (point) org-effort-property inherit))))

(defun ecl-org-set-property (file segments name value)
  "Set property NAME of the heading at SEGMENTS in FILE to VALUE; save.
NAME is a property name such as \"Owner\" or \"URL\" (no colons); an
empty VALUE removes the property.  Returns the new value, or nil when
cleared."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments
                 (format "; trailing args taken as NAME VALUE: %S %S" name value)))
     (save-excursion
       (if (string-empty-p value)
           (org-entry-delete (point) name)
         (org-entry-put (point) name value)))
     (ecl-org--save)
     (org-entry-get (point) name))))

(defun ecl-org-get-property (file segments name &optional inherit)
  "Return property NAME of the heading at SEGMENTS in FILE, or nil.
Reads the heading's own value; with INHERIT non-nil, fall back to the
nearest ancestor that sets NAME.  Pure query."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as NAME: %S" name)))
     (org-entry-get (point) name inherit))))

(defun ecl-org-get-properties (file segments)
  "Return the own properties of the heading at SEGMENTS in FILE.
One NAME: VALUE per line.
Lists only what is set in the heading's own property drawer, excluding
inherited and Org's computed properties (e.g. the filename-derived
CATEGORY).  Empty string when the drawer is empty or absent.  Pure query."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (mapconcat (lambda (kv) (format "%s: %s" (car kv) (cdr kv)))
                (seq-filter (lambda (kv) (org--property-local-values (car kv) nil))
                            (org-entry-properties (point) 'standard))
                "\n"))))

(defun ecl-org--insert-child (parent-path title)
  "Insert a heading TITLE as the last child of PARENT-PATH in the current buffer.
PARENT-PATH is an outline path as a list; nil inserts a top-level heading
at the end of the buffer.  Returns the position of the new heading."
  (let (level)
    (if parent-path
        (progn
          (goto-char (org-find-olp parent-path t))
          (setq level (1+ (org-current-level)))
          (org-end-of-subtree t t))
      (setq level 1)
      (goto-char (point-max)))
    (unless (bolp) (insert "\n"))
    (let ((beg (point)))
      (insert (make-string level ?*) " " title "\n")
      beg)))

(defun ecl-org-create (file segments todo effort tags properties parents clear-body body
                            &optional if-match)
  "Upsert the heading at SEGMENTS in FILE; save.  Returns what happened.
Creates the leaf as the last child of its parent when missing; a missing
intermediate segment errors unless PARENTS is non-nil (then all missing
segments are created, mkdir -p style).  On the resolved heading, only what
was passed is touched: TODO (set without state-change logging), EFFORT,
TAGS (added to existing tags), and PROPERTIES (a list of K=V strings,
split on the first =; an empty value removes the property).  A non-empty
BODY replaces the section's body -- the content after the planning line
and any leading drawers, up to the first child heading -- while empty
BODY leaves it untouched; clearing is only via CLEAR-BODY.

IF-MATCH is the content etag from `section --with-etag'.  It is required
only when this call is a blind overwrite -- a body rewrite of a heading
that is already there.  Setting metadata overwrites nothing, and a
heading being created has nothing to match yet; passing an etag for one
that does not exist is an error rather than a silent no-op."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     ;; Validate inputs before touching the tree, so a bad flag cannot
     ;; leave a half-created heading behind in the buffer.
     (when todo
       (unless (member todo (append org-not-done-keywords org-done-keywords))
         (error "Unknown TODO state %S; file defines: %s" todo
                (string-join (append org-not-done-keywords org-done-keywords) " "))))
     (dolist (kv properties)
       (unless (string-search "=" kv)
         (error "--property needs K=V, got %S" kv)))
     (ecl-org--check-private-file file)
     ;; The etag is settled here rather than at the body rewrite below,
     ;; because the walk that follows creates missing headings as it
     ;; goes -- by the time the leaf is in hand the tree has already
     ;; moved, and a refusal then would leave a heading behind.
     (let ((existing (condition-case nil (org-find-olp segments t) (error nil))))
       (cond
        (existing
         (save-excursion
           (goto-char existing)
           (ecl-org--check-private (ecl-org--path-label segments))
           (ecl-org--check-etag
            if-match "content" (ecl-org--region-text (ecl-org--content-region))
            "create" (ecl-org--section-hint file segments "content")
            (or clear-body (not (string-empty-p (or body "")))))))
        (if-match
         (error "No heading %s to match; --if-match wants one that exists"
                (ecl-org--path-label segments)))))
     (let ((n (length segments)) (i 0) (prefix nil) (created nil) pos)
       (while (< i n)
         (let* ((seg (nth i segments))
                (path (append prefix (list seg)))
                (found (condition-case nil (org-find-olp path t) (error nil))))
           ;; This resolves paths itself instead of through
           ;; `ecl-org--find-olp', so the private check is repeated here --
           ;; on every prefix, which also refuses a new child under a
           ;; private parent.
           (when found
             (save-excursion
               (goto-char found)
               (ecl-org--check-private (ecl-org--path-label path))))
           (cond
            (found (setq pos found))
            ((or parents (= i (1- n)))
             (setq pos (ecl-org--insert-child prefix seg) created t))
            (t (error "No child %S under %s; --parents creates intermediates"
                      seg (if prefix (format "\"%s\"" (string-join prefix " > "))
                            "the top level"))))
           (setq prefix path i (1+ i))))
       (goto-char pos)
       (when todo
         (let ((org-inhibit-logging t))
           (org-todo todo)))
       (when tags
         (org-set-tags (delete-dups (append (org-get-tags nil t) tags))))
       (dolist (kv properties)
         (let* ((eq-pos (or (string-search "=" kv)
                            (error "--property needs K=V, got %S" kv)))
                (name (substring kv 0 eq-pos))
                (value (substring kv (1+ eq-pos))))
           (if (string-empty-p value)
               (org-entry-delete (point) name)
             (org-entry-put (point) name value))))
       (when effort
         (if (string-empty-p effort)
             (org-entry-delete (point) org-effort-property)
           (org-set-effort nil effort)))
       (when (or clear-body (not (string-empty-p (or body ""))))
         (org-back-to-heading t)
         (let ((body-beg (save-excursion (org-end-of-meta-data t) (point)))
               (body-end (cdr (ecl-org--content-region))))
           (delete-region (min body-beg body-end) body-end)
           (goto-char (min body-beg body-end))
           (unless (string-empty-p (or body ""))
             (insert (if (string-suffix-p "\n" body) body (concat body "\n"))))))
       (ecl-org--save)
       (format "%s %s" (if created "created" "updated")
               (string-join segments " > "))))))

(defun ecl-org-delete (file segments &optional if-match)
  "Remove the entire subtree at SEGMENTS in FILE; save.
The subtree is cut, so it stays recoverable from the kill ring of the
running Emacs session.  A subtree holding a heading tagged with one of
`ecl-org-private-tags' is refused: it cannot be read here, so it cannot be
destroyed here either.

IF-MATCH is the subtree etag from `section --subtree --with-etag',
required by default: the subtree may have grown children since the
caller looked at it, and they would go too."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (let ((bounds (ecl-org--subtree-region)))
       (ecl-org--check-private-region (car bounds) (cdr bounds)
                                      (ecl-org--path-label segments))
       (ecl-org--check-etag if-match "subtree" (ecl-org--region-text bounds)
                            "delete"
                            (ecl-org--section-hint file segments "subtree")
                            t))
     (org-cut-subtree)
     (ecl-org--save))
    nil))

(defun ecl-org-rename (file segments title)
  "Retitle the heading at SEGMENTS in FILE to TITLE, in place; save.
Stars, TODO keyword, priority and tags are preserved.  Returns TITLE."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as TITLE: %S" title)))
     (org-edit-headline title)
     (ecl-org--save)
     title)))

(defun ecl-org-refile (file segments &optional to-file to-segments if-match)
  "Move the subtree at SEGMENTS in FILE under TO-SEGMENTS; save.
Delegates to `org-refile', so the subtree's level is adapted to the
destination and `org-reverse-note-order' decides whether it lands as the
first or last child.  TO-SEGMENTS nil refiles to the top level; TO-FILE,
when given, is the destination file (default FILE), so moves may cross
files.  Honors `org-log-refile' by driving Org's log note directly (the
interactive post-command hook never fires under `emacsclient', same
technique as `ecl-org-set-status').  Saves both via `ecl-org--save'.  Returns a
confirmation string.  A subtree holding a heading tagged with one of
`ecl-org-private-tags' does not move.

IF-MATCH is the subtree etag from `section --subtree --with-etag',
required by default, and covers the source only: the destination gains a
child rather than losing one, so a change there costs nothing."
  (let* ((dest-buf (ecl-org--buffer (or to-file file)))
         (dest-pos
          (when to-segments
            (with-current-buffer dest-buf
              (org-with-wide-buffer
               (ecl-org--find-olp to-segments "; resolving --to destination")))))
         new-loc)
    (with-current-buffer (ecl-org--buffer file)
      (org-with-wide-buffer
       (goto-char (ecl-org--find-olp segments))
       (let ((bounds (ecl-org--subtree-region)))
         (ecl-org--check-private-region (car bounds) (cdr bounds)
                                        (ecl-org--path-label segments))
         (ecl-org--check-etag if-match "subtree" (ecl-org--region-text bounds)
                              "refile"
                              (ecl-org--section-hint file segments "subtree")
                              t))
       (let ((log org-log-refile)
             ;; Refile with Org's own logging off: `org-add-log-setup'
             ;; defers the entry via `post-command-hook', which never
             ;; fires under `emacsclient'.  The hook below remembers
             ;; where the subtree landed so we can log there ourselves.
             (org-log-refile nil)
             (org-after-refile-insert-hook
              (cons (lambda () (setq new-loc (point-marker)))
                    (ensure-list org-after-refile-insert-hook))))
         (org-refile nil nil
                     (list (if to-segments (string-join to-segments " > ")
                             "top level")
                           (buffer-file-name dest-buf) nil dest-pos))
         (when (and log new-loc)
           (with-current-buffer (marker-buffer new-loc)
             (org-with-wide-buffer
              (goto-char new-loc)
              (org-back-to-heading t)
              (move-marker org-log-note-marker (point))
              (move-marker org-log-note-return-to (point))
              (setq org-log-note-window-configuration (current-window-configuration)
                    org-log-note-purpose 'refile
                    org-log-note-state nil
                    org-log-note-previous-state nil
                    org-log-note-how 'time
                    org-log-note-extra nil
                    org-log-note-effective-time (org-current-effective-time))
              (let ((b (get-buffer-create " *ecl-org-note*")))
                (unwind-protect
                    (with-current-buffer b
                      (erase-buffer)
                      (org-store-log-note))
                  (when (buffer-live-p b) (kill-buffer b)))))))
         (when (markerp new-loc) (move-marker new-loc nil))))
      (ecl-org--save)
      (unless (eq (current-buffer) dest-buf)
        (with-current-buffer dest-buf (ecl-org--save))))
    (format "refiled %s -> %s%s"
            (string-join segments " > ")
            (if to-segments (string-join to-segments " > ") "top level")
            (if to-file (format " in %s" to-file) ""))))

(defun ecl-org--get-keyword (file name)
  "Return the value(s) of the leading #+NAME: keyword in FILE.
Multiple occurrences are joined with newlines; \"\" when none is present."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (let ((case-fold-search t)
           (re (format "^[ \t]*#\\+%s:[ \t]*\\(.*\\)$" (regexp-quote name)))
           vals)
       (while (re-search-forward re nil t)
         (push (string-trim (match-string-no-properties 1)) vals))
       (string-join (nreverse vals) "\n")))))

(defun ecl-org--set-keyword (name value)
  "In the current buffer, set the leading #+NAME: keyword to VALUE.
Replace the first existing #+NAME: line (case-insensitive); if none, insert
after the leading run of #+ keyword lines.  Caller is responsible for saving."
  (goto-char (point-min))
  (let ((case-fold-search t)
        (re (format "^[ \t]*#\\+%s:.*$" (regexp-quote name))))
    (if (re-search-forward re nil t)
        (replace-match (format "#+%s: %s" name value) t t)
      (goto-char (point-min))
      (while (looking-at "^[ \t]*#\\+") (forward-line 1))
      (insert (format "#+%s: %s\n" name value)))))

(defun ecl-org-get-filetags (file)
  "Return FILE's #+FILETAGS value."
  (ecl-org--get-keyword file "FILETAGS"))

(defun ecl-org-get-todo-keywords (file)
  "Return FILE's #+TODO keyword spec line(s)."
  (ecl-org--get-keyword file "TODO"))

(defun ecl-org-set-filetags (file tags-string)
  "Set FILE's #+FILETAGS from TAGS-STRING (whitespace/colon separated); save.
An empty TAGS-STRING clears the value."
  (let ((tags (split-string tags-string "[ \t:]+" t)))
    (with-current-buffer (ecl-org--buffer file)
      (org-with-wide-buffer
       (ecl-org--set-keyword "FILETAGS"
                            (if tags (concat ":" (string-join tags ":") ":") ""))
       (ecl-org--save))
      nil)))

(defun ecl-org-set-todo-keywords (file spec)
  "Set FILE's #+TODO keyword spec to SPEC, re-parse options, and save.
Replaces the first #+TODO line; consolidate manually if several exist."
  (with-current-buffer (ecl-org--buffer file)
    (org-with-wide-buffer
     (ecl-org--set-keyword "TODO" spec)
     (org-set-regexps-and-options)
     (ecl-org--save))
    nil))

(defconst ecl-org-commands
  `(("outline" . ecl-org-outline)
    ("section"
     :usage "[--subtree] [--with-etag] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Print the content of the heading at SEG... in FILE.
Content only: after the heading line (property drawer included) up to
the first child heading -- exactly what replace can edit.  --subtree
prints the entire subtree (heading line and children) instead.
--with-etag adds a leading #+ETAG: line to hand to --if-match; the
etag covers whichever of the two you asked for."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--subtree" . boolean)
                                               ("--with-etag" . boolean))
                                        0
                                        "ecl org section [--subtree] [--with-etag] FILE SEG...")))
              (ecl-org-section file segs
                               (cdr (assoc "--subtree" opts))
                               (cdr (assoc "--with-etag" opts))))))
    ("append" :stdin t
     :usage "FILE SEG..."
     :fn ,(lambda (&rest args)
            "Append piped stdin to the end of the content at SEG... in FILE.
Inserts before the first child heading.  Body text only -- payloads
containing org heading lines are rejected; new sub-headings go
through `ecl org create'.  Content should include its own leading
newline."
            (pcase-let ((`(,_ ,file ,segs)
                         (ecl-org--args args nil 0
                                        "ecl org append FILE SEG...")))
              (ecl-org-append-section file segs ecl-stdin))))
    ("replace" :stdin t
     :usage "[--regexp] [--sep SENTINEL] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Replace OLD with NEW inside the content at SEG... in FILE.
Stdin holds OLD/NEW chunks separated by lines equal to SENTINEL
\(default @@REPLACE@@); several pairs may be given in one call.
Scope is the section's content only (no heading lines).  Literal
match unless --regexp (Emacs regexp, \\N backrefs in NEW).  Atomic:
every OLD must match or nothing is written.  Prints one replacement
count per pair."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--regexp" . boolean)
                                               ("--sep" . value))
                                        0
                                        "ecl org replace [--regexp] [--sep SENTINEL] FILE SEG...")))
              (ecl-org-replace-section
               file segs
               (ecl-org--split-pairs ecl-stdin
                                     (or (cdr (assoc "--sep" opts))
                                         "@@REPLACE@@"))
               (cdr (assoc "--regexp" opts))))))
    ("cut" :stdin t
     :usage "[--regexp] [--sep SENTINEL] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Remove text from the content at SEG... in FILE.
Stdin holds the text to remove; several chunks may be given in one
call, separated by lines equal to SENTINEL (default @@CUT@@), and a
single chunk needs no sentinel.  Scope is the section's content only
\(no heading lines) -- removing a whole subtree is `ecl org delete'.
Literal match unless --regexp.  Atomic: every chunk must match or
nothing is written.  Prints one removal count per chunk."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--regexp" . boolean)
                                               ("--sep" . value))
                                        0
                                        "ecl org cut [--regexp] [--sep SENTINEL] FILE SEG...")))
              (ecl-org-cut-section
               file segs
               (ecl-org--cut-chunks ecl-stdin
                                    (or (cdr (assoc "--sep" opts)) "@@CUT@@"))
               (cdr (assoc "--regexp" opts))))))
    ("create" :stdin optional
     :usage "[--parents] [--todo STATE] [--effort E] [--tag T]... [--property K=V]... [--clear-body] [--if-match ETAG] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Create or update the heading at SEG... in FILE (upsert).
A missing leaf is created as the last child of its parent; missing
intermediates error unless --parents.  On an existing heading only
the passed metadata is touched: --todo (no state-change logging),
--effort, --tag (repeatable, added), --property K=V (repeatable,
empty V removes).  Non-empty stdin replaces the body; empty stdin
leaves it untouched (clearing only via --clear-body).

--if-match ETAG is required when rewriting the body of a heading
that already exists -- that overwrites whatever arrived since you
read it.  Get one from `ecl org section --with-etag'.  Setting
metadata and creating a new heading need no etag."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--parents" . boolean)
                                               ("--todo" . value)
                                               ("--effort" . value)
                                               ("--tag" . repeat)
                                               ("--property" . repeat)
                                               ("--clear-body" . boolean)
                                               ("--if-match" . value))
                                        0
                                        "ecl org create [--parents] [--todo STATE] [--effort E] [--tag T]... [--property K=V]... [--clear-body] [--if-match ETAG] FILE SEG...")))
              (ecl-org-create file segs
                              (cdr (assoc "--todo" opts))
                              (cdr (assoc "--effort" opts))
                              (cdr (assoc "--tag" opts))
                              (cdr (assoc "--property" opts))
                              (cdr (assoc "--parents" opts))
                              (cdr (assoc "--clear-body" opts))
                              ecl-stdin
                              (cdr (assoc "--if-match" opts))))))
    ("delete"
     :usage "[--if-match ETAG] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Remove the entire subtree at SEG... in FILE.
The subtree is cut, so it stays recoverable from the Emacs kill ring.
--if-match ETAG is required: the subtree may have grown children
since you read it, and they go too.  Get one from
`ecl org section --subtree --with-etag'."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--if-match" . value)) 0
                                        "ecl org delete [--if-match ETAG] FILE SEG...")))
              (ecl-org-delete file segs (cdr (assoc "--if-match" opts))))))
    ("rename"
     :usage "FILE SEG... TITLE"
     :fn ,(lambda (&rest args)
            "Retitle the heading at SEG... in FILE to TITLE, in place.
Stars, TODO keyword, priority and tags are preserved."
            (pcase-let ((`(,_ ,file ,segs ,title)
                         (ecl-org--args args nil 1
                                        "ecl org rename FILE SEG... TITLE")))
              (ecl-org-rename file segs title))))
    ("refile"
     :usage "[--to SEG]... [--to-file DEST] [--if-match ETAG] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Move the subtree at SEG... in FILE under the --to path (like C-c C-w).
The subtree's level adapts to the destination; --to repeats one
destination segment per outline level, and no --to refiles to the
top level.  --to-file DEST moves it into another file (default
FILE).  Honors org-log-refile.  --if-match ETAG is required, and
covers the source subtree -- get one from
`ecl org section --subtree --with-etag'."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--to" . repeat)
                                               ("--to-file" . value)
                                               ("--if-match" . value))
                                        0
                                        "ecl org refile [--to SEG]... [--to-file DEST] [--if-match ETAG] FILE SEG...")))
              (ecl-org-refile file segs
                              (cdr (assoc "--to-file" opts))
                              (cdr (assoc "--to" opts))
                              (cdr (assoc "--if-match" opts))))))
    ("blocks" . ecl-org-blocks)
    ("block"
     :usage "[--full] [--with-etag] FILE NAME"
     :fn ,(lambda (&rest args)
            "Print the body of the src block named NAME in FILE.
Body only -- the text between #+begin_src and #+end_src.  --full
prints the whole block instead, from its #+name: line through
#+end_src (header args included).  --with-etag adds a leading
#+ETAG: line for set-block's --if-match; it covers the body either
way.  Blocks are addressed by name, not by outline path;
`ecl org blocks' lists the names."
            (pcase-let ((`(,opts ,file ,segs ,name)
                         (ecl-org--args args '(("--full" . boolean)
                                               ("--with-etag" . boolean))
                                        1
                                        "ecl org block [--full] [--with-etag] FILE NAME"
                                        0)))
              (when segs
                (error "usage: ecl org block [--full] [--with-etag] FILE NAME\n\
extra args between FILE and NAME: %s" (string-join segs " ")))
              (ecl-org-block file name
                             (cdr (assoc "--full" opts))
                             (cdr (assoc "--with-etag" opts))))))
    ("set-block" :stdin t
     :usage "[--if-match ETAG] FILE NAME"
     :fn ,(lambda (&rest args)
            "Replace the body of the src block named NAME in FILE with stdin.
The #+name: line, the header arguments and every neighbouring line
are left alone -- unlike `ecl org create', which rewrites a whole
section body.  Stdin is written verbatim; any stale #+RESULTS: is
left as it is.  --if-match ETAG is required: the whole body goes.
Get one from `ecl org block --with-etag'."
            (pcase-let ((`(,opts ,file ,segs ,name)
                         (ecl-org--args args '(("--if-match" . value)) 1
                                        "ecl org set-block [--if-match ETAG] FILE NAME"
                                        0)))
              (when segs
                (error "usage: ecl org set-block [--if-match ETAG] FILE NAME\n\
extra args between FILE and NAME: %s" (string-join segs " ")))
              (ecl-org-set-block file name ecl-stdin
                                 (cdr (assoc "--if-match" opts))))))
    ("run" . ecl-org-run)
    ("tangle"
     :usage "[--block NAME] FILE [SEG...]"
     :fn ,(lambda (&rest args)
            "Tangle src blocks in FILE; print the files written, one per line.
No path tangles the whole file; SEG... tangles every block in that
subtree; --block tangles the one #+name'd block."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--block" . value)) 0
                                        "ecl org tangle [--block NAME] FILE [SEG...]"
                                        0)))
              (ecl-org-tangle file (cdr (assoc "--block" opts)) segs))))
    ("attach"
     :usage "FILE SEG... SOURCE"
     :fn ,(lambda (&rest args)
            "Attach SOURCE to the heading at SEG... in FILE (a copy by default).
Tags the heading ATTACH and prints its attachment directory."
            (pcase-let ((`(,_ ,file ,segs ,source)
                         (ecl-org--args args nil 1
                                        "ecl org attach FILE SEG... SOURCE")))
              (ecl-org-attach file segs source))))
    ("attach-dir"
     :usage "FILE SEG..."
     :fn ,(lambda (&rest args)
            "Print the attachment directory of the heading at SEG... in FILE.
Pure query: neither creates the directory nor assigns an ID."
            (pcase-let ((`(,_ ,file ,segs)
                         (ecl-org--args args nil 0
                                        "ecl org attach-dir FILE SEG...")))
              (ecl-org-attach-dir file segs))))
    ("attachments"
     :usage "FILE SEG..."
     :fn ,(lambda (&rest args)
            "List the filenames attached to the heading at SEG... in FILE."
            (pcase-let ((`(,_ ,file ,segs)
                         (ecl-org--args args nil 0
                                        "ecl org attachments FILE SEG...")))
              (ecl-org-attachments file segs))))
    ("status"
     :usage "[--note NOTE] FILE SEG... STATE"
     :fn ,(lambda (&rest args)
            "Set the TODO state of the heading at SEG... in FILE to STATE.
Honors the file's #+TODO logging; states flagged @ require --note
\(any logging state records it when given).  Prints the new state."
            (pcase-let ((`(,opts ,file ,segs ,state)
                         (ecl-org--args args '(("--note" . value)) 1
                                        "ecl org status [--note NOTE] FILE SEG... STATE")))
              (ecl-org-set-status file segs state
                                  (cdr (assoc "--note" opts))))))
    ("note"
     :usage "FILE SEG... NOTE"
     :fn ,(lambda (&rest args)
            "Add a timestamped log note to the heading at SEG... in FILE.
Files the note into the heading's LOGBOOK drawer (honoring
org-log-into-drawer), like C-c C-z.  NOTE must be non-empty."
            (pcase-let ((`(,_ ,file ,segs ,note)
                         (ecl-org--args args nil 1
                                        "ecl org note FILE SEG... NOTE")))
              (ecl-org-add-note file segs note))))
    ("effort"
     :usage "FILE SEG... EFFORT"
     :fn ,(lambda (&rest args)
            "Set the Effort estimate of the heading at SEG... in FILE.
EFFORT is an Org effort string such as 0:30 or 2d; an empty EFFORT
\(\"\") removes it.  Prints the new value, or nothing when cleared."
            (pcase-let ((`(,_ ,file ,segs ,effort)
                         (ecl-org--args args nil 1
                                        "ecl org effort FILE SEG... EFFORT")))
              (ecl-org-set-effort file segs effort))))
    ("effort-get"
     :usage "[--inherit] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Print the Effort estimate of the heading at SEG... in FILE.
Reads the heading's own Effort; with --inherit, falls back to the
nearest ancestor's Effort when the heading has none."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--inherit" . boolean)) 0
                                        "ecl org effort-get [--inherit] FILE SEG...")))
              (ecl-org-get-effort file segs
                                  (cdr (assoc "--inherit" opts))))))
    ("property"
     :usage "FILE SEG... NAME VALUE"
     :fn ,(lambda (&rest args)
            "Set property NAME of the heading at SEG... in FILE to VALUE.
An empty VALUE removes the property.  Prints the new value, or nil
when cleared."
            (pcase-let ((`(,_ ,file ,segs ,name ,value)
                         (ecl-org--args args nil 2
                                        "ecl org property FILE SEG... NAME VALUE")))
              (ecl-org-set-property file segs name value))))
    ("property-get"
     :usage "[--inherit] FILE SEG... NAME"
     :fn ,(lambda (&rest args)
            "Print property NAME of the heading at SEG... in FILE, or nil.
With --inherit, fall back to the nearest ancestor that sets NAME."
            (pcase-let ((`(,opts ,file ,segs ,name)
                         (ecl-org--args args '(("--inherit" . boolean)) 1
                                        "ecl org property-get [--inherit] FILE SEG... NAME")))
              (ecl-org-get-property file segs name
                                    (cdr (assoc "--inherit" opts))))))
    ("properties"
     :usage "FILE SEG..."
     :fn ,(lambda (&rest args)
            "List the heading at SEG... in FILE's own properties, one NAME: VALUE per line."
            (pcase-let ((`(,_ ,file ,segs)
                         (ecl-org--args args nil 0
                                        "ecl org properties FILE SEG...")))
              (ecl-org-get-properties file segs))))
    ("filetags" . ecl-org-get-filetags)
    ("set-filetags" . ,(lambda (file &rest tags)
                         "Set FILE's #+FILETAGS to TAGS; no TAGS clears the value."
                         (ecl-org-set-filetags file (string-join tags " "))))
    ("todo-keywords" . ecl-org-get-todo-keywords)
    ("set-todo-keywords" . ecl-org-set-todo-keywords)
    ("agenda-files" . ,(lambda ()
                         "List the files org-agenda scans."
                         (bound-and-true-p org-agenda-files)))
    ("private-tags" . ,(lambda ()
                         "List the tags that put a heading out of reach here.
A heading carrying one -- or inheriting one from an ancestor or from
#+FILETAGS: -- is neither readable nor editable through `ecl org'.
It shows in `ecl org outline' as <hidden :TAG:>."
                         (string-join ecl-org-private-tags "\n"))))
  "Command entries of the `ecl org' group, in listing order.")

(defconst ecl-org-command-group
  `("org"
    :help "Org file tools (headings addressed as positional path segments)"
    :commands ,ecl-org-commands)
  "Complete `org' group entry for `ecl-commands'.
Register it with (ecl-register ecl-org-command-group).")

(provide 'ecl-org)
;;; ecl-org.el ends here

