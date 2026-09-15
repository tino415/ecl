---
name: ecl
description: Reach a running Emacs daemon from the shell with the `ecl` client -- read and edit org files by heading path or :ID: instead of slurping them, edit or run a single babel block, and ask the user to approve elisp (`ecl eval`), a command in their Emacs (`ecl shell run`) or a page to open (`ecl browse-url`). Auto-triggers on org-mode files, "project notes", "single file workflow", any reading/writing of org headings, sections or outlines, and on evaluating elisp or running something the user should watch in Emacs.
---

# ecl: a curated surface into a running Emacs daemon

`ecl` forwards a shell call to a running Emacs daemon over `server-eval-at`, reaching only the commands that daemon publishes. Two halves:

- **`ecl org`** -- org files as single-file project documents (typically `~/org/<project>/main.org`), addressed by heading. Ungated: these read and edit files, and this skill is mostly about them. They see the same buffer state the user sees.
- **`ecl eval`, `ecl shell`, `ecl browse-url`** -- the daemon itself, each gated on a human approving it in Emacs. See *The other groups* near the end.

`ECL_SERVER` picks the daemon (default `server`). Every command is self-documenting: `ecl --help` lists the groups, `ecl org --help` lists the org verbs, `ecl org <cmd> --help` shows usage.

## When to Use

Auto-trigger when the user:
- Mentions an `.org` file as a project notes / brainstorming / task tracker doc
- Asks about a heading, section, or subtree inside an org file
- Asks to add analysis, notes, or generated content under an existing heading
- References the "single file project doc" workflow
- Wants elisp evaluated, or something read or changed in their running Emacs
- Wants a command run where they can watch it, rather than in your own shell
- Wants a page opened in their browser

## Heading Path Convention

Headings are addressed as **positional path segments** -- one shell argument per outline level, top-down:

```bash
ecl org section ~/org/project.org "Resources" "Base prompt"
```

- Quote each segment individually; `/` inside a heading title is just text (`"API /v2/payouts endpoint"` is one segment)
- Match the heading title text exactly. Case folding depends on the daemon, so do not lean on it -- give the text as written
- Do NOT include leading stars (`*`) or TODO keywords (`TODO`, `DONE`)
- A heading whose title holds a link also answers to that link's display text: `*** [[~/p/CLAUDE.local.md][CLAUDE.local.md]]` is reachable as `"CLAUDE.local.md"`. Every link in the title is stripped, so a bare `[[Vendor API]]` and a link inside a longer heading (`pozri si nieco k [[SPEC]]`) work the same way. The literal form is tried first, so a plain sibling of that name wins and the linked one still takes its full `[[...]]` form

Every path command follows the grammar `[--flags] FILE SEG... [FIXED-DATA]`: optional front flags, then FILE, then the path segments, then any fixed trailing data (e.g. `NAME VALUE` for `property`). Multiline content goes on stdin. `--` ends flag parsing. `--id ID` stands in for the whole `SEG...` run -- see below.

**Count your arguments.** Like `cp`/`mv`, a wrong token count reshuffles the split silently (a missing segment becomes the trailing datum). Resolution is progressive, so a failed lookup prints what resolved, which child is missing, and which arguments were taken as fixed data. Edits are scoped to one section's content, so a miscount can at worst mangle one body, never restructure the tree.

Always run `ecl org outline` first if unsure of the exact heading text.

## Addressing by ID

A path is spelled out of titles, and titles are what the user edits. `--id ID` addresses the heading carrying that `:ID:` property instead, and **replaces the whole path** rather than one segment of it:

```bash
ID=$(ecl org id --create ~/org/todo.org "Projects" "Ship v2")
ecl org rename  --id "$ID" ~/org/todo.org "Ship v3"
ecl org section --id "$ID" ~/org/todo.org     # same heading, new title
```

Every command below that takes `FILE SEG...` takes `--id ID` in place of the segments -- reads and edits alike, `delete` and `refile` included -- and `refile` takes `--to-id ID` for its destination. It is a front flag, so it goes **before** FILE. Passing both a path and `--id` is an error, not a filter.

**Reach for it when the address has to outlive the title.** A path breaks the moment someone renames or refiles the heading, and it does not break cleanly: the next call lands on whatever answers to that path now, or creates it. Worth minting an ID for:

- a heading you will come back to across turns or sessions -- a task you are driving to done
- anything the user is plausibly retitling while you work
- a loop that re-reads and re-writes the same section

Not worth it for a one-shot read. `outline` plus a path is cheaper than an ID nobody uses twice.

Details that matter:

- The lookup is **exact and scoped to the file you name**: no case folding, no link display text, and no cross-file ID database. If the heading was refiled into another file, name that file -- the ID alone will not find it.
- `create --id` only ever **updates**. An ID names a heading that exists, so there is no path to build, and `--parents` beside it is refused.
- A heading tagged `:noai:` refuses an ID exactly as it refuses a path. The ID is a second door to the same heading, not a way around the tag.
- Two headings carrying one ID is an error naming the ID. Fix the duplicate in Emacs; nothing here picks a winner.
- `attach` assigns an ID as a side effect (Org needs one for the attachment directory), so an attached heading already has an address -- `ecl org id` prints it.

## Content vs Structure

Text edits (`append`, `replace`, `cut`, `create` body) touch only a section's **content**: from after the heading line (planning line and property drawer included) to the first child heading. Structure -- headings themselves -- is never editable as text; it has its own commands: `create`, `delete`, `rename`, `refile`, `status`. Reordering siblings under the same parent is deliberately absent; do that in Emacs.

Babel blocks are a third layer, addressed by `#+name:` instead of a heading path: `blocks`, `block`, `set-block`, `run`, `tangle --block`. **Editing one block is `ecl org set-block`, never `ecl org create`** -- `create` rewrites the whole section body and silently drops the prose around the block.

## Read Before You Overwrite

Four commands replace a whole region rather than a matched piece of it, so nothing in them would notice work another agent -- or the user, editing in Emacs -- added after you read it. They require `--if-match ETAG`:

| command | etag from | covers |
| --- | --- | --- |
| `create` with a body or `--clear-body`, on a heading that already exists | `section --with-etag` | the section's content |
| `set-block` | `block --with-etag` | the block body |
| `delete`, `refile` | `section --subtree --with-etag` | the whole subtree |

```bash
ecl org section --with-etag ~/org/todo.org "Notes"
# #+ETAG: content:6f2a1c9d
# Loose note.

ecl org create --if-match content:6f2a1c9d ~/org/todo.org "Notes" <<'EOF'
rewritten
EOF
```

Content and etag come back together, so **do not** fetch them in two calls -- that reopens the gap the etag closes. Without `--with-etag` the output is unchanged, so `block | set-block` pipelines still work.

A refusal writes nothing and exits 2. Three shapes, each naming what to run next:

- `needs --if-match` -- you skipped the read.
- `checks the subtree; re-read with: ... --subtree --with-etag` -- wrong scope. A content etag says nothing about the children `delete` would also take.
- `Changed in Emacs since content:...` -- someone got there first. Re-read, **reconcile with what is now there**, then write. Do not just re-fetch the etag and resend the same body; that is precisely the overwrite the check stopped.

Metadata-only `create` needs no etag (it overwrites no text), and neither does creating a heading that does not exist yet -- there is nothing to match.

**Prefer the commands that never conflict.** `append` and `note` merge; `replace` and `cut` already refuse unless every OLD is still present, so they conflict only on the lines they actually touch. Reach for a whole-body `create` when you genuinely mean to discard what is there.

## Commands

### ecl org outline FILE

Lists every heading in FILE, one per line, as `STARS [TODO ]TITLE`.

```bash
ecl org outline ~/org/project/main.org
```

Cheap -- read this first to orient before fetching specific sections.

### ecl org section [--subtree] [--with-etag] FILE SEG...

Returns the section's content -- exactly the region `replace` can edit (property drawer included, heading line and children excluded). With `--subtree`, the entire subtree (heading line, body, and sub-headings). Output always ends in a newline.

```bash
ecl org section ~/org/project/main.org "Resources" "Base prompt"
ecl org section --subtree ~/org/project/main.org "Tasks"
```

`--with-etag` prefixes a `#+ETAG:` line for `--if-match`, over whichever scope you asked for -- `content:` by default, `subtree:` with `--subtree`. Without the flag the output is byte-identical to before.

```bash
ecl org section --with-etag ~/org/todo.org "Notes"
# #+ETAG: content:6f2a1c9d
# Loose note.
```

### ecl org append FILE SEG...

Appends stdin to the end of the section's content (before the first child heading), then saves the file. Body text only: payloads containing org heading lines are rejected -- new sub-headings go through `ecl org create`. Errors if nothing is piped.

CONTENT should include its own leading newline. Pipe it in with a heredoc:

```bash
ecl org append ~/org/project/main.org "Resources" <<'EOF'

Body paragraph 1.

Body paragraph 2.
EOF
```

### ecl org replace [--regexp] [--sep SENTINEL] FILE SEG...

Search-and-replace within the section's **content** (heading lines are out of scope), then saves the file. OLD and NEW text come from stdin, separated by a line equal to SENTINEL (default `@@REPLACE@@`). Several OLD/NEW pairs may be given in one call by repeating the sentinel; pairs apply in order. Prints one replacement count per pair. **Atomic: every OLD must be found or the file is left unchanged** (non-zero exit) -- so a mistyped search is caught, like a failed `Edit`.

By default OLD is matched **literally**. Pass `--regexp` to treat OLD as an Emacs regexp, with `\1`, `\2`, ... backreferences usable in NEW.

Literal replace (the heredoc carries OLD, then the sentinel line, then NEW):

```bash
ecl org replace ~/org/project/main.org "Resources" <<'EOF'
the existing integration uses provider A
@@REPLACE@@
the existing integration uses provider B
EOF
```

Two pairs in one call, second one a regexp-free literal:

```bash
ecl org replace ~/org/project/main.org "Tasks" <<'EOF'
old text A
@@REPLACE@@
new text A
@@REPLACE@@
old text B
@@REPLACE@@
new text B
EOF
```

Notes:
- A single trailing newline (the heredoc artifact) is stripped before splitting.
- An empty NEW chunk is an error -- removing text is `ecl org cut`, removing a whole subtree is `ecl org delete`, and body clearing is `ecl org create --clear-body`.
- If OLD or NEW would itself contain a line equal to `@@REPLACE@@`, choose a different delimiter with `--sep`, e.g. `--sep '<<<>>>'`.

### ecl org cut [--regexp] [--sep SENTINEL] FILE SEG...

Removes text from the section's **content**, then saves the file -- `replace` with nothing on the other side. The text to remove comes from stdin; a single chunk needs no sentinel, several are separated by lines equal to SENTINEL (default `@@CUT@@`). Prints one removal count per chunk.

```bash
ecl org cut ~/org/project/main.org "Resources" <<'EOF'
The paragraph that is no longer true.
EOF
```

Two chunks in one call:

```bash
ecl org cut ~/org/todo.org "Tasks" <<'EOF'
first stale line
@@CUT@@
second stale line
EOF
```

Notes:
- Same scope and atomicity as `replace`: heading lines are out of reach, and **every chunk must match or the file is left unchanged** (non-zero exit).
- `--regexp` treats each chunk as an Emacs regexp.
- Like `replace`, the heredoc's final newline is stripped, so cutting a whole paragraph leaves the blank line that followed it -- include the blank line in the chunk to take that too.
- An empty chunk is an error, so a stray sentinel cannot turn into "remove nothing".
- This is the tool for dropping a paragraph. Reach for `ecl org create` only when replacing an entire body -- it overwrites everything else in the section.

### ecl org create [--parents] [--todo STATE] [--effort E] [--tag T]... [--property K=V]... [--clear-body] FILE SEG...

Upsert a heading, then save. Creates the leaf as the last child of its parent when missing; on an existing heading only the passed metadata is touched. Prints `created ...` or `updated ...`.

- `--parents`: create missing intermediate segments too (mkdir -p style); without it a missing intermediate errors.
- `--todo STATE`: set the TODO keyword (no state-change logging -- use `ecl org status` for a logged transition).
- `--tag T` (repeatable): added to the heading's existing tags.
- `--property K=V` (repeatable): set property K; an empty V (`K=`) removes it.
- Body comes from stdin and **replaces** the section's body (planning line, property drawer and other leading drawers survive). Empty stdin never clears -- a metadata-only call is `... </dev/null`; clearing is explicit via `--clear-body`.
- `--if-match ETAG`: **required when the body rewrite lands on a heading that already exists** -- that is the blind overwrite. Not needed for a metadata-only call, nor for a heading being created. Get one from `ecl org section --with-etag`.

```bash
ecl org create --parents --todo TODO --tag api --property Owner=alice \
  ~/org/project.org "Tasks" "Wire the provider" <<'EOF'
Initial task description.
EOF

# metadata-only touch, body untouched -- no etag needed:
ecl org create --effort 1:00 ~/org/project.org "Tasks" "Wire the provider" </dev/null

# rewriting a body that is already there:
ecl org create --if-match content:6f2a1c9d ~/org/project.org "Tasks" "Wire the provider" <<'EOF'
Rewritten description.
EOF
```

### ecl org delete [--if-match ETAG] FILE SEG...

Removes the entire subtree, then saves. The subtree is cut, so it stays recoverable from the Emacs kill ring of the running session.

`--if-match` is **required**, and covers the whole subtree -- it may have grown children since you looked, and they go too. A `content:` etag is refused with a message naming the right read.

```bash
ecl org delete --if-match "subtree:1a2b3c4d5e6f" \
  ~/org/project.org "Tasks" "Obsolete task"
```

### ecl org rename FILE SEG... TITLE

Retitles the heading in place, then saves. Stars, TODO keyword, priority and tags are preserved. Sub-heading paths change accordingly.

```bash
ecl org rename ~/org/project.org "Tasks" "Wire the provider" "Wire the sandbox"
```

### ecl org refile [--to SEG]... [--to-id ID] [--to-file DEST] [--if-match ETAG] FILE SEG...

Moves the subtree at `FILE SEG...` under another heading (the scripted `C-c C-w`), then saves. The subtree's level adapts to the destination; drawers, logbook and children move intact.

- `--to SEG` (repeatable): the destination path, **one flag per outline level**, top-down. No `--to` at all refiles to the **top level** of the destination file.
- `--to-id ID`: the destination by its `:ID:` instead, looked up **in the destination file** (so it composes with `--to-file`). Exclusive with `--to`. The confirmation and the `org-log-refile` entry name the path it resolved to, not the ID.
- `--to-file DEST`: destination file (default: same FILE), so subtrees can move across files.
- `--if-match ETAG`: **required**, from `ecl org section --subtree --with-etag`. It covers the source only -- the destination gains a child rather than losing one, so a change there costs nothing.
- Honors `org-log-refile` (a "Refiled on" timestamp when configured). Refiling a heading into its own subtree errors and changes nothing.

```bash
# under a sibling in the same file:
ecl org refile --to "Archive" --to "2026" ~/org/todo.org "Projects" "Ship v2"

# promote to top level:
ecl org refile ~/org/todo.org "Projects" "Ship v2"

# into another file:
ecl org refile --to-file ~/org/archive.org --to "Done" ~/org/todo.org "Projects" "Ship v2"

# under a heading addressed by its ID, in that other file:
ecl org refile --to-file ~/org/archive.org --to-id "$ID" \
  --if-match "subtree:1a2b3c4d5e6f" ~/org/todo.org "Projects" "Ship v2"
```

### ecl org blocks FILE

Lists the **named** babel src blocks and `#+call:` lines in FILE, in document order -- use it to discover the names that `ecl org block`, `set-block`, `run` and `tangle --block` take. Read-only. One row per block, aligned columns with a header:

```bash
ecl org blocks ~/org/repositories.org
# NAME       LANG        TANGLE
# build-nix  nix         default.nix
# greet      emacs-lisp  -
# my-call    call:greet  -
```

- **NAME** is the block's `#+name:`. Anonymous blocks are omitted -- they can't be addressed by name (they're still covered by whole-file/subtree tangling).
- **LANG** is the src language, or `call:CALLEE` for a `#+call:` line (CALLEE being the block it invokes).
- **TANGLE** is the block's resolved `:tangle` target, or `-` when it isn't tangled.
- Prints nothing for a file with no named blocks.

### ecl org block [--full] [--with-etag] FILE NAME -- read one src block

Prints the body of the src block named NAME (the text between `#+begin_src` and `#+end_src`), verbatim and always newline-terminated. Read-only.

```bash
ecl org block ~/org/repositories.org time-tracker-nix        # body only
ecl org block --full ~/org/repositories.org time-tracker-nix # #+name: .. #+end_src
```

- Default output is the body as babel sees it: Org's comma escapes (`,*`, `,#+`) are already removed.
- `--full` prints the block as it appears in the file instead -- `#+name:` line, header args, both fences -- for inspecting `:tangle`/`:dir`/`:results` settings.
- `--with-etag` prefixes a `#+ETAG: block:...` line for `set-block --if-match`. It covers the **body** with or without `--full`, since the body is what `set-block` overwrites.
- Unknown NAME errors (exit 2) and points at `ecl org blocks`.

### ecl org set-block [--if-match ETAG] FILE NAME -- rewrite one src block

Replaces that block's body with stdin, then saves the file. The `#+name:` line, the header arguments and **every neighbouring line stay untouched** -- this is the whole point: regenerating a block with `ecl org create` rewrites the entire section body and drops the prose around it.

`--if-match` is **required** -- the whole body goes. Get one from `ecl org block --with-etag`.

```bash
ecl org set-block --if-match "block:9f8e7d6c5b4a" \
  ~/org/repositories.org time-tracker-nix <<'EOF'
let pkgs = import <nixpkgs> {}; in pkgs.mkShell { }
EOF
```

Notes:
- Stdin is written with its own indentation preserved, and re-escaped the way Org stores block content -- so `ecl org block NAME | ecl org set-block NAME` leaves the file byte-identical, and a body line starting with `*` or `#+` cannot end the block or fork the outline.
- Addressing by name survives the section being moved or renamed, which a heading path does not.
- A `#+RESULTS:` drawer from an earlier `ecl org run` is left alone -- re-run the block if you want it refreshed.
- Errors if nothing is piped.

### ecl org run FILE BLOCK-NAME

Executes the babel src block whose `#+name:` matches BLOCK-NAME, prints its result on stdout, and saves the file (with the inserted `#+RESULTS:` drawer).

```bash
ecl org run ~/org/project/main.org prepare-repo
```

The block must be named -- i.e. preceded by a `#+name: <name>` line:

```org
#+name: prepare-repo
#+begin_src shell :dir ~/Projects/acme/api
git checkout master && git pull && git switch -c feature/foo
#+end_src
```

If a block the user wants to run is currently unnamed, suggest naming it first (one-line edit above the `#+begin_src`).

Notes:
- **Gated, and the default is `ask`.** Org's own `org-confirm-babel-evaluate` is bypassed -- a prompt raised inside a dispatch has no one to answer it -- and a policy read from the file takes its place. `ecl-org-run-policy` decides for anything the file does not speak for, and it asks; the `ECL_RUN` property overrides it, inherited, so a heading covers its subtree and `#+PROPERTY: ECL_RUN allow` covers a whole trusted runbook, nearest one wins. Values are `allow`, `ask`, `deny`, and anything else refuses. A `#+call:` line answers for both ends -- where it sits and the block it names -- with the stricter of the two winning.
  - `deny` -> exit 2, nothing runs, and the message names the knob that refused.
  - `ask` -> the call blocks, printing `waiting for approval in Emacs` on stderr, while a read-only review buffer waits for the user's `C-c C-c` (`C-c C-k` denies with a reason, exit 3; killing the buffer denies too). There is no timeout, so an unmarked block run in the background will sit there until the user gets to it -- say that you are about to run one rather than leaving them to find a stalled call. What runs is the block as the file has it at approval time, not what you read earlier.
  - Unmarked means asking, so a file of steps the user drives unattended wants `#+PROPERTY: ECL_RUN allow` of its own. Suggest it; do not add it to their file without saying so.
- The gate does not replace asking. **Treat any `ecl org run` invocation as executing user-supplied code** -- if the block does anything destructive (deletes data, force-pushes, calls a paid API, etc.), confirm with the user before invoking, whatever the policy says.
- Saves the file. The `#+RESULTS:` drawer is persisted.
- Multi-step flows: name each block (`step-1`, `step-2`, ...) and run them in order. Or compose with org's own `#+call:` chains inside the file.

### ecl org tangle [--block NAME] FILE [SEG...]

Tangles src blocks (writes them to the files named by their `:tangle` headers), and prints the written file paths, one per line. Three forms:

```bash
ecl org tangle ~/org/repositories.org                      # whole file -- every :tangle block
ecl org tangle --block api-nix ~/org/repositories.org    # just the block #+name'd api-nix
ecl org tangle ~/org/repositories.org "acme/api"          # every block in that subtree
```

- `--block NAME` targets the single block preceded by `#+name: NAME`. Path segments tangle that whole subtree. The two are mutually exclusive; with neither, the whole file is tangled.
- Only blocks with a `:tangle <file>` header are written (`:tangle no`, the default, is skipped). If nothing in the targeted scope opts into tangling, the command prints nothing.
- Does **not** evaluate code or modify the org buffer -- it only writes the tangle targets, so no confirmation prompt and no `#+RESULTS:`. Relative `:tangle` paths resolve against the org file's own directory.
- This is the scripted equivalent of `C-c C-v t` in Emacs -- e.g. re-tangling `~/org/repositories.org` to regenerate a repo's `default.nix` after editing its block.

### ecl org attach / attach-dir / attachments -- org-attach on a heading

Wrap Org's built-in `org-attach` so a heading's file attachments are reachable from the shell.

```bash
ecl org attach FILE SEG... SOURCE   # attach SOURCE to the heading; prints the attachment dir
ecl org attach-dir FILE SEG...      # print the heading's attachment dir (empty if none)
ecl org attachments FILE SEG...     # list attached filenames, one per line
```

Example:

```bash
ecl org attach ~/org/project.org "Design" ~/Downloads/spec.pdf
ecl org attachments ~/org/project.org "Design"   # -> spec.pdf
ecl org attach-dir ~/org/project.org "Design"    # -> .../data/ab/cd12.../
```

- **`attach`** uses Org's default method (`org-attach-method`, a **copy** -- the source file is left in place), tags the heading `:ATTACH:`, assigns it an `:ID:` if it lacks one, creates the attachment directory (default `<org-dir>/data/<xx>/<id>/`), and **saves the file**. SOURCE resolves against the caller's cwd; errors if it doesn't exist. Prints the attachment directory.
- **`attach-dir`** is a pure query -- it neither creates the directory nor assigns an ID; prints nothing when the heading has no attachments yet (attach one first).
- **`attachments`** lists the filenames in that directory (empty when there's no attachment dir). Backup files ending in `~` are ignored.
- These are the scripted equivalents of the `C-c C-a` attach dispatcher (`a` attach, `f` reveal/list) in Emacs.

### ecl org status [--note NOTE] FILE SEG... STATE

Sets the TODO state of the heading, then saves the file. STATE must be one of the keywords defined in the file's `#+TODO:` line (use `ecl org todo-keywords` if unsure). Logging is honored exactly as Org would do it interactively: state-change timestamps and notes are written in the file's configured format (respecting `org-log-into-drawer`). Prints the new state.

**Notes / states that require a comment.** In the `#+TODO:` spec a keyword may carry a logging flag: `!` records a timestamp, `@` records a **note**. For a state flagged `@` (e.g. `WAITING(w@)`, `CANCELED(c@)`), `--note` is **required**:

```bash
ecl org status --note 'dropped: superseded by bar' ~/org/ai.org "Projects" "Foo" CANCELED
```

If a `@` state is requested with **no** note, the command **errors and changes nothing** (non-zero exit). A note may also be supplied for a non-`@` logging state (e.g. `DONE`), in which case it is attached to the timestamp line. States with no flag (e.g. `MAYBE`) just change the keyword.

### ecl org note FILE SEG... NOTE

Files a timestamped log note under the heading, then saves the file. The note lands in the heading's `:LOGBOOK:` drawer exactly as the interactive `org-add-note` (`C-c C-z`) would, honoring the file's `org-log-into-drawer` setting. Use this for a standalone note (no TODO state change) -- unlike `ecl org append`, which inserts plain body text.

NOTE is passed as a single quoted argument (not stdin) and must be non-empty; an empty note errors and changes nothing.

```bash
ecl org note ~/org/project/main.org "Tasks" "Wire the provider" 'waiting on sandbox credentials from vendor'
```

Produces (timestamp is the current time):

```org
:LOGBOOK:
- Note taken on [2026-07-22 Wed 14:30] \\
  waiting on sandbox credentials from vendor
:END:
```

Repeated notes stack in the same drawer, newest first (Org's usual ordering).

### ecl org effort FILE SEG... EFFORT

Sets the `Effort` property of the heading (Org's effort estimate, as used by column view and clocking), then saves the file. Prints the new value.

```bash
ecl org effort ~/org/todo.org "Projects" "Ship v2" 1:30   # 1h30m estimate
ecl org effort ~/org/todo.org "Projects" "Ship v2" ''     # clear the estimate
```

- EFFORT is an Org effort string -- `H:MM` (e.g. `0:30`, `1:00`), or a duration like `2d`/`90min` if `org-effort-durations` defines those units. It lands in the heading's `:PROPERTIES:` drawer as `:Effort:`.
- An **empty** EFFORT (`''`) removes the property; the command then prints nothing.
- Sets the property on the exact heading at the path (creating its `:PROPERTIES:` drawer if needed) -- no inheritance.

**Read it back** with `ecl org effort-get [--inherit] FILE SEG...` -- prints the heading's own `Effort` value, or nothing when it has none. Read-only. With `--inherit`, a heading that has no `Effort` of its own falls back to the nearest ancestor's.

```bash
ecl org effort-get ~/org/todo.org "Projects" "Ship v2"              # heading's own -> 1:30
ecl org effort-get --inherit ~/org/todo.org "Projects" "Ship v2" "QA"  # inherited from an ancestor
```

### ecl org property / property-get / properties -- arbitrary heading properties

The generic form of `effort` for any property in a heading's `:PROPERTIES:` drawer.

```bash
ecl org property FILE SEG... NAME VALUE            # set NAME to VALUE (empty VALUE clears); prints new value
ecl org property-get [--inherit] FILE SEG... NAME  # read NAME (empty if unset); --inherit walks ancestors
ecl org properties FILE SEG...                     # list the heading's own drawer properties, NAME: VALUE per line
```

Example:

```bash
ecl org property ~/org/todo.org "Projects" "Ship v2" Owner alice
ecl org property-get ~/org/todo.org "Projects" "Ship v2" Owner              # -> alice
ecl org property-get --inherit ~/org/todo.org "Projects" "Ship v2" "QA" Owner  # -> alice (from ancestor)
ecl org properties ~/org/todo.org "Projects" "Ship v2"                      # -> OWNER: alice
```

- **`property`** sets NAME on the exact heading (creating the drawer if needed) and saves; an empty VALUE removes it. NAME is a bare property name (no colons), e.g. `Owner`, `URL`, `CLIENT`. `Effort` is just a well-known property -- `ecl org effort` is the same as `property ... Effort ...`.
- **`property-get`** reads the heading's own value; `--inherit` falls back to the nearest ancestor that sets NAME. Read-only.
- **`properties`** lists only what's in the heading's own drawer -- Org's computed `CATEGORY` (derived from the filename) is excluded, and inherited values aren't shown. Names come back upper-cased (Org normalizes them; property lookup is case-insensitive). Note: a property whose name collides with an Org *special* property (`Priority`, `Todo`, `Deadline`, ...) won't appear in this listing, though `property-get NAME` still reads it.

### ecl org id [--create] FILE SEG...

Prints the heading's `:ID:` -- the address every other command takes as `--id`. Errors when the heading has none, unless `--create` mints one (and saves).

```bash
ecl org id ~/org/todo.org "Projects" "Ship v2"              # errors when there is none
ID=$(ecl org id --create ~/org/todo.org "Projects" "Ship v2")
ecl org section --id "$ID" ~/org/todo.org
```

- A plain read never writes, so probing with `id` is safe; a file grows IDs only where you ask with `--create`.
- Addressed by **path only** -- fetching an ID you already hold says nothing.
- It is Org's own `:ID:` property, so `org-id-goto` and a stored link in Emacs reach the same heading.

### ecl org filetags FILE

Prints the file's `#+FILETAGS:` value (e.g. `:work:urgent:`), or empty if none.

### ecl org set-filetags FILE TAG [TAG...]

Writes `#+FILETAGS: :TAG:...:` into the file header (replacing any existing line), then saves. No TAG arguments clears the value.

```bash
ecl org set-filetags ~/org/ai.org work urgent
```

### ecl org todo-keywords FILE

Prints the file's `#+TODO:` keyword spec line(s) verbatim, including the `!`/`@` flags.

### ecl org set-todo-keywords FILE SPEC

Replaces the file's first `#+TODO:` line with SPEC (one quoted argument -- the full value, with `(`, `|`, flags), re-parses the buffer so the new keywords take effect immediately, then saves.

```bash
ecl org set-todo-keywords ~/org/ai.org 'TODO(t!) NEXT(n@) | DONE(d!) CANCELED(c@)'
```

Note: changing the keyword set does not rewrite existing headings -- a heading whose old keyword is no longer defined will have that word fold into its title.

## The other groups: eval, shell, browse-url

Everything above is the `org` group. The rest of the client reaches the daemon itself, and every one of them is **gated on a human in Emacs** -- they are how you ask for something you cannot do from your own shell, not a faster way to do what you already can.

```bash
ecl eval '(emacs-version)'            # or pipe the code in
printf 'mix test --only integration' | ecl shell run
ecl browse-url https://example.com
```

- **`ecl eval [CODE...]`** evaluates elisp *in the running daemon* -- the user's live Emacs, with their buffers, their config and their state. The code goes up in an editable buffer; `C-c C-c` evaluates **the buffer as it stands**, so what runs may be the user's fixed version of what you sent. Prints the value, then a `--- messages ---` section with anything the code printed. This is the tool for reading or driving Emacs itself; it is not a general elisp runtime.
- **`ecl shell run [COMMAND...]`** runs a command in **your** working directory, after the same approval, and answers with a *handle* rather than output: the command runs in a compilation buffer the user can watch. Read it back with `ecl shell wait HANDLE` (blocks until it exits; exit 2 if the command failed), `ecl shell output HANDLE [--from N]` to tail it without waiting, `ecl shell list`, `ecl shell kill HANDLE`. Reach for it when the user should *see* the run -- a long build, a dev server, a test suite they are watching -- not for ordinary shell work you can do yourself.
- **`ecl browse-url URL`** opens a page through the daemon's browser after a `y-or-n-p` in Emacs. Needs a scheme. This one times out (60s) and denies.

What to expect as a caller:

- The call **blocks with no timeout** (`browse-url` excepted), printing `waiting for approval in Emacs` on stderr. Nobody at the keyboard means it waits indefinitely -- say you are about to do it rather than leaving the user to find a stalled call, and do not fire one into a background pipeline.
- **Exit 3 is a denial**, with the user's reason on stderr. It is not an error to retry: take the reason as the answer. Exit 2 is a real failure, 4 an unknown command, 64 usage.
- Killing the client cancels the request and tears the approval buffer down, so an abandoned call leaves nothing behind in the user's Emacs.

## Workflow

1. `ecl org outline FILE` -- get the heading map
2. `ecl org section FILE SEG...` -- pull only the sections you need (don't `Read` the whole org file). Add `--with-etag` when the write you have in mind is one of the four that need it. If you will be coming back to this heading later, take an `ecl org id --create` now and address it by `--id` from here on; the etag hints then come back with `--id` in them and stay copy-pasteable.
3. Do the work (analysis, code generation, executing recorded steps via `ecl org run`, etc.)
4. Write results back: `ecl org append` / `ecl org replace` / `ecl org cut` for body text, `ecl org set-block` for a single babel block, `ecl org create` for new headings (and only for a whole-body rewrite, with `--if-match`)

The etag is the read from step 2. If the work in step 3 takes a while, that is exactly the window it exists to cover -- on a refusal, go back to step 2 and reconcile rather than resending.

If the user has the file open in Emacs, the buffer is updated -- they may need `revert-buffer` (or `auto-revert-mode`) to see it. It is saved to disk too, **unless they already had unsaved changes** in that buffer: an agent edit will not flush a half-finished edit of theirs, so until they save, `git status` will not show what you wrote. `ecl org section` reads it back regardless.
