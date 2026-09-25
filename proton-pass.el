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

;; A thin wrapper around `pass-cli', the Proton Pass command-line tool,
;; modelled on pass.el / password-store.el:
;;
;;   - `proton-pass'                browse a vault, act on items with one key
;;   - `proton-pass-insert', `proton-pass-generate', `proton-pass-edit',
;;     `proton-pass-rename', `proton-pass-remove', `proton-pass-url'
;;                                  manage items (remove = move to trash)
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

(defconst proton-pass-buffer-name "*Proton Pass*"
  "Name of the `proton-pass' browser buffer.")

;;;; Process plumbing

(defun proton-pass--call (&rest args)
  "Run `pass-cli' with ARGS and return stdout without the trailing newline.
Signal a `user-error' carrying stderr on failure."
  (apply #'proton-pass--call-with-input nil args))

(defun proton-pass--call-with-input (input &rest args)
  "Run `pass-cli' with ARGS, feeding string INPUT (if non-nil) on stdin.
Return stdout like `proton-pass--call'.  Secrets passed this way stay
out of the process list."
  (let ((err-file (make-temp-file "proton-pass-err")))
    (unwind-protect
        (with-temp-buffer
          (when input (insert input))
          (let ((status (apply #'call-process-region (point-min) (point-max)
                               proton-pass-executable t
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
  "Build a title-based pass:// URI for TITLE, FIELD and VAULT.
FIELD defaults to password.  Titles aren't unique; this is for
user-written references such as `proton-pass-auth-source-alist'."
  (format "pass://%s/%s/%s" (or vault proton-pass-vault) title (or field "password")))

;;;; Secret cache

(defvar proton-pass--items-cache nil
  "Cached (VAULT . ITEMS) from `pass-cli item list'.  No secrets in it.")

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
  (proton-pass--invalidate)
  (message "Proton Pass cache cleared"))

(defun proton-pass--invalidate ()
  "Drop cached secrets and item lists, e.g. after changing an item."
  (clrhash proton-pass--cache)
  (setq proton-pass--items-cache nil)
  (auth-source-forget-all-cached))

;;;; Item selection

(defun proton-pass--items (&optional refresh)
  "Return the active items of `proton-pass-vault', cached per vault.
With REFRESH, or when the cached list is for another vault, re-list."
  (when (or refresh (not (equal (car proton-pass--items-cache) proton-pass-vault)))
    (message "Listing %s vault..." proton-pass-vault)
    (setq proton-pass--items-cache
          (cons proton-pass-vault
                (alist-get 'items (proton-pass--json
                                   "item" "list" proton-pass-vault
                                   "--filter-state" "active"
                                   "--output" "json"))))
    (message nil))
  (cdr proton-pass--items-cache))

(cl-defstruct (proton-pass-item (:constructor proton-pass-item-create)
                                 (:copier nil))
  "Reference to one Proton Pass item.
Titles aren't unique, so commands act on SHARE-ID and ID; TITLE is
for display."
  title share-id id)

(defun proton-pass--item-from-list (it)
  "Make a `proton-pass-item' from IT, an entry of `item list' output."
  (proton-pass-item-create :title (alist-get 'title it)
                           :share-id (alist-get 'share_id it)
                           :id (alist-get 'id it)))

(defun proton-pass--item-args (item)
  "Return the pass-cli arguments that select ITEM by ID."
  (list "--share-id" (proton-pass-item-share-id item)
        "--item-id" (proton-pass-item-id item)))

(defun proton-pass--item-uri (item &optional field)
  "Return the ID-based pass:// URI for FIELD (default password) of ITEM."
  (format "pass://%s/%s/%s" (proton-pass-item-share-id item)
          (proton-pass-item-id item) (or field "password")))

(defun proton-pass--resolve (item)
  "Return ITEM as a `proton-pass-item'.
ITEM may already be one, or a title string, which must match exactly
one item in `proton-pass-vault'."
  (if (proton-pass-item-p item)
      item
    (let ((matches (seq-filter (lambda (it) (equal (alist-get 'title it) item))
                               (proton-pass--items))))
      (pcase (length matches)
        (0 (user-error "No item titled %s in %s" item proton-pass-vault))
        (1 (proton-pass--item-from-list (car matches)))
        (n (user-error "%d items are titled %s in %s; pick one with completion or the browser"
                       n item proton-pass-vault))))))

(defun proton-pass--candidates (items)
  "Return an alist of (DISPLAY . `proton-pass-item') for ITEMS.
Titles shared by several items get their modification time, and the
start of their ID if that still collides, so every DISPLAY is unique."
  (let ((counts (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal)))
    (dolist (it items)
      (cl-incf (gethash (alist-get 'title it) counts 0)))
    (mapcar
     (lambda (it)
       (let* ((title (alist-get 'title it))
              (display (if (= 1 (gethash title counts))
                           title
                         (format "%s  (%s)" title
                                 (proton-pass--short-time (alist-get 'modify_time it))))))
         (when (gethash display seen)
           (setq display (format "%s [%s]" display
                                 (substring (alist-get 'id it) 0
                                            (min 8 (length (alist-get 'id it)))))))
         (puthash display t seen)
         (cons display (proton-pass--item-from-list it))))
     items)))

(defun proton-pass--read-item (&optional prompt)
  "Read an item of `proton-pass-vault' with completion.
Return a `proton-pass-item'.  PROMPT defaults to \"Proton Pass item: \".
With a prefix argument, refresh the cached item list first.  In a
`proton-pass-mode' or item view buffer, the item at point is used
without prompting."
  (or (and (not prompt) (proton-pass--item-at-point))
      (let ((candidates (proton-pass--candidates
                         (proton-pass--items current-prefix-arg))))
        (cdr (assoc (completing-read (or prompt "Proton Pass item: ")
                                     candidates nil t)
                    candidates)))))

(defun proton-pass--login (item-json)
  "Return the Login content alist of ITEM-JSON, or nil for other types."
  (alist-get 'Login (alist-get 'content (alist-get 'content item-json))))

(defun proton-pass--item (item)
  "Return the full JSON of ITEM (a `proton-pass-item' or unique title)."
  (alist-get 'item (apply #'proton-pass--json "item" "view"
                          (append (proton-pass--item-args (proton-pass--resolve item))
                                  '("--output" "json")))))

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
(defun proton-pass-copy-password (item)
  "Copy the password of ITEM."
  (interactive (list (proton-pass--read-item)))
  (let ((item (proton-pass--resolve item)))
    (proton-pass--copy (proton-pass-get (proton-pass--item-uri item))
                       (format "password for %s" (proton-pass-item-title item)))))

;;;###autoload
(defun proton-pass-copy-username (item)
  "Copy the username (or email) of ITEM."
  (interactive (list (proton-pass--read-item)))
  (let* ((item (proton-pass--resolve item))
         (login (proton-pass--login (proton-pass--item item)))
         (user (seq-find (lambda (s) (and s (not (string-empty-p s))))
                         (list (alist-get 'username login) (alist-get 'email login)))))
    (unless user (user-error "%s has no username or email" (proton-pass-item-title item)))
    ;; Usernames aren't secret: plain kill, no auto-clear.
    (kill-new user)
    (message "Copied username for %s" (proton-pass-item-title item))))

;;;###autoload
(defun proton-pass-copy-field (item field)
  "Copy FIELD of ITEM, choosing among the fields the item has."
  (interactive
   (let ((item (proton-pass--read-item)))
     (list item (completing-read (format "Field of %s: " (proton-pass-item-title item))
                                 (proton-pass--field-names item) nil t))))
  (let ((item (proton-pass--resolve item)))
    (proton-pass--copy (proton-pass-get (proton-pass--item-uri item field))
                       (format "%s of %s" field (proton-pass-item-title item)))))

;;;###autoload
(defun proton-pass-totp (item)
  "Copy the current TOTP code of ITEM."
  (interactive (list (proton-pass--read-item)))
  (let* ((item (proton-pass--resolve item))
         (out (apply #'proton-pass--call "item" "totp" (proton-pass--item-args item)))
         (code (and (string-match "\\b[0-9]\\{6,8\\}\\b" out) (match-string 0 out))))
    (unless code (user-error "No TOTP code for %s" (proton-pass-item-title item)))
    (proton-pass--copy code (format "TOTP for %s" (proton-pass-item-title item)))))

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

;;;; Managing items (password-store parity)

(defun proton-pass--read-new-password (title)
  "Read a new password for TITLE twice, without echo."
  (read-passwd (format "Password for %s: " title) t))

(defun proton-pass--generate-password (&optional length)
  "Return a new random password of LENGTH (default 24) from pass-cli."
  (proton-pass--call "password" "generate" "random" "--length"
                     (number-to-string (or length 24))))

(defun proton-pass--create-login (title username password &optional url)
  "Create login TITLE with USERNAME, PASSWORD and URL in `proton-pass-vault'.
The item is sent on stdin, so PASSWORD never appears in the process list."
  (proton-pass--call-with-input
   (json-serialize `((title . ,title)
                     (username . ,(if (string-empty-p username) :null username))
                     (email . :null)
                     (password . ,password)
                     (totp_uri . :null)
                     (urls . ,(vconcat (and url (not (string-empty-p url)) (list url))))))
   "item" "create" "login" "--vault-name" proton-pass-vault "--from-template" "-")
  (proton-pass--changed))

(defun proton-pass--update (item &rest field-values)
  "Set FIELD-VALUES (alternating FIELD VALUE strings) on ITEM.
Unknown field names become custom fields."
  (apply #'proton-pass--call "item" "update"
         (append (proton-pass--item-args (proton-pass--resolve item))
                 (cl-loop for (f v) on field-values by #'cddr
                          append (list "--field" (concat f "=" v)))))
  (proton-pass--changed))

(defun proton-pass--changed ()
  "Invalidate caches and refresh any open `proton-pass' buffer."
  (proton-pass--invalidate)
  (when-let* ((buf (get-buffer proton-pass-buffer-name)))
    (with-current-buffer buf (proton-pass-refresh))))

;;;###autoload
(defun proton-pass-insert (title username password &optional url)
  "Create a login item TITLE with USERNAME, PASSWORD and optional URL."
  (interactive
   (let* ((title (read-string "New item title: "))
          (username (read-string "Username (empty for none): "))
          (password (proton-pass--read-new-password title))
          (url (read-string "URL (empty for none): ")))
     (list title username password url)))
  (proton-pass--create-login title username password url)
  (message "Created %s in %s" title proton-pass-vault))

;;;###autoload
(defun proton-pass-generate (title username &optional length)
  "Create login TITLE for USERNAME with a generated password of LENGTH.
LENGTH is the numeric prefix argument (default 24).  The new password
is copied to the kill ring."
  (interactive (list (read-string "New item title: ")
                     (read-string "Username (empty for none): ")
                     (and current-prefix-arg
                          (prefix-numeric-value current-prefix-arg))))
  (let ((password (proton-pass--generate-password length)))
    (proton-pass--create-login title username password)
    (proton-pass--copy password (format "new password for %s" title))))

;;;###autoload
(defun proton-pass-edit (item field value)
  "Set FIELD of ITEM to VALUE.
Offers the item's existing fields; a new name adds a custom field.
Password-like fields are read without echo."
  (interactive
   (let* ((item (proton-pass--read-item))
          (title (proton-pass-item-title item))
          (field (completing-read (format "Field of %s to set: " title)
                                  (proton-pass--field-names item)))
          (value (if (member field '("password" "totp_uri"))
                     (proton-pass--read-new-password title)
                   (read-string (format "New %s: " field)))))
     (list item field value)))
  (let ((item (proton-pass--resolve item)))
    (proton-pass--update item field value)
    (message "Updated %s of %s" field (proton-pass-item-title item))))

;;;###autoload
(defun proton-pass-rename (item new-title)
  "Rename ITEM to NEW-TITLE."
  (interactive
   (let ((item (proton-pass--read-item)))
     (list item (read-string (format "Rename %s to: " (proton-pass-item-title item))
                             (proton-pass-item-title item)))))
  (let ((item (proton-pass--resolve item)))
    (proton-pass--update item "title" new-title)
    (message "Renamed %s to %s" (proton-pass-item-title item) new-title)))

;;;###autoload
(defun proton-pass-remove (item)
  "Move ITEM to the Proton Pass trash (recoverable)."
  (interactive (list (proton-pass--read-item)))
  (let* ((item (proton-pass--resolve item))
         (title (proton-pass-item-title item)))
    (when (yes-or-no-p (format "Move %s to trash? " title))
      (apply #'proton-pass--call "item" "trash" (proton-pass--item-args item))
      (proton-pass--changed)
      (message "Moved %s to trash" title))))

;;;###autoload
(defun proton-pass-url (item)
  "Open the first URL of ITEM with `browse-url'."
  (interactive (list (proton-pass--read-item)))
  (let* ((item (proton-pass--resolve item))
         (url (car (alist-get 'urls (proton-pass--login (proton-pass--item item))))))
    (unless url (user-error "%s has no URL" (proton-pass-item-title item)))
    (browse-url url)))

;;;###autoload
(defun proton-pass-switch-vault (vault)
  "Make VAULT the vault used by `proton-pass' commands."
  (interactive
   (list (completing-read "Vault: "
                          (mapcar (lambda (v) (alist-get 'name v))
                                  (alist-get 'vaults (proton-pass--json
                                                      "vault" "list" "--output" "json")))
                          nil t)))
  (setq proton-pass-vault vault)
  (when-let* ((buf (get-buffer proton-pass-buffer-name)))
    (with-current-buffer buf (proton-pass-refresh)))
  (message "Proton Pass vault: %s" vault))

(defun proton-pass--field-names (item)
  "Return the names of the non-empty fields of ITEM."
  (let* ((content (alist-get 'content (proton-pass--item item)))
         (typed (cdar (alist-get 'content content))))
    (append (cl-loop for (k . v) in typed
                     when (and (stringp v) (not (string-empty-p v)))
                     collect (symbol-name k))
            (delq nil (mapcar (lambda (f) (alist-get 'name f))
                              (alist-get 'extra_fields content))))))

;;;; Browser: M-x proton-pass

(defvar-local proton-pass--view-item nil
  "The `proton-pass-item' shown in a `proton-pass-view-mode' buffer.")

(defun proton-pass--item-at-point ()
  "Return the `proton-pass-item' at point in a Proton Pass buffer, or nil."
  (cond ((derived-mode-p 'proton-pass-mode) (tabulated-list-get-id))
        ((derived-mode-p 'proton-pass-view-mode) proton-pass--view-item)))

(defvar-keymap proton-pass-command-map
  :doc "Item commands shared by `proton-pass-mode' and `proton-pass-view-mode'."
  "w" #'proton-pass-copy-password
  "b" #'proton-pass-copy-username
  "f" #'proton-pass-copy-field
  "o" #'proton-pass-totp
  "U" #'proton-pass-url
  "e" #'proton-pass-edit
  "r" #'proton-pass-rename
  "d" #'proton-pass-remove
  "i" #'proton-pass-insert
  "I" #'proton-pass-generate
  "V" #'proton-pass-switch-vault
  "?" #'describe-mode)

(defvar-keymap proton-pass-mode-map
  :parent (make-composed-keymap proton-pass-command-map tabulated-list-mode-map)
  "RET" #'proton-pass-view
  "v" #'proton-pass-view
  "g" #'proton-pass-refresh)

(define-derived-mode proton-pass-mode tabulated-list-mode "Proton Pass"
  "Browse the items of `proton-pass-vault'.
Commands act on the item at point.  Nothing secret is displayed;
passwords go straight to the kill ring and clear automatically.

\\{proton-pass-mode-map}"
  (setq tabulated-list-format [("Title" 40 t) ("Type" 10 t) ("Modified" 20 t)]
        tabulated-list-sort-key '("Title"))
  (tabulated-list-init-header))

(defun proton-pass--entries (&optional refresh)
  "Tabulated list entries for the current vault; REFRESH re-lists."
  (mapcar (lambda (it)
            (let ((title (alist-get 'title it)))
              (list (proton-pass--item-from-list it)
                    (vector title
                                  (downcase (format "%s" (alist-get 'item_type it)))
                                  (proton-pass--short-time (alist-get 'modify_time it))))))
          (proton-pass--items refresh)))

(defun proton-pass--short-time (time)
  "Format TIME from pass-cli (ISO string or epoch seconds) as YYYY-MM-DD HH:MM."
  (let ((time (format "%s" time)))
    (cond ((string-match "\\`\\([0-9-]\\{10\\}\\)T\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)" time)
           (concat (match-string 1 time) " " (match-string 2 time)))
          ((string-match-p "\\`[0-9]+\\'" time)
           (format-time-string "%Y-%m-%d %H:%M" (string-to-number time)))
          (t time))))

(defun proton-pass-refresh ()
  "Re-list the vault in the `proton-pass' buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (setq tabulated-list-entries (proton-pass--entries t)
          mode-name (format "Proton Pass[%s]" proton-pass-vault))
    (tabulated-list-print t)))

;;;###autoload
(defun proton-pass ()
  "Browse `proton-pass-vault' in a pass.el-style buffer."
  (interactive)
  (let ((buf (get-buffer-create proton-pass-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'proton-pass-mode)
        (proton-pass-mode))
      (setq tabulated-list-entries (proton-pass--entries)
            mode-name (format "Proton Pass[%s]" proton-pass-vault))
      (tabulated-list-print t))
    (pop-to-buffer-same-window buf)))

(defvar-keymap proton-pass-view-mode-map
  :parent (make-composed-keymap proton-pass-command-map special-mode-map)
  "g" #'proton-pass-view-refresh)

(define-derived-mode proton-pass-view-mode special-mode "Proton Pass Item"
  "Show one Proton Pass item.  Secret values are masked.

\\{proton-pass-view-mode-map}")

(defun proton-pass--view-insert (item)
  "Insert a masked description of ITEM into the current buffer."
  (let* ((content (alist-get 'content item))
         (typed (car (alist-get 'content content)))
         (secretp (lambda (k) (memq k '(password totp_uri number cvv pin)))))
    (insert (propertize (alist-get 'title content) 'face 'bold) "\n"
            (propertize (format "%s in %s\n\n" (car typed) proton-pass-vault)
                        'face 'shadow))
    (pcase-dolist (`(,k . ,v) (cdr typed))
      (cond ((and (stringp v) (not (string-empty-p v)))
             (insert (format "%-12s %s\n" k (if (funcall secretp k) "********" v))))
            ((and (consp v) (stringp (car v)))
             (insert (format "%-12s %s\n" k (string-join v "  "))))))
    (dolist (f (alist-get 'extra_fields content))
      (insert (format "%-12s ********\n" (alist-get 'name f))))
    (let ((note (alist-get 'note content)))
      (when (and note (not (string-empty-p note)))
        (insert "\n" note "\n")))
    (insert (propertize "\nw password  b username  f field  o TOTP  U url  e edit  r rename  d trash  q quit\n"
                        'face 'shadow))))

;;;###autoload
(defun proton-pass-view (item)
  "Show ITEM with secrets masked."
  (interactive (list (proton-pass--read-item)))
  (let* ((item (proton-pass--resolve item))
         (json (proton-pass--item item))
         (buf (get-buffer-create (format "*Proton Pass: %s*" (proton-pass-item-title item)))))
    (with-current-buffer buf
      (proton-pass-view-mode)
      (setq proton-pass--view-item item)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (proton-pass--view-insert json)
        (goto-char (point-min))))
    (pop-to-buffer buf)))

(defun proton-pass-view-refresh ()
  "Re-fetch the item in this view buffer."
  (interactive)
  (proton-pass-view proton-pass--view-item))

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
