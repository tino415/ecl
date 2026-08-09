# ecl

Call allowlisted functions in a running Emacs daemon from the shell —
built for coding agents that need a curated, safe surface into Emacs
instead of raw `emacsclient --eval`.

- `bin/ecl` — client: forwards argv, stdin and cwd over `server-eval-at`,
  formats the reply. `ECL_SERVER` selects the daemon (default `server`).
- `ecl.el` — framework: command tree (`ecl-commands`), dispatch, help,
  per-command y-or-n-p confirmation, stdin handshake.
- `ecl-org.el` — org module: heading-addressed queries and edits
  (`ecl org outline|section|append|replace|create|delete|rename|refile|...`).
  Headings are positional path segments; text edits are scoped to a
  section's content, structure has its own commands.

## Wiring

```elisp
(use-package ecl)                 ; framework; ecl-commands starts empty

(use-package ecl-org              ; org module from this package
  :after ecl
  :config (ecl-register ecl-org-command-group))

(use-package my-local-module      ; your own glue registers the same way
  :after ecl
  :config (ecl-register `("project" :help "..." :commands (...))))
```

`ecl-register` adds or replaces a group by name (idempotent), so
re-evaluating a module's block updates the table.

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
