;;; ecl-browse.el --- Open a URL from an ecl client -*- lexical-binding: t; -*-

;; Author: Martin Cernak
;; URL: https://github.com/tino415/ecl
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; `ecl browse-url' hands a URL to this daemon's `browse-url', so a
;; shell caller -- primarily a coding agent -- can put a page in front
;; of the human sitting at Emacs:
;;
;;   ecl browse-url https://api.dev.localhost/admin
;;
;; The entry is :confirm t: a browser window arrives in the user's
;; face, so they say yes to it first.  The quick y-or-n-p is enough
;; here -- unlike `ecl eval' there is nothing to read and edit, only a
;; target to recognise, and it is in the prompt.
;;
;; Register it from your init:
;;   (use-package ecl-browse
;;     :after ecl
;;     :config (ecl-register ecl-browse-command))

;;; Code:

(require 'ecl)
(require 'browse-url)

(defun ecl-browse--check-scheme (url)
  "Signal unless URL carries a scheme.
A bare path would reach the browser as a relative URL resolved
against nothing in particular; better to say so than to open it."
  (unless (string-match-p "\\`[a-zA-Z][-+.a-zA-Z0-9]*:" url)
    (error "Not a URL (no scheme): %s" url)))

(defconst ecl-browse-command
  `("browse-url" :confirm t
    :usage "URL"
    :fn ,(lambda (url)
           "Open a URL in the user's browser, via this daemon's `browse-url'.
Which browser that is comes from `browse-url-browser-function'.
URL must carry a scheme.  Emacs asks for confirmation first; a
denial exits 3."
           (ecl-browse--check-scheme url)
           (browse-url url)
           (concat "browsing " url)))
  "ecl entry for `browse-url'.  Register it with `ecl-register'.")

(provide 'ecl-browse)
;;; ecl-browse.el ends here
