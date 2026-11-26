# git-recommit-sign

[中文](README.zh-CN.md) | English

`git-recommit-sign.sh` rewrites the current branch's selected commits and
renews their OpenPGP signatures. It can replace author/committer identity,
dates, and commit messages, applies the changes to descendants of matched
commits, migrates local tags, creates a backup, and never pushes.

## Requirements

- Linux, Bash 4.4 or newer
- Git 2.43 or newer
- GnuPG 2.4 or newer with an available OpenPGP secret key
- An attached local branch with a clean index and working tree

The tests use temporary repositories, temporary `GNUPGHOME` directories, and
test keys generated in the past so signatures can be verified without touching
the real history.

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SpiralTower/git-recommit-sign/main/git-recommit-sign.sh)
```

The interactive flow asks for the selection, four identity filters, identity
and date replacements, message or message-file edits, per-commit TSV map,
signing key, tag policy, and the explicit key-time-conflict switch. It shows
the plan before a dry run, or asks for final confirmation before changing
references. Use `b` to return to the top-level menu and `q` to cancel.

Preview one commit:

```bash
./git-recommit-sign.sh --commit HEAD --message "fix: rewrite history" --dry-run
```

Rewrite a branch, moving local tags:

```bash
./git-recommit-sign.sh --all --message "fix: align identity" --yes
```

`--yes` is mandatory for a non-interactive write. `--dry-run` only builds
objects in a temporary location and prints a preview; it does not update the
branch, tags, or backup refs.

## Selection

Choose exactly one of:

- `--commit <rev>`: the selected commit; its `--message`/`--message-file`
  replacement applies only to that commit.
- `--range <FROM..TO>`: the inclusive history plane from `FROM` to `TO`.
  `FROM` and every commit reachable from `TO` are selected, except ancestors
  reachable from any parent of `FROM`. Both endpoints must be ancestors of the
  current branch tip.
- `--all`: every commit reachable from the current `HEAD`, including merged
  side branches.

Identity filters are optional:

```text
--author-filter-name <name>
--author-filter-email <email>
--committer-filter-name <name>
--committer-filter-email <email>
```

Multiple filters are ANDed. Names and emails are exact, case-sensitive full
strings. Author filters check only `author`; committer filters check only
`committer`. If no filter is given, the selected range is the set of matched
commits.

Every descendant of a matched commit is rebuilt so its parents point at new
objects. Descendant metadata is preserved; only the parent chain and signature
change. All parents of a merge commit are preserved.

## Replacement fields

```text
--author-name <name>
--author-email <email>
--committer-name <name>
--committer-email <email>
--author-date <date>
--committer-date <date>
--message <text>
--message-file <path>
--edit-messages
```

Unspecified identity fields are preserved per commit. Dates use an absolute
timestamp with a timezone offset, for example:

```text
2024-02-03T04:05:06-05:00
```

All matched commits receive the same date when a date option is supplied.
`--message-file` is copied byte-for-byte, including a missing final newline.
`--edit-messages` invokes `$GIT_EDITOR` for each matched message. Unmatched
descendants are never edited.

### Per-commit TSV map

`--map <tsv>` uses four tab-separated columns:

```text
commit	author_date	committer_date	message_file
<full-oid>	2024-01-01T00:00:00Z	2024-01-02T00:00:00Z	/path/msg
<full-oid>	2024-03-01T00:00:00Z		/path/msg
```

Empty fields fall back to the corresponding command-wide option or the
original value. Map message files override the global message. Use a tab
character between fields; spaces are not delimiters.

## Signing and tags

`--signing-key` selects the OpenPGP secret key; otherwise
`user.signingKey` is used. Only OpenPGP is supported, so `gpg.format` must be
`openpgp` or unset.

Each new commit is rebuilt from `git cat-file commit`, not `git show`. The
unsigned payload is signed with the target committer epoch. The signature is
embedded in Git's `gpgsig` format and the resulting object must pass
`git verify-commit` with a `VALIDSIG` status whose signature epoch equals the
committer epoch. A signed annotated tag is detached from its old signature,
re-signed using its original tagger identity and epoch, and verified with
`git verify-tag`.

`--tag-policy` controls tags pointing at rebuilt commits:

- `move` (default): move lightweight tags and rewrite annotated tags.
- `keep`: leave old tags untouched.
- `abort`: fail before updating any references.

Signing records one time. The commit signature follows the committer timestamp;
the author timestamp may differ. When the target epoch predates the key
creation time, GnuPG needs the explicit dangerous
`--allow-key-time-conflict` switch. In that mode the script verifies the
detached signature and epoch with GnuPG, but Git's own verification may still
reject it; a warning is printed.

## Backup, restore, and safety

Before a real update the script creates:

```text
refs/backups/git-recommit-sign/<UTC timestamp>-<pid>/
```

It stores the branch tip, affected tags, and a manifest containing the old/new
object mapping. The branch and all tag updates are applied through one
`git update-ref --stdin` transaction. A failed prepared transaction or hook
leaves the branch and tags unchanged.

Restore a backup with:

```bash
./git-recommit-sign.sh --restore <backup-id>
```

The command validates the manifest and the current branch before restoring.
Backups are retained after success. The script also acquires a repository lock,
checks for an in-progress merge/rebase/cherry-pick/revert/bisect, and refuses
dirty worktrees. It does not create commits in the source repository by
invoking `git commit`, and it never pushes. Follow the printed
`git push --force-with-lease` guidance manually.

## Testing

```bash
bash test/git-recommit-sign-test.sh
```

The integration suite creates isolated repositories and temporary OpenPGP
keys. It covers selection and merge propagation, filters, dates, TSV maps,
message bytes and editor flow, signed tags, all tag policies, backups and
restores, safety failures, time conflicts, transaction failures, duplicate
backup IDs, locks, and the no-push guarantee.
