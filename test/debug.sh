#!/usr/bin/env bash
# Probe why `ecl org outline FILE' can hang (and freeze the daemon's UI)
# on a large org file.  Every step is bounded and timed, against the
# throwaway daemon on .debug/socket -- never the user's.
#
#   make debug-results.txt                  # DEBUG_ORG defaults below
#   DEBUG_ORG=/path/to/big.org make debug-results.txt
set -u
cd "$(dirname "$0")/.."

ORG=${DEBUG_ORG:-$HOME/org/payout/runfile.org}
LIMIT=${DEBUG_TIMEOUT:-30}
DAEMON=./test/debug-daemon.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A control file with the same shape as a runfile but a fraction of the
# size, so "big file" and "any file" are told apart.
SMALL="$WORK/small.org"
{
  echo "#+TITLE: Small"
  echo "#+STARTUP: overview"
  for i in $(seq 1 20); do
    echo "* Heading $i"
    echo "#+begin_src shell"
    echo "echo $i"
    echo "#+end_src"
  done
} > "$SMALL"

# A probe that wedges the daemon (the failure mode this script exists to
# catch) would make every later probe time out too, so each one starts
# from a fresh daemon and measures only itself.
timed() {
  local desc=$1; shift
  local start end status
  $DAEMON up >/dev/null 2>&1
  start=$(date +%s%N)
  out=$(timeout "$LIMIT" "$@" 2>&1); status=$?
  end=$(date +%s%N)
  printf '%-46s %6s ms  exit=%-3s %s\n' \
    "$desc" "$(( (end - start) / 1000000 ))" "$status" \
    "$(printf '%s' "$out" | head -c 60 | tr '\n' ' ')"
  [ "$status" -eq 124 ] && printf '%-46s TIMED OUT after %ss\n' "" "$LIMIT"
  return 0
}

echo "debug probe"
echo "  file    : $ORG"
[ -f "$ORG" ] && echo "  size    : $(wc -c < "$ORG") bytes, $(grep -c '^\*' "$ORG") headings" \
              || { echo "  MISSING -- set DEBUG_ORG"; exit 1; }
echo "  timeout : ${LIMIT}s"
echo

echo "-- through the client (bin/ecl -> server-eval-at -> ecl-dispatch) --"
timed "outline small (control)"        ./test/decl org outline "$SMALL"
timed "outline target"                 ./test/decl org outline "$ORG"
timed "section target (small reply)"   ./test/decl org section "$ORG" README
echo

echo "-- split: compute vs transport, tiny replies --"
# Raw `find-file-noselect', i.e. without ecl-org--visit's no-prompt
# bindings: this is the one that used to hang forever on a file whose
# directory carries risky local variables.
timed "visit target, raw find-file"    $DAEMON eval "(progn (find-file-noselect \"$ORG\") nil)" "$LIMIT"
timed "visit target, ecl-org--visit"   $DAEMON eval "(progn (ecl-org--visit \"$ORG\") nil)" "$LIMIT"
timed "outline target, buffer open"    $DAEMON eval "(length (ecl-org-outline \"$ORG\"))" "$LIMIT"
timed "outline target, again"          $DAEMON eval "(length (ecl-org-outline \"$ORG\"))" "$LIMIT"
timed "org-map-entries alone"          $DAEMON eval "(let ((n 0)) (with-current-buffer (ecl-org--visit \"$ORG\") (org-map-entries (lambda () (setq n (1+ n))))) n)" "$LIMIT"
timed "plain heading scan alone"       $DAEMON eval "(with-current-buffer (ecl-org--visit \"$ORG\") (save-excursion (goto-char (point-min)) (let ((n 0)) (while (re-search-forward org-outline-regexp-bol nil t) (setq n (1+ n))) n)))" "$LIMIT"
timed "transport 16k reply"            $DAEMON eval "(length (make-string 16281 ?x))" "$LIMIT"
echo

echo "-- same splits on the control file --"
timed "visit small, raw find-file"     $DAEMON eval "(progn (find-file-noselect \"$SMALL\") nil)" "$LIMIT"
timed "org-map-entries small"          $DAEMON eval "(let ((n 0)) (with-current-buffer (ecl-org--visit \"$SMALL\") (org-map-entries (lambda () (setq n (1+ n))))) n)" "$LIMIT"
echo "done"
