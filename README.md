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
- `ecl-org.el` — org module: heading-addressed queries and edits
  (`ecl org outline|section|append|replace|cut|create|delete|rename|refile|...`).
  Headings are positional path segments; text edits are scoped to a
  section's content, structure has its own commands. Babel blocks are the
  exception: `blocks|block|set-block|run|tangle --block` address a
  `#+name:`, so one block can be rewritten without touching the prose
  around it. A heading tagged `:noai:` is out of reach — see below.

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
