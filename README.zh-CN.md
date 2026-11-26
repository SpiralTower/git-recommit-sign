# git-recommit-sign

中文 | [English](README.md)

`git-recommit-sign.sh` 用于批量改写当前分支上的选定提交，并重新生成
OpenPGP 签名。它可以替换 author/committer 身份、日期和提交消息，
同时重建命中提交的所有后代、迁移本地标签、创建备份，且不自动推送。

## 环境要求

- Linux、Bash 4.4+
- Git 2.43+
- GnuPG 2.4+，并有可用的 OpenPGP 私钥
- 当前必须检出本地分支，工作树和索引必须干净

测试会在临时仓库和临时 `GNUPGHOME` 中生成过去的测试密钥，
不会改写真实历史。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SpiralTower/git-recommit-sign/main/git-recommit-sign.sh)
```

交互流程会依次询问范围、四个身份筛选条件、身份与日期替换、消息或
消息文件、逐提交 TSV、签名密钥、标签策略和密钥时间冲突开关。
dry-run 会直接显示计划；正式执行前还会要求最终确认。
`b` 返回主菜单，`q` 取消。

预览单个提交的改写：

```bash
./git-recommit-sign.sh --commit HEAD --message "fix: rewrite history" --dry-run
```

正式改写整条分支，并迁移本地标签：

```bash
./git-recommit-sign.sh --all --message "fix: align identity" --yes
```

非交互写引用必须带 `--yes`。`--dry-run` 只在临时位置创建对象并预览，
不会更新分支、标签或备份引用。

## 选择范围

以下范围参数互斥，必须选择一个：

- `--commit <rev>`：单个提交；统一消息替换只用于该提交。
- `--range <FROM..TO>`：选择 `FROM` 到 `TO` 的闭区间历史平面。
  会选中 `FROM` 以及从 `TO` 可达的提交，但排除从 `FROM` 的任一父提交
  可达的祖先。两端都必须能从当前分支 tip 到达。
- `--all`：当前 `HEAD` 可达的全部提交，包括已合并旁支。

可选的精确身份筛选：

```text
--author-filter-name <name>
--author-filter-email <email>
--committer-filter-name <name>
--committer-filter-email <email>
```

多个条件按 AND 组合。姓名和邮箱为完整字符串、区分大小写。
作者条件只检查 author，提交者条件只检查 committer。
未提供任何条件时，范围内全部提交命中。

命中提交的所有后代都会重建，使父链指向新对象；后代自己的身份、
日期和消息保持原值，仅父哈希和签名更新。merge 提交的全部 parents
都会保留。

## 替换字段

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

未提供的身份字段逐提交保留。日期必须是带时区偏移的绝对时间，例如：

```text
2024-02-03T04:05:06-05:00
```

提供统一日期时，所有命中提交共用同一 epoch 和时区。
`--message-file` 按字节复制，包括缺失的末尾换行。
`--edit-messages` 会用 `$GIT_EDITOR` 逐条编辑命中消息；
未命中的后代不会进入编辑器。

### 逐提交 TSV

`--map <tsv>` 固定四列，必须以制表符分隔：

```text
commit	author_date	committer_date	message_file
<完整oid>	2024-01-01T00:00:00Z	2024-01-02T00:00:00Z	/path/msg
<完整oid>	2024-03-01T00:00:00Z		/path/msg
```

空字段回退到对应命令行统一值，再回退到原值。map 中的消息文件
优先于全局消息；字段不能用空格代替制表符。

## 签名与标签

`--signing-key` 指定 OpenPGP 私钥，未提供时读取 `user.signingKey`。
只支持 OpenPGP，`gpg.format` 必须为 `openpgp` 或未设置。

新提交直接基于 `git cat-file commit` 的字节构建，不使用 `git show`
重新序列化。无签名载荷使用目标 committer epoch 签名，按 Git 的
`gpgsig` 续行格式嵌入，并要求 `git verify-commit` 出现 `VALIDSIG`，
且签名 epoch 等于 committer epoch。

已签名附注标签会剥离旧签名，使用原 tagger 身份和 epoch 重签，
并通过 `git verify-tag` 验证。

`--tag-policy` 处理指向重建提交的本地标签：

- `move`（默认）：移动轻量标签，重写附注标签。
- `keep`：保留旧标签。
- `abort`：更新任何引用前直接失败。

签名只能记录一个时间：提交签名跟随 committer 时间，author 时间可以
不同。当目标 epoch 早于密钥创建时间时，必须显式使用危险开关
`--allow-key-time-conflict`。该模式用 GnuPG 验证 detached signature
和 epoch，但 Git 自带验签仍可能拒绝，脚本会打印警告。

## 备份、恢复与安全

正式更新前会创建：

```text
refs/backups/git-recommit-sign/<UTC timestamp>-<pid>/
```

其中保存原分支 tip、受影响标签及包含原/新对象映射的 manifest。
分支和标签通过一次 `git update-ref --stdin` 事务更新；prepared 事务失败
或 hook 拒绝时，分支和标签都不会被部分更新。

恢复命令：

```bash
./git-recommit-sign.sh --restore <backup-id>
```

恢复前会校验 manifest 和当前分支。成功后备份引用保留。脚本还会：

- 创建仓库级并发锁；
- 拒绝进行中的 merge/rebase/cherry-pick/revert/bisect；
- 拒绝脏工作树和索引；
- 不调用 `git commit` 改写源仓库；
- 不自动 push，只输出 `git push --force-with-lease` 指引。

请手动检查并执行推送命令。