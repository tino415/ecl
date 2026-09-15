---
name: ecl
description: Reach a running Emacs daemon from the shell with the `ecl` client -- read and edit org files by heading path or :ID: instead of slurping them, edit or run a single babel block, and ask the user to approve elisp (`ecl eval`), a command in their Emacs (`ecl shell run`) or a page to open (`ecl browse-url`). Auto-triggers on org-mode files, "project notes", "single file workflow", any reading/writing of org headings, sections or outlines, and on evaluating elisp or running something the user should watch in Emacs.
---

# ecl: a curated surface into a running Emacs daemon

`ecl` forwards a shell call to a running Emacs daemon over `server-eval-at`, reaching only the commands that daemon publishes. Two halves:

- **`ecl org`** -- org files as single-file project documents, addressed by heading. Ungated, and most of this skill.
- **`ecl eval`, `ecl shell`, `ecl browse-url`** -- the daemon itself, each gated on a human approving it in Emacs. See *The other groups*.

This covers what the `ecl` package registers. A daemon may publish groups of its own -- a project runner, a dev server -- which are documented wherever they come from; `ecl --help` is the only truth about what this daemon has.

**Every command is self-documenting.** `ecl --help` lists the groups, `ecl org --help` the verbs, `ecl org <cmd> --help` the exact usage, flags and stdin behaviour. Read those for spelling. This skill is what `--help` cannot tell you: how a heading is addressed, what each verb is scoped to, which writes need a read first, and what happens when a command has to ask a human.

`ECL_SERVER` picks the daemon (default `server`). Exit codes: 0 ok, 2 error, 3 denied by the user, 4 unknown command, 64 usage.

## When to Use

Auto-trigger when the user:
- Mentions an `.org` file as a project notes / brainstorming / task tracker doc
- Asks about a heading, section, or subtree inside an org file
- Asks to add analysis, notes, or generated content under an existing heading
- References the "single file project doc" workflow
- Wants elisp evaluated, or something read or changed in their running Emacs
- Wants a command run where they can watch it, rather than in your own shell
- Wants a page opened in their browser

## Addressing a heading

Positional path segments -- one shell argument per outline level, top-down:

```bash
ecl org section ~/org/project.org "Resources" "Base prompt"
```

- Quote each segment. `/` inside a title is just text: `"API /v2/payouts endpoint"` is one segment.
- Give the title as written -- no stars, no TODO keyword. Case folding depends on the daemon, so do not lean on it.
- A title holding a link also answers to that link's display text, so `*** [[~/p/CLAUDE.local.md][CLAUDE.local.md]]` is reachable as `"CLAUDE.local.md"`. Every link in the title is stripped, bare `[[Vendor API]]` and a link inside a longer heading alike. The literal form is tried first, so a plain sibling of that name wins and its linked sibling keeps its full `[[...]]` form. Two children displaying the same is an error naming the segment, not a coin toss.
- Every path command is `[--flags] FILE SEG... [FIXED-DATA]`: front flags, the file, the path, then any fixed trailing data (`NAME VALUE` for `property`). Multiline content goes on stdin. `--` ends flag parsing.
- **Count your arguments.** Like `cp`, a wrong token count reshuffles the split silently -- a missing segment becomes the trailing datum. A failed lookup prints what resolved and which child is missing, and edits are scoped to one section, so the worst case is one mangled body, never a restructured tree. Run `ecl org outline FILE` first when unsure of the exact text.

`--id ID` addresses the heading carrying that `:ID:` property and **replaces the whole path**, not one segment of it:

```bash
ID=$(ecl org id --create ~/org/todo.org "Projects" "Ship v2")
ecl org rename  --id "$ID" ~/org/todo.org "Ship v3"
ecl org section --id "$ID" ~/org/todo.org      # same heading, new title
```

Mint one when the address has to outlive the title: a heading you drive across turns, one the user is plausibly retitling while you work, a loop that re-reads and re-writes the same section. A path breaks under a rename or refile, and it does not break cleanly -- the next call lands on whatever answers to that path now, or creates it. Not worth it for a one-shot read.

The lookup is exact and stays inside the file you name: no case folding, no link display text, no cross-file ID database. `create --id` only ever updates, so `--parents` beside it is refused. Two headings carrying one ID is an error naming the ID. A heading tagged `:noai:` refuses an ID exactly as it refuses a path.

## What each verb is scoped to

Text edits touch a section's **content**: from after the heading line (planning line and property drawer included) to the first child heading. Structure is never editable as text -- it has its own verbs. Babel blocks are a third layer, addressed by `#+name:` instead of by path, so they keep working when a section is moved or retitled.

**Reads** -- pure queries, no writes:

- `outline FILE` -- every heading as `STARS [TODO ]TITLE`. Cheap: orient with this instead of reading the file.
- `section [--subtree] [--with-etag] FILE SEG...` -- the content region, or the whole subtree with `--subtree`. Always ends in a newline.
- `blocks FILE` -- the **named** src blocks and `#+call:` lines: NAME, LANG (`call:CALLEE` for a call line), and the resolved `:tangle` target or `-`. Anonymous blocks are omitted; they cannot be addressed.
- `block [--full] [--with-etag] FILE NAME` -- a block's body as babel sees it (comma escapes removed); `--full` gives the `#+name:` line, header args and both fences instead.
- `properties`, `property-get [--inherit]`, `effort-get [--inherit]`, `attachments`, `attach-dir`, `id`, `filetags`, `todo-keywords`, `agenda-files`, `private-tags` -- one value or list each. `attach-dir` neither creates the directory nor mints an ID; `id` without `--create` never writes.

**Text edits** -- content only, each saves the file:

- `append FILE SEG...` -- stdin onto the end of the content, before the first child. Body text only; a payload containing a heading line is refused (new headings go through `create`). It merges, so it never conflicts with someone else's edit.
- `replace [--regexp] [--sep S] FILE SEG...` -- OLD/NEW pairs on stdin, separated by a line equal to `@@REPLACE@@`, repeated for several pairs, applied in order. **Atomic**: every OLD must be found or the file is untouched and the exit is non-zero. An empty NEW is an error -- removing text is `cut`.
- `cut [--regexp] [--sep S] FILE SEG...` -- the same protocol without the NEW half; sentinel `@@CUT@@`, one chunk needs none. Same atomicity. This is the tool for dropping a paragraph.
- `set-block [--if-match ETAG] FILE NAME` -- replaces one block's body from stdin. The `#+name:` line, the header args and every neighbouring line are left alone, and a stale `#+RESULTS:` is not touched. **Editing a block is this, never `create`** -- `create` rewrites the whole section body and silently drops the prose around the block.

```bash
ecl org replace ~/org/project.org "Resources" <<'EOF'
the existing integration uses provider A
@@REPLACE@@
the existing integration uses provider B
EOF
```

`--regexp` makes each OLD an Emacs regexp, with `\1` usable in NEW. A trailing newline from the heredoc is stripped before splitting, so cutting a paragraph leaves the blank line that followed it -- include it in the chunk to take it too. If your text contains a line equal to the sentinel, pick another with `--sep`.

**Structure** -- each saves the file:

- `create [--parents] [--todo S] [--effort E] [--tag T]... [--property K=V]... [--clear-body] [--if-match ETAG] FILE SEG...` -- upsert. Creates the leaf as the last child of its parent; on an existing heading only the metadata you pass is touched. `--parents` builds missing intermediates. Body comes from stdin and **replaces** the body; empty stdin never clears (a metadata-only call is `</dev/null`, clearing is `--clear-body`).
- `delete [--if-match ETAG] FILE SEG...` -- cuts the whole subtree, so it stays in the Emacs kill ring of that session.
- `rename FILE SEG... TITLE` -- retitles in place; stars, TODO keyword, priority and tags survive, and sub-heading paths change accordingly.
- `refile [--to SEG]... [--to-id ID] [--to-file DEST] [--if-match ETAG] FILE SEG...` -- the scripted `C-c C-w`. One `--to` per outline level; none at all means the top level of the destination file. Level adapts; drawers, logbook and children move intact. Refiling a heading into its own subtree errors.
- `status [--note NOTE] FILE SEG... STATE` -- a logged TODO transition, honouring the file's `#+TODO:` flags. A state flagged `@` (`WAITING(w@)`, `CANCELLED(c@)`) **requires** `--note`; without one it errors and changes nothing.
- `note FILE SEG... NOTE` -- a timestamped `:LOGBOOK:` note with no state change, as `C-c C-z` would file it. NOTE is one quoted argument, not stdin.
- `effort`, `property`, `set-filetags`, `set-todo-keywords` -- one scalar each, on the exact heading (no inheritance); an empty value clears it.
- `attach FILE SEG... SOURCE` -- copies SOURCE into the heading's attachment dir, tags it `:ATTACH:`, mints an `:ID:` if it has none, prints the directory.

**Babel** -- `run FILE NAME` (see *The run gate*) and `tangle [--block NAME] FILE [SEG...]`, which writes the `:tangle` targets and prints the paths. Tangling evaluates nothing and writes no `#+RESULTS:`; blocks without a `:tangle <file>` header are skipped, and no scope means the whole file.

Reordering siblings under one parent is deliberately absent. That is a job for Emacs.

## Read before you overwrite

Four commands replace a whole region rather than a matched piece of it, so nothing in them would notice work another agent -- or the user, editing in Emacs -- added after you read. They require `--if-match ETAG`:

| command | etag from | covers |
| --- | --- | --- |
| `create` with a body or `--clear-body`, on a heading that already exists | `section --with-etag` | the section's content |
| `set-block` | `block --with-etag` | the block body |
| `delete`, `refile` | `section --subtree --with-etag` | the whole subtree |

Content and etag come back together, so **do not** fetch them in two calls -- that reopens the gap the etag closes.

```bash
ecl org section --with-etag ~/org/todo.org "Notes"
# #+ETAG: content:6f2a1c9d
# Loose note.

ecl org create --if-match content:6f2a1c9d ~/org/todo.org "Notes" <<'EOF'
rewritten
EOF
```

A refusal writes nothing and exits 2, in one of three shapes, each naming what to run next: `needs --if-match` (you skipped the read); `checks the subtree; re-read with: ... --subtree --with-etag` (wrong scope -- a content etag says nothing about children `delete` would also take); `Changed in Emacs since content:...` (someone got there first -- re-read, **reconcile with what is now there**, then write; do not re-fetch the etag and resend the same body, which is exactly the overwrite the check stopped).

Metadata-only `create` needs no etag, and neither does a heading that does not exist yet. **Prefer the verbs that cannot conflict**: `append` and `note` merge, `replace` and `cut` refuse unless every OLD is still present, so they collide only on the lines they touch. Reach for a whole-body `create` when you genuinely mean to discard what is there.

## The run gate

`ecl org run FILE NAME` executes the src block or `#+call:` line named NAME, prints its result, and saves the file with the `#+RESULTS:` drawer. A call line runs **where it sits**, carrying the vars and header args of its own call site, which is the point of one -- the body verbs (`block`, `set-block`, `tangle --block`) want a src block instead, a call line having no body.

Org's own `org-confirm-babel-evaluate` is bypassed -- a prompt raised inside a dispatch has no one to answer it -- and a policy read from the file stands in its place. `ecl-org-run-policy` decides for anything the file does not speak for, and **it asks**; the `ECL_RUN` property overrides it, inherited, so a heading covers its subtree and `#+PROPERTY: ECL_RUN allow` covers a whole trusted runbook, nearest one wins. Values are `allow`, `ask`, `deny`; anything else refuses. A `#+call:` line answers for both ends -- where it sits and the block it names -- with the stricter of the two winning.

- `deny` -> exit 2, nothing runs, and the message names the knob that refused.
- `ask` -> the call blocks (see *The other groups* for what waiting looks like) while a read-only review buffer waits for `C-c C-c`. What runs is the block as the file has it **at approval time**, not what you read earlier.
- Unmarked means asking, so a file of steps the user drives unattended wants `#+PROPERTY: ECL_RUN allow` of its own. Suggest it; do not add it to their file without saying so.

The gate does not replace asking. **Treat any `ecl org run` as executing user-supplied code**: if the block deletes data, force-pushes or calls a paid API, confirm with the user before invoking, whatever the policy says. A block must be named to be addressable -- if the one the user means is anonymous, suggest naming it first.

## Headings the agent does not get

A heading tagged with one of `ecl-org-private-tags` -- `noai`, `crypt`, `private`, `secret` by default, case-insensitive -- is refused by every `ecl org` command, reads and edits alike. The tag is inherited, so it covers its subtree, and `#+FILETAGS:` covers a whole file. It shows in `outline` as `<hidden :TAG:>`.

Refusal is wider than the obvious reads: a public parent will not hand out a private child via `section --subtree`, `delete` or `refile`; `blocks` omits blocks under one; `tangle` declines a scope containing one; and a public `#+call:` line into a private block is refused too. Adding the tag is allowed, removing it is not.

## The other groups: eval, shell, browse-url

Everything above is the `org` group. The rest of the client reaches the daemon itself, and every one of them is **gated on a human in Emacs** -- they are how you ask for something you cannot do from your own shell, not a faster way to do what you already can.

```bash
ecl eval '(emacs-version)'            # or pipe the code in
printf 'mix test --only integration' | ecl shell run
ecl browse-url https://example.com
```

- **`ecl eval [CODE...]`** evaluates elisp *in the running daemon* -- the user's live Emacs, with their buffers, config and state. The code goes up in an editable buffer; `C-c C-c` evaluates **the buffer as it stands**, so what runs may be the user's fixed version of what you sent. Prints the value, then a `--- messages ---` section with anything the code printed. This is the tool for reading or driving Emacs itself, not a general elisp runtime.
- **`ecl shell run [COMMAND...]`** runs a command in **your** working directory after the same approval, and answers with a *handle* rather than output: the command runs in a compilation buffer the user can watch. Read it back with `ecl shell wait HANDLE` (blocks until it exits; exit 2 if the command failed), `ecl shell output HANDLE [--from N]` to tail it without waiting, `ecl shell list`, `ecl shell kill HANDLE`. Reach for it when the user should *see* the run -- a long build, a dev server, a suite they are watching -- not for ordinary shell work you can do yourself.
- **`ecl browse-url URL`** opens a page through the daemon's browser after a `y-or-n-p` in Emacs. Needs a scheme. This one times out (60s) and denies.

What to expect as a caller:

- The call **blocks with no timeout** (`browse-url` excepted), printing `waiting for approval in Emacs` on stderr. Nobody at the keyboard means it waits indefinitely -- say you are about to do it rather than leaving the user to find a stalled call, and do not fire one into a background pipeline.
- **Exit 3 is a denial**, with the user's reason on stderr. It is not an error to retry: take the reason as the answer. Exit 2 is a real failure.
- Killing the client cancels the request and tears the approval buffer down, so an abandoned call leaves nothing behind in the user's Emacs.

## Workflow

1. `ecl org outline FILE` -- get the heading map.
2. `ecl org section FILE SEG...` -- pull only the sections you need; do not `Read` the whole org file. Add `--with-etag` when the write you have in mind needs one. If you will come back to this heading, take an `ecl org id --create` now and address it by `--id` from here on.
3. Do the work.
4. Write back: `append` / `replace` / `cut` for body text, `set-block` for one babel block, `create` for new headings and only for a whole-body rewrite.

The etag is the read from step 2; if step 3 takes a while, that is exactly the window it exists to cover.

**Saving is not always yours.** These commands save the file, so `git` and `rg` see the change -- **unless the user already had unsaved changes in that buffer**. An agent edit will not flush a half-finished edit of theirs, so until they save, `git status` will not show what you wrote, though `ecl org section` reads it back regardless. If the file changed on disk while their buffer holds unsaved changes, every command refuses until they resolve it in Emacs. A file they have open updates in the buffer; they may need `revert-buffer` to see it.
