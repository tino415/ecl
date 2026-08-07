# ecl

Call allowlisted functions in a running Emacs daemon from the shell —
built for coding agents that need a curated, safe surface into Emacs
instead of raw `emacsclient --eval`.

- `bin/ecl` — client: forwards argv, stdin and cwd over `server-eval-at`,
  formats the reply. `ECL_SERVER` selects the daemon (default `server`).
- `ecl.el` — framework: command tree (`ecl-commands`), dispatch, help,
  per-command y-or-n-p confirmation, stdin handshake.
- `ecl-org.el` — org module: heading-addressed queries and edits
  (`ecl org outline|section|append|replace|create|delete|rename|...`).
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

## Install (nix)

`default.nix` builds `bin/ecl` plus the elisp under
`share/emacs/site-lisp`. Consume a committed (tested) state via
`builtins.fetchGit` pinned to a rev and add the site-lisp dir to
`load-path`.
