;;; proton-pass.el --- Proton Pass CLI integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Meier

;; Author: Paul Meier
;; URL: https://github.com/paulmeier/proton-pass.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience, password
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A thin wrapper around `pass-cli', the Proton Pass command-line tool.
;;
;;   - `proton-pass-get'            fetch a secret by pass:// URI (for config code)
;;   - auth-source backend          `proton-pass' in `auth-sources', driven by
;;                                  `proton-pass-auth-source-alist'
;;   - `proton-pass-copy-password'  and friends: copy to kill ring, auto-clear
;;   - `proton-pass-totp'           copy a TOTP code
;;   - `proton-pass-use-ssh-agent'  point Emacs (magit, tramp) at the Proton
;;                                  Pass SSH agent socket
;;
;; `pass-cli' is slow (a few seconds per call), so nothing runs at load
;; time: auth-source results carry a lazy :secret, and fetched secrets
;; are cached in memory for `proton-pass-cache-ttl' seconds.
;;
;; Quick start:
;;
;;   (require 'proton-pass)
;;   (setq proton-pass-auth-source-alist
;;         '(("api.anthropic.com" "apikey" "pass://Personal/Anthropic API/password")))
;;   (proton-pass-auth-source-enable)
;;   (proton-pass-use-ssh-agent)

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup proton-pass nil
  "Proton Pass CLI integration."
  :group 'tools)

(defcustom proton-pass-executable
  (or (executable-find "pass-cli") (expand-file-name "~/.local/bin/pass-cli"))
  "Path to the Proton Pass CLI."
  :type 'file)

(defcustom proton-pass-vault "Personal"
  "Default vault for interactive commands."
  :type 'string)

(defcustom proton-pass-clipboard-timeout 45
  "Seconds before a copied secret is removed from the kill ring and clipboard."
  :type 'integer)

(defcustom proton-pass-cache-ttl 3600
  "Seconds to keep fetched secrets in memory.  nil disables caching."
  :type '(choice integer (const nil)))

(defcustom proton-pass-auth-source-alist nil
  "Map auth-source queries to Proton Pass URIs.
Each entry is (HOST USER URI).  HOST and USER are strings; USER may
be nil to match any user.  Example:

  ((\"api.anthropic.com\" \"apikey\" \"pass://Personal/Anthropic API/password\")
   (\"127.0.0.1\" nil \"pass://Personal/Proton Mail Bridge/password\"))"
  :type '(repeat (list string (choice string (const nil)) string)))

(defcustom proton-pass-ssh-agent-socket "~/.ssh/proton-pass-ssh-agent.sock"
  "Socket of the Proton Pass SSH agent (`pass-cli ssh-agent')."
  :type 'file)

;;;; Process plumbing

(defun proton-pass--call (&rest args)
  "Run `pass-cli' with ARGS and return stdout without the trailing newline.
Signal a `user-error' carrying stderr on failure."
  (let ((err-file (make-temp-file "proton-pass-err")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process proton-pass-executable nil
                               (list t err-file) nil args)))
            (unless (eq status 0)
              (user-error "Command `pass-cli %s' failed: %s" (car args)
                          (string-trim
                           (with-temp-buffer
                             (insert-file-contents err-file)
                             (buffer-string)))))
            (string-trim-right (buffer-string) "\n")))
      (delete-file err-file))))

(defun proton-pass--json (&rest args)
  "Run `pass-cli' with ARGS and parse its JSON output as alists."
  (json-parse-string (apply #'proton-pass--call args)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun proton-pass--uri (title &optional field vault)
  "Build a pass:// URI for TITLE, FIELD (default password) and VAULT."
  (format "pass://%s/%s/%s" (or vault proton-pass-vault) title (or field "password")))

;;;; Secret cache

(defvar proton-pass--titles nil
  "Cached (VAULT . TITLES) for completion.  Titles are not secret.")

(defvar proton-pass--cache (make-hash-table :test #'equal)
  "URI -> (FETCH-TIME . SECRET).")

(defun proton-pass-get (uri)
  "Return the secret at pass:// URI, using the in-memory cache."
  (let ((hit (gethash uri proton-pass--cache)))
    (if (and hit proton-pass-cache-ttl
             (< (float-time (time-subtract nil (car hit))) proton-pass-cache-ttl))
        (cdr hit)
      (message "Fetching %s from Proton Pass..." uri)
      (let ((secret (proton-pass--call "item" "view" uri)))
        (when proton-pass-cache-ttl
          (puthash uri (cons (current-time) secret) proton-pass--cache))
        (message nil)
        secret))))

(defun proton-pass-clear-cache ()
  "Forget cached secrets and item titles, including auth-source's cache."
  (interactive)
  (clrhash proton-pass--cache)
  (setq proton-pass--titles nil)
  (auth-source-forget-all-cached)
  (message "Proton Pass cache cleared"))

;;;; Item selection

(defun proton-pass--read-title (&optional prompt)
  "Read an item title from `proton-pass-vault' with completion.
PROMPT defaults to \"Proton Pass item: \".  With a prefix argument,
refresh the cached title list first."
  (when (or current-prefix-arg
            (not (equal (car proton-pass--titles) proton-pass-vault)))
    (message "Listing %s vault..." proton-pass-vault)
    (setq proton-pass--titles
          (cons proton-pass-vault
                (mapcar (lambda (it) (alist-get 'title it))
                        (alist-get 'items (proton-pass--json
                                           "item" "list" proton-pass-vault
                                           "--output" "json"))))))
  (completing-read (or prompt "Proton Pass item: ") (cdr proton-pass--titles)
                   nil t))

(defun proton-pass--item (title)
  "Return the full JSON item TITLE from `proton-pass-vault'."
  (alist-get 'item (proton-pass--json "item" "view"
                                      "--vault-name" proton-pass-vault
                                      "--item-title" title
                                      "--output" "json")))

;;;; Kill ring with auto-clear

(defvar proton-pass--kill nil "Secret most recently copied by this package.")
(defvar proton-pass--kill-timer nil)

(defun proton-pass--clear-kill ()
  "Remove the last copied secret from the kill ring and clipboard."
  (when (timerp proton-pass--kill-timer)
    (cancel-timer proton-pass--kill-timer))
  (setq proton-pass--kill-timer nil)
  (when proton-pass--kill
    (setq kill-ring (delete proton-pass--kill kill-ring)
          kill-ring-yank-pointer kill-ring)
    (ignore-errors
      (when (equal (gui-get-selection 'CLIPBOARD) proton-pass--kill)
        (gui-set-selection 'CLIPBOARD "")))
    (setq proton-pass--kill nil)))

(defun proton-pass--copy (secret what)
  "Put SECRET on the kill ring; describe it as WHAT."
  (proton-pass--clear-kill)
  (kill-new secret)
  (setq proton-pass--kill secret
        proton-pass--kill-timer (run-at-time proton-pass-clipboard-timeout nil
                                             #'proton-pass--clear-kill))
  (message "Copied %s; clears in %ds" what proton-pass-clipboard-timeout))

;;;; Commands

;;;###autoload
(defun proton-pass-copy-password (title)
  "Copy the password of item TITLE."
  (interactive (list (proton-pass--read-title)))
  (proton-pass--copy (proton-pass-get (proton-pass--uri title))
                     (format "password for %s" title)))

;;;###autoload
(defun proton-pass-copy-username (title)
  "Copy the username (or email) of item TITLE."
  (interactive (list (proton-pass--read-title)))
  (let* ((login (alist-get 'Login (alist-get 'content (alist-get 'content (proton-pass--item title)))))
         (user (seq-find (lambda (s) (and s (not (string-empty-p s))))
                         (list (alist-get 'username login) (alist-get 'email login)))))
    (unless user (user-error "%s has no username or email" title))
    ;; Usernames aren't secret: plain kill, no auto-clear.
    (kill-new user)
    (message "Copied username for %s" title)))

;;;###autoload
(defun proton-pass-copy-field (title field)
  "Copy FIELD of item TITLE, choosing among the fields the item has."
  (interactive
   (let* ((title (proton-pass--read-title))
          (content (alist-get 'content (proton-pass--item title)))
          (typed (cdar (alist-get 'content content)))
          (fields (append
                   (cl-loop for (k . v) in typed
                            when (and (stringp v) (not (string-empty-p v)))
                            collect (symbol-name k))
                   (delq nil (mapcar (lambda (f) (alist-get 'name f))
                                     (alist-get 'extra_fields content))))))
     (list title (completing-read (format "Field of %s: " title) fields nil t))))
  (proton-pass--copy (proton-pass-get (proton-pass--uri title field))
                     (format "%s of %s" field title)))

;;;###autoload
(defun proton-pass-totp (title)
  "Copy the current TOTP code of item TITLE."
  (interactive (list (proton-pass--read-title)))
  (let* ((out (proton-pass--call "item" "totp" "--vault-name" proton-pass-vault
                                 "--item-title" title))
         (code (and (string-match "\\b[0-9]\\{6,8\\}\\b" out) (match-string 0 out))))
    (unless code (user-error "No TOTP code for %s" title))
    (proton-pass--copy code (format "TOTP for %s" title))))

;;;###autoload
(defun proton-pass-insert-generated-password (length)
  "Insert a freshly generated password of LENGTH (prefix arg, default 24)."
  (interactive "p")
  (insert (proton-pass--call "password" "generate" "random" "--length"
                             (number-to-string (if (> length 1) length 24)))))

;;;###autoload
(defun proton-pass-info ()
  "Show the current Proton Pass CLI session."
  (interactive)
  (message "%s" (proton-pass--call "info")))

;;;###autoload
(defun proton-pass-use-ssh-agent ()
  "Point `SSH_AUTH_SOCK' at the Proton Pass SSH agent if it is running.
GUI Emacs on macOS doesn't inherit the shell's value, so magit/tramp
would otherwise talk to the launchd agent instead."
  (interactive)
  (let ((sock (expand-file-name proton-pass-ssh-agent-socket)))
    (if (file-exists-p sock)
        (progn (setenv "SSH_AUTH_SOCK" sock)
               (when (called-interactively-p 'any)
                 (message "SSH_AUTH_SOCK -> %s" sock)))
      (when (called-interactively-p 'any)
        (message "No Proton Pass SSH agent at %s (run: pass-cli ssh-agent start)" sock)))))

;;;; auth-source backend

(defun proton-pass--auth-match (query value)
  "Non-nil if auth-source QUERY (nil, t, string or list) matches VALUE."
  (cond ((memq query '(nil t)) t)
        ((listp query) (member value query))
        (t (equal query value))))

(cl-defun proton-pass-auth-source-search (&rest spec &key host user port require max
                                                &allow-other-keys)
  "Search `proton-pass-auth-source-alist' for auth-source.
SPEC is the full query; HOST, USER, PORT, REQUIRE and MAX are as in
`auth-source-search'.  Returned :secret is a closure, so pass-cli only
runs when a password is actually needed."
  (ignore spec)
  (let ((max (or max 1)) results)
    (pcase-dolist (`(,h ,u ,uri) proton-pass-auth-source-alist)
      (let ((u (or u (and (stringp user) user))))
        (when (and (< (length results) max)
                   (proton-pass--auth-match host h)
                   (or (null u) (proton-pass--auth-match user u))
                   (not (and (memq :user require) (null u))))
          (push (append (list :host h
                              :secret (lambda () (proton-pass-get uri)))
                        (and u (list :user u))
                        (and (stringp port) (list :port port)))
                results))))
    (nreverse results)))

(defvar proton-pass-auth-source-backend
  (auth-source-backend :source "." :type 'proton-pass
                       :search-function #'proton-pass-auth-source-search)
  "The auth-source backend for Proton Pass.")

(defun proton-pass-auth-source-backend-parse (entry)
  "Return the Proton Pass backend when ENTRY is the symbol `proton-pass'."
  (when (eq entry 'proton-pass)
    (auth-source-backend-parse-parameters entry proton-pass-auth-source-backend)))

(add-hook 'auth-source-backend-parser-functions
          #'proton-pass-auth-source-backend-parse)

;;;###autoload
(defun proton-pass-auth-source-enable ()
  "Put `proton-pass' first in `auth-sources'."
  (setq auth-sources (cons 'proton-pass (delq 'proton-pass auth-sources)))
  (auth-source-forget-all-cached))

(provide 'proton-pass)
;;; proton-pass.el ends here
