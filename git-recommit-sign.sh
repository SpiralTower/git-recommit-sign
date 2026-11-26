#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM_NAME=${0##*/}
AUTHOR_NAME_SET=0
AUTHOR_EMAIL_SET=0
COMMITTER_NAME_SET=0
COMMITTER_EMAIL_SET=0
AUTHOR_DATE=
COMMITTER_DATE=
MESSAGE=
MESSAGE_SET=0
MESSAGE_FILE=
SIGNING_KEY=
DRY_RUN=0
ASSUME_YES=0
EDIT_MESSAGES=0
ALLOW_KEY_TIME_CONFLICT=0
AUTHOR_NAME=
AUTHOR_EMAIL=
COMMITTER_NAME=
COMMITTER_EMAIL=
MAP_FILE=
TAG_POLICY=move
AUTHOR_FILTER_NAME=
AUTHOR_FILTER_EMAIL=
COMMITTER_FILTER_NAME=
COMMITTER_FILTER_EMAIL=
SELECTION_KIND=
SELECTION_VALUE=
RESTORE_ID=
TMP_BASE=
LOCK_DIR=
WORK_DIR=

usage() {
  cat <<'EOF'
Usage: git-recommit-sign.sh [OPTIONS]

Rewrite commits on the current branch and renew their OpenPGP signatures.

Selection:
  --commit <rev>                 Select one commit
  --range <FROM..TO>             Select an inclusive commit range
  --all                          Select every commit reachable from HEAD
  --author-filter-name <name>    Match the complete author name (case-sensitive)
  --author-filter-email <email>  Match the complete author email (case-sensitive)
  --committer-filter-name <name> Match the complete committer name (case-sensitive)
  --committer-filter-email <email>
                                 Match the complete committer email (case-sensitive)

Replacement:
  --author-name <name>           Replace every selected author name
  --author-email <email>         Replace every selected author email
  --committer-name <name>        Replace every selected committer name
  --committer-email <email>      Replace every selected committer email
  --author-date <date>           Replace every selected author date
  --committer-date <date>        Replace every selected committer date
  --message <text>               Replace every selected commit message
  --message-file <path>          Read replacement messages from a file
  --edit-messages                Edit every matched message with $GIT_EDITOR
  --map <tsv>                    Apply per-commit date and message overrides

Signing and references:
  --signing-key <key>            OpenPGP key (default: user.signingKey)
  --tag-policy <move|keep|abort> How to handle tags (default: move)
  --allow-key-time-conflict      Explicitly allow GPG key time conflicts

Execution:
  --dry-run                      Preview without changing references
  --yes                          Confirm a non-interactive rewrite
  --restore <backup-id>          Restore a backup created by this script
  -h, --help                     Show this help

With no arguments, an interactive menu is shown. No command pushes.
EOF
}

cancel_and_exit() {
  printf 'Cancelled; no references changed.\n'
  exit 0
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

usage_error() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  printf 'Run %s --help for usage.\n' "$PROGRAM_NAME" >&2
  exit 2
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || usage_error "$1 requires a value"
}

parse_args() {
  HELP_REQUESTED=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        HELP_REQUESTED=1
        shift
        ;;
      --commit)
        require_value "$@"
        [[ -z "$SELECTION_KIND" ]] ||
          usage_error "selection options are mutually exclusive"
        SELECTION_KIND=commit
        SELECTION_VALUE=$2
      SELECTED_FROM=
      SELECTED_TO=
        shift 2
        ;;
      --range)
        require_value "$@"
        [[ -z "$SELECTION_KIND" ]] ||
          usage_error "selection options are mutually exclusive"
        SELECTION_KIND=range
        SELECTION_VALUE=$2
      SELECTED_FROM=
      SELECTED_TO=
        shift 2
        ;;
      --all)
        [[ -z "$SELECTION_KIND" ]] ||
          usage_error "selection options are mutually exclusive"
        SELECTION_KIND=all
        SELECTION_VALUE=
      SELECTED_FROM=
      SELECTED_TO=
        shift
        ;;
      --author-filter-name)
        require_value "$@"
        AUTHOR_FILTER_NAME=$2
        shift 2
        ;;
      --author-filter-email)
        require_value "$@"
        AUTHOR_FILTER_EMAIL=$2
        shift 2
        ;;
      --committer-filter-name)
        require_value "$@"
        COMMITTER_FILTER_NAME=$2
        shift 2
        ;;
      --committer-filter-email)
        require_value "$@"
        COMMITTER_FILTER_EMAIL=$2
        shift 2
        ;;
      --author-name)
        require_value "$@"
        AUTHOR_NAME=$2
        AUTHOR_NAME_SET=1
        shift 2
        ;;
      --author-email)
        require_value "$@"
        AUTHOR_EMAIL=$2
        AUTHOR_EMAIL_SET=1
        shift 2
        ;;
      --committer-name)
        require_value "$@"
        COMMITTER_NAME=$2
        COMMITTER_NAME_SET=1
        shift 2
        ;;
      --committer-email)
        require_value "$@"
        COMMITTER_EMAIL=$2
        COMMITTER_EMAIL_SET=1
        shift 2
        ;;
      --author-date)
        require_value "$@"
        AUTHOR_DATE=$2
        shift 2
        ;;
      --committer-date)
        require_value "$@"
        COMMITTER_DATE=$2
        shift 2
        ;;
      --message)
        require_value "$@"
        MESSAGE=$2
        MESSAGE_SET=1
        shift 2
        ;;
      --message-file)
        require_value "$@"
        MESSAGE_FILE=$2
        shift 2
        ;;
      --edit-messages)
        EDIT_MESSAGES=1
        shift
        ;;
      --map)
        require_value "$@"
        MAP_FILE=$2
        shift 2
        ;;
      --signing-key)
        require_value "$@"
        SIGNING_KEY=$2
        shift 2
        ;;
      --tag-policy)
        require_value "$@"
        TAG_POLICY=$2
        shift 2
        ;;
      --allow-key-time-conflict)
        ALLOW_KEY_TIME_CONFLICT=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --restore)
        require_value "$@"
        RESTORE_ID=$2
        shift 2
        ;;
      --)
        shift
        [[ $# -eq 0 ]] || usage_error "unexpected argument: $1"
        ;;
      -*)
        usage_error "unsupported option: $1"
        ;;
      *)
        usage_error "unexpected argument: $1"
        ;;
    esac
  done

}

normalize_date() {
  local value=$1
  local regex='^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{2}:?[0-9]{2})$'

  [[ "$value" =~ $regex ]] ||
    die "invalid date '$value'; use YYYY-MM-DDTHH:MM:SS±HH:MM"

  local year=${BASH_REMATCH[1]}
  local month=${BASH_REMATCH[2]}
  local day=${BASH_REMATCH[3]}
  local hour=${BASH_REMATCH[4]}
  local minute=${BASH_REMATCH[5]}
  local second=${BASH_REMATCH[6]}
  local zone=${BASH_REMATCH[7]}
  local offset=${zone/Z/+00:00}
  if [[ "$offset" != [+-]* ]]; then
    offset="+$offset"
  fi
  if [[ "$offset" =~ ^([+-][0-9]{2})([0-9]{2})$ ]]; then
    offset="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
  fi
  if [[ ! "$offset" =~ ^[+-][0-9]{2}:[0-9]{2}$ ]]; then
    die "invalid timezone offset in '$value'"
  fi

  local offset_hour=${offset:1:2}
  local offset_minute=${offset:4:2}
  ((10#$offset_hour <= 23)) || die "invalid timezone offset in '$value'"
  ((10#$offset_minute <= 59)) || die "invalid timezone offset in '$value'"

  local epoch
  epoch=$(TZ=UTC date -d \
    "$year-$month-$day $hour:$minute:$second $offset" +%s 2>/dev/null) ||
    die "invalid date '$value'"
  [[ "$epoch" =~ ^[0-9]+$ ]] || die "invalid date '$value'"

  printf '%s %s\n' "$epoch" "${offset/:/}"
}

extract_identity() {
  local line=$1
  [[ "$line" =~ ^(.*)\ [0-9]+\ [+-][0-9]{4}$ ]] ||
    die "cannot parse identity line: $line"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

extract_epoch() {
  local line=$1
  [[ "$line" =~ \ ([0-9]+)\ [+-][0-9]{4}$ ]] ||
    die "cannot parse timestamp: $line"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

extract_zone() {
  local line=$1
  [[ "$line" =~ \ ([+-][0-9]{4})$ ]] ||
    die "cannot parse timezone: $line"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

rewrite_identity() {
  local role=$1
  local ident=$2
  local name email

  if [[ "$ident" =~ ^(.*)\ \<([^\<\>]*)\>$ ]]; then
    name=${BASH_REMATCH[1]}
    email=${BASH_REMATCH[2]}
  else
    die "cannot parse $role identity: $ident"
  fi

  if [[ "$role" == author ]]; then
    [[ "$AUTHOR_NAME_SET" -eq 1 ]] && name=$AUTHOR_NAME
    [[ "$AUTHOR_EMAIL_SET" -eq 1 ]] && email=$AUTHOR_EMAIL
  else
    [[ "$COMMITTER_NAME_SET" -eq 1 ]] && name=$COMMITTER_NAME
    [[ "$COMMITTER_EMAIL_SET" -eq 1 ]] && email=$COMMITTER_EMAIL
  fi

  [[ "$name" != *$'\n'* && "$email" != *$'\n'* ]] ||
    die "$role identity cannot contain a newline"
  [[ "$name" != *'<'* && "$name" != *'>'* ]] ||
    die "$role name cannot contain angle brackets"
  [[ "$email" != *'<'* && "$email" != *'>'* ]] ||
    die "$role email cannot contain angle brackets"

  printf '%s <%s>\n' "$name" "$email"
}

validate_message_file() {
  local path=$1

  [[ -f "$path" ]] || die "message file does not exist: $path"
  [[ -r "$path" ]] || die "message file is not readable: $path"
}

read_message_file() {
  local path=$1
  local output=$2
  validate_message_file "$path"
  cp -- "$path" "$output"
}

load_selected_message() {
  local output=$1

  if [[ "$MESSAGE_SET" -eq 1 ]]; then
    printf '%s' "$MESSAGE" >"$output"
  elif [[ -n "$MESSAGE_FILE" ]]; then
    read_message_file "$MESSAGE_FILE" "$output"
  else
    return 1
  fi
}

edit_selected_message() {
  local oid=$1
  local original=$2
  local output=$3
  local editor

  editor=$(git var GIT_EDITOR 2>/dev/null) ||
    die "no editor configured (set GIT_EDITOR or core.editor)"
  [[ -n "$editor" ]] || die "no editor configured"
  cp -- "$original" "$output"
  (
    eval "$editor \"\$output\""
  ) || die "editor failed while editing $oid"
}

sign_bytes() {
  local input=$1
  local output=$2
  local epoch=$3
  local gpg_args=(
    --batch --yes --armor --detach-sign --digest-algo SHA256
    --faked-system-time "$epoch" --local-user "$SIGNING_KEY!"
  )
  if [[ "$ALLOW_KEY_TIME_CONFLICT" -eq 1 ]]; then
    gpg_args+=(--ignore-time-conflict)
  fi
  gpg_args+=(--output "$output" "$input")

  gpg "${gpg_args[@]}" >/dev/null 2>"$WORK_DIR/gpg.err" ||
    die "GnuPG could not create a signature: $(<"$WORK_DIR/gpg.err")"
}

gpg_status_verify() {
  local signature=$1
  local payload=$2
  local gpg_args=(--batch --status-fd 1 --verify)

  if [[ "$ALLOW_KEY_TIME_CONFLICT" -eq 1 ]]; then
    gpg_args+=(--ignore-time-conflict)
  fi
  gpg_args+=("$signature" "$payload")
  gpg "${gpg_args[@]}" 2>/dev/null
}

verify_gpg_signature() {
  local signature=$1
  local payload=$2
  local expected_epoch=$3
  local status

  if ! status=$(gpg_status_verify "$signature" "$payload"); then
    die "GnuPG rejected the generated signature"
  fi

  local validsig
  validsig=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print; exit }')
  [[ -n "$validsig" ]] || die "GnuPG did not report a valid signature"
  assert_eq "${validsig##* }" "$SIGNING_KEY" "primary signing key"
  local signed_epoch
  signed_epoch=$(
    printf '%s\n' "$validsig" | awk '{ print $5 }'
  )
  assert_eq "$signed_epoch" "$expected_epoch" "signature epoch"
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3
  [[ "$actual" == "$expected" ]] ||
    die "$label: expected [$expected], got [$actual]"
}

resolve_commit_range() {
  local from_to=$1
  [[ "$from_to" == *..* && "$from_to" != *...* ]] ||
    usage_error "--range requires FROM..TO"
  local from=${from_to%%..*}
  local to=${from_to#*..}
  [[ -n "$from" && -n "$to" ]] ||
    usage_error "--range requires both FROM and TO"

  local from_oid to_oid
  from_oid=$(git rev-parse --verify "$from^{commit}" 2>/dev/null) ||
    die "cannot resolve range start: $from"
  to_oid=$(git rev-parse --verify "$to^{commit}" 2>/dev/null) ||
    die "cannot resolve range end: $to"

  git merge-base --is-ancestor "$from_oid" "$to_oid" ||
    die "range start is not an ancestor of range end"

  printf '%s\n' "$from_oid" "$to_oid"
}

collect_commits() {
  local rev_list=(
    git rev-list --topo-order --reverse --parents
  )

  case "$SELECTION_KIND" in
    commit)
      local oid
      oid=$(git rev-parse --verify "$SELECTION_VALUE^{commit}" 2>/dev/null) ||
        die "cannot resolve commit: $SELECTION_VALUE"
      SELECTED_OID=$oid
      SELECTED_TO=$CURRENT_HEAD
      ;;
    range)
      local range
      range=$(resolve_commit_range "$SELECTION_VALUE")
      SELECTED_FROM=${range%%$'\n'*}
      SELECTED_TO=${range#*$'\n'}
      git merge-base --is-ancestor "$SELECTED_TO" "$CURRENT_HEAD" ||
        die "range end is not reachable from the current branch tip"
      ;;
    all)
      SELECTED_FROM=
      SELECTED_TO=$(git rev-parse --verify 'HEAD^{commit}') ||
        die "HEAD does not point to a commit"
      ;;
    *)
      die "commit selection is required; use --commit, --range, or --all"
      ;;
  esac

  "${rev_list[@]}" HEAD
}

identity_name() {
  local ident=$1
  [[ "$ident" =~ ^(.*)\ \<[^\<\>]*\>$ ]] ||
    die "cannot parse identity: $ident"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

identity_email() {
  local ident=$1
  [[ "$ident" =~ ^[^\<\>]*\ \<([^\<\>]*)\>$ ]] ||
    die "cannot parse identity: $ident"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

parse_map() {
  local path=$1
  [[ -f "$path" && -r "$path" ]] || die "map file is not readable: $path"

  declare -gA MAP_AUTHOR_DATE=()
  declare -gA MAP_COMMITTER_DATE=()
  declare -gA MAP_MESSAGE_FILE=()
  declare -gA MAP_SEEN=()
  local number=0 commit author_date committer_date message_file extra
  local invalid_line
  invalid_line=$(awk -F '\t' 'NF != 4 { print NR; exit }' "$path")
  [[ -z "$invalid_line" ]] ||
    die "map line $invalid_line: expected four tab-separated columns"

  while IFS=$'\034' read -r number commit author_date committer_date \
    message_file extra; do
    if [[ "$number" -eq 1 && "$commit" == commit ]]; then
      [[ "$author_date" == author_date &&
        "$committer_date" == committer_date &&
        "$message_file" == message_file ]] ||
        die "map header must be: commit, author_date, committer_date, message_file"
      continue
    fi
    [[ -n "$commit" ]] || die "map line $number: commit is required"
    valid_full_oid "${commit,,}" ||
      die "map line $number: commit must be a full object ID"
    commit=${commit,,}
    [[ -z "${MAP_SEEN[$commit]:-}" ]] ||
      die "map line $number: duplicate commit '$commit'"
    MAP_SEEN[$commit]=1
    if [[ -n "$author_date" ]]; then
      MAP_AUTHOR_DATE[$commit]=$author_date
    fi
    if [[ -n "$committer_date" ]]; then
      MAP_COMMITTER_DATE[$commit]=$committer_date
    fi
    if [[ -n "$message_file" ]]; then
      validate_message_file "$message_file"
      MAP_MESSAGE_FILE[$commit]=$message_file
    fi
  done < <(
    awk -F '\t' 'BEGIN { OFS="\034" } { print NR, $1, $2, $3, $4, "end" }' \
      "$path"
  )
}

replace_header_value() {
  local key=$1
  local value=$2
  local input=$3
  local output=$4
  local replaced=0 line header_bytes input_bytes

  header_bytes=$(commit_header_bytes "$input") ||
    die "cannot locate object header separator"
  input_bytes=$(wc -c <"$input")
  [[ "$header_bytes" -lt "$input_bytes" ]] ||
    die "object has no header/message separator"

  : >"$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$replaced" -eq 0 && "$line" == "$key "* ]]; then
      printf '%s %s\n' "$key" "$value" >>"$output"
      replaced=1
    else
      printf '%s\n' "$line" >>"$output"
    fi
  done < <(head -c "$header_bytes" "$input")
  [[ "$replaced" -eq 1 ]] || die "missing $key header"
  printf '\n' >>"$output"
  tail -c "+$((header_bytes + 2))" "$input" >>"$output"
}

split_commit_object() {
  local raw=$1
  local headers=$2
  local message=$3
  local header_bytes raw_bytes skipping_sig=0 line
  local filtered="$headers.filtered"

  header_bytes=$(commit_header_bytes "$raw") ||
    die "cannot locate commit header separator"
  raw_bytes=$(wc -c <"$raw")
  [[ "$header_bytes" -lt "$raw_bytes" ]] ||
    die "commit object has no header/message separator"

  head -c "$header_bytes" "$raw" >"$headers"
  tail -c "+$((header_bytes + 2))" "$raw" >"$message"

  : >"$filtered"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$skipping_sig" -eq 1 ]]; then
      if [[ "$line" == ' '* ]]; then
        continue
      fi
      die "malformed gpgsig continuation"
    fi
    if [[ "$line" == gpgsig\ * ]]; then
      skipping_sig=1
      continue
    fi
    printf '%s\n' "$line" >>"$filtered"
  done <"$headers"
  mv -- "$filtered" "$headers"
}

commit_header_bytes() {
  local raw=$1
  local line_bytes=0 total_bytes=0 line matched=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_bytes=$(LC_ALL=C printf '%s' "$line" | wc -c)
    if [[ "$line_bytes" -eq 0 ]]; then
      matched=1
      break
    fi
    total_bytes=$((total_bytes + line_bytes + 1))
  done <"$raw"
  [[ "$matched" -eq 1 ]] || return 1
  printf '%s\n' "$total_bytes"
}

rebuild_commit_object() {
  local headers=$1
  local message=$2
  local unsigned=$3
  local parent_map=$4
  local author_name=$5
  local author_email=$6
  local author_epoch=$7
  local author_zone=$8
  local committer_name=$9
  local committer_email=${10}
  local committer_epoch=${11}
  local committer_zone=${12}
  local line

  : >"$unsigned"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      parent\ *)
        local old_parent=${line#parent }
        local new_parent
        new_parent=$(
          awk -v key="$old_parent" '$1 == key { print $2; exit }' "$parent_map"
        )
        printf 'parent %s\n' "${new_parent:-$old_parent}" >>"$unsigned"
        ;;
      author\ *)
        printf 'author %s <%s> %s %s\n' \
          "$author_name" "$author_email" "$author_epoch" "$author_zone" \
          >>"$unsigned"
        ;;
      committer\ *)
        printf 'committer %s <%s> %s %s\n' \
          "$committer_name" "$committer_email" "$committer_epoch" \
          "$committer_zone" >>"$unsigned"
        ;;
      tree\ *|encoding\ *|mergetag\ *)
        printf '%s\n' "$line" >>"$unsigned"
        ;;
      gpgsig\ *)
        die "signature was not removed from commit headers"
        ;;
      *)
        printf '%s\n' "$line" >>"$unsigned"
        ;;
    esac
  done <"$headers"
  printf '\n' >>"$unsigned"
  cat -- "$message" >>"$unsigned"
}

write_signed_commit() {
  local unsigned=$1
  local output=$2
  local epoch=$3

  local signature="$WORK_DIR/commit-$epoch.signature"
  sign_bytes "$unsigned" "$signature" "$epoch"

  local header_bytes
  header_bytes=$(
    LC_ALL=C sed -n '/^$/q; p' "$unsigned" | wc -c
  )
  [[ "$header_bytes" -gt 0 ]] ||
    die "commit object has no header/message separator"

  head -c "$header_bytes" "$unsigned" >"$output"
  local first=1 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$first" -eq 1 ]]; then
      printf 'gpgsig %s\n' "$line" >>"$output"
      first=0
    else
      printf ' %s\n' "$line" >>"$output"
    fi
  done <"$signature"
  printf '\n' >>"$output"
  tail -c "+$((header_bytes + 2))" "$unsigned" >>"$output"

  local status
  if ! status=$(gpg_status_verify "$signature" "$unsigned"); then
    die "GnuPG rejected the generated commit signature"
  fi
  [[ "$status" == *'[GNUPG:] VALIDSIG '*'[GNUPG:]'* ]] ||
    die "GnuPG did not report VALIDSIG"
  local signed_epoch
  signed_epoch=$(printf '%s\n' "$status" |
    awk '$2 == "VALIDSIG" { print $5; exit }')
  [[ "$signed_epoch" == "$epoch" ]] ||
    die "signature epoch mismatch: expected $epoch, got $signed_epoch"
}

verify_created_commit() {
  local oid=$1
  local expected_epoch=$2
  local unsigned_payload=${3:-}
  local output rc=0

  output=$(
    git verify-commit --raw "$oid" 2>&1
  ) || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    [[ "$output" == *'[GNUPG:] VALIDSIG '* ]] ||
      die "git did not report VALIDSIG for $oid"
    local git_epoch
    git_epoch=$(printf '%s\n' "$output" |
      awk '$2 == "VALIDSIG" { print $5; exit }')
    assert_eq "$expected_epoch" "$git_epoch" "git signature epoch"
    return
  fi

  [[ "$ALLOW_KEY_TIME_CONFLICT" -eq 1 ]] ||
    die "git verify-commit failed for $oid: $output"
  [[ -n "$unsigned_payload" && -f "$unsigned_payload" ]] ||
    die "cannot verify time-conflict signature without payload"

  local signature="$WORK_DIR/allowed-conflict.signature"
  git cat-file commit "$oid" |
    sed -n '/^gpgsig /,/^[^ ]/p' |
    sed '$d' |
    sed '1s/^gpgsig //; 2,$s/^ //' >"$signature"
  [[ -s "$signature" ]] || die "cannot extract signature from $oid"
  verify_gpg_signature "$signature" "$unsigned_payload" "$expected_epoch"
  printf 'WARNING: git verify-commit rejects this time-conflict signature; GnuPG VALIDSIG was used.\n' >&2
}

expected_new_head_for_selection() {
  local mapping=$1
  awk -v top="$CURRENT_HEAD" '$1 == top { print $2; exit }' "$mapping"
}

preflight_repository() {
  git rev-parse --git-dir >/dev/null 2>&1 ||
    die "not inside a Git repository"
  [[ "$(git rev-parse --is-bare-repository 2>/dev/null)" == false ]] ||
    die "bare repositories are not supported"

  CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) ||
    die "detached HEAD is not supported; check out a local branch"
  CURRENT_REF="refs/heads/$CURRENT_BRANCH"
  CURRENT_HEAD=$(git rev-parse --verify 'HEAD^{commit}') ||
    die "current branch has no commit"

  FULL_WORKTREE_STATUS=$(
    git status --porcelain=v1 --untracked-files=all
  )
  [[ -z "$FULL_WORKTREE_STATUS" ]] ||
    die "working tree and index must be clean (untracked files count as dirty)"

  local git_dir
  git_dir=$(git rev-parse --git-path rebase-merge)
  [[ ! -d "$git_dir" ]] || die "a rebase is in progress"
  git_dir=$(git rev-parse --git-path rebase-apply)
  [[ ! -d "$git_dir" ]] || die "a rebase is in progress"
  git_dir=$(git rev-parse --git-path MERGE_HEAD)
  [[ ! -e "$git_dir" ]] || die "a merge is in progress"
  git_dir=$(git rev-parse --git-path CHERRY_PICK_HEAD)
  [[ ! -e "$git_dir" ]] || die "a cherry-pick is in progress"
  git_dir=$(git rev-parse --git-path REVERT_HEAD)
  [[ ! -e "$git_dir" ]] || die "a revert is in progress"
  git_dir=$(git rev-parse --git-path BISECT_LOG)
  [[ ! -e "$git_dir" ]] || die "a bisect is in progress"

  local index_lock
  index_lock=$(git rev-parse --git-path index.lock)
  [[ ! -e "$index_lock" ]] ||
    die "index.lock exists; another Git operation may be running"
}

preflight_signing() {
  local format
  format=$(git config --get gpg.format 2>/dev/null || true)
  [[ "${format:-openpgp}" == openpgp ]] ||
    die "only OpenPGP signing is supported (gpg.format=$format)"

  if [[ -z "$SIGNING_KEY" ]]; then
    SIGNING_KEY=$(git config --get user.signingKey 2>/dev/null || true)
  fi
  [[ -n "$SIGNING_KEY" ]] ||
    die "no signing key configured; use --signing-key or user.signingKey"

  command -v gpg >/dev/null 2>&1 || die "gpg is not installed"
  command -v git >/dev/null 2>&1 || die "git is not installed"

  local requested=$SIGNING_KEY
  local key_status fingerprints key_count resolved_key
  key_status=$(
    gpg --batch --with-colons --list-secret-keys -- "$requested" 2>/dev/null
  ) || die "secret signing key not found: $requested"
  fingerprints=$(
    printf '%s\n' "$key_status" |
      awk -F: '$1 == "fpr" { print $10 }'
  )
  key_count=$(printf '%s\n' "$fingerprints" | awk 'NF { count++ } END { print count + 0 }')
  [[ "$key_count" -gt 0 ]] ||
    die "secret signing key not found: $requested"
  [[ "$key_count" -eq 1 ]] ||
    die "signing key selector is ambiguous: $requested"
  resolved_key=$(printf '%s\n' "$fingerprints" | awk 'NF { print; exit }')
  SIGNING_KEY=$resolved_key
}

acquire_lock() {
  local common_dir
  common_dir=$(git rev-parse --git-common-dir)
  LOCK_DIR="$common_dir/git-recommit-sign.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local owner=
    [[ -r "$LOCK_DIR/pid" ]] && owner=$(<"$LOCK_DIR/pid") || true
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      die "another rewrite is running (pid $owner)"
    fi
    die "lock exists: $LOCK_DIR (remove it only after confirming no rewrite is running)"
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap release_lock EXIT
}

release_lock() {
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rm -rf -- "$LOCK_DIR"
  fi
  if [[ -n "$TMP_BASE" && -d "$TMP_BASE" ]]; then
    rm -rf -- "$TMP_BASE"
  fi
}

read_commit_headers_and_message() {
  local oid=$1
  local raw=$2
  local headers=$3
  local message=$4
  local tree parent author committer

  git cat-file commit "$oid" >"$raw" ||
    die "cannot read commit: $oid"
  split_commit_object "$raw" "$headers" "$message"

  COMMIT_TREE=$(awk '$1 == "tree" { print $2; exit }' "$headers")
  COMMIT_PARENT=()
  while IFS= read -r parent; do
    [[ -n "$parent" ]] && COMMIT_PARENT+=("$parent")
  done < <(awk '$1 == "parent" { print $2 }' "$headers")
  author=$(awk '$1 == "author" { sub(/^author /, ""); print; exit }' "$headers")
  committer=$(awk '$1 == "committer" { sub(/^committer /, ""); print; exit }' "$headers")
  COMMIT_AUTHOR=$author
  COMMIT_COMMITTER=$committer
  [[ -n "$COMMIT_TREE" && -n "$author" && -n "$committer" ]] ||
    die "malformed commit object: $oid"
}

selected_by_filters() {
  local author=$1
  local committer=$2

  if [[ -z "$AUTHOR_FILTER_NAME" && -z "$AUTHOR_FILTER_EMAIL" &&
    -z "$COMMITTER_FILTER_NAME" && -z "$COMMITTER_FILTER_EMAIL" ]]; then
    return 0
  fi

  if [[ -n "$AUTHOR_FILTER_NAME" || -n "$AUTHOR_FILTER_EMAIL" ]]; then
    if [[ -n "$AUTHOR_FILTER_NAME" &&
      "$(identity_name "$(extract_identity "$author")")" != "$AUTHOR_FILTER_NAME" ]]; then
      return 1
    fi
    if [[ -n "$AUTHOR_FILTER_EMAIL" &&
      "$(identity_email "$(extract_identity "$author")")" != "$AUTHOR_FILTER_EMAIL" ]]; then
      return 1
    fi
  fi
  if [[ -n "$COMMITTER_FILTER_NAME" || -n "$COMMITTER_FILTER_EMAIL" ]]; then
    if [[ -n "$COMMITTER_FILTER_NAME" &&
      "$(identity_name "$(extract_identity "$committer")")" != "$COMMITTER_FILTER_NAME" ]]; then
      return 1
    fi
    if [[ -n "$COMMITTER_FILTER_EMAIL" &&
      "$(identity_email "$(extract_identity "$committer")")" != "$COMMITTER_FILTER_EMAIL" ]]; then
      return 1
    fi
  fi
  return 0
}

valid_full_oid() {
  [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

selected_message_for() {
  local oid=$1
  local output=$2

  if [[ -n "${MAP_MESSAGE_FILE[$oid]:-}" ]]; then
    read_message_file "${MAP_MESSAGE_FILE[$oid]}" "$output"
  elif load_selected_message "$output"; then
    :
  else
    return 1
  fi
}

date_for_commit() {
  local oid=$1
  local role=$2
  local fallback_line=$3
  local value=

  if [[ "$role" == author ]]; then
    value=${MAP_AUTHOR_DATE[$oid]:-${AUTHOR_DATE:-}}
  else
    value=${MAP_COMMITTER_DATE[$oid]:-${COMMITTER_DATE:-}}
  fi
  if [[ -n "$value" ]]; then
    normalize_date "$value"
  else
    printf '%s %s\n' "$(extract_epoch "$fallback_line")" \
      "$(extract_zone "$fallback_line")"
  fi
}

load_map_if_present() {
  declare -gA MAP_AUTHOR_DATE=()
  declare -gA MAP_COMMITTER_DATE=()
  declare -gA MAP_MESSAGE_FILE=()
  declare -gA MAP_SEEN=()
  if [[ -n "$MAP_FILE" ]]; then
    parse_map "$MAP_FILE"
  fi
}

build_rewrite_plan() {
  local graph="$WORK_DIR/graph"
  local candidates="$WORK_DIR/candidates"
  local rewritten="$WORK_DIR/rewritten"
  local plan="$WORK_DIR/plan"
  local oid

  collect_commits >"$graph" ||
    die "could not enumerate current branch commits"
  if [[ "$SELECTION_KIND" == range ]]; then
    if [[ "$SELECTED_FROM" == "$SELECTED_TO" ]]; then
      printf '%s\n' "$SELECTED_FROM" >"$candidates"
    else
      local -a excluded_parents=()
      local parent
      while IFS= read -r parent; do
        [[ -n "$parent" ]] && excluded_parents+=("$parent")
      done < <(
        git rev-list --parents -n 1 "$SELECTED_FROM" |
          cut -d' ' -f2- |
          tr ' ' '\n'
      )
      if [[ ${#excluded_parents[@]} -eq 0 ]]; then
        git rev-list --topo-order "$SELECTED_TO" >"$candidates"
      else
        git rev-list --topo-order "$SELECTED_TO" \
          --not "${excluded_parents[@]}" >"$candidates"
      fi
      printf '%s\n' "$SELECTED_FROM" >>"$candidates"
    fi
  else
    cut -d' ' -f1 "$graph" >"$candidates"
  fi
  : >"$rewritten"
  : >"$plan"

  while read -r oid _; do
    [[ -n "$oid" ]] || continue
    local in_scope=0
    if [[ "$SELECTION_KIND" == commit ]]; then
      [[ "$oid" == "$SELECTED_OID" ]] && in_scope=1
    elif grep -qx "$oid" "$candidates"; then
      in_scope=1
    fi

    local raw="$WORK_DIR/object-$oid.raw"
    local headers="$WORK_DIR/object-$oid.headers"
    local message="$WORK_DIR/object-$oid.message"
    read_commit_headers_and_message "$oid" "$raw" "$headers" "$message"

    local is_matched=0
    if [[ "$in_scope" -eq 1 ]] &&
      selected_by_filters "$COMMIT_AUTHOR" "$COMMIT_COMMITTER"; then
      is_matched=1
    fi
    local is_selected=$is_matched

    local has_selected_ancestor=0
    local parent
    for parent in "${COMMIT_PARENT[@]}"; do
      if grep -qx "$parent" "$rewritten" 2>/dev/null; then
        has_selected_ancestor=1
        break
      fi
    done

    if [[ "$has_selected_ancestor" -eq 1 ]]; then
      is_selected=1
    fi
    [[ "$is_selected" -eq 1 ]] || continue

    printf '%s\n' "$oid" >>"$rewritten"
    printf '%s %s\n' "$oid" "$is_matched" >>"$plan"
  done <"$graph"

  [[ -s "$plan" ]] || die "no commits matched the selection"
}

rewrite_plan() {
  local plan="$WORK_DIR/plan"
  local mapping="$WORK_DIR/mapping"
  : >"$mapping"

  local oid matched
  while read -r oid matched; do
    [[ -n "$oid" ]] || continue
    local raw="$WORK_DIR/object-$oid.raw"
    local headers="$WORK_DIR/object-$oid.headers"
    local object_message="$WORK_DIR/object-$oid.message"
    read_commit_headers_and_message "$oid" "$raw" "$headers" "$object_message"

    local author_ident committer_ident author_name author_email
    local committer_name committer_email
    if [[ "$matched" -eq 1 ]]; then
      author_ident=$(rewrite_identity author \
        "$(extract_identity "$COMMIT_AUTHOR")")
      committer_ident=$(rewrite_identity committer \
        "$(extract_identity "$COMMIT_COMMITTER")")
    else
      author_ident=$(extract_identity "$COMMIT_AUTHOR")
      committer_ident=$(extract_identity "$COMMIT_COMMITTER")
    fi
    if [[ "$author_ident" =~ ^(.*)\ \<([^\<\>]*)\>$ ]]; then
      author_name=${BASH_REMATCH[1]}
      author_email=${BASH_REMATCH[2]}
    fi
    if [[ "$committer_ident" =~ ^(.*)\ \<([^\<\>]*)\>$ ]]; then
      committer_name=${BASH_REMATCH[1]}
      committer_email=${BASH_REMATCH[2]}
    fi

    local author_date committer_date author_epoch author_zone
    local committer_epoch committer_zone
    if [[ "$matched" -eq 1 ]]; then
      author_date=$(date_for_commit "$oid" author "$COMMIT_AUTHOR")
      committer_date=$(date_for_commit "$oid" committer "$COMMIT_COMMITTER")
    else
      author_date=$(printf '%s %s\n' "$(extract_epoch "$COMMIT_AUTHOR")" \
        "$(extract_zone "$COMMIT_AUTHOR")")
      committer_date=$(printf '%s %s\n' \
        "$(extract_epoch "$COMMIT_COMMITTER")" \
        "$(extract_zone "$COMMIT_COMMITTER")")
    fi
    author_epoch=${author_date% *}
    author_zone=${author_date##* }
    committer_epoch=${committer_date% *}
    committer_zone=${committer_date##* }

    local new_message="$WORK_DIR/new-message-$oid"
    if [[ "$EDIT_MESSAGES" -eq 1 && "$matched" -eq 1 ]]; then
      edit_selected_message "$oid" "$object_message" "$new_message"
    elif [[ "$matched" -eq 0 ]] ||
      ! selected_message_for "$oid" "$new_message"; then
      cp -- "$object_message" "$new_message"
    fi

    local new_headers="$WORK_DIR/unsigned-$oid"
    local signed="$WORK_DIR/signed-$oid"
    rebuild_commit_object "$headers" "$new_message" "$new_headers" \
      "$mapping" "$author_name" "$author_email" "$author_epoch" \
      "$author_zone" "$committer_name" "$committer_email" \
      "$committer_epoch" "$committer_zone"
    write_signed_commit "$new_headers" "$signed" "$committer_epoch"
    local new_oid
    new_oid=$(git hash-object -t commit -w --stdin <"$signed") ||
      die "could not write commit object for $oid"
    printf '%s %s\n' "$oid" "$new_oid" >>"$mapping"

    verify_created_commit "$new_oid" "$committer_epoch" "$new_headers"

    local new_tree
    new_tree=$(git cat-file -p "$new_oid" | awk '$1 == "tree" { print $2; exit }')
    [[ "$new_tree" == "$COMMIT_TREE" ]] ||
      die "tree changed for $oid"
    local -a expected_parents=() actual_parents=()
    local parent
    for parent in "${COMMIT_PARENT[@]}"; do
      local mapped_parent
      mapped_parent=$(
        awk -v old="$parent" '$1 == old { print $2; exit }' "$mapping"
      )
      expected_parents+=("${mapped_parent:-$parent}")
    done
    while IFS= read -r parent; do
      [[ -n "$parent" ]] && actual_parents+=("$parent")
    done < <(git cat-file -p "$new_oid" |
      awk '$1 == "parent" { print $2 }')
    assert_eq "${expected_parents[*]:-}" "${actual_parents[*]:-}" \
      "parents for $oid"
    assert_eq "$author_epoch" \
      "$(git cat-file -p "$new_oid" |
        awk '$1 == "author" { print $(NF-1); exit }')" \
      "author epoch"
    assert_eq "$committer_epoch" \
      "$(git cat-file -p "$new_oid" |
        awk '$1 == "committer" { print $(NF-1); exit }')" \
      "committer epoch"
  done <"$plan"

  NEW_HEAD=$(expected_new_head_for_selection "$mapping")
  [[ -n "$NEW_HEAD" ]] ||
    die "new branch head could not be determined"
}

print_plan() {
  local mapping="$WORK_DIR/mapping"
  printf 'Commits to rewrite on %s:\n' "$CURRENT_BRANCH"
  local old new
  while read -r old new; do
    local subject
    subject=$(git show -s --format=%s "$new")
    printf '  %.12s..%.12s %s\n' "$old" "$new" "$subject"
  done <"$mapping"
  printf 'New HEAD candidate: %s\n' "$NEW_HEAD"
  printf 'Backup: refs/backups/git-recommit-sign/%s\n' "${BACKUP_ID:-<dry-run>}"
  printf 'No references changed.\n'
}

create_backup() {
  local mapping=$1
  local base=$BACKUP_REF
  local manifest="$WORK_DIR/backup-manifest"

  printf 'format=1\n' >"$manifest"
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$manifest"
  printf 'branch=%s\n' "$CURRENT_REF" >>"$manifest"
  printf 'head=%s\n' "$CURRENT_HEAD" >>"$manifest"
  printf 'new_head=%s\n' "$NEW_HEAD" >>"$manifest"
  printf 'mapping_begin\n' >>"$manifest"
  cat -- "$mapping" >>"$manifest"
  printf 'mapping_end\n' >>"$manifest"
  printf 'tags_begin\n' >>"$manifest"

  local transaction="$WORK_DIR/ref-transaction-backups"
  : >"$transaction"
  printf 'create %s/%s %s\n' "$base/branches" "$CURRENT_BRANCH" \
    "$CURRENT_HEAD" >>"$transaction"

  local ref type old
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    old=$(git rev-parse --verify "$ref")
    type=$(git cat-file -t "$ref")
    printf 'tag=%s\ntype=%s\nobject=%s\n' "$ref" "$type" "$old" >>"$manifest"
    printf 'create %s/tags/%s %s\n' "$base" "${ref#refs/tags/}" \
      "$old" >>"$transaction"
  done < <(
    git for-each-ref --format='%(refname)' refs/tags |
      while IFS= read -r ref; do
        target=$(git rev-parse --verify "$ref^{commit}" 2>/dev/null) || continue
        if awk -v old="$target" '$1 == old { found=1 } END { exit !found }' \
          "$mapping"; then
          printf '%s\n' "$ref"
        fi
      done
  )
  printf 'tags_end\n' >>"$manifest"

  local tree
  tree=$(git hash-object -t blob -w --stdin <"$manifest") ||
    die "could not write backup manifest"
  printf 'create %s/manifest %s\n' "$base" "$tree" >>"$transaction"
  BACKUP_REF="$base"
}

create_rewritten_tag() {
  local ref=$1
  local old_object=$2
  local new_commit=$3
  local transaction=$4

  local raw="$WORK_DIR/tag-${old_object}.raw"
  local payload="$WORK_DIR/tag-${old_object}.payload"
  local signature="$WORK_DIR/tag-${old_object}.signature"
  local new_object="$WORK_DIR/tag-${old_object}.new"
  local tagger tagger_epoch tagger_zone signed=0

  git cat-file tag "$old_object" >"$raw" ||
    die "cannot read annotated tag: $ref"
  tagger=$(awk '$1 == "tagger" { sub(/^tagger /, ""); print; exit }' "$raw")
  [[ -n "$tagger" ]] || die "annotated tag has no tagger: $ref"
  tagger_epoch=$(extract_epoch "$tagger")
  tagger_zone=$(extract_zone "$tagger")

  if grep -q '^-----BEGIN PGP SIGNATURE-----$' "$raw"; then
    signed=1
    perl -0777 -pe \
      's/\n-----BEGIN PGP SIGNATURE-----.*?-----END PGP SIGNATURE-----(\n)?\z/\n/s' \
      "$raw" >"$payload"
    perl -0777 -ne \
      'if (/\n(-----BEGIN PGP SIGNATURE-----.*?-----END PGP SIGNATURE-----)(?:\n)?\z/s) { print "$1\n" }' \
      "$raw" >"$signature"
    [[ -s "$signature" ]] || die "cannot extract tag signature: $ref"
  else
    cp -- "$raw" "$payload"
  fi

  replace_header_value object "$new_commit" "$payload" \
    "$WORK_DIR/tag-unsigned-$old_object"
  mv -- "$WORK_DIR/tag-unsigned-$old_object" "$payload"

  if [[ "$signed" -eq 1 ]]; then
    sign_bytes "$payload" "$signature" "$tagger_epoch"
    {
      cat -- "$payload"
      cat -- "$signature"
    } >"$new_object"
  else
    cp -- "$payload" "$new_object"
  fi

  local new_oid
  new_oid=$(git hash-object -t tag -w --stdin <"$new_object") ||
    die "could not write tag object for $ref"
  if [[ "$signed" -eq 1 ]]; then
    if ! git verify-tag --raw "$new_oid" >/dev/null 2>&1 &&
      [[ "$ALLOW_KEY_TIME_CONFLICT" -ne 1 ]]; then
      die "new tag object did not verify: $ref"
    fi
    local signed_epoch
    signed_epoch=$(git verify-tag --raw "$new_oid" 2>&1 |
      awk '$2 == "VALIDSIG" { print $5; exit }')
    assert_eq "$tagger_epoch" "$signed_epoch" "tag signature epoch"
    printf 'update %s %s %s\n' "$ref" "$new_oid" "$old_object" \
      >>"$transaction"
  else
    printf 'update %s %s %s\n' "$ref" "$new_oid" "$old_object" \
      >>"$transaction"
  fi
}

update_references() {
  local mapping=$1
  local tags_transaction="$WORK_DIR/tags-transaction"
  local main_transaction="$WORK_DIR/ref-transaction-main"
  local tags_requested="$WORK_DIR/tags-requested"
  : >"$tags_transaction"
  : >"$main_transaction"
  : >"$tags_requested"
  local ref type target new_target

  if [[ "$TAG_POLICY" != keep ]]; then
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      type=$(git cat-file -t "$ref")
      target=$(git rev-parse --verify "$ref^{commit}")
      new_target=$(awk -v old="$target" '$1 == old { print $2; exit }' "$mapping")
      [[ -n "$new_target" ]] || continue
      if [[ "$TAG_POLICY" == abort ]]; then
        die "tag $ref points to a rewritten commit; use --tag-policy move or keep"
      fi
      local old_target
      old_target=$(git rev-parse --verify "$ref")
      printf '%s\n' "$ref" >>"$tags_requested"
      if [[ "$type" == commit ]]; then
        printf 'update %s %s %s\n' "$ref" "$new_target" "$old_target" \
          >>"$tags_transaction"
      elif [[ "$type" == tag ]]; then
        create_rewritten_tag "$ref" "$old_target" "$new_target" \
          "$tags_transaction"
      fi
    done < <(git for-each-ref --format='%(refname)' refs/tags)
  fi

  local moved_ref
  while IFS= read -r moved_ref; do
    [[ -n "$moved_ref" ]] || continue
    local expected
    expected=$(awk -v ref="$moved_ref" '$1 == "update" { print $4; exit }' \
      "$tags_transaction")
    [[ -n "$expected" ]] || expected=$(git rev-parse --verify "$moved_ref")
    [[ "$(git cat-file -t "$expected" 2>/dev/null || true)" == tag ]] ||
      continue
    git cat-file tag "$expected" |
      grep -q '^-----BEGIN PGP SIGNATURE-----$' || continue
    local tag_epoch signed_epoch tag_verify tag_verify_rc=0
    tag_epoch=$(git cat-file tag "$expected" |
      awk '$1 == "tagger" { print $(NF-1); exit }')
    tag_verify=$(
      git verify-tag --raw "$expected" 2>&1
    ) || tag_verify_rc=$?
    if [[ "$tag_verify_rc" -ne 0 ]]; then
      [[ "$ALLOW_KEY_TIME_CONFLICT" -eq 1 ]] ||
        die "new annotated tag did not verify: $moved_ref"
      [[ "$tag_verify" == *'[GNUPG:] VALIDSIG '* ]] ||
        die "GnuPG did not report VALIDSIG for tag $moved_ref: $tag_verify"
    fi
    signed_epoch=$(printf '%s\n' "$tag_verify" |
      awk '$2 == "VALIDSIG" { print $5; exit }')
    assert_eq "$tag_epoch" "$signed_epoch" "tag signature epoch"
  done <"$tags_requested"

  printf 'update %s %s %s\n' "$CURRENT_REF" "$NEW_HEAD" \
    "$CURRENT_HEAD" >>"$main_transaction"

  cat -- "$main_transaction" "$tags_transaction" \
    "$WORK_DIR/ref-transaction-backups" >"$WORK_DIR/final-transaction"
  if ! {
    printf 'start\n'
    cat -- "$WORK_DIR/final-transaction"
    printf 'prepare\ncommit\n'
  } | git update-ref --stdin; then
    die "reference transaction failed; no references were changed"
  fi
}

restore_backup() {
  local requested=$1
  local backup_ref
  if [[ "$requested" == refs/backups/git-recommit-sign/* ]]; then
    backup_ref=$requested
  else
    backup_ref="refs/backups/git-recommit-sign/$requested"
  fi

  [[ "$backup_ref" != *$'\n'* && "$backup_ref" != *' '* ]] ||
    die "invalid backup id"
  git rev-parse --verify "$backup_ref/manifest^{blob}" >/dev/null 2>&1 ||
    die "backup manifest not found: $backup_ref"
  [[ -n "$(git for-each-ref --format='%(refname)' \
    "$backup_ref/branches/$CURRENT_BRANCH" 2>/dev/null)" ]] ||
    die "backup does not contain current branch $CURRENT_BRANCH"

  local manifest="$WORK_DIR/restore-manifest"
  git cat-file blob "$backup_ref/manifest" >"$manifest"
  local manifest_format expected_branch expected_head
  manifest_format=$(awk -F= '$1 == "format" { print $2; exit }' "$manifest")
  [[ "$manifest_format" == 1 ]] ||
    die "unsupported or missing backup manifest format: ${manifest_format:-<missing>}"
  expected_branch=$(awk -F= '$1 == "branch" { print $2; exit }' "$manifest")
  expected_head=$(awk -F= '$1 == "head" { print $2; exit }' "$manifest")
  [[ "$expected_branch" == "$CURRENT_REF" ]] ||
    die "backup belongs to $expected_branch, not $CURRENT_REF"
  [[ "$expected_head" =~ ^[0-9a-f]+$ ]] ||
    die "backup manifest has invalid head"

  local transaction="$WORK_DIR/restore-transaction"
  : >"$transaction"
  printf 'update %s %s %s\n' "$CURRENT_REF" "$expected_head" \
    "$CURRENT_HEAD" >>"$transaction"

  local backup_tag_ref ref old
  while IFS= read -r backup_tag_ref; do
    [[ -n "$backup_tag_ref" ]] || continue
    ref="refs/tags/${backup_tag_ref#"$backup_ref"/tags/}"
    old=$(git rev-parse --verify "$backup_tag_ref" 2>/dev/null) ||
      die "backup tag ref is missing: $ref"
    local current_old
    current_old=$(git rev-parse --verify "$ref" 2>/dev/null || true)
    if [[ -n "$current_old" ]]; then
      printf 'update %s %s %s\n' "$ref" "$old" "$current_old" \
        >>"$transaction"
    else
      printf 'create %s %s\n' "$ref" "$old" >>"$transaction"
    fi
  done < <(git for-each-ref --format='%(refname)' "$backup_ref/tags/")

  {
    printf 'start\n'
    cat -- "$transaction"
    printf 'prepare\ncommit\n'
  } | git update-ref --stdin ||
    die "restore transaction failed; no references were changed"
  printf 'Restored %s from %s\n' "$CURRENT_REF" "$backup_ref"
}

run_rewrite() {
  [[ "$TAG_POLICY" == move || "$TAG_POLICY" == keep ||
    "$TAG_POLICY" == abort ]] ||
    usage_error "--tag-policy must be move, keep, or abort"
  [[ "$MESSAGE_SET" -eq 0 || -z "$MESSAGE_FILE" ]] ||
    usage_error "--message and --message-file are mutually exclusive"
  [[ "$EDIT_MESSAGES" -eq 0 || "$MESSAGE_SET" -eq 0 ]] ||
    usage_error "--edit-messages and --message are mutually exclusive"
  [[ "$EDIT_MESSAGES" -eq 0 || -z "$MESSAGE_FILE" ]] ||
    usage_error "--edit-messages and --message-file are mutually exclusive"
  if [[ -z "$RESTORE_ID" && -z "$SELECTION_KIND" ]]; then
    usage_error "use --commit <rev>, --range <FROM..TO>, or --all"
  fi

  preflight_repository
  TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/git-recommit-sign.XXXXXX")
  WORK_DIR="$TMP_BASE/work"
  mkdir -p "$WORK_DIR"
  acquire_lock

  if [[ -n "$RESTORE_ID" ]]; then
    restore_backup "$RESTORE_ID"
    return
  fi

  preflight_signing
  load_map_if_present

  build_rewrite_plan
  NEW_HEAD=$CURRENT_HEAD
  rewrite_plan

  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_plan
    return
  fi
  [[ "$ASSUME_YES" -eq 1 ]] ||
    die "non-interactive execution requires --yes"

  if [[ -n "${GIT_RECOMMIT_SIGN_TEST_BACKUP_ID:-}" ]]; then
    BACKUP_ID=$GIT_RECOMMIT_SIGN_TEST_BACKUP_ID
  else
    BACKUP_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
  fi
  BACKUP_REF="refs/backups/git-recommit-sign/$BACKUP_ID"
  [[ -z "$(git for-each-ref --format='%(refname)' "$BACKUP_REF")" ]] ||
    die "backup id already exists: $BACKUP_ID"

  create_backup "$WORK_DIR/mapping"
  update_references "$WORK_DIR/mapping"

  local worktree_status
  worktree_status=$(
    git status --porcelain=v1 --untracked-files=all
  ) || die "could not inspect worktree after update"
  [[ "$worktree_status" == "$FULL_WORKTREE_STATUS" ]] ||
    die "worktree changed unexpectedly after reference update"

  printf 'Rewrote %s commit(s); new HEAD %s\n' \
    "$(wc -l <"$WORK_DIR/mapping")" "$NEW_HEAD"
  printf 'Backup: %s\n' "$BACKUP_REF"
  printf 'Restore: %s --restore %s\n' "$PROGRAM_NAME" "$BACKUP_ID"
  printf 'Push: git push --force-with-lease origin %s\n' "$CURRENT_BRANCH"
  printf 'No command was pushed.\n'
}

interactive_prompt() {
  local prompt=$1
  local default=${2:-}
  local answer

  INTERACTIVE_CANCELLED=0
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  IFS= read -r answer || answer=
  case "$answer" in
    q|Q)
      INTERACTIVE_CANCELLED=1
      INTERACTIVE_VALUE=
      return 2
      ;;
    b|B)
      INTERACTIVE_VALUE=
      return 1
      ;;
    '') INTERACTIVE_VALUE=$default ;;
    *) INTERACTIVE_VALUE=$answer ;;
  esac
  return 0
}

interactive_choose_range() {
  local choice commit range
  while true; do
    printf '%s\n' \
      '1) one commit' '2) inclusive range' '3) all commits' \
      '1) 单个提交' '2) 闭区间' '3) 全部提交' \
      'b) back' 'q) cancel'
    printf 'Selection/范围: '
    IFS= read -r choice || choice=q
    case "$choice" in
      1)
        interactive_prompt 'Commit/提交' HEAD
        case $? in
          2) cancel_and_exit ;;
          1) continue ;;
        esac
        commit=$INTERACTIVE_VALUE
        SELECTION_KIND=commit
        SELECTION_VALUE=$commit
        SELECTED_FROM=
        SELECTED_TO=
        return 0
        ;;
      2)
        interactive_prompt 'Range/区间 (FROM..TO)' HEAD~1..HEAD
        case $? in
          2) cancel_and_exit ;;
          1) continue ;;
        esac
        range=$INTERACTIVE_VALUE
        SELECTION_KIND=range
        SELECTION_VALUE=$range
        SELECTED_FROM=
        SELECTED_TO=
        return 0
        ;;
      3)
        SELECTION_KIND=all
        SELECTION_VALUE=
        SELECTED_FROM=
        SELECTED_TO=
        return 0
        ;;
      b|B) return 1 ;;
      q|Q) cancel_and_exit ;;
      *) printf 'Invalid selection.\n' >&2 ;;
    esac
  done
}

interactive_collect() {
  local value
  interactive_choose_range || return 1

  interactive_prompt 'Author filter name/筛选作者姓名 (blank=any)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  AUTHOR_FILTER_NAME=$INTERACTIVE_VALUE

  interactive_prompt 'Author filter email/筛选作者邮箱 (blank=any)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  AUTHOR_FILTER_EMAIL=$INTERACTIVE_VALUE

  interactive_prompt 'Committer filter name/筛选提交者姓名 (blank=any)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  COMMITTER_FILTER_NAME=$INTERACTIVE_VALUE

  interactive_prompt 'Committer filter email/筛选提交者邮箱 (blank=any)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  COMMITTER_FILTER_EMAIL=$INTERACTIVE_VALUE

  interactive_prompt 'Author name/作者姓名 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { AUTHOR_NAME=$value; AUTHOR_NAME_SET=1; }

  interactive_prompt 'Author email/作者邮箱 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { AUTHOR_EMAIL=$value; AUTHOR_EMAIL_SET=1; }

  interactive_prompt 'Committer name/提交者姓名 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { COMMITTER_NAME=$value; COMMITTER_NAME_SET=1; }

  interactive_prompt 'Committer email/提交者邮箱 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { COMMITTER_EMAIL=$value; COMMITTER_EMAIL_SET=1; }

  interactive_prompt 'Author date/作者日期 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  AUTHOR_DATE=$value

  interactive_prompt 'Committer date/提交者日期 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  COMMITTER_DATE=$value

  interactive_prompt 'Message/消息 (blank=keep)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ -n "$value" ]]; then
    MESSAGE=$value
    MESSAGE_SET=1
  fi

  interactive_prompt 'Message file/消息文件 (blank=none)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  MESSAGE_FILE=$value

  interactive_prompt 'Edit each matched message? [y/N]' N ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ "$value" =~ ^[Yy]$ ]]; then
    EDIT_MESSAGES=1
  else
    EDIT_MESSAGES=0
  fi

  interactive_prompt 'Per-commit TSV map/逐提交映射 (blank=none)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  MAP_FILE=$INTERACTIVE_VALUE

  interactive_prompt 'Signing key/签名密钥 (blank=config)' '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  SIGNING_KEY=$value

  interactive_prompt 'Tag policy/标签策略 (move/keep/abort)' move ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  TAG_POLICY=$value

  interactive_prompt 'Allow GPG key time conflict? [y/N]' N ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ "$value" =~ ^[Yy]$ ]]; then
    ALLOW_KEY_TIME_CONFLICT=1
  else
    ALLOW_KEY_TIME_CONFLICT=0
  fi

  interactive_prompt 'Dry run? [y/N]' N ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ "$value" =~ ^[Yy]$ ]]; then
    DRY_RUN=1
  else
    DRY_RUN=0
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    interactive_prompt 'Proceed with rewrite? [y/N]' N ||
      { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
    value=$INTERACTIVE_VALUE
    [[ "$value" =~ ^[Yy]$ ]] || cancel_and_exit
    ASSUME_YES=1
  fi
}

interactive_main() {
  SELECTION_KIND=
  SELECTION_VALUE=
  SELECTED_FROM=
  SELECTED_TO=
  AUTHOR_NAME_SET=0
  AUTHOR_EMAIL_SET=0
  COMMITTER_NAME_SET=0
  COMMITTER_EMAIL_SET=0
  AUTHOR_NAME=
  AUTHOR_EMAIL=
  COMMITTER_NAME=
  COMMITTER_EMAIL=
  AUTHOR_FILTER_NAME=
  AUTHOR_FILTER_EMAIL=
  COMMITTER_FILTER_NAME=
  COMMITTER_FILTER_EMAIL=
  AUTHOR_DATE=
  COMMITTER_DATE=
  MESSAGE=
  MESSAGE_SET=0
  MESSAGE_FILE=
  MAP_FILE=
  SIGNING_KEY=
  TAG_POLICY=move
  ALLOW_KEY_TIME_CONFLICT=0
  DRY_RUN=0
  ASSUME_YES=0
  EDIT_MESSAGES=0
  RESTORE_ID=
  printf '%s\n' \
    'Git commit recommit and OpenPGP re-sign' \
    'Git 提交批量改写与 OpenPGP 重签' \
    'q) cancel/取消' 'b) back/返回'
  while ! interactive_collect; do
    printf 'Returned to the main menu.\n'
  done
  run_rewrite
}

main() {
  if [[ $# -eq 0 ]]; then
    interactive_main
    return
  fi

  parse_args "$@"
  if [[ "${HELP_REQUESTED:-0}" -eq 1 ]]; then
    usage
    return
  fi
  run_rewrite
}

main "$@"
