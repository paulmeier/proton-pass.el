;;; proton-pass-test.el --- Tests for proton-pass -*- lexical-binding: t; -*-

;;; Commentary:

;; `pass-cli' is mocked throughout; these tests never touch a real vault.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'proton-pass)

(defmacro proton-pass-test--with-cli (responses &rest body)
  "Run BODY with `proton-pass--call' mocked.
RESPONSES is an alist of (ARGS . OUTPUT); unknown args signal.  The
list of calls made is bound to `calls' (most recent first)."
  (declare (indent 1))
  `(let ((calls nil)
         (proton-pass--cache (make-hash-table :test #'equal))
         (proton-pass--titles nil)
         (proton-pass-cache-ttl 3600))
     (cl-letf (((symbol-function 'proton-pass--call)
                (lambda (&rest args)
                  (push args calls)
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
      '((("item" "totp" "--vault-name" "V" "--item-title" "GitHub") . "GitHub: 123456"))
    (let ((proton-pass-vault "V") (kill-ring nil) (kill-ring-yank-pointer nil)
          (interprogram-cut-function nil))
      (proton-pass-totp "GitHub")
      (should (equal (car kill-ring) "123456"))
      (proton-pass--clear-kill))))

(provide 'proton-pass-test)
;;; proton-pass-test.el ends here
