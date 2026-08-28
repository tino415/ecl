# ecl

Call allowlisted functions in a running Emacs daemon from the shell —
built for coding agents that need a curated, safe surface into Emacs
instead of raw `emacsclient --eval`.

- `bin/ecl` — client: forwards argv, stdin and cwd over `server-eval-at`,
  formats the reply. `ECL_SERVER` selects the daemon (default `server`).
- `ecl.el` — framework: command tree (`ecl-commands`), dispatch, help,
  per-command y-or-n-p confirmation, stdin handshake, pending requests.
  A yes/no prompt reached by a running command becomes an error — see
  below.
- `ecl-eval.el` — elisp module: `ecl eval` runs code in the daemon, but
  only after a human approves it in an Emacs buffer.
- `ecl-browse.el` — browser module: `ecl browse-url URL` opens a page
  through the daemon's `browse-url`, after a y-or-n-p in Emacs. The
  target must be a URL with a scheme.
- `ecl-shell.el` — shell module: `ecl shell run` shows a command in an
  Emacs buffer, runs it in the caller's folder once approved, and answers
  with a handle to read the output back by (`wait`, `output`, `list`,
  `kill`).
- `ecl-org.el` — org module: heading-addressed queries and edits
  (`ecl org outline|section|append|replace|cut|create|delete|rename|refile|...`).
  Headings are positional path segments; text edits are scoped to a
  section's content, structure has its own commands. Babel blocks are the
  exception: `blocks|block|set-block|run|tangle --block` address a
  `#+name:`, so one block can be rewritten without touching the prose
  around it. A heading tagged `:noai:` is out of reach, and a command
  that replaces a whole region wants an etag of it — both below.

## Wiring

```elisp
(use-package ecl)                 ; framework; ecl-commands starts empty

(use-package ecl-org              ; org module from this package
  :after ecl
  :config (ecl-register ecl-org-command-group))

(use-package ecl-eval             ; elisp, gated on approval in Emacs
  :after ecl
  :config (ecl-register ecl-eval-command))

(use-package ecl-browse           ; browse-url, gated on y-or-n-p
  :after ecl
  :config (ecl-register ecl-browse-command))

(use-package ecl-shell            ; shell commands, gated on approval
  :after ecl
  :config (ecl-register ecl-shell-command-group))

(use-package my-local-module      ; your own glue registers the same way
  :after ecl
  :config (ecl-register `("project" :help "..." :commands (...))))
```

`ecl-register` adds or replaces a group by name (idempotent), so
re-evaluating a module's block updates the table.

## Headings the agent does not get

A heading tagged with one of `ecl-org-private-tags` — `noai`, `crypt`,
`private`, `secret` by default, matched case-insensitively — is refused by
every `ecl org` command, reads and edits alike. The tag is inherited, so it
covers the subtree under it, and `#+FILETAGS: :noai:` covers a whole file.
`ecl org private-tags` prints the current list.

```org
* Bank                              :noai:
** Card                                        <- covered, by inheritance
```

```sh
ecl org outline ~/org/todo.org
# * Projects
# * <hidden :noai:>              <- place kept, title and children not
ecl org section ~/org/todo.org Bank
# "Bank" is tagged noai; not available to agents    (exit 2)
```

Refusal is wider than the obvious reads: a public parent will not hand out a
private child via `section --subtree`, `delete` or `refile`; `blocks` omits
blocks under a private heading; and `tangle` declines a scope containing one
rather than writing its body to a file. Adding the tag is still allowed
(`ecl org create --tag noai ...`) — removing it is not. `crypt` is in the
defaults because an org-crypt subtree sits decrypted in the daemon's buffer,
which is what these commands read.

This gates the sanctioned tool path, not the file. Anything that can run
`cat` on the org file reads it regardless; for that, deny the file.

## Where a new heading lands

`create` puts a missing leaf at the end of its parent — below a trailing
`* Archive :ARCHIVE:`, not above it. `refile` lands there too.

This matches Org: `org-capture` into `(file F)` and `(file+headline F H)`
both append below the archive sibling, `org-refile` does the same, and
`org-archive-to-archive-sibling` only ever creates that sibling "at the end
of the subtree". Org's one lever is first-child vs last-child (`:prepend`,
`org-reverse-note-order`), which is a different axis. `C-c C-w` and `C-c c`
already do this to you, so nothing here special-cases it.

## Questions nobody can answer

Emacs is single-threaded. A command that reaches `y-or-n-p` with only a
pipe on the other end stops the daemon answering *anything* — `(emacs-pid)`
included — and killing the client does not free it. So every yes/no prompt
raised while a command runs is turned into an error instead. The one
exception is the `:confirm` question, which is asked before the command
starts, with the caller waiting on the answer.

The prompt this actually rescues is a file that moved under the daemon —
a `git checkout`, a rebase, another editor:

```sh
ecl org section ~/org/todo.org Notes   # daemon visits the file
git checkout main                      # todo.org changes on disk
ecl org append ~/org/todo.org Notes    # would have wedged the daemon
```

`ecl org` settles that before Emacs can ask. A buffer with no unsaved
changes is simply reread — there is nothing to lose, and refusing would
block every command until someone reverted it by hand. A buffer that *is*
modified holds a second version, and picking a side would throw one away:

```sh
ecl org append ~/org/todo.org Notes <<< x
# ecl: ~/org/todo.org changed on disk while the Emacs buffer has unsaved
#      changes; resolve it in Emacs first          (exit 2)
```

Nothing is written and the buffer is left alone, so Emacs still offers its
own diff on the next visit. That resolution is a human's; these commands
only decline to pre-empt it.

## Not writing over another agent

Every dispatch is serialised — the daemon is single-threaded — so two
commands never interleave. What they do instead is lose each other's
work: read a section, spend a minute composing, write it back over an
edit that arrived meanwhile.

Most commands cannot do that. `replace` and `cut` need every OLD to still
be there; `append` and `note` merge; `status`, `effort` and `property`
set one scalar. The four that replace a whole region blind take an etag
of that region first:

```sh
ecl org section --with-etag ~/org/todo.org Notes
# #+ETAG: content:6f2a1c9d
# Loose note.

ecl org create --if-match content:6f2a1c9d ~/org/todo.org Notes <<'EOF'
rewritten
EOF
```

Without `--with-etag` the output is unchanged, so pipelines and the
`block | set-block` round trip are unaffected.

| command | needs | etag covers |
| --- | --- | --- |
| `create` with a body or `--clear-body` | on a heading that already exists | the section's content |
| `set-block` | always | the block body |
| `delete`, `refile` | always | the whole subtree |

The scope is part of the etag, so handing `delete` a `content:` one is a
different answer from handing it a stale one:

```sh
ecl org delete --if-match content:6f2a1c9d ~/org/todo.org Notes
# ecl: delete checks the subtree; re-read with:
#        ecl org section --subtree --with-etag ~/org/todo.org Notes
```

Scoping to what you read also means a concurrent `rename` or `status`
does not invalidate a body rewrite — those do not conflict. Nothing is
written on a refusal.

Metadata-only `create` needs no etag (it overwrites no text), and neither
does creating a heading that is not there yet — there would be nothing to
match. `ecl-org-require-if-match` lists the guarded commands; set it to
nil for a scripted bulk edit, and an etag you do pass is still checked.

## Whose unsaved work it is

An edit is written out, because `git`, `rg` and everything else that is
not this daemon reads the file rather than the buffer. The exception is a
buffer you were already editing: saving that would flush an unfinished
edit of yours somewhere else in the file, on the timing of an agent that
knows nothing about it.

So a command onto a modified buffer leaves the change in memory and says
nothing. Your next `C-x C-s` writes both. The next command after that
saves again — it is a per-command decision, not a mode the buffer gets
stuck in.

The cost is that while you sit on unsaved changes, `git status` in
`~/org` will not show what an agent just wrote. It is in the buffer, and
`ecl org section` reads it back.

## Approving elisp

```sh
printf '(length (buffer-list))' | ecl eval
ecl eval '(emacs-version)'
```

The code appears in an `*ecl eval N*` buffer — ordinary `emacs-lisp-mode`,
so it is font-locked, indented and **editable**. `C-c C-c` evaluates the
buffer as it stands (fix a near-miss instead of rejecting it); `C-c C-k`
asks for a reason and returns it to the caller; killing the buffer denies.
There is no timeout and no way to skip the prompt.

Approved calls print the value of the last form, followed by a
`--- messages ---` section with anything the code printed or messaged.
Denial exits 3, an error while evaluating exits 2.

Two protocols keep this from blocking the daemon. A command that needs a
human returns `(ecl-pending ID)` from `ecl-pending-start` and answers the
client immediately; the client polls `ecl-poll` until the UI calls
`ecl-pending-resolve`, and sends `ecl-cancel` if it is killed first. So
Emacs stays usable — including for the review itself — while a request
waits, and no review buffer outlives its caller.

## Running a shell command

```sh
cd ~/Projects/thing
printf 'mix test --only integration' | ecl shell run
# 3
# read it back with: ecl shell wait 3
```

The command lands in an `*ecl shell approve N*` buffer — `sh-mode`, so it
is font-locked and **editable** — with the folder it would run in on the
header line. `C-c C-c` runs the buffer as it stands, `C-c C-k` denies with
a reason, killing the buffer denies. Same protocol as `ecl eval` above,
and the same absence of a timeout.

That folder is the client's working directory and nothing else. There is
no flag to point it elsewhere: a caller picks the folder by being in it,
the way every other shell tool works.

Approval answers with a handle rather than with output. The command runs
in a compilation buffer the user can watch, and the caller reads it back:

| command | |
| --- | --- |
| `ecl shell wait 3` | the whole output, once it exits; exit 2 if the command failed |
| `ecl shell output 3` | what it has printed so far, without waiting |
| `ecl shell output 3 --from 512` | the same, past the first 512 characters |
| `ecl shell list` | handle, status and command for every job still held |
| `ecl shell kill 3` | interrupt it; the output stays readable |

`wait` is a pending request like the approval itself, so a caller sitting
on a slow test suite does not stop the daemon answering everything else.
Interrupting a `wait` abandons the reading, not the command — `kill` is
for that.

A handle is all these commands take, and handles only name jobs that
`ecl shell run` started. An arbitrary Emacs buffer cannot be spelled, so
`output` stays a way to read your own command back rather than a reader
for the rest of the session. A job is held until its buffer is killed,
and `ecl shell list` is what is still there.

## Tests

All test entry points are Makefile file targets — run these, nothing else:

```sh
make static-results.txt   # byte-compile check
make test-results.txt     # ERT unit suites (batch, no daemon)
make e2e-results.txt      # end-to-end via bin/ecl against emacs -Q --daemon=testing
make check                # all three
```

The e2e layer starts a throwaway daemon named `testing`; it never touches
your live Emacs.

## Debugging

A throwaway daemon of your own, on a socket inside the checkout:

```sh
make .debug/socket                      # emacs -Q --daemon on .debug/socket
./test/decl org outline ~/some/file.org # bin/ecl pointed at that socket
make debug-down                         # stop it
make debug-results.txt                  # timed probe table, DEBUG_ORG=FILE
```

`test/decl` has the socket path baked in, so it cannot reach your real
daemon; `make .debug/socket` restarts the daemon whenever the elisp
changes. `test/debug-daemon.sh eval FORM` evaluates a form in it (over
`server-eval-at`, like the client) when a probe needs more than the
command surface.

The daemon loads `test/debug-init.el`, which is `test/e2e-init.el` plus
`enable-dir-local-variables` nil — see the comment there for why a `-Q`
daemon otherwise wedges on files under your home directory for reasons
that have nothing to do with what you are debugging.

## Install

**Elisp** (any system with Emacs 29+): straight from git via the
built-in `:vc` keyword, pinned to a tested revision:

```elisp
(use-package ecl
  :vc (:url "https://github.com/tino415/ecl" :rev "<sha>")
  ...)
```

Releasing = green `make check`, commit, bump `:rev`. Note that a `:rev`
change does not rebuild an already-installed package — run
`M-x package-vc-rebuild` after updating the checkout, or delete
`~/.emacs.d/elpa/ecl` and restart. Avoid `package-vc-upgrade`: it pulls
HEAD past the pin.

**Client** (`bin/ecl`) must be on PATH separately. On nix, `default.nix`
builds it — consume via `builtins.fetchGit` pinned to the same rev.
Elsewhere, symlink `~/.emacs.d/elpa/ecl/bin/ecl` into a PATH directory.
