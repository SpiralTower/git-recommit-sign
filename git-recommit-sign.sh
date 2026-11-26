#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM_NAME=${0##*/}
UI_LANGUAGE=
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
  printf '%s\n' "$(ui_text cancel)"
  exit 0
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

usage_error() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  if [[ "$UI_LANGUAGE" == zh ]]; then
    printf '运行 %s --help 查看用法。\n' "$PROGRAM_NAME" >&2
  else
    printf 'Run %s --help for usage.\n' "$PROGRAM_NAME" >&2
  fi
  exit 2
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] ||
    usage_error "$(ui_error selection_requires_value "$1")"
}

ui_text() {
  local key=$1
  shift
  local template

  if [[ "$UI_LANGUAGE" == zh ]]; then
    case "$key" in
      title) template='Git 提交批量改写与 OpenPGP 重签' ;;
      cancel_option) template='q) 取消' ;;
      back_option) template='b) 返回' ;;
      selection_prompt) template='选择范围' ;;
      one_commit) template='1) 单个提交' ;;
      inclusive_range) template='2) 闭区间' ;;
      all_commits) template='3) 全部提交' ;;
      commit_prompt) template='提交' ;;
      range_prompt) template='区间 (FROM..TO)' ;;
      invalid_selection) template='无效选择。' ;;
      author_filter_name) template='筛选作者姓名 (留空=任意)' ;;
      author_filter_email) template='筛选作者邮箱 (留空=任意)' ;;
      committer_filter_name) template='筛选提交者姓名 (留空=任意)' ;;
      committer_filter_email) template='筛选提交者邮箱 (留空=任意)' ;;
      author_name) template='作者姓名 (留空=保留)' ;;
      author_email) template='作者邮箱 (留空=保留)' ;;
      committer_name) template='提交者姓名 (留空=保留)' ;;
      committer_email) template='提交者邮箱 (留空=保留)' ;;
      author_date) template='作者日期 (留空=保留)' ;;
      committer_date) template='提交者日期 (留空=保留)' ;;
      message) template='消息 (留空=保留)' ;;
      message_file) template='消息文件 (留空=无)' ;;
      edit_messages) template='逐条编辑命中消息？[y/N]' ;;
      map_file) template='逐提交 TSV 映射 (留空=无)' ;;
      signing_key) template='签名密钥 (留空=配置值)' ;;
      tag_policy) template='标签策略 (move/keep/abort)' ;;
      allow_time_conflict) template='允许 GPG 密钥时间冲突？[y/N]' ;;
      dry_run) template='仅预览？[y/N]' ;;
      proceed) template='开始改写？[y/N]' ;;
      returned_to_menu) template='已返回主菜单。' ;;
      cancel) template='已取消；未修改任何引用。' ;;
      plan_heading) template='将在 %s 上改写以下提交：' ;;
      new_head) template='新的 HEAD 候选：%s' ;;
      backup) template='备份：%s' ;;
      no_refs) template='未修改任何引用。' ;;
      rewrote) template='已改写 %s 个提交；新的 HEAD 为 %s' ;;
      restore_command) template='恢复：%s --restore %s' ;;
      push_command) template='推送：git push --force-with-lease origin %s' ;;
      not_pushed) template='未执行任何推送。' ;;
      time_conflict_warning) template='警告：git verify-commit 拒绝该密钥时间冲突签名；已使用 GnuPG VALIDSIG 验证。' ;;
      *) template=$key ;;
    esac
  else
    case "$key" in
      title) template='Git commit recommit and OpenPGP re-sign' ;;
      cancel_option) template='q) cancel' ;;
      back_option) template='b) back' ;;
      selection_prompt) template='Selection' ;;
      one_commit) template='1) one commit' ;;
      inclusive_range) template='2) inclusive range' ;;
      all_commits) template='3) all commits' ;;
      commit_prompt) template='Commit' ;;
      range_prompt) template='Range (FROM..TO)' ;;
      invalid_selection) template='Invalid selection.' ;;
      author_filter_name) template='Author filter name (blank=any)' ;;
      author_filter_email) template='Author filter email (blank=any)' ;;
      committer_filter_name) template='Committer filter name (blank=any)' ;;
      committer_filter_email) template='Committer filter email (blank=any)' ;;
      author_name) template='Author name (blank=keep)' ;;
      author_email) template='Author email (blank=keep)' ;;
      committer_name) template='Committer name (blank=keep)' ;;
      committer_email) template='Committer email (blank=keep)' ;;
      author_date) template='Author date (blank=keep)' ;;
      committer_date) template='Committer date (blank=keep)' ;;
      message) template='Message (blank=keep)' ;;
      message_file) template='Message file (blank=none)' ;;
      edit_messages) template='Edit each matched message? [y/N]' ;;
      map_file) template='Per-commit TSV map (blank=none)' ;;
      signing_key) template='Signing key (blank=config)' ;;
      tag_policy) template='Tag policy (move/keep/abort)' ;;
      allow_time_conflict) template='Allow GPG key time conflict? [y/N]' ;;
      dry_run) template='Dry run? [y/N]' ;;
      proceed) template='Proceed with rewrite? [y/N]' ;;
      returned_to_menu) template='Returned to the main menu.' ;;
      cancel) template='Cancelled; no references changed.' ;;
      plan_heading) template='Commits to rewrite on %s:' ;;
      new_head) template='New HEAD candidate: %s' ;;
      backup) template='Backup: %s' ;;
      no_refs) template='No references changed.' ;;
      rewrote) template='Rewrote %s commit(s); new HEAD %s' ;;
      restore_command) template='Restore: %s --restore %s' ;;
      push_command) template='Push: git push --force-with-lease origin %s' ;;
      not_pushed) template='No command was pushed.' ;;
      time_conflict_warning) template='WARNING: git verify-commit rejects this time-conflict signature; GnuPG VALIDSIG was used.' ;;
      *) template=$key ;;
    esac
  fi
  if [[ $# -gt 0 ]]; then
    printf "$template" "$@"
  else
    printf '%s' "$template"
  fi
}

ui_error() {
  local key=$1
  shift
  local format
  local -a values=("$@")

  if [[ "$UI_LANGUAGE" == zh ]]; then
    case "$key" in
      selection_requires_value) format='%s 需要一个值' ;;
      selection_mutually_exclusive) format='范围选项互斥，只能选择一个' ;;
      unexpected_argument) format='意外参数：%s' ;;
      unsupported_option) format='不支持的选项：%s' ;;
      invalid_date) format="日期无效 '%s'；请使用 YYYY-MM-DDTHH:MM:SS±HH:MM" ;;
      invalid_timezone) format="时区偏移无效：'%s'" ;;
      cannot_parse_identity_line) format='无法解析身份行：%s' ;;
      cannot_parse_timestamp) format='无法解析时间戳：%s' ;;
      cannot_parse_timezone) format='无法解析时区：%s' ;;
      cannot_parse_role_identity) format='无法解析 %s 身份：%s' ;;
      identity_newline) format='%s 身份不能包含换行' ;;
      identity_angle_brackets) format='%s %s 不能包含尖括号' ;;
      message_file_missing) format='消息文件不存在：%s' ;;
      message_file_unreadable) format='消息文件不可读：%s' ;;
      no_editor) format='未配置编辑器（请设置 GIT_EDITOR 或 core.editor）' ;;
      editor_failed) format='编辑 %s 的消息时编辑器失败' ;;
      gpg_sign_failed) format='GnuPG 无法创建签名：%s' ;;
      gpg_signature_rejected) format='GnuPG 拒绝了生成的签名' ;;
      gpg_no_validsig) format='GnuPG 未报告有效签名' ;;
      range_syntax) format='--range 需要 FROM..TO' ;;
      range_endpoints) format='--range 需要同时提供 FROM 和 TO' ;;
      range_start_missing) format='无法解析范围起点：%s' ;;
      range_end_missing) format='无法解析范围终点：%s' ;;
      range_not_ancestor) format='范围起点不是范围终点的祖先' ;;
      commit_missing) format='无法解析提交：%s' ;;
      range_end_unreachable) format='范围终点无法从当前分支 tip 到达' ;;
      head_missing) format='HEAD 未指向任何提交' ;;
      selection_required) format='必须选择提交范围；请使用 --commit、--range 或 --all' ;;
      cannot_parse_identity) format='无法解析身份：%s' ;;
      map_unreadable) format='映射文件不可读：%s' ;;
      map_columns) format='映射第 %s 行：需要四个制表符分隔的列' ;;
      map_header) format='映射表头必须为：commit, author_date, committer_date, message_file' ;;
      map_commit_required) format='映射第 %s 行：commit 不能为空' ;;
      map_commit_oid) format='映射第 %s 行：commit 必须是完整对象 ID' ;;
      map_duplicate) format="映射第 %s 行：重复提交 '%s'" ;;
      object_no_separator) format='%s 没有头部/消息分隔符' ;;
      object_missing_header) format='缺少 %s 头' ;;
      malformed_gpgsig) format='gpgsig 续行格式错误' ;;
      signature_not_removed) format='提交头中的签名未被移除' ;;
      signature_epoch_mismatch) format='签名 epoch 不匹配：期望 %s，实际 %s' ;;
      git_no_validsig) format='Git 未为 %s 报告 VALIDSIG' ;;
      git_verify_failed) format='提交 %s 的 git verify-commit 失败：%s' ;;
      no_payload_for_conflict) format='缺少用于验证密钥时间冲突签名的载荷' ;;
      cannot_extract_signature) format='无法从 %s 提取签名' ;;
      not_repository) format='当前目录不是 Git 仓库' ;;
      bare_repository) format='不支持裸仓库' ;;
      detached_head) format='不支持 detached HEAD；请检出本地分支' ;;
      empty_branch) format='当前分支没有任何提交' ;;
      dirty_worktree) format='工作树和索引必须干净（未跟踪文件也视为脏）' ;;
      rebase_in_progress) format='正在进行 rebase' ;;
      merge_in_progress) format='正在进行 merge' ;;
      cherry_pick_in_progress) format='正在进行 cherry-pick' ;;
      revert_in_progress) format='正在进行 revert' ;;
      bisect_in_progress) format='正在进行 bisect' ;;
      index_locked) format='index.lock 存在；可能有其他 Git 操作正在运行' ;;
      only_openpgp) format='仅支持 OpenPGP 签名（gpg.format=%s）' ;;
      no_signing_key) format='未配置签名密钥；请使用 --signing-key 或 user.signingKey' ;;
      gpg_missing) format='未安装 gpg' ;;
      git_missing) format='未安装 git' ;;
      secret_key_missing) format='找不到私钥：%s' ;;
      ambiguous_key) format='签名密钥选择不唯一：%s' ;;
      another_rewrite) format='另一个改写任务正在运行（pid %s）' ;;
      stale_lock) format='锁已存在：%s（确认没有改写任务运行后再删除）' ;;
      cannot_read_commit) format='无法读取提交：%s' ;;
      malformed_commit) format='提交对象格式错误：%s' ;;
      enumerate_failed) format='无法枚举当前分支提交' ;;
      no_matches) format='没有提交匹配所选范围' ;;
      write_commit_failed) format='无法为 %s 写入提交对象' ;;
      tree_changed) format='%s 的 tree 发生变化' ;;
      no_new_head) format='无法确定新的分支 HEAD' ;;
      write_manifest_failed) format='无法写入备份 manifest' ;;
      read_annotated_tag) format='无法读取附注标签：%s' ;;
      tag_no_tagger) format='附注标签缺少 tagger：%s' ;;
      extract_tag_signature) format='无法提取标签签名：%s' ;;
      write_tag_failed) format='无法为 %s 写入标签对象' ;;
      tag_verify_failed) format='新的附注标签验签失败：%s' ;;
      tag_gpg_no_validsig) format='GnuPG 未为标签 %s 报告 VALIDSIG：%s' ;;
      tag_requires_policy) format='标签 %s 指向被改写提交；请使用 --tag-policy move 或 keep' ;;
      ref_transaction_failed) format='引用事务失败；未修改任何引用' ;;
      invalid_backup_id) format='备份 ID 无效' ;;
      backup_manifest_missing) format='找不到备份 manifest：%s' ;;
      backup_wrong_branch) format='备份不属于当前分支 %s' ;;
      backup_manifest_format) format='不支持或缺少备份 manifest 格式：%s' ;;
      backup_branch_mismatch) format='备份属于 %s，不属于 %s' ;;
      backup_invalid_head) format='备份 manifest 的 head 无效' ;;
      backup_tag_missing) format='备份缺少标签引用：%s' ;;
      restore_failed) format='恢复事务失败；未修改任何引用' ;;
      tag_policy_invalid) format='--tag-policy 必须为 move、keep 或 abort' ;;
      message_conflict) format='%s 与 %s 互斥' ;;
      yes_required) format='非交互执行必须带 --yes' ;;
      backup_exists) format='备份 ID 已存在：%s' ;;
      inspect_worktree_failed) format='更新后无法检查工作树' ;;
      worktree_changed) format='更新引用后工作树意外改变' ;;
      label_primary_signing_key) format='主签名密钥' ;;
      label_signature_epoch) format='签名 epoch' ;;
      label_git_signature_epoch) format='Git 签名 epoch' ;;
      label_parents) format='%s 的父提交' ;;
      label_author_epoch) format='作者 epoch' ;;
      label_committer_epoch) format='提交者 epoch' ;;
      label_tag_signature_epoch) format='标签签名 epoch' ;;
      *) format=$key ;;
    esac
  else
    case "$key" in
      selection_requires_value) format='%s requires a value' ;;
      selection_mutually_exclusive) format='selection options are mutually exclusive' ;;
      unexpected_argument) format='unexpected argument: %s' ;;
      unsupported_option) format='unsupported option: %s' ;;
      invalid_date) format="invalid date '%s'; use YYYY-MM-DDTHH:MM:SS±HH:MM" ;;
      invalid_timezone) format="invalid timezone offset in '%s'" ;;
      cannot_parse_identity_line) format='cannot parse identity line: %s' ;;
      cannot_parse_timestamp) format='cannot parse timestamp: %s' ;;
      cannot_parse_timezone) format='cannot parse timezone: %s' ;;
      cannot_parse_role_identity) format='cannot parse %s identity: %s' ;;
      identity_newline) format='%s identity cannot contain a newline' ;;
      identity_angle_brackets) format='%s %s cannot contain angle brackets' ;;
      message_file_missing) format='message file does not exist: %s' ;;
      message_file_unreadable) format='message file is not readable: %s' ;;
      no_editor) format='no editor configured (set GIT_EDITOR or core.editor)' ;;
      editor_failed) format='editor failed while editing %s' ;;
      gpg_sign_failed) format='GnuPG could not create a signature: %s' ;;
      gpg_signature_rejected) format='GnuPG rejected the generated signature' ;;
      gpg_no_validsig) format='GnuPG did not report a valid signature' ;;
      range_syntax) format='--range requires FROM..TO' ;;
      range_endpoints) format='--range requires both FROM and TO' ;;
      range_start_missing) format='cannot resolve range start: %s' ;;
      range_end_missing) format='cannot resolve range end: %s' ;;
      range_not_ancestor) format='range start is not an ancestor of range end' ;;
      commit_missing) format='cannot resolve commit: %s' ;;
      range_end_unreachable) format='range end is not reachable from the current branch tip' ;;
      head_missing) format='HEAD does not point to a commit' ;;
      selection_required) format='commit selection is required; use --commit, --range, or --all' ;;
      cannot_parse_identity) format='cannot parse identity: %s' ;;
      map_unreadable) format='map file is not readable: %s' ;;
      map_columns) format='map line %s: expected four tab-separated columns' ;;
      map_header) format='map header must be: commit, author_date, committer_date, message_file' ;;
      map_commit_required) format='map line %s: commit is required' ;;
      map_commit_oid) format='map line %s: commit must be a full object ID' ;;
      map_duplicate) format="map line %s: duplicate commit '%s'" ;;
      object_no_separator) format='%s has no header/message separator' ;;
      object_missing_header) format='missing %s header' ;;
      malformed_gpgsig) format='malformed gpgsig continuation' ;;
      signature_not_removed) format='signature was not removed from commit headers' ;;
      signature_epoch_mismatch) format='signature epoch mismatch: expected %s, got %s' ;;
      git_no_validsig) format='git did not report VALIDSIG for %s' ;;
      git_verify_failed) format='git verify-commit failed for %s: %s' ;;
      no_payload_for_conflict) format='cannot verify time-conflict signature without payload' ;;
      cannot_extract_signature) format='cannot extract signature from %s' ;;
      not_repository) format='not inside a Git repository' ;;
      bare_repository) format='bare repositories are not supported' ;;
      detached_head) format='detached HEAD is not supported; check out a local branch' ;;
      empty_branch) format='current branch has no commit' ;;
      dirty_worktree) format='working tree and index must be clean (untracked files count as dirty)' ;;
      rebase_in_progress) format='a rebase is in progress' ;;
      merge_in_progress) format='a merge is in progress' ;;
      cherry_pick_in_progress) format='a cherry-pick is in progress' ;;
      revert_in_progress) format='a revert is in progress' ;;
      bisect_in_progress) format='a bisect is in progress' ;;
      index_locked) format='index.lock exists; another Git operation may be running' ;;
      only_openpgp) format='only OpenPGP signing is supported (gpg.format=%s)' ;;
      no_signing_key) format='no signing key configured; use --signing-key or user.signingKey' ;;
      gpg_missing) format='gpg is not installed' ;;
      git_missing) format='git is not installed' ;;
      secret_key_missing) format='secret signing key not found: %s' ;;
      ambiguous_key) format='signing key selector is ambiguous: %s' ;;
      another_rewrite) format='another rewrite is running (pid %s)' ;;
      stale_lock) format='lock exists: %s (remove it only after confirming no rewrite is running)' ;;
      cannot_read_commit) format='cannot read commit: %s' ;;
      malformed_commit) format='malformed commit object: %s' ;;
      enumerate_failed) format='could not enumerate current branch commits' ;;
      no_matches) format='no commits matched the selection' ;;
      write_commit_failed) format='could not write commit object for %s' ;;
      tree_changed) format='tree changed for %s' ;;
      no_new_head) format='new branch head could not be determined' ;;
      write_manifest_failed) format='could not write backup manifest' ;;
      read_annotated_tag) format='cannot read annotated tag: %s' ;;
      tag_no_tagger) format='annotated tag has no tagger: %s' ;;
      extract_tag_signature) format='cannot extract tag signature: %s' ;;
      write_tag_failed) format='could not write tag object for %s' ;;
      tag_verify_failed) format='new annotated tag did not verify: %s' ;;
      tag_gpg_no_validsig) format='GnuPG did not report VALIDSIG for tag %s: %s' ;;
      tag_requires_policy) format='tag %s points to a rewritten commit; use --tag-policy move or keep' ;;
      ref_transaction_failed) format='reference transaction failed; no references were changed' ;;
      invalid_backup_id) format='invalid backup id' ;;
      backup_manifest_missing) format='backup manifest not found: %s' ;;
      backup_wrong_branch) format='backup does not contain current branch %s' ;;
      backup_manifest_format) format='unsupported or missing backup manifest format: %s' ;;
      backup_branch_mismatch) format='backup belongs to %s, not %s' ;;
      backup_invalid_head) format='backup manifest has invalid head' ;;
      backup_tag_missing) format='backup tag ref is missing: %s' ;;
      restore_failed) format='restore transaction failed; no references were changed' ;;
      tag_policy_invalid) format='--tag-policy must be move, keep, or abort' ;;
      message_conflict) format='%s and %s are mutually exclusive' ;;
      yes_required) format='non-interactive execution requires --yes' ;;
      backup_exists) format='backup id already exists: %s' ;;
      inspect_worktree_failed) format='could not inspect worktree after update' ;;
      worktree_changed) format='worktree changed unexpectedly after reference update' ;;
      label_primary_signing_key) format='primary signing key' ;;
      label_signature_epoch) format='signature epoch' ;;
      label_git_signature_epoch) format='git signature epoch' ;;
      label_parents) format='parents for %s' ;;
      label_author_epoch) format='author epoch' ;;
      label_committer_epoch) format='committer epoch' ;;
      label_tag_signature_epoch) format='tag signature epoch' ;;
      *) format=$key ;;
    esac
  fi
  if [[ ${#values[@]} -gt 0 ]]; then
    printf "$format" "${values[@]}"
  else
    printf '%s' "$format"
  fi
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
          usage_error "$(ui_error selection_mutually_exclusive)"
        SELECTION_KIND=commit
        SELECTION_VALUE=$2
      SELECTED_FROM=
      SELECTED_TO=
        shift 2
        ;;
      --range)
        require_value "$@"
        [[ -z "$SELECTION_KIND" ]] ||
          usage_error "$(ui_error selection_mutually_exclusive)"
        SELECTION_KIND=range
        SELECTION_VALUE=$2
      SELECTED_FROM=
      SELECTED_TO=
        shift 2
        ;;
      --all)
        [[ -z "$SELECTION_KIND" ]] ||
          usage_error "$(ui_error selection_mutually_exclusive)"
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
        [[ $# -eq 0 ]] || usage_error "$(ui_error unexpected_argument "$1")"
        ;;
      -*)
        usage_error "$(ui_error unsupported_option "$1")"
        ;;
      *)
        usage_error "$(ui_error unexpected_argument "$1")"
        ;;
    esac
  done

}

normalize_date() {
  local value=$1
  local regex='^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|[+-][0-9]{2}:?[0-9]{2})$'

  [[ "$value" =~ $regex ]] ||
    die "$(ui_error invalid_date "$value")"

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
    die "$(ui_error invalid_timezone "$value")"
  fi

  local offset_hour=${offset:1:2}
  local offset_minute=${offset:4:2}
  ((10#$offset_hour <= 23)) || die "$(ui_error invalid_timezone "$value")"
  ((10#$offset_minute <= 59)) || die "$(ui_error invalid_timezone "$value")"

  local epoch
  epoch=$(TZ=UTC date -d \
    "$year-$month-$day $hour:$minute:$second $offset" +%s 2>/dev/null) ||
    die "$(ui_error invalid_date "$value")"
  [[ "$epoch" =~ ^[0-9]+$ ]] || die "$(ui_error invalid_date "$value")"

  printf '%s %s\n' "$epoch" "${offset/:/}"
}

extract_identity() {
  local line=$1
  [[ "$line" =~ ^(.*)\ [0-9]+\ [+-][0-9]{4}$ ]] ||
    die "$(ui_error cannot_parse_identity_line "$line")"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

extract_epoch() {
  local line=$1
  [[ "$line" =~ \ ([0-9]+)\ [+-][0-9]{4}$ ]] ||
    die "$(ui_error cannot_parse_timestamp "$line")"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

extract_zone() {
  local line=$1
  [[ "$line" =~ \ ([+-][0-9]{4})$ ]] ||
    die "$(ui_error cannot_parse_timezone "$line")"
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
    die "$(ui_error cannot_parse_role_identity "$role" "$ident")"
  fi

  if [[ "$role" == author ]]; then
    [[ "$AUTHOR_NAME_SET" -eq 1 ]] && name=$AUTHOR_NAME
    [[ "$AUTHOR_EMAIL_SET" -eq 1 ]] && email=$AUTHOR_EMAIL
  else
    [[ "$COMMITTER_NAME_SET" -eq 1 ]] && name=$COMMITTER_NAME
    [[ "$COMMITTER_EMAIL_SET" -eq 1 ]] && email=$COMMITTER_EMAIL
  fi

  [[ "$name" != *$'\n'* && "$email" != *$'\n'* ]] ||
    die "$(ui_error identity_newline "$role")"
  [[ "$name" != *'<'* && "$name" != *'>'* ]] ||
    die "$(ui_error identity_angle_brackets "$role" name)"
  [[ "$email" != *'<'* && "$email" != *'>'* ]] ||
    die "$(ui_error identity_angle_brackets "$role" email)"

  printf '%s <%s>\n' "$name" "$email"
}

validate_message_file() {
  local path=$1

  [[ -f "$path" ]] || die "$(ui_error message_file_missing "$path")"
  [[ -r "$path" ]] || die "$(ui_error message_file_unreadable "$path")"
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
    die "$(ui_error no_editor)"
  [[ -n "$editor" ]] || die "$(ui_error no_editor)"
  cp -- "$original" "$output"
  (
    eval "$editor \"\$output\""
  ) || die "$(ui_error editor_failed "$oid")"
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
    die "$(ui_error gpg_sign_failed "$(<"$WORK_DIR/gpg.err")")"
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
    die "$(ui_error gpg_signature_rejected)"
  fi

  local validsig
  validsig=$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print; exit }')
  [[ -n "$validsig" ]] || die "$(ui_error gpg_no_validsig)"
  assert_eq "${validsig##* }" "$SIGNING_KEY" \
    "$(ui_error label_primary_signing_key)"
  local signed_epoch
  signed_epoch=$(
    printf '%s\n' "$validsig" | awk '{ print $5 }'
  )
  assert_eq "$signed_epoch" "$expected_epoch" \
    "$(ui_error label_signature_epoch)"
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3
  [[ "$actual" == "$expected" ]] && return 0
  if [[ "$UI_LANGUAGE" == zh ]]; then
    die "$label：期望 [$expected]，实际 [$actual]"
  fi
  die "$label: expected [$expected], got [$actual]"
}

resolve_commit_range() {
  local from_to=$1
  [[ "$from_to" == *..* && "$from_to" != *...* ]] ||
    usage_error "$(ui_error range_syntax)"
  local from=${from_to%%..*}
  local to=${from_to#*..}
  [[ -n "$from" && -n "$to" ]] ||
    usage_error "$(ui_error range_endpoints)"

  local from_oid to_oid
  from_oid=$(git rev-parse --verify "$from^{commit}" 2>/dev/null) ||
    die "$(ui_error range_start_missing "$from")"
  to_oid=$(git rev-parse --verify "$to^{commit}" 2>/dev/null) ||
    die "$(ui_error range_end_missing "$to")"

  git merge-base --is-ancestor "$from_oid" "$to_oid" ||
    die "$(ui_error range_not_ancestor)"

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
        die "$(ui_error commit_missing "$SELECTION_VALUE")"
      SELECTED_OID=$oid
      SELECTED_TO=$CURRENT_HEAD
      ;;
    range)
      local range
      range=$(resolve_commit_range "$SELECTION_VALUE")
      SELECTED_FROM=${range%%$'\n'*}
      SELECTED_TO=${range#*$'\n'}
      git merge-base --is-ancestor "$SELECTED_TO" "$CURRENT_HEAD" ||
        die "$(ui_error range_end_unreachable)"
      ;;
    all)
      SELECTED_FROM=
      SELECTED_TO=$(git rev-parse --verify 'HEAD^{commit}') ||
        die "$(ui_error head_missing)"
      ;;
    *)
      die "$(ui_error selection_required)"
      ;;
  esac

  "${rev_list[@]}" HEAD
}

identity_name() {
  local ident=$1
  [[ "$ident" =~ ^(.*)\ \<[^\<\>]*\>$ ]] ||
    die "$(ui_error cannot_parse_identity "$ident")"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

identity_email() {
  local ident=$1
  [[ "$ident" =~ ^[^\<\>]*\ \<([^\<\>]*)\>$ ]] ||
    die "$(ui_error cannot_parse_identity "$ident")"
  printf '%s\n' "${BASH_REMATCH[1]}"
}

parse_map() {
  local path=$1
  [[ -f "$path" && -r "$path" ]] || die "$(ui_error map_unreadable "$path")"

  declare -gA MAP_AUTHOR_DATE=()
  declare -gA MAP_COMMITTER_DATE=()
  declare -gA MAP_MESSAGE_FILE=()
  declare -gA MAP_SEEN=()
  local number=0 commit author_date committer_date message_file extra
  local invalid_line
  invalid_line=$(awk -F '\t' 'NF != 4 { print NR; exit }' "$path")
  [[ -z "$invalid_line" ]] ||
    die "$(ui_error map_columns "$invalid_line")"

  while IFS=$'\034' read -r number commit author_date committer_date \
    message_file extra; do
    if [[ "$number" -eq 1 && "$commit" == commit ]]; then
      [[ "$author_date" == author_date &&
        "$committer_date" == committer_date &&
        "$message_file" == message_file ]] ||
        die "$(ui_error map_header)"
      continue
    fi
    [[ -n "$commit" ]] || die "$(ui_error map_commit_required "$number")"
    valid_full_oid "${commit,,}" ||
      die "$(ui_error map_commit_oid "$number")"
    commit=${commit,,}
    [[ -z "${MAP_SEEN[$commit]:-}" ]] ||
      die "$(ui_error map_duplicate "$number" "$commit")"
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
    die "$(ui_error object_no_separator "$input")"
  input_bytes=$(wc -c <"$input")
  [[ "$header_bytes" -lt "$input_bytes" ]] ||
    die "$(ui_error object_no_separator "$input")"

  : >"$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$replaced" -eq 0 && "$line" == "$key "* ]]; then
      printf '%s %s\n' "$key" "$value" >>"$output"
      replaced=1
    else
      printf '%s\n' "$line" >>"$output"
    fi
  done < <(head -c "$header_bytes" "$input")
  [[ "$replaced" -eq 1 ]] || die "$(ui_error object_missing_header "$key")"
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
    die "$(ui_error object_no_separator "$raw")"
  raw_bytes=$(wc -c <"$raw")
  [[ "$header_bytes" -lt "$raw_bytes" ]] ||
    die "$(ui_error object_no_separator "$raw")"

  head -c "$header_bytes" "$raw" >"$headers"
  tail -c "+$((header_bytes + 2))" "$raw" >"$message"

  : >"$filtered"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$skipping_sig" -eq 1 ]]; then
      if [[ "$line" == ' '* ]]; then
        continue
      fi
      die "$(ui_error malformed_gpgsig)"
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
        die "$(ui_error signature_not_removed)"
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
    die "$(ui_error object_no_separator "$unsigned")"

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
    die "$(ui_error gpg_signature_rejected)"
  fi
  [[ "$status" == *'[GNUPG:] VALIDSIG '*'[GNUPG:]'* ]] ||
    die "$(ui_error gpg_no_validsig)"
  local signed_epoch
  signed_epoch=$(printf '%s\n' "$status" |
    awk '$2 == "VALIDSIG" { print $5; exit }')
  [[ "$signed_epoch" == "$epoch" ]] ||
    die "$(ui_error signature_epoch_mismatch "$epoch" "$signed_epoch")"
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
      die "$(ui_error git_no_validsig "$oid")"
    local git_epoch
    git_epoch=$(printf '%s\n' "$output" |
      awk '$2 == "VALIDSIG" { print $5; exit }')
    assert_eq "$expected_epoch" "$git_epoch" \
      "$(ui_error label_git_signature_epoch)"
    return
  fi

  [[ "$ALLOW_KEY_TIME_CONFLICT" -eq 1 ]] ||
    die "$(ui_error git_verify_failed "$oid" "$output")"
  [[ -n "$unsigned_payload" && -f "$unsigned_payload" ]] ||
    die "$(ui_error no_payload_for_conflict)"

  local signature="$WORK_DIR/allowed-conflict.signature"
  git cat-file commit "$oid" |
    sed -n '/^gpgsig /,/^[^ ]/p' |
    sed '$d' |
    sed '1s/^gpgsig //; 2,$s/^ //' >"$signature"
  [[ -s "$signature" ]] || die "$(ui_error cannot_extract_signature "$oid")"
  verify_gpg_signature "$signature" "$unsigned_payload" "$expected_epoch"
  printf '%s\n' "$(ui_text time_conflict_warning)" >&2
}

expected_new_head_for_selection() {
  local mapping=$1
  awk -v top="$CURRENT_HEAD" '$1 == top { print $2; exit }' "$mapping"
}

preflight_repository() {
  git rev-parse --git-dir >/dev/null 2>&1 ||
    die "$(ui_error not_repository)"
  [[ "$(git rev-parse --is-bare-repository 2>/dev/null)" == false ]] ||
    die "$(ui_error bare_repository)"

  CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) ||
    die "$(ui_error detached_head)"
  CURRENT_REF="refs/heads/$CURRENT_BRANCH"
  CURRENT_HEAD=$(git rev-parse --verify 'HEAD^{commit}') ||
    die "$(ui_error empty_branch)"

  FULL_WORKTREE_STATUS=$(
    git status --porcelain=v1 --untracked-files=all
  )
  [[ -z "$FULL_WORKTREE_STATUS" ]] ||
    die "$(ui_error dirty_worktree)"

  local git_dir
  git_dir=$(git rev-parse --git-path rebase-merge)
  [[ ! -d "$git_dir" ]] || die "$(ui_error rebase_in_progress)"
  git_dir=$(git rev-parse --git-path rebase-apply)
  [[ ! -d "$git_dir" ]] || die "$(ui_error rebase_in_progress)"
  git_dir=$(git rev-parse --git-path MERGE_HEAD)
  [[ ! -e "$git_dir" ]] || die "$(ui_error merge_in_progress)"
  git_dir=$(git rev-parse --git-path CHERRY_PICK_HEAD)
  [[ ! -e "$git_dir" ]] || die "$(ui_error cherry_pick_in_progress)"
  git_dir=$(git rev-parse --git-path REVERT_HEAD)
  [[ ! -e "$git_dir" ]] || die "$(ui_error revert_in_progress)"
  git_dir=$(git rev-parse --git-path BISECT_LOG)
  [[ ! -e "$git_dir" ]] || die "$(ui_error bisect_in_progress)"

  local index_lock
  index_lock=$(git rev-parse --git-path index.lock)
  [[ ! -e "$index_lock" ]] ||
    die "$(ui_error index_locked)"
}

preflight_signing() {
  local format
  format=$(git config --get gpg.format 2>/dev/null || true)
  [[ "${format:-openpgp}" == openpgp ]] ||
    die "$(ui_error only_openpgp "$format")"

  if [[ -z "$SIGNING_KEY" ]]; then
    SIGNING_KEY=$(git config --get user.signingKey 2>/dev/null || true)
  fi
  [[ -n "$SIGNING_KEY" ]] ||
    die "$(ui_error no_signing_key)"

  command -v gpg >/dev/null 2>&1 || die "$(ui_error gpg_missing)"
  command -v git >/dev/null 2>&1 || die "$(ui_error git_missing)"

  local requested=$SIGNING_KEY
  local key_status fingerprints key_count resolved_key
  key_status=$(
    gpg --batch --with-colons --list-secret-keys -- "$requested" 2>/dev/null
  ) || die "$(ui_error secret_key_missing "$requested")"
  fingerprints=$(
    printf '%s\n' "$key_status" |
      awk -F: '
        $1 == "sec" { await_primary_fpr = 1; next }
        $1 == "ssb" { await_primary_fpr = 0; next }
        await_primary_fpr && $1 == "fpr" {
          print $10
          await_primary_fpr = 0
        }
      '
  )
  key_count=$(printf '%s\n' "$fingerprints" | awk 'NF { count++ } END { print count + 0 }')
  [[ "$key_count" -gt 0 ]] ||
    die "$(ui_error secret_key_missing "$requested")"
  [[ "$key_count" -eq 1 ]] ||
    die "$(ui_error ambiguous_key "$requested")"
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
      die "$(ui_error another_rewrite "$owner")"
    fi
    die "$(ui_error stale_lock "$LOCK_DIR")"
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
    die "$(ui_error cannot_read_commit "$oid")"
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
    die "$(ui_error malformed_commit "$oid")"
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
    die "$(ui_error enumerate_failed)"
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

  [[ -s "$plan" ]] || die "$(ui_error no_matches)"
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
      die "$(ui_error write_commit_failed "$oid")"
    printf '%s %s\n' "$oid" "$new_oid" >>"$mapping"

    verify_created_commit "$new_oid" "$committer_epoch" "$new_headers"

    local new_tree
    new_tree=$(git cat-file -p "$new_oid" | awk '$1 == "tree" { print $2; exit }')
    [[ "$new_tree" == "$COMMIT_TREE" ]] ||
      die "$(ui_error tree_changed "$oid")"
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
      "$(ui_error label_parents "$oid")"
    assert_eq "$author_epoch" \
      "$(git cat-file -p "$new_oid" |
        awk '$1 == "author" { print $(NF-1); exit }')" \
      "$(ui_error label_author_epoch)"
    assert_eq "$committer_epoch" \
      "$(git cat-file -p "$new_oid" |
        awk '$1 == "committer" { print $(NF-1); exit }')" \
      "$(ui_error label_committer_epoch)"
  done <"$plan"

  NEW_HEAD=$(expected_new_head_for_selection "$mapping")
  [[ -n "$NEW_HEAD" ]] ||
    die "$(ui_error no_new_head)"
}

print_plan() {
  local mapping="$WORK_DIR/mapping"
  if [[ "$UI_LANGUAGE" == zh ]]; then
    printf '将在 %s 上改写以下提交：\n' "$CURRENT_BRANCH"
  else
    printf 'Commits to rewrite on %s:\n' "$CURRENT_BRANCH"
  fi
  local old new
  while read -r old new; do
    local subject
    subject=$(git show -s --format=%s "$new")
    printf '  %.12s..%.12s %s\n' "$old" "$new" "$subject"
  done <"$mapping"
  if [[ "$UI_LANGUAGE" == zh ]]; then
    printf '新的 HEAD 候选：%s\n' "$NEW_HEAD"
    printf '备份：refs/backups/git-recommit-sign/%s\n' \
      "${BACKUP_ID:-<dry-run>}"
    printf '未修改任何引用。\n'
  else
    printf 'New HEAD candidate: %s\n' "$NEW_HEAD"
    printf 'Backup: refs/backups/git-recommit-sign/%s\n' \
      "${BACKUP_ID:-<dry-run>}"
    printf 'No references changed.\n'
  fi
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
    die "$(ui_error write_manifest_failed)"
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
    die "$(ui_error read_annotated_tag "$ref")"
  tagger=$(awk '$1 == "tagger" { sub(/^tagger /, ""); print; exit }' "$raw")
  [[ -n "$tagger" ]] || die "$(ui_error tag_no_tagger "$ref")"
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
    [[ -s "$signature" ]] || die "$(ui_error extract_tag_signature "$ref")"
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
    die "$(ui_error write_tag_failed "$ref")"
  if [[ "$signed" -eq 1 ]]; then
    if ! git verify-tag --raw "$new_oid" >/dev/null 2>&1 &&
      [[ "$ALLOW_KEY_TIME_CONFLICT" -ne 1 ]]; then
      die "$(ui_error tag_verify_failed "$ref")"
    fi
    local signed_epoch
    signed_epoch=$(git verify-tag --raw "$new_oid" 2>&1 |
      awk '$2 == "VALIDSIG" { print $5; exit }')
    assert_eq "$tagger_epoch" "$signed_epoch" \
      "$(ui_error label_tag_signature_epoch)"
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
        die "$(ui_error tag_requires_policy "$ref")"
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
        die "$(ui_error tag_verify_failed "$moved_ref")"
      [[ "$tag_verify" == *'[GNUPG:] VALIDSIG '* ]] ||
        die "$(ui_error tag_gpg_no_validsig "$moved_ref" "$tag_verify")"
    fi
    signed_epoch=$(printf '%s\n' "$tag_verify" |
      awk '$2 == "VALIDSIG" { print $5; exit }')
    assert_eq "$tag_epoch" "$signed_epoch" \
      "$(ui_error label_tag_signature_epoch)"
  done <"$tags_requested"

  printf 'update %s %s %s\n' "$CURRENT_REF" "$NEW_HEAD" \
    "$CURRENT_HEAD" >>"$main_transaction"

  cat -- "$main_transaction" "$tags_transaction" \
    "$WORK_DIR/ref-transaction-backups" >"$WORK_DIR/final-transaction"
  if ! {
    printf 'start\n'
    cat -- "$WORK_DIR/final-transaction"
    printf 'prepare\ncommit\n'
  } | if [[ "$UI_LANGUAGE" == zh ]]; then
        git update-ref --stdin >/dev/null
      else
        git update-ref --stdin
      fi; then
    die "$(ui_error ref_transaction_failed)"
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
    die "$(ui_error invalid_backup_id)"
  git rev-parse --verify "$backup_ref/manifest^{blob}" >/dev/null 2>&1 ||
    die "$(ui_error backup_manifest_missing "$backup_ref")"
  [[ -n "$(git for-each-ref --format='%(refname)' \
    "$backup_ref/branches/$CURRENT_BRANCH" 2>/dev/null)" ]] ||
    die "$(ui_error backup_wrong_branch "$CURRENT_BRANCH")"

  local manifest="$WORK_DIR/restore-manifest"
  git cat-file blob "$backup_ref/manifest" >"$manifest"
  local manifest_format expected_branch expected_head
  manifest_format=$(awk -F= '$1 == "format" { print $2; exit }' "$manifest")
  [[ "$manifest_format" == 1 ]] ||
    die "$(ui_error backup_manifest_format "${manifest_format:-<missing>}")"
  expected_branch=$(awk -F= '$1 == "branch" { print $2; exit }' "$manifest")
  expected_head=$(awk -F= '$1 == "head" { print $2; exit }' "$manifest")
  [[ "$expected_branch" == "$CURRENT_REF" ]] ||
    die "$(ui_error backup_branch_mismatch "$expected_branch" "$CURRENT_REF")"
  [[ "$expected_head" =~ ^[0-9a-f]+$ ]] ||
    die "$(ui_error backup_invalid_head)"

  local transaction="$WORK_DIR/restore-transaction"
  : >"$transaction"
  printf 'update %s %s %s\n' "$CURRENT_REF" "$expected_head" \
    "$CURRENT_HEAD" >>"$transaction"

  local backup_tag_ref ref old
  while IFS= read -r backup_tag_ref; do
    [[ -n "$backup_tag_ref" ]] || continue
    ref="refs/tags/${backup_tag_ref#"$backup_ref"/tags/}"
    old=$(git rev-parse --verify "$backup_tag_ref" 2>/dev/null) ||
      die "$(ui_error backup_tag_missing "$ref")"
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
  } | if [[ "$UI_LANGUAGE" == zh ]]; then
        git update-ref --stdin >/dev/null
      else
        git update-ref --stdin
      fi ||
    die "$(ui_error restore_failed)"
  if [[ "$UI_LANGUAGE" == zh ]]; then
    printf '已从 %s 恢复 %s\n' "$backup_ref" "$CURRENT_REF"
  else
    printf 'Restored %s from %s\n' "$CURRENT_REF" "$backup_ref"
  fi
}

run_rewrite() {
  [[ "$TAG_POLICY" == move || "$TAG_POLICY" == keep ||
    "$TAG_POLICY" == abort ]] ||
    usage_error "$(ui_error tag_policy_invalid)"
  [[ "$MESSAGE_SET" -eq 0 || -z "$MESSAGE_FILE" ]] ||
    usage_error "$(ui_error message_conflict --message --message-file)"
  [[ "$EDIT_MESSAGES" -eq 0 || "$MESSAGE_SET" -eq 0 ]] ||
    usage_error "$(ui_error message_conflict --edit-messages --message)"
  [[ "$EDIT_MESSAGES" -eq 0 || -z "$MESSAGE_FILE" ]] ||
    usage_error "$(ui_error message_conflict --edit-messages --message-file)"
  if [[ -z "$RESTORE_ID" && -z "$SELECTION_KIND" ]]; then
    usage_error "$(ui_error selection_required)"
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
    die "$(ui_error yes_required)"

  if [[ -n "${GIT_RECOMMIT_SIGN_TEST_BACKUP_ID:-}" ]]; then
    BACKUP_ID=$GIT_RECOMMIT_SIGN_TEST_BACKUP_ID
  else
    BACKUP_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
  fi
  BACKUP_REF="refs/backups/git-recommit-sign/$BACKUP_ID"
  [[ -z "$(git for-each-ref --format='%(refname)' "$BACKUP_REF")" ]] ||
    die "$(ui_error backup_exists "$BACKUP_ID")"

  create_backup "$WORK_DIR/mapping"
  update_references "$WORK_DIR/mapping"

  local worktree_status
  worktree_status=$(
    git status --porcelain=v1 --untracked-files=all
  ) || die "$(ui_error inspect_worktree_failed)"
  [[ "$worktree_status" == "$FULL_WORKTREE_STATUS" ]] ||
    die "$(ui_error worktree_changed)"

  printf '%s\n' "$(ui_text rewrote \
    "$(wc -l <"$WORK_DIR/mapping")" "$NEW_HEAD")"
  printf '%s\n' "$(ui_text backup "$BACKUP_REF")"
  printf '%s\n' "$(ui_text restore_command "$PROGRAM_NAME" "$BACKUP_ID")"
  printf '%s\n' "$(ui_text push_command "$CURRENT_BRANCH")"
  printf '%s\n' "$(ui_text not_pushed)"
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
      "$(ui_text one_commit)" \
      "$(ui_text inclusive_range)" \
      "$(ui_text all_commits)" \
      "$(ui_text back_option)" \
      "$(ui_text cancel_option)"
    printf '%s: ' "$(ui_text selection_prompt)"
    IFS= read -r choice || choice=q
    case "$choice" in
      1)
        interactive_prompt "$(ui_text commit_prompt)" HEAD
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
        interactive_prompt "$(ui_text range_prompt)" HEAD~1..HEAD
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
      *) printf '%s\n' "$(ui_text invalid_selection)" >&2 ;;
    esac
  done
}

interactive_collect() {
  local value
  interactive_choose_range || return 1

  interactive_prompt "$(ui_text author_filter_name)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  AUTHOR_FILTER_NAME=$INTERACTIVE_VALUE

  interactive_prompt "$(ui_text author_filter_email)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  AUTHOR_FILTER_EMAIL=$INTERACTIVE_VALUE

  interactive_prompt "$(ui_text committer_filter_name)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  COMMITTER_FILTER_NAME=$INTERACTIVE_VALUE

  interactive_prompt "$(ui_text committer_filter_email)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  COMMITTER_FILTER_EMAIL=$INTERACTIVE_VALUE

  interactive_prompt "$(ui_text author_name)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { AUTHOR_NAME=$value; AUTHOR_NAME_SET=1; }

  interactive_prompt "$(ui_text author_email)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { AUTHOR_EMAIL=$value; AUTHOR_EMAIL_SET=1; }

  interactive_prompt "$(ui_text committer_name)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { COMMITTER_NAME=$value; COMMITTER_NAME_SET=1; }

  interactive_prompt "$(ui_text committer_email)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  [[ -z "$value" ]] || { COMMITTER_EMAIL=$value; COMMITTER_EMAIL_SET=1; }

  interactive_prompt "$(ui_text author_date)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  AUTHOR_DATE=$value

  interactive_prompt "$(ui_text committer_date)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  COMMITTER_DATE=$value

  interactive_prompt "$(ui_text message)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ -n "$value" ]]; then
    MESSAGE=$value
    MESSAGE_SET=1
  fi

  interactive_prompt "$(ui_text message_file)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  MESSAGE_FILE=$value

  interactive_prompt "$(ui_text edit_messages)" N ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ "$value" =~ ^[Yy]$ ]]; then
    EDIT_MESSAGES=1
  else
    EDIT_MESSAGES=0
  fi

  interactive_prompt "$(ui_text map_file)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  MAP_FILE=$INTERACTIVE_VALUE

  interactive_prompt "$(ui_text signing_key)" '' ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  SIGNING_KEY=$value

  interactive_prompt "$(ui_text tag_policy)" move ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  TAG_POLICY=$value

  interactive_prompt "$(ui_text allow_time_conflict)" N ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ "$value" =~ ^[Yy]$ ]]; then
    ALLOW_KEY_TIME_CONFLICT=1
  else
    ALLOW_KEY_TIME_CONFLICT=0
  fi

  interactive_prompt "$(ui_text dry_run)" N ||
    { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
  value=$INTERACTIVE_VALUE
  if [[ "$value" =~ ^[Yy]$ ]]; then
    DRY_RUN=1
  else
    DRY_RUN=0
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    interactive_prompt "$(ui_text proceed)" N ||
      { [[ "$INTERACTIVE_CANCELLED" -eq 0 ]] || cancel_and_exit; return 1; }
    value=$INTERACTIVE_VALUE
    [[ "$value" =~ ^[Yy]$ ]] || cancel_and_exit
    ASSUME_YES=1
  fi
}

select_language() {
  local language
  printf '%s\n' 'Select language / 选择语言:' '1) English' '2) 中文'
  printf 'Language/语言 [1]: '
  IFS= read -r language || language=q
  case "$language" in
    ''|1) UI_LANGUAGE=en ;;
    2) UI_LANGUAGE=zh ;;
    q|Q) cancel_and_exit ;;
    *)
      printf 'Invalid language. / 无效语言。\n' >&2
      return 1
      ;;
  esac
}

interactive_main() {
  select_language || return 1
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
  printf '%s\n' "$(ui_text title)"
  while ! interactive_collect; do
    printf '%s\n' "$(ui_text returned_to_menu)"
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
  if [[ -n "$RESTORE_ID" ]]; then
    select_language || return 1
  fi
  run_rewrite
}

main "$@"
