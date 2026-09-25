# proton-pass.el

Use [Proton Pass](https://proton.me/pass) from Emacs through its CLI, `pass-cli`.

- **auth-source backend**: anything that reads credentials through
  auth-source (gptel, smtpmail, forge, sql, tramp, …) can read them from
  Proton Pass.
- **`proton-pass-get`**: fetch a secret by `pass://` URI from your config code.
- **Copy commands**: copy a password, username, any field or TOTP code to
  the kill ring. Secrets clear from the kill ring and the system clipboard
  after 45s.
- **SSH agent**: point `SSH_AUTH_SOCK` at the Proton Pass SSH agent so
  magit and tramp use the SSH keys stored in Pass.

`pass-cli` takes a few seconds per call, so nothing runs at load time.
auth-source results carry a *lazy* secret, fetched only when a password
is actually needed. Fetched secrets are then cached in memory for
`proton-pass-cache-ttl` seconds (1 hour by default).

## Requirements

- Emacs 29.1+
- `pass-cli` on `PATH` (or set `proton-pass-executable`), logged in with
  `pass-cli login`

## Install

Doom Emacs (`packages.el`):

```elisp
(package! proton-pass :recipe (:host github :repo "paulmeier/proton-pass.el"))
```

`use-package` with `:vc` (Emacs 30):

```elisp
(use-package proton-pass
  :vc (:url "https://github.com/paulmeier/proton-pass.el"))
```

## Configure

```elisp
(require 'proton-pass)

(setq proton-pass-vault "Personal"
      ;; (HOST USER URI); USER nil matches any user.
      proton-pass-auth-source-alist
      '(("api.anthropic.com" "apikey" "pass://Personal/Anthropic API/password")
        ("127.0.0.1"         nil      "pass://Personal/Proton Mail Bridge/password")))

(proton-pass-auth-source-enable)   ; put `proton-pass' first in `auth-sources'
(proton-pass-use-ssh-agent)        ; SSH_AUTH_SOCK -> Proton Pass agent
```

Only map an item after it exists in Proton Pass. auth-source stops at
the first backend that matches, so a mapping to a missing item raises an
error instead of falling back to `~/.authinfo.gpg`.

Item titles aren't secret, so this mapping can live in a public dotfiles
repo.

URIs have the form `pass://VAULT/ITEM TITLE/FIELD`. `FIELD` is a
standard field (`password`, `username`, `email`, …) or the name of a
custom field.

## Commands

| Command                                  | Does                                            |
|------------------------------------------|-------------------------------------------------|
| `proton-pass-copy-password`              | Copy an item's password (auto-clears)           |
| `proton-pass-copy-username`              | Copy username or email                          |
| `proton-pass-copy-field`                 | Choose any field of an item and copy it         |
| `proton-pass-totp`                       | Copy the current TOTP code (auto-clears)        |
| `proton-pass-insert-generated-password`  | Insert a new random password (prefix = length)  |
| `proton-pass-clear-cache`                | Forget cached secrets and titles                |
| `proton-pass-info`                       | Show the `pass-cli` session                     |
| `proton-pass-use-ssh-agent`              | Export the Proton Pass SSH agent socket         |

Item completion lists titles from `proton-pass-vault`. Titles are
cached for the session; call a command with `C-u` to refresh the list.

Example Doom bindings:

```elisp
(map! :leader
      (:prefix ("P" . "proton pass")
       :desc "Copy password" "p" #'proton-pass-copy-password
       :desc "Copy username" "u" #'proton-pass-copy-username
       :desc "Copy field"    "f" #'proton-pass-copy-field
       :desc "Copy TOTP"     "t" #'proton-pass-totp))
```

## Customization

| Variable                          | Default                                |
|-----------------------------------|----------------------------------------|
| `proton-pass-executable`          | `pass-cli` on `PATH`                   |
| `proton-pass-vault`               | `"Personal"`                           |
| `proton-pass-auth-source-alist`   | `nil`                                  |
| `proton-pass-cache-ttl`           | `3600` (seconds; `nil` disables)       |
| `proton-pass-clipboard-timeout`   | `45` (seconds)                         |
| `proton-pass-ssh-agent-socket`    | `~/.ssh/proton-pass-ssh-agent.sock`    |

## Development

```sh
make check   # byte-compile (warnings are errors), checkdoc, ERT tests
```

The tests mock `pass-cli` and never touch a real vault.

## License

MIT
