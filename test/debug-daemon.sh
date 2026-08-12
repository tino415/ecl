#!/usr/bin/env bash
# Throwaway ecl daemon on a project-local socket, for interactive
# debugging.  It is bound to <project>/.debug/socket and started with
# `emacs -Q', so it can never reach -- or be confused with -- the user's
# real daemon, and carries none of their init.
#
#   test/debug-daemon.sh up     start it (restarting any previous one)
#   test/debug-daemon.sh down   stop it and remove the socket
#   test/debug-daemon.sh eval FORM   evaluate FORM in it, print the result
#
# Normally driven through the Makefile target `.debug/socket'; `test/decl'
# is the ecl client pointed at the same socket.
set -u
cd "$(dirname "$0")/.."

EMACS=${EMACS:-emacs}
DIR="$PWD/.debug"
SOCK="$DIR/socket"
PIDFILE="$DIR/pid"

# Talk to the daemon the way bin/ecl does -- `server-eval-at' from a batch
# Emacs.  emacsclient needs a socket of its own, which some sandboxes deny.
eval_at() {
  timeout "${2:-20}" "$EMACS" -Q --batch --eval \
    "(progn (require 'server)
            (prin1 (server-eval-at \"$SOCK\" '$1)))" 2>/dev/null
}

# Same bounded teardown as test/e2e.sh: a daemon that ignores kill-emacs
# over the socket would hold the socket name and poison the next run.
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

down() {
  [ -S "$SOCK" ] && eval_at '(kill-emacs)' 5 >/dev/null
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE")
    # Only ever signal a process that is still this daemon: a pid file
    # left by an older run may name something else entirely by now.
    if [ -r "/proc/$pid/cmdline" ] &&
         grep -qz -- "$SOCK" "/proc/$pid/cmdline" 2>/dev/null; then
      reap "$pid"
    fi
    rm -f "$PIDFILE"
  fi
  rm -f "$SOCK"
}

up() {
  down
  mkdir -p "$DIR"
  # `server-ensure-safe-dir' refuses a socket directory that is readable
  # by anyone else, and the project directory itself is 0755.
  chmod 700 "$DIR"
  "$EMACS" -Q --daemon="$SOCK" -l test/debug-init.el || {
    echo "debug-daemon: could not start on $SOCK" >&2; exit 1; }
  [ -S "$SOCK" ] || { echo "debug-daemon: no socket at $SOCK" >&2; exit 1; }
  # Record the pid while the daemon can still answer.  The whole point
  # of this daemon is to reproduce hangs, and a daemon wedged on a
  # prompt answers nothing -- including `(emacs-pid)'.  Without this,
  # `down' would drop the socket and leave the process running forever.
  eval_at '(emacs-pid)' 5 > "$PIDFILE"
  echo "debug daemon up: $SOCK (pid $(cat "$PIDFILE"))"
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  eval) shift; eval_at "$1" "${2:-20}"; echo ;;
  *) echo "usage: $0 up|down|eval FORM [TIMEOUT]" >&2; exit 64 ;;
esac
