> Notice: legacy entry points described here are archived; see README for the current workflow.

# Migrating from Org-Supertag to Supertag

Supertag 6.0 is a deliberate breaking rename. It does not provide the old
library, Lisp aliases, Babel language, or an automatic data-directory move.
The knowledge model and stored entity IDs are unchanged.

## 1. Stop Emacs and move the data directory

Quit every Emacs instance that may write the database and make a backup. If
you used the default location, rename:

```text
~/.emacs.d/org-supertag/  ->  ~/.emacs.d/supertag/
```

Do not merge two directories blindly. If both paths exist, inspect them and
choose explicitly. Supertag refuses to initialize when the old default path
still exists, so it cannot silently create an empty replacement database.
A custom `supertag-data-directory` does not need to be moved.

## 2. Update installation and loading

```emacs-lisp
;; Before
(straight-use-package '(org-supertag :host github :repo "yibie/org-supertag"))
(require 'org-supertag)

;; After
(straight-use-package '(supertag :host github :repo "yibie/supertag"))
(require 'supertag)
```

The entry file is now `supertag.el`, and the Customization group is
`supertag`.

## 3. Rename remaining configuration

| Before | After |
|---|---|
| `org-supertag-data-directory` | `supertag-data-directory` |
| `org-supertag-sync-directories` | `supertag-sync-directories` |
| `org-supertag-sync-directories-mode` | `supertag-sync-directories-mode` |
| `org-supertag-active-sync-directory` | `supertag-active-sync-directory` |
| `org-supertag-vault-auto-switch` | `supertag-vault-auto-switch` |
| `org-supertag-vault-modeline-indicator` | `supertag-vault-modeline-indicator` |
| `org-supertag-file-id-source` | `supertag-file-id-source` |

Search your configuration for `org-supertag` after making these changes.
There are no obsolete aliases, so a missed name fails visibly instead of
quietly maintaining two interfaces.

## 4. Rename Babel query blocks

```org
#+begin_src supertag-query-block
(tag "paper")
#+end_src
```

Replace the retired languages `org-supertag-query-block` and
`org-supertag-query` with `supertag-query-block`.

## 5. Verify

Restart Emacs, evaluate `(require 'supertag)`, then run:

1. `M-: (supertag-doctor)` (report in the *Supertag Doctor* buffer)
2. `M-x supertag-menu`
3. one representative query or view against the migrated database

If startup reports the retired data directory, stop and resolve the directory
move first. Supertag intentionally does not move, delete, or combine user data.
