;;; debug-init.el --- init for the ecl debug daemon -*- lexical-binding: t; -*-
;; Loaded by test/debug-daemon.sh into
;; `emacs -Q --daemon=<checkout>/.debug/socket'.  Same modules as the e2e
;; daemon, plus one difference that exists only for debugging.
;;
;; Directory-local variables are off here.  A -Q Emacs reads
;; ~/.dir-locals.el with nothing settled, so a risky variable in it
;; (anything named `*-command', say) makes `find-file-noselect' ask for
;; confirmation -- on a frame this daemon does not have.  Every file
;; under the home directory then wedges the daemon for a reason that has
;; nothing to do with whatever is being investigated, and a configured
;; Emacs, where that question was long since answered, does not behave
;; this way.  Turning dir-locals off keeps the daemon comparable to the
;; real one.

;;; Code:

(load (expand-file-name "e2e-init.el" (file-name-directory load-file-name)))

(setq enable-dir-local-variables nil)
