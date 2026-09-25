;;; init.el --- Emacs setup for recording the README demo -*- lexical-binding: t; -*-

;; emacs -nw -Q -l demo/init.el
;; Uses demo/pass-cli, a fake CLI over a made-up vault.

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name ".." dir))
  (require 'proton-pass)
  (setq proton-pass-executable (expand-file-name "pass-cli" dir)))

(setq inhibit-startup-screen t
      initial-scratch-message ";; Any buffer: C-t (proton-pass-copy-password) completes item titles.\n"
      ring-bell-function #'ignore
      echo-keystrokes 0.1)
(menu-bar-mode -1)
(load-theme 'modus-vivendi t)
(fido-vertical-mode 1)
(global-hl-line-mode 1)
(keymap-global-set "C-t" #'proton-pass-copy-password)
(add-hook 'emacs-startup-hook #'proton-pass)
;;; init.el ends here
