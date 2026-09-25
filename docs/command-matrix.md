# pass-cli command matrix

Which `pass-cli` commands proton-pass.el wraps, and where the gaps are
tracked. Generated from `pass-cli --help` for **Proton Pass CLI 2.4.1**
(78 leaf commands).

Status: ✅ supported · 🟡 partial · ❌ missing (planned) · ⛔ not planned

Summary of the 78 commands: **7** supported, **3** partial, **49** missing and
planned, **19** not planned.

The roadmap is the [milestones](https://github.com/paulmeier/proton-pass.el/milestones);
see also the [Roadmap issue](https://github.com/paulmeier/proton-pass.el/issues/24).

## Known issues in what's supported

| Issue | Problem |
|---|---|
| [#2](https://github.com/paulmeier/proton-pass.el/issues/2) | `proton-pass-edit` passes the new value in argv (`item update` has no stdin input). |
| [#7](https://github.com/paulmeier/proton-pass.el/issues/7) | `item list` is synchronous: ~19s for ~1,100 items on first use. |

## Items

| pass-cli command | Status | proton-pass.el | Issue |
|---|---|---|---|
| `item list` | ✅ | `proton-pass` browser, item completion | [#7](https://github.com/paulmeier/proton-pass.el/issues/7) (speed) |
| `item list --filter-state trashed` (flag) | ❌ | | [#3](https://github.com/paulmeier/proton-pass.el/issues/3) |
| `item view` | ✅ | `proton-pass-view`, `proton-pass-get`, copy commands, auth-source | |
| `item totp` | ✅ | `proton-pass-totp` (`o`) | |
| `item update` | ✅ | `proton-pass-edit` (`e`), `proton-pass-rename` (`r`) | [#2](https://github.com/paulmeier/proton-pass.el/issues/2) |
| `item trash` | ✅ | `proton-pass-remove` (`d`) | |
| `item untrash` | ❌ | | [#3](https://github.com/paulmeier/proton-pass.el/issues/3) |
| `item create login` | 🟡 | `proton-pass-insert` (`i`), `proton-pass-generate` (`I`); no `--generate-passphrase` | [#5](https://github.com/paulmeier/proton-pass.el/issues/5) |
| `item create note` | ❌ | | [#6](https://github.com/paulmeier/proton-pass.el/issues/6) |
| `item create credit-card` | ❌ | | [#8](https://github.com/paulmeier/proton-pass.el/issues/8) |
| `item create wifi` | ❌ | | [#8](https://github.com/paulmeier/proton-pass.el/issues/8) |
| `item create identity` | ❌ | | [#8](https://github.com/paulmeier/proton-pass.el/issues/8) |
| `item create custom` | ❌ | | [#8](https://github.com/paulmeier/proton-pass.el/issues/8) |
| `item create ssh-key generate` | ❌ | | [#16](https://github.com/paulmeier/proton-pass.el/issues/16) |
| `item create ssh-key import` | ❌ | | [#16](https://github.com/paulmeier/proton-pass.el/issues/16) |
| `item move` | ❌ | | [#4](https://github.com/paulmeier/proton-pass.el/issues/4) |
| `item delete` | ❌ | Deliberately only from the trash view | [#22](https://github.com/paulmeier/proton-pass.el/issues/22) |
| `item attachment download` | ❌ | | [#9](https://github.com/paulmeier/proton-pass.el/issues/9) |
| `item alias create` | ❌ | | [#10](https://github.com/paulmeier/proton-pass.el/issues/10) |
| `item share` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `item member list` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `item member update` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `item member remove` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |

## Vaults and shares

| pass-cli command | Status | proton-pass.el | Issue |
|---|---|---|---|
| `vault list` | ✅ | `proton-pass-switch-vault` (`V`) | |
| `share list` | ❌ | | [#11](https://github.com/paulmeier/proton-pass.el/issues/11) |
| `vault create` | ❌ | | [#19](https://github.com/paulmeier/proton-pass.el/issues/19) |
| `vault update` | ❌ | | [#19](https://github.com/paulmeier/proton-pass.el/issues/19) |
| `vault delete` | ❌ | | [#19](https://github.com/paulmeier/proton-pass.el/issues/19) |
| `vault share` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `vault transfer` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `vault member list` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `vault member update` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `vault member remove` | ❌ | | [#20](https://github.com/paulmeier/proton-pass.el/issues/20) |
| `invite list` | ❌ | | [#21](https://github.com/paulmeier/proton-pass.el/issues/21) |
| `invite accept` | ❌ | | [#21](https://github.com/paulmeier/proton-pass.el/issues/21) |
| `invite reject` | ❌ | | [#21](https://github.com/paulmeier/proton-pass.el/issues/21) |

## Passwords and TOTP

| pass-cli command | Status | proton-pass.el | Issue |
|---|---|---|---|
| `password generate random` | 🟡 | `proton-pass-generate`, `proton-pass-insert-generated-password`; length only | [#5](https://github.com/paulmeier/proton-pass.el/issues/5) |
| `password generate passphrase` | ❌ | | [#5](https://github.com/paulmeier/proton-pass.el/issues/5) |
| `password score` | ❌ | | [#12](https://github.com/paulmeier/proton-pass.el/issues/12) |
| `totp generate` | ❌ | | [#12](https://github.com/paulmeier/proton-pass.el/issues/12) |

## Session, account and settings

| pass-cli command | Status | proton-pass.el | Issue |
|---|---|---|---|
| `info` | ✅ | `proton-pass-info` | [#13](https://github.com/paulmeier/proton-pass.el/issues/13) |
| `login` | ❌ | | [#13](https://github.com/paulmeier/proton-pass.el/issues/13) |
| `logout` | ❌ | | [#13](https://github.com/paulmeier/proton-pass.el/issues/13) |
| `session create-lock` | ❌ | | [#14](https://github.com/paulmeier/proton-pass.el/issues/14) |
| `session lock` | ❌ | | [#14](https://github.com/paulmeier/proton-pass.el/issues/14) |
| `session unlock` | ❌ | | [#14](https://github.com/paulmeier/proton-pass.el/issues/14) |
| `session remove-lock` | ❌ | | [#14](https://github.com/paulmeier/proton-pass.el/issues/14) |
| `settings view` | ❌ | | [#18](https://github.com/paulmeier/proton-pass.el/issues/18) |
| `settings set default-vault` | ❌ | | [#18](https://github.com/paulmeier/proton-pass.el/issues/18) |
| `settings set default-format` | ❌ | | [#18](https://github.com/paulmeier/proton-pass.el/issues/18) |
| `settings unset default-vault` | ❌ | | [#18](https://github.com/paulmeier/proton-pass.el/issues/18) |
| `settings unset default-format` | ❌ | | [#18](https://github.com/paulmeier/proton-pass.el/issues/18) |
| `user info` | ⛔ | `proton-pass-info` covers the session | [#23](https://github.com/paulmeier/proton-pass.el/issues/23) |
| `user generate-report` | ⛔ | Organization admin | [#23](https://github.com/paulmeier/proton-pass.el/issues/23) |
| `update` | ⛔ | Belongs to the package manager / CLI | [#23](https://github.com/paulmeier/proton-pass.el/issues/23) |
| `support` | ⛔ | | [#23](https://github.com/paulmeier/proton-pass.el/issues/23) |

## SSH

| pass-cli command | Status | proton-pass.el | Issue |
|---|---|---|---|
| `ssh-agent start` | 🟡 | `proton-pass-use-ssh-agent` uses an already-running agent's socket; doesn't start one | [#15](https://github.com/paulmeier/proton-pass.el/issues/15) |
| `ssh-agent load` | ❌ | | [#15](https://github.com/paulmeier/proton-pass.el/issues/15) |
| `ssh-agent debug` | ❌ | | [#15](https://github.com/paulmeier/proton-pass.el/issues/15) |
| `ssh-agent daemon start` | ❌ | | [#15](https://github.com/paulmeier/proton-pass.el/issues/15) |
| `ssh-agent daemon status` | ❌ | | [#15](https://github.com/paulmeier/proton-pass.el/issues/15) |
| `ssh-agent daemon stop` | ❌ | | [#15](https://github.com/paulmeier/proton-pass.el/issues/15) |

## Secrets for processes

| pass-cli command | Status | proton-pass.el | Issue |
|---|---|---|---|
| `run` | ❌ | | [#17](https://github.com/paulmeier/proton-pass.el/issues/17) |
| `inject` | ❌ | | [#17](https://github.com/paulmeier/proton-pass.el/issues/17) |

## Account tooling (not planned)

AI agents and personal access tokens are account/admin tooling. They're
parked in [#23](https://github.com/paulmeier/proton-pass.el/issues/23);
comment there with a use case.

| pass-cli command | Status |
|---|---|
| `agent create` · `agent list` · `agent delete` · `agent monitor` · `agent renew` · `agent instructions` · `agent access grant` · `agent access revoke` | ⛔ |
| `personal-access-token create` · `list` · `delete` · `renew` · `access grant` · `access revoke` · `access list-access` | ⛔ |

## Item selection

Commands pick items by ID (`--share-id`/`--item-id`, or
`pass://SHARE_ID/ITEM_ID/field`), never by title, because titles aren't
unique ([#1](https://github.com/paulmeier/proton-pass.el/issues/1), fixed).
Completion labels duplicate titles with their modification time.
Title-based `pass://Vault/Title/field` references are only used where
you write them yourself (`proton-pass-get`, `proton-pass-auth-source-alist`),
so those titles must be unique.

## Beyond pass-cli

Features with no single `pass-cli` counterpart: the auth-source backend,
the in-memory secret cache, kill-ring auto-clear, and `SSH_AUTH_SOCK`
setup.
