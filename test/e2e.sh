#!/usr/bin/env bash
# End-to-end battery: the real bin/ecl client against a throwaway
# `emacs -Q --daemon=testing`.  Never touches the default daemon.
set -u
cd "$(dirname "$0")/.."

export ECL_SERVER=testing
ECL=./bin/ecl
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# desc, expected-exit, actual-exit
expect_exit() {
  if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $3, want $2)"; fi
}

# Asking the daemon to die can hang -- it has been seen ignoring
# `kill-emacs' over the socket while still answering everything else --
# so every teardown is bounded and then insists with a signal.  A daemon
# that survives holds the socket name and poisons the next run.
reap() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill "$pid" 2>/dev/null
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null
}

kill_daemon() {
  local pid
  pid=$(timeout 5 emacsclient -s testing -e '(emacs-pid)' 2>/dev/null)
  timeout 5 emacsclient -s testing -e '(kill-emacs)' >/dev/null 2>&1
  reap "$pid"
}

cleanup() {
  kill_daemon
  rm -rf "$WORK"
}

kill_daemon
emacs -Q --daemon=testing -l test/e2e-init.el 2>/dev/null || {
  echo "FAIL: could not start testing daemon"; exit 1; }
WORK=$(mktemp -d)
trap cleanup EXIT

run() { timeout 20 "$ECL" "$@"; }

F="$WORK/doc.org"
cat > "$F" <<'EOF'
#+TODO: TODO(t!) WAITING(w@) | DONE(d!)

* Projects
** API /v2/payouts endpoint
Endpoint notes.
* Notes
Loose note.
* Snippets
Prose before the block.

#+name: greet
#+begin_src shell :results output
echo hi
#+end_src

Prose after the block.
EOF

# --- plumbing ---
out=$(run version); expect_exit "version exits 0" 0 $?
[ -n "$out" ] && ok "version has output" || bad "version output empty"

run no-such-command >/dev/null 2>&1; expect_exit "unknown command exits 4" 4 $?
run org >/dev/null 2>&1; expect_exit "bare group exits 64 (usage)" 64 $?

out=$(run org create --help)
expect_exit "create --help exits 0" 0 $?
echo "$out" | grep -q "usage: ecl org create \[--parents\]" \
  && ok "create --help shows :usage line" || bad "create --help usage line"
echo "$out" | grep -q "optionally reads input from stdin" \
  && ok "create --help notes optional stdin" || bad "create --help stdin note"

# --- slash-in-title addressing (the original motivation) ---
out=$(run org section "$F" Projects "API /v2/payouts endpoint")
expect_exit "slash-title section exits 0" 0 $?
echo "$out" | grep -q "Endpoint notes." \
  && ok "slash-title section content" || bad "slash-title section content"

# --- create: heredoc body + metadata, then </dev/null upsert ---
run org create --todo TODO --tag api --property Owner=bob "$F" Projects "Rate limiting" >/dev/null <<'EOF'
Design the limiter.
EOF
expect_exit "create with body+metadata" 0 $?
run org create --effort 1:00 "$F" Projects "Rate limiting" >/dev/null </dev/null
expect_exit "metadata-only create </dev/null" 0 $?
out=$(run org section --subtree "$F" Projects "Rate limiting")
echo "$out" | grep -q "Design the limiter." \
  && ok "upsert kept body" || bad "upsert kept body: $out"
echo "$out" | grep -q ":Effort:" \
  && ok "upsert added effort" || bad "upsert added effort"

# --- append: stdin over the handshake; heading payload rejected ---
run org append "$F" Notes >/dev/null <<'EOF'

Appended paragraph.
EOF
expect_exit "append body text" 0 $?
printf '\n*** Sneaky\n' | run org append "$F" Notes >/dev/null 2>&1
expect_exit "append heading payload exits 2" 2 $?

# --- replace: pair applies; failed pair leaves file byte-identical ---
out=$(run org replace "$F" Notes <<'EOF'
Appended paragraph.
@@REPLACE@@
Appended and edited paragraph.
EOF
)
expect_exit "replace pair" 0 $?
[ "$out" = "1" ] && ok "replace prints count" || bad "replace count: $out"

cp "$F" "$WORK/before.org"
run org replace "$F" Notes >/dev/null 2>&1 <<'EOF'
Loose note.
@@REPLACE@@
CHANGED
@@REPLACE@@
text that does not exist
@@REPLACE@@
irrelevant
EOF
expect_exit "failed multi-pair replace exits 2" 2 $?
cmp -s "$F" "$WORK/before.org" \
  && ok "failed replace leaves file byte-identical" || bad "atomicity broken"

# --- cut: removes one chunk, atomic when a chunk misses ---
out=$(run org cut "$F" Notes <<'EOF'
Appended and edited paragraph.
EOF
)
expect_exit "cut a chunk" 0 $?
[ "$out" = "1" ] && ok "cut prints count" || bad "cut count: $out"
out=$(run org section "$F" Notes)
echo "$out" | grep -q "Appended and edited" \
  && bad "cut left the text behind" || ok "cut removed the text"
echo "$out" | grep -q "Loose note." \
  && ok "cut kept the rest of the body" || bad "cut ate the neighbour: $out"

cp "$F" "$WORK/before-cut.org"
run org cut "$F" Notes >/dev/null 2>&1 <<'EOF'
Loose note.
@@CUT@@
text that does not exist
EOF
expect_exit "failed multi-chunk cut exits 2" 2 $?
cmp -s "$F" "$WORK/before-cut.org" \
  && ok "failed cut leaves file byte-identical" || bad "cut atomicity broken"

# --- block / set-block: addressed by #+name:, neighbours untouched ---
out=$(run org block "$F" greet)
expect_exit "block exits 0" 0 $?
[ "$out" = "echo hi" ] && ok "block prints the body only" || bad "block body: $out"
out=$(run org block --full "$F" greet)
echo "$out" | grep -q '^#+name: greet' \
  && ok "block --full includes the name line" || bad "block --full: $out"
echo "$out" | grep -q ':results output' \
  && ok "block --full includes header args" || bad "block --full header args"

run org set-block "$F" greet >/dev/null <<'EOF'
echo replaced
echo again
EOF
expect_exit "set-block" 0 $?
out=$(run org section "$F" Snippets)
echo "$out" | grep -q "echo replaced" \
  && ok "set-block wrote the body" || bad "set-block body: $out"
echo "$out" | grep -q "Prose before the block." && echo "$out" | grep -q "Prose after the block." \
  && ok "set-block kept the surrounding prose" || bad "set-block ate a neighbour: $out"
echo "$out" | grep -q ':results output' \
  && ok "set-block kept the header args" || bad "set-block lost header args"

run org block "$F" nosuchblock >/dev/null 2>&1
expect_exit "unknown block exits 2" 2 $?

# --- status --note: the daemon-only logging path ---
run org status --note "blocked on infra" "$F" Projects "Rate limiting" WAITING >/dev/null
expect_exit "status --note on @ state" 0 $?
out=$(run org section "$F" Projects "Rate limiting")
echo "$out" | grep -q "blocked on infra" \
  && ok "state note recorded" || bad "state note missing: $out"
run org status "$F" Notes WAITING >/dev/null 2>&1
expect_exit "@ state without note exits 2" 2 $?

# --- structure verbs ---
run org rename "$F" Projects "Rate limiting" "Rate limits" >/dev/null
expect_exit "rename" 0 $?
run org delete "$F" Projects "Rate limits" >/dev/null
expect_exit "delete" 0 $?
run org section "$F" Projects "Rate limits" >/dev/null 2>&1
expect_exit "deleted heading gone (exit 2)" 2 $?

run org refile --to Notes "$F" Projects "API /v2/payouts endpoint" >/dev/null
expect_exit "refile under Notes" 0 $?
out=$(run org section --subtree "$F" Notes)
echo "$out" | grep -q '^\*\* API /v2/payouts endpoint' \
  && ok "refile moved heading" || bad "refile moved heading: $out"
run org refile --to Nowhere "$F" Notes "API /v2/payouts endpoint" >/dev/null 2>&1
expect_exit "refile bad dest exits 2" 2 $?

# --- private tags: refused at the client, hidden in the outline ---
run org create --tag noai "$F" Notes Secret >/dev/null <<'EOF'
Sensitive body.
EOF
expect_exit "create a private heading" 0 $?
out=$(run org section "$F" Notes Secret 2>&1)
expect_exit "private section exits 2" 2 $?
echo "$out" | grep -q "not available to agents" \
  && ok "refusal reaches the caller" || bad "refusal message: $out"
out=$(run org outline "$F")
echo "$out" | grep -q "<hidden :noai:>" \
  && ok "outline shows the placeholder" || bad "outline placeholder: $out"
echo "$out" | grep -q "Secret" \
  && bad "outline leaked the private title" || ok "outline hides the title"
out=$(run org private-tags)
echo "$out" | grep -q "^noai$" \
  && ok "private-tags lists the defaults" || bad "private-tags: $out"

# --- miscount diagnostics ---
out=$(run org property "$F" Projects Nope Owner bob 2>&1)
expect_exit "bad path exits 2" 2 $?
echo "$out" | grep -q "taken as NAME VALUE" \
  && ok "miscount hint printed" || bad "miscount hint: $out"

# --- the file moves underneath the daemon ---
# The regression that matters: `find-file-noselect' and `basic-save-buffer'
# both ask about a file that changed on disk, and a single-threaded daemon
# waiting on a question nobody can answer stops serving anything at all --
# `(emacs-pid)' included, with killing the client no help.  So every step
# here is bounded, and the last two assertions are about the daemon still
# being there rather than about the command.
S="$WORK/moved.org"
printf '* Notes\nbefore\n' > "$S"
run org section "$S" Notes >/dev/null 2>&1
printf '* Notes\nafter\n' > "$S"          # git checkout, rebase, other editor

out=$(run org section "$S" Notes 2>&1)
expect_exit "read after the file moved exits 0" 0 $?
[ "$out" = "after" ] \
  && ok "clean buffer is reread from disk" || bad "reread gave: $out"

printf '\nappended\n' | run org append "$S" Notes >/dev/null 2>&1
expect_exit "write after the file moved exits 0" 0 $?
grep -q '^after$' "$S" && grep -q '^appended$' "$S" \
  && ok "write builds on the disk version" || bad "write clobbered: $(cat "$S")"

# Both sides changed: refuse, and leave the conflict for Emacs.
printf '* Notes\nbase\n' > "$S"
run org section "$S" Notes >/dev/null 2>&1
emacsclient -s testing -e "(with-current-buffer (find-buffer-visiting \"$S\")
  (goto-char (point-max)) (insert \"unsaved\\n\") (buffer-modified-p))" >/dev/null 2>&1
printf '* Notes\ndisk moved on\n' > "$S"
out=$(printf '\nx\n' | run org append "$S" Notes 2>&1)
expect_exit "conflicting write exits 2" 2 $?
echo "$out" | grep -q "unsaved" \
  && ok "conflict names the unsaved buffer" || bad "conflict message: $out"
grep -q '^disk moved on$' "$S" && ! grep -q '^x$' "$S" \
  && ok "conflicting write leaves the file alone" || bad "file changed: $(cat "$S")"

# Nothing above may have cost us the daemon.
[ -n "$(timeout 5 emacsclient -s testing -e '(emacs-pid)' 2>/dev/null)" ] \
  && ok "daemon still answers after a stale file" || bad "daemon stopped answering"
run org outline "$F" >/dev/null 2>&1
expect_exit "an unrelated file still works" 0 $?

# --- eval: the client waits for a human ---
# No user in this daemon, so we play the user over a second emacsclient:
# wait for the review buffer to appear, then run the real commands in it.
decide() {
  local i=0
  while [ $i -lt 100 ]; do
    if [ "$(emacsclient -s testing -e '(and (ecl-eval--buffers) t)' 2>/dev/null)" = "t" ]; then
      emacsclient -s testing -e \
        "(with-current-buffer (car (ecl-eval--buffers)) $1)" >/dev/null 2>&1
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "decide: no review buffer appeared"
  return 1
}

printf '(message "logged") (+ 1 2)' | run eval > "$WORK/ok.out" 2>"$WORK/ok.err" &
pid=$!
decide '(ecl-eval-approve)'
wait $pid; expect_exit "eval approved exits 0" 0 $?
grep -q '=> 3' "$WORK/ok.out" \
  && ok "eval prints the value" || bad "eval value: $(cat "$WORK/ok.out")"
grep -q 'logged' "$WORK/ok.out" \
  && ok "eval prints captured messages" || bad "eval messages missing"
grep -q 'waiting for approval' "$WORK/ok.err" \
  && ok "eval announces the wait on stderr" || bad "eval wait notice missing"

printf '(+ 1 2)' | run eval > "$WORK/edit.out" 2>&1 &
pid=$!
decide '(erase-buffer) (insert "(* 6 7)") (ecl-eval-approve)'
wait $pid; expect_exit "edited buffer approved exits 0" 0 $?
grep -q '=> 42' "$WORK/edit.out" \
  && ok "eval runs the edited buffer" || bad "edited buffer: $(cat "$WORK/edit.out")"

printf '(delete-file "/etc/passwd")' | run eval > "$WORK/deny.out" 2>&1 &
pid=$!
decide '(ecl-eval-deny "not now")'
wait $pid; expect_exit "eval denied exits 3" 3 $?
grep -q 'denied: not now' "$WORK/deny.out" \
  && ok "deny reason reaches the caller" || bad "deny reason: $(cat "$WORK/deny.out")"

printf '(error "boom")' | run eval > "$WORK/err.out" 2>&1 &
pid=$!
decide '(ecl-eval-approve)'
wait $pid; expect_exit "eval error exits 2" 2 $?
grep -q 'boom' "$WORK/err.out" \
  && ok "eval error message reaches the caller" || bad "eval error: $(cat "$WORK/err.out")"

# Client killed mid-wait: the daemon must not keep the review buffer.
printf '(ignore)' | "$ECL" eval >/dev/null 2>&1 &
pid=$!
decide '(ignore)'
kill "$pid" 2>/dev/null
wait $pid 2>/dev/null
sleep 0.5
[ "$(emacsclient -s testing -e '(and (ecl-eval--buffers) t)' 2>/dev/null)" = "nil" ] \
  && ok "killed client cancels the review buffer" || bad "review buffer leaked"

out=$(run eval --help)
expect_exit "eval --help exits 0" 0 $?
echo "$out" | grep -q "usage: ecl eval \[CODE...\]" \
  && ok "eval --help shows :usage line" || bad "eval --help usage line"

# --- browse-url: the :confirm path ---
# This daemon has neither a user nor a browser, so we supply both:
# y-or-n-p answers e2e-allow, and browse-url only records its argument,
# which is what the assertions read back.
stub_browser() {
  emacsclient -s testing -e '(progn
    (defvar e2e-allow t)
    (defvar e2e-browsed nil)
    (defalias (quote browse-url) (lambda (url &rest _) (setq e2e-browsed url)))
    (defalias (quote y-or-n-p) (lambda (_prompt) e2e-allow))
    t)' >/dev/null 2>&1
}
browsed() { emacsclient -s testing -e 'e2e-browsed' 2>/dev/null; }

stub_browser
out=$(run browse-url https://example.org/page)
expect_exit "browse-url confirmed exits 0" 0 $?
[ "$(browsed)" = '"https://example.org/page"' ] \
  && ok "browse-url opened the URL" || bad "browse-url opened: $(browsed)"
echo "$out" | grep -q "browsing https://example.org/page" \
  && ok "browse-url reports the target" || bad "browse-url output: $out"

emacsclient -s testing -e '(setq e2e-allow nil e2e-browsed nil)' >/dev/null 2>&1
run browse-url https://example.org/denied >/dev/null 2>&1
expect_exit "browse-url denied exits 3" 3 $?
[ "$(browsed)" = "nil" ] \
  && ok "denial opens nothing" || bad "denied but opened: $(browsed)"

emacsclient -s testing -e '(setq e2e-allow t)' >/dev/null 2>&1
run browse-url "$WORK/report.html" >/dev/null 2>&1
expect_exit "target without a scheme exits 2" 2 $?

echo
echo "e2e: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
