;;; e2e-init.el --- init for the ecl e2e scratch daemon -*- lexical-binding: t; -*-
;; Loaded by test/e2e.sh into `emacs -Q --daemon=testing'.  Registers the
;; same modules a real init would, from this checkout.
(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory load-file-name)))
(require 'ecl)
(require 'ecl-org)
(require 'ecl-eval)
(ecl-register `("version" . ,(lambda ()
                               "Emacs version of the running daemon."
                               (emacs-version))))
(ecl-register ecl-org-command-group)
(ecl-register ecl-eval-command)
