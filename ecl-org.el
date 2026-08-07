;;; ecl-org.el --- Org file commands for the ecl shell client -*- lexical-binding: t; -*-

;;; Commentary:
;; Org module for ecl: heading-addressed queries and edits on org files,
;; exposed to shell callers (primarily coding agents) as `ecl org ...'.
;;
;; Headings are addressed as positional path segments -- one argument per
;; outline level -- and every path command follows the grammar
;; [--flags] FILE SEG... [FIXED-DATA] (exactly one elastic run; anything
;; optional is a front flag or stdin).  Text edits (append, replace,
;; create body) are scoped to a section's CONTENT -- after the heading
;; line, property drawer included, up to the first child heading; the
;; tree structure is only reachable through its own commands (create,
;; delete, rename, status).
;;
;; Register the command group from your init file:
;;   (use-package ecl-org
;;     :after ecl
;;     :config (ecl-register ecl-org-command-group))

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-attach)
(require 'ecl)

(defun ecl-org--file (file)
  "Expand FILE against the ecl client's cwd when dispatched via ecl."
  (expand-file-name file (or (bound-and-true-p ecl-directory) default-directory)))

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
show which arguments were NOT taken as path segments."
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

(defun ecl-org-outline (file)
  "Return outline of FILE: one heading per line as `STARS [TODO ]TITLE'."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (let (lines)
       (org-map-entries
        (lambda ()
          (let* ((c (org-heading-components))
                 (level (nth 0 c))
                 (todo  (nth 2 c))
                 (title (nth 4 c)))
            (push (concat (make-string level ?*)
                          (when todo (concat " " todo))
                          " " title)
                  lines))))
       (mapconcat #'identity (nreverse lines) "\n")))))

(defun ecl-org-section (file segments &optional subtree)
  "Return the content of the heading at SEGMENTS in FILE.
By default only the section's own content -- from after the heading line
\(property drawer included) to the first child heading -- i.e. exactly
the region `ecl-org-replace-section' can edit.  With SUBTREE non-nil,
the entire subtree (heading line and children included).  The result
always ends in a newline."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (let* ((bounds (if subtree
                        (cons (line-beginning-position)
                              (save-excursion (org-end-of-subtree t t) (point)))
                      (ecl-org--content-region)))
            (text (buffer-substring-no-properties (car bounds) (cdr bounds))))
       (if (string-suffix-p "\n" text) text (concat text "\n"))))))

(defun ecl-org-append-section (file segments content)
  "Append CONTENT to the end of the content of the heading at SEGMENTS in FILE.
Inserts before the first child heading (body text only -- CONTENT may not
contain org heading lines; new sub-headings go through `ecl-org-create').
CONTENT should include its own leading newline.  Saves the buffer."
  (when (string-match-p "^\\*+ " content)
    (error "Content contains an org heading line; use `ecl org create' for structure"))
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (goto-char (cdr (ecl-org--content-region)))
     (insert (if (string-suffix-p "\n" content) content (concat content "\n"))))
    (save-buffer))
  nil)

(defun ecl-org-run (file name)
  "Execute the babel src block named NAME (via #+name:) in FILE.
Return result as string. Inserts #+RESULTS: in buffer and saves.
Bypasses `org-confirm-babel-evaluate'."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (let ((pos (org-babel-find-named-block name)))
       (unless pos (error "No src block named '%s' in %s" name file))
       (goto-char pos)
       (let* ((org-confirm-babel-evaluate nil)
              (result (org-babel-execute-src-block)))
         (save-buffer)
         (format "%s" (or result "")))))))

(defun ecl-org-tangle (file &optional block segments)
  "Tangle src blocks in FILE, returning the list of files written.
With BLOCK, tangle only the src block named BLOCK (via #+name:).
With SEGMENTS (an outline path as a list), tangle every block in that
subtree.  With neither, tangle the whole file.  BLOCK and SEGMENTS are
mutually exclusive."
  (when (and block segments)
    (error "Give only one of --block / path segments"))
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (save-restriction
       (cond
        (block
         (let ((pos (org-babel-find-named-block block)))
           (unless pos (error "No src block named '%s' in %s" block file))
           (goto-char pos)
           (org-babel-tangle '(4))))
        (segments
         (goto-char (ecl-org--find-olp segments))
         (org-narrow-to-subtree)
         (org-babel-tangle))
        (t (org-babel-tangle)))))))

(defun ecl-org-attach (file segments source)
  "Attach SOURCE to the heading at SEGMENTS in FILE, using Org's default method.
SOURCE is resolved against the ecl caller's cwd.  Uses `org-attach-method'
\(a copy by default), tags the heading ATTACH, and saves the file.  Returns
the heading's attachment directory."
  (require 'org-attach)
  (let ((src (ecl-org--file source)))
    (unless (file-exists-p src)
      (error "No such file: %s" source))
    (with-current-buffer (find-file-noselect (ecl-org--file file))
      (org-with-wide-buffer
       (goto-char (ecl-org--find-olp
                   segments (format "; trailing arg taken as SOURCE: %S" source)))
       (save-excursion (org-attach-attach src))
       (save-buffer)
       (org-attach-dir)))))

(defun ecl-org-attach-dir (file segments)
  "Return the attachment directory of the heading at SEGMENTS in FILE, or nil.
Pure query: unlike attaching, it neither creates the directory nor
assigns an ID."
  (require 'org-attach)
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (org-attach-dir))))

(defun ecl-org-attachments (file segments)
  "List the filenames attached to the heading at SEGMENTS in FILE.
Returns nil when the heading has no attachment directory."
  (require 'org-attach)
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (let ((dir (org-attach-dir)))
       (and dir (org-attach-file-list dir))))))

(defun ecl-org-blocks (file)
  "List named babel src blocks and #+call: lines in FILE, in document order.
Columns per row: NAME, LANG (\"call:CALLEE\" for a #+call: line), and the
block's resolved :tangle target (or - when it is not tangled).  NAME is
what `ecl org run' and `ecl org tangle --block' address; anonymous blocks
are omitted since they cannot be named on the command line."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (let ((rows
            (org-element-map (org-element-parse-buffer) '(src-block babel-call)
              (lambda (el)
                (when-let ((name (org-element-property :name el)))
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

(defun ecl-org--split-pairs (content sentinel)
  "Split CONTENT on SENTINEL lines into a list of (OLD . NEW) pairs.
One trailing newline (a heredoc artifact) is stripped from CONTENT first.
SENTINEL must appear on a line of its own; chunks pair up in order
\(OLD1 NEW1 OLD2 NEW2 ...), so the count must be even.  An empty OLD or
NEW chunk is an error -- deletion has its own command."
  (when (string-suffix-p "\n" content)
    (setq content (substring content 0 -1)))
  (let ((chunks (split-string content
                              (concat "\n" (regexp-quote sentinel) "\n"))))
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
            (error "Empty NEW chunk; deleting a section is `ecl org delete'"))
          (push (cons old new) pairs)))
      (nreverse pairs))))

(defun ecl-org-replace-section (file segments pairs &optional regexp)
  "Apply PAIRS of (OLD . NEW) replacements to the content at SEGMENTS in FILE.
Scope is the section's content only -- after the heading line (property
drawer included) up to the first child heading; the tree structure is
never touched.  With REGEXP non-nil, each OLD is an Emacs regexp and its
NEW may use \\N backrefs; otherwise literal strings.  Atomic: every OLD
must match or nothing is written.  Returns the per-pair replacement
counts, one per line.  Saves the buffer."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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
       (save-buffer)
       (mapconcat #'number-to-string (nreverse counts) "\n")))))

(defun ecl-org-set-status (file segments state &optional note)
  "Set the TODO STATE of the heading at SEGMENTS in FILE, honoring Org logging.
Drives Org's own logging non-interactively (the `*Org Note*' post-command
hook does not fire under `emacsclient'), so timestamps and state-change notes
are written exactly as Org would, respecting `org-log-into-drawer'.

STATE must be one of the file's TODO keywords.  If entering STATE (or leaving
the current state) is configured to record a note (an `@' flag in `#+TODO:')
and NOTE is nil, signal an error and change nothing.  When NOTE is given it is
recorded for any state that logs.  Returns the new state string."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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
       (save-buffer)
       state))))

(defun ecl-org-add-note (file segments note)
  "Add a timestamped log NOTE to the heading at SEGMENTS in FILE; save buffer.
Files NOTE into the heading's LOGBOOK drawer exactly as the interactive
`org-add-note' (\\[org-add-log-note], `C-c C-z') would, honoring
`org-log-into-drawer'.  Drives `org-store-log-note' directly because the
interactive `*Org Note*' post-command hook never fires under `emacsclient'
\(same technique as `ecl-org-set-status').  Signal an error and change nothing
if NOTE is blank.  Return a short confirmation string."
  (when (or (null note) (string-blank-p note))
    (error "Note text is empty"))
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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
     (save-buffer)
     "note added")))

(defun ecl-org-set-effort (file segments effort)
  "Set the Effort property of the heading at SEGMENTS in FILE to EFFORT; save.
EFFORT is an Org effort string such as \"0:30\", \"1:00\" or \"2d\"; an
empty EFFORT removes the property.  Returns the new Effort value, or nil
when cleared."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as EFFORT: %S" effort)))
     (save-excursion
       (if (string-empty-p effort)
           (org-entry-delete (point) org-effort-property)
         (org-set-effort nil effort)))
     (save-buffer)
     (org-entry-get (point) org-effort-property))))

(defun ecl-org-get-effort (file segments &optional inherit)
  "Return the Effort property of the heading at SEGMENTS in FILE, or nil.
Reads the heading's own Effort; with INHERIT non-nil, fall back to the
nearest ancestor's Effort when the heading has none.  Pure query."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (org-entry-get (point) org-effort-property inherit))))

(defun ecl-org-set-property (file segments name value)
  "Set property NAME of the heading at SEGMENTS in FILE to VALUE; save.
NAME is a property name such as \"Owner\" or \"URL\" (no colons); an
empty VALUE removes the property.  Returns the new value, or nil when
cleared."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments
                 (format "; trailing args taken as NAME VALUE: %S %S" name value)))
     (save-excursion
       (if (string-empty-p value)
           (org-entry-delete (point) name)
         (org-entry-put (point) name value)))
     (save-buffer)
     (org-entry-get (point) name))))

(defun ecl-org-get-property (file segments name &optional inherit)
  "Return property NAME of the heading at SEGMENTS in FILE, or nil.
Reads the heading's own value; with INHERIT non-nil, fall back to the
nearest ancestor that sets NAME.  Pure query."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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

(defun ecl-org-create (file segments todo effort tags properties parents clear-body body)
  "Upsert the heading at SEGMENTS in FILE; save.  Returns what happened.
Creates the leaf as the last child of its parent when missing; a missing
intermediate segment errors unless PARENTS is non-nil (then all missing
segments are created, mkdir -p style).  On the resolved heading, only what
was passed is touched: TODO (set without state-change logging), EFFORT,
TAGS (added to existing tags), and PROPERTIES (a list of K=V strings,
split on the first =; an empty value removes the property).  A non-empty
BODY replaces the section's body -- the content after the planning line
and any leading drawers, up to the first child heading -- while empty
BODY leaves it untouched; clearing is only via CLEAR-BODY."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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
     (let ((n (length segments)) (i 0) (prefix nil) (created nil) pos)
       (while (< i n)
         (let* ((seg (nth i segments))
                (path (append prefix (list seg)))
                (found (condition-case nil (org-find-olp path t) (error nil))))
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
       (save-buffer)
       (format "%s %s" (if created "created" "updated")
               (string-join segments " > "))))))

(defun ecl-org-delete (file segments)
  "Remove the entire subtree at SEGMENTS in FILE; save.
The subtree is cut, so it stays recoverable from the kill ring of the
running Emacs session."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp segments))
     (org-cut-subtree)
     (save-buffer))
    nil))

(defun ecl-org-rename (file segments title)
  "Retitle the heading at SEGMENTS in FILE to TITLE, in place; save.
Stars, TODO keyword, priority and tags are preserved.  Returns TITLE."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (goto-char (ecl-org--find-olp
                 segments (format "; trailing arg taken as TITLE: %S" title)))
     (org-edit-headline title)
     (save-buffer)
     title)))

(defun ecl-org--get-keyword (file name)
  "Return the value(s) of the leading #+NAME: keyword in FILE.
Multiple occurrences are joined with newlines; \"\" when none is present."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
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
    (with-current-buffer (find-file-noselect (ecl-org--file file))
      (org-with-wide-buffer
       (ecl-org--set-keyword "FILETAGS"
                            (if tags (concat ":" (string-join tags ":") ":") ""))
       (save-buffer))
      nil)))

(defun ecl-org-set-todo-keywords (file spec)
  "Set FILE's #+TODO keyword spec to SPEC, re-parse options, and save.
Replaces the first #+TODO line; consolidate manually if several exist."
  (with-current-buffer (find-file-noselect (ecl-org--file file))
    (org-with-wide-buffer
     (ecl-org--set-keyword "TODO" spec)
     (org-set-regexps-and-options)
     (save-buffer))
    nil))

(defvar ecl-org-commands
  `(("outline" . ecl-org-outline)
    ("section"
     :usage "[--subtree] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Print the content of the heading at SEG... in FILE.
Content only: after the heading line (property drawer included) up to
the first child heading -- exactly what replace can edit.  --subtree
prints the entire subtree (heading line and children) instead."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--subtree" . boolean)) 0
                                        "ecl org section [--subtree] FILE SEG...")))
              (ecl-org-section file segs (cdr (assoc "--subtree" opts))))))
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
    ("create" :stdin optional
     :usage "[--parents] [--todo STATE] [--effort E] [--tag T]... [--property K=V]... [--clear-body] FILE SEG..."
     :fn ,(lambda (&rest args)
            "Create or update the heading at SEG... in FILE (upsert).
A missing leaf is created as the last child of its parent; missing
intermediates error unless --parents.  On an existing heading only
the passed metadata is touched: --todo (no state-change logging),
--effort, --tag (repeatable, added), --property K=V (repeatable,
empty V removes).  Non-empty stdin replaces the body; empty stdin
leaves it untouched (clearing only via --clear-body)."
            (pcase-let ((`(,opts ,file ,segs)
                         (ecl-org--args args '(("--parents" . boolean)
                                               ("--todo" . value)
                                               ("--effort" . value)
                                               ("--tag" . repeat)
                                               ("--property" . repeat)
                                               ("--clear-body" . boolean))
                                        0
                                        "ecl org create [--parents] [--todo STATE] [--effort E] [--tag T]... [--property K=V]... [--clear-body] FILE SEG...")))
              (ecl-org-create file segs
                              (cdr (assoc "--todo" opts))
                              (cdr (assoc "--effort" opts))
                              (cdr (assoc "--tag" opts))
                              (cdr (assoc "--property" opts))
                              (cdr (assoc "--parents" opts))
                              (cdr (assoc "--clear-body" opts))
                              ecl-stdin))))
    ("delete"
     :usage "FILE SEG..."
     :fn ,(lambda (&rest args)
            "Remove the entire subtree at SEG... in FILE.
The subtree is cut, so it stays recoverable from the Emacs kill ring."
            (pcase-let ((`(,_ ,file ,segs)
                         (ecl-org--args args nil 0
                                        "ecl org delete FILE SEG...")))
              (ecl-org-delete file segs))))
    ("rename"
     :usage "FILE SEG... TITLE"
     :fn ,(lambda (&rest args)
            "Retitle the heading at SEG... in FILE to TITLE, in place.
Stars, TODO keyword, priority and tags are preserved."
            (pcase-let ((`(,_ ,file ,segs ,title)
                         (ecl-org--args args nil 1
                                        "ecl org rename FILE SEG... TITLE")))
              (ecl-org-rename file segs title))))
    ("blocks" . ecl-org-blocks)
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
                         (bound-and-true-p org-agenda-files))))
  "Command entries of the `ecl org' group, in listing order.")

(defvar ecl-org-command-group
  `("org"
    :help "Org file tools (headings addressed as positional path segments)"
    :commands ,ecl-org-commands)
  "Complete `org' group entry for `ecl-commands'.
Register it with (ecl-register ecl-org-command-group).")

(provide 'ecl-org)
;;; ecl-org.el ends here

