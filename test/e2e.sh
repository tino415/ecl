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

cleanup() {
  emacsclient -s testing -e '(kill-emacs)' >/dev/null 2>&1
  rm -rf "$WORK"
}

emacsclient -s testing -e '(kill-emacs)' >/dev/null 2>&1
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

# --- miscount diagnostics ---
out=$(run org property "$F" Projects Nope Owner bob 2>&1)
expect_exit "bad path exits 2" 2 $?
echo "$out" | grep -q "taken as NAME VALUE" \
  && ok "miscount hint printed" || bad "miscount hint: $out"

echo
echo "e2e: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
