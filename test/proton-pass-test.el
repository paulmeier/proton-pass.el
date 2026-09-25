;;; proton-pass-test.el --- Tests for proton-pass -*- lexical-binding: t; -*-

;;; Commentary:

;; `pass-cli' is mocked throughout; these tests never touch a real vault.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'proton-pass)

(defmacro proton-pass-test--with-cli (responses &rest body)
  "Run BODY with pass-cli mocked.
RESPONSES is an alist of (ARGS . OUTPUT); unknown args signal.  The
calls made are bound to `calls' and their stdin to `inputs' (most
recent first)."
  (declare (indent 1))
  `(let ((calls nil) (inputs nil)
         (proton-pass--cache (make-hash-table :test #'equal))
         (proton-pass--items-cache nil)
         (proton-pass-cache-ttl 3600))
     (cl-letf (((symbol-function 'proton-pass--call-with-input)
                (lambda (input &rest args)
                  (push args calls)
                  (push input inputs)
                  (or (cdr (assoc args ,responses))
                      (user-error "Not mocked: %S" args)))))
       ,@body)))

;;;; URIs and cache

(ert-deftest proton-pass-test-uri ()
  (let ((proton-pass-vault "Personal"))
    (should (equal (proton-pass--uri "GitHub") "pass://Personal/GitHub/password"))
    (should (equal (proton-pass--uri "GitHub" "username" "Work")
                   "pass://Work/GitHub/username"))))

(ert-deftest proton-pass-test-get-caches ()
  (proton-pass-test--with-cli '((("item" "view" "pass://V/I/password") . "s3cret"))
    (should (equal (proton-pass-get "pass://V/I/password") "s3cret"))
    (should (equal (proton-pass-get "pass://V/I/password") "s3cret"))
    (should (= (length calls) 1))))

(ert-deftest proton-pass-test-get-no-cache ()
  (proton-pass-test--with-cli '((("item" "view" "pass://V/I/password") . "s3cret"))
    (let ((proton-pass-cache-ttl nil))
      (proton-pass-get "pass://V/I/password")
      (proton-pass-get "pass://V/I/password")
      (should (= (length calls) 2)))))

(ert-deftest proton-pass-test-call-failure-is-user-error ()
  (let ((proton-pass-executable (executable-find "false")))
    (should-error (proton-pass--call "info") :type 'user-error)))

;;;; auth-source

(ert-deftest proton-pass-test-auth-match ()
  (should (proton-pass--auth-match nil "x"))
  (should (proton-pass--auth-match t "x"))
  (should (proton-pass--auth-match "x" "x"))
  (should-not (proton-pass--auth-match "y" "x"))
  (should (proton-pass--auth-match '("y" "x") "x"))
  (should-not (proton-pass--auth-match '("y" "z") "x")))

(defconst proton-pass-test--alist
  '(("api.example.com" "apikey" "pass://V/Example/password")
    ("mail.example.com" nil "pass://V/Mail/password")))

(ert-deftest proton-pass-test-search-is-lazy ()
  (proton-pass-test--with-cli '((("item" "view" "pass://V/Example/password") . "k3y"))
    (let* ((proton-pass-auth-source-alist proton-pass-test--alist)
           (hit (car (proton-pass-auth-source-search :host "api.example.com"))))
      (should (equal (plist-get hit :user) "apikey"))
      (should (null calls))
      (should (equal (funcall (plist-get hit :secret)) "k3y"))
      (should (= (length calls) 1)))))

(ert-deftest proton-pass-test-search-any-user ()
  (let* ((proton-pass-auth-source-alist proton-pass-test--alist)
         (hit (car (proton-pass-auth-source-search
                    :host "mail.example.com" :user "me" :port "1025"))))
    (should (equal (plist-get hit :user) "me"))
    (should (equal (plist-get hit :port) "1025"))))

(ert-deftest proton-pass-test-search-misses ()
  (let ((proton-pass-auth-source-alist proton-pass-test--alist))
    (should-not (proton-pass-auth-source-search :host "nope.example.com"))
    (should-not (proton-pass-auth-source-search :host "api.example.com" :user "other"))
    (should-not (proton-pass-auth-source-search :host "mail.example.com"
                                                :require '(:user)))))

(ert-deftest proton-pass-test-search-max ()
  (let ((proton-pass-auth-source-alist proton-pass-test--alist))
    (should (= 1 (length (proton-pass-auth-source-search :host t))))
    (should (= 2 (length (proton-pass-auth-source-search :host t :max 5))))))

(ert-deftest proton-pass-test-auth-source-integration ()
  (proton-pass-test--with-cli '((("item" "view" "pass://V/Example/password") . "k3y"))
    (let ((proton-pass-auth-source-alist proton-pass-test--alist)
          (auth-sources nil))
      (proton-pass-auth-source-enable)
      (should (eq (car auth-sources) 'proton-pass))
      (should (equal (auth-source-pick-first-password :host "api.example.com"
                                                      :user "apikey")
                     "k3y"))
      (auth-source-forget-all-cached))))

;;;; Kill ring

(ert-deftest proton-pass-test-copy-and-clear ()
  (let ((kill-ring nil) (kill-ring-yank-pointer nil)
        (interprogram-cut-function nil)
        (proton-pass-clipboard-timeout 60))
    (proton-pass--copy "s3cret" "test")
    (should (equal (car kill-ring) "s3cret"))
    (should (timerp proton-pass--kill-timer))
    (proton-pass--clear-kill)
    (should-not (member "s3cret" kill-ring))
    (should-not proton-pass--kill-timer)))

(ert-deftest proton-pass-test-totp ()
  (proton-pass-test--with-cli
      '((("item" "totp" "--share-id" "s" "--item-id" "1") . "GitHub: 123456"))
    (let ((proton-pass-vault "V") (kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil))
      (proton-pass-totp (proton-pass-item-create :title "GitHub" :share-id "s" :id "1"))
      (should (equal (car kill-ring) "123456"))
      (proton-pass--clear-kill))))

;;;; Managing items

(ert-deftest proton-pass-test-create-login-uses-stdin ()
  (proton-pass-test--with-cli
      '((("item" "create" "login" "--vault-name" "V" "--from-template" "-") . "ok"))
    (let ((proton-pass-vault "V"))
      (proton-pass--create-login "New" "me" "hunter2" "https://x.test")
      (should-not (cl-some (lambda (a) (member "hunter2" a)) calls))
      (let ((json (json-parse-string (car inputs) :object-type 'alist
                                     :null-object nil)))
        (should (equal (alist-get 'title json) "New"))
        (should (equal (alist-get 'password json) "hunter2"))
        (should (equal (alist-get 'urls json) ["https://x.test"]))))))

(ert-deftest proton-pass-test-create-login-empty-optionals ()
  (proton-pass-test--with-cli
      '((("item" "create" "login" "--vault-name" "V" "--from-template" "-") . "ok"))
    (let ((proton-pass-vault "V"))
      (proton-pass--create-login "New" "" "pw" "")
      (let ((json (json-parse-string (car inputs) :object-type 'alist
                                     :null-object nil)))
        (should (null (alist-get 'username json)))
        (should (equal (alist-get 'urls json) []))))))

(ert-deftest proton-pass-test-update-args ()
  (proton-pass-test--with-cli
      '((("item" "update" "--share-id" "s" "--item-id" "1"
          "--field" "title=B" "--field" "note=hi") . "ok"))
    (let ((proton-pass-vault "V"))
      (proton-pass--update (proton-pass-item-create :title "A" :share-id "s" :id "1")
                           "title" "B" "note" "hi")
      (should (= (length calls) 1)))))

(ert-deftest proton-pass-test-changed-invalidates ()
  (let ((proton-pass--cache (make-hash-table :test #'equal))
        (proton-pass--items-cache '("V" . (x))))
    (puthash "pass://V/A/password" (cons (current-time) "s") proton-pass--cache)
    (proton-pass--changed)
    (should (= 0 (hash-table-count proton-pass--cache)))
    (should-not proton-pass--items-cache)))

;;;; Browser

(defconst proton-pass-test--list-json
  "{\"items\":[{\"id\":\"1\",\"share_id\":\"s\",\"title\":\"GitHub\",\"item_type\":\"Login\",\"modify_time\":\"1758800000\"},{\"id\":\"2\",\"share_id\":\"s\",\"title\":\"Notes\",\"item_type\":\"Note\",\"modify_time\":\"1758800000\"}]}")

(ert-deftest proton-pass-test-browser-lists-and-reads-point ()
  (proton-pass-test--with-cli
      `((("item" "list" "V" "--filter-state" "active" "--output" "json")
         . ,proton-pass-test--list-json))
    (let ((proton-pass-vault "V"))
      (save-window-excursion
        (proton-pass)
        (unwind-protect
            (progn
              (should (derived-mode-p 'proton-pass-mode))
              (should (= 2 (length tabulated-list-entries)))
              (goto-char (point-min))
              (should (equal (proton-pass-item-title (proton-pass--read-item)) "GitHub"))
              (should (eq (key-binding "w") #'proton-pass-copy-password))
              (should (eq (key-binding (kbd "RET")) #'proton-pass-view)))
          (kill-buffer proton-pass-buffer-name))))))

(ert-deftest proton-pass-test-view-masks-secrets ()
  (with-temp-buffer
    (let ((proton-pass-vault "V"))
      (proton-pass--view-insert
       '((content (title . "GitHub") (note . "a note")
                  (content (Login (username . "me") (password . "hunter2")
                                  (totp_uri . "otpauth://x") (urls "https://github.com")))
                  (extra_fields ((name . "recovery") (content (Hidden . "zzz")))))))
      (let ((text (buffer-string)))
        (should (string-match-p "username +me" text))
        (should (string-match-p "https://github.com" text))
        (should (string-match-p "recovery +\\*+" text))
        (should (string-match-p "a note" text))
        (should-not (string-match-p "hunter2\\|otpauth\\|zzz" text))))))

(ert-deftest proton-pass-test-short-time ()
  (should (equal (proton-pass--short-time "2026-09-12T02:14:21") "2026-09-12 02:14"))
  (should (string-match-p "\\`[0-9-]+ [0-9:]+\\'" (proton-pass--short-time "1758800000")))
  (should (equal (proton-pass--short-time "garbage") "garbage")))

;;;; Duplicate titles (#1)

(defconst proton-pass-test--dup-json
  "{\"items\":[{\"id\":\"aaaa1111\",\"share_id\":\"s\",\"title\":\"GitHub\",\"item_type\":\"login\",\"modify_time\":\"2026-09-01T10:00:00\"},{\"id\":\"bbbb2222\",\"share_id\":\"s\",\"title\":\"GitHub\",\"item_type\":\"login\",\"modify_time\":\"2026-09-02T11:30:00\"},{\"id\":\"cccc3333\",\"share_id\":\"s\",\"title\":\"GitHub\",\"item_type\":\"login\",\"modify_time\":\"2026-09-02T11:30:00\"},{\"id\":\"dddd4444\",\"share_id\":\"s\",\"title\":\"Codeberg\",\"item_type\":\"login\",\"modify_time\":\"2026-09-03T09:00:00\"}]}")

(defconst proton-pass-test--dup-responses
  `((("item" "list" "V" "--filter-state" "active" "--output" "json")
     . ,proton-pass-test--dup-json)
    (("item" "trash" "--share-id" "s" "--item-id" "bbbb2222") . "ok")
    (("item" "update" "--share-id" "s" "--item-id" "cccc3333" "--field" "title=GitHub (old)") . "ok")
    (("item" "view" "pass://s/bbbb2222/password") . "second-pw")))

(ert-deftest proton-pass-test-dup-candidates-unique ()
  (let* ((c (proton-pass--candidates
             (alist-get 'items (json-parse-string proton-pass-test--dup-json
                                                  :object-type 'alist :array-type 'list))))
         (names (mapcar #'car c)))
    (should (equal (length names) (length (delete-dups (copy-sequence names)))))
    (should (member "Codeberg" names))
    (should (member "GitHub  (2026-09-01 10:00)" names))
    ;; Same title and same minute: the ID prefix breaks the tie.
    (should (member "GitHub  (2026-09-02 11:30) [cccc3333]" names))
    (should (equal (proton-pass-item-id (cdr (assoc "GitHub  (2026-09-01 10:00)" c)))
                   "aaaa1111"))))

(ert-deftest proton-pass-test-dup-completion-returns-the-chosen-item ()
  (proton-pass-test--with-cli proton-pass-test--dup-responses
    (let ((proton-pass-vault "V"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (car (seq-find (lambda (c) (string-prefix-p "GitHub  (2026-09-02 11:30)" (car c)))
                                  coll)))))
        (should (equal (proton-pass-item-id (proton-pass--read-item)) "bbbb2222"))))))

(ert-deftest proton-pass-test-dup-title-string-is-rejected ()
  (proton-pass-test--with-cli proton-pass-test--dup-responses
    (let ((proton-pass-vault "V"))
      (should-error (proton-pass--resolve "GitHub") :type 'user-error)
      (should (equal (proton-pass-item-id (proton-pass--resolve "Codeberg")) "dddd4444"))
      (should-error (proton-pass--resolve "Nope") :type 'user-error))))

(ert-deftest proton-pass-test-dup-browser-acts-on-row ()
  (proton-pass-test--with-cli proton-pass-test--dup-responses
    (let ((proton-pass-vault "V") (kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (save-window-excursion
          (proton-pass)
          (unwind-protect
              (progn
                ;; Sorted by title: Codeberg, then the three GitHubs.
                (goto-char (point-min))
                (while (not (equal (proton-pass-item-id (tabulated-list-get-id)) "bbbb2222"))
                  (forward-line 1))
                (proton-pass-copy-password (proton-pass--read-item))
                (should (equal (car kill-ring) "second-pw"))
                (proton-pass-remove (proton-pass--read-item))
                (should (member '("item" "trash" "--share-id" "s" "--item-id" "bbbb2222") calls))
                (proton-pass-rename (proton-pass-item-create :title "GitHub" :share-id "s"
                                                             :id "cccc3333")
                                    "GitHub (old)")
                (should-not (cl-some (lambda (a) (member "--item-title" a)) calls))
                (proton-pass--clear-kill))
            (kill-buffer proton-pass-buffer-name)))))))

(provide 'proton-pass-test)
;;; proton-pass-test.el ends here
