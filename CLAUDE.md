# CLAUDE.md

给在这个仓库里工作的 Claude 看。项目介绍见 [README](README.md)，架构见 [docs/architecture-v3.md](docs/architecture-v3.md)，任务分解见 [docs/wbs.md](docs/wbs.md)。

## 防止工作丢失

云端会话随时可能因为用量限额等原因中断，容器闲置后会被回收，没推送的代码就丢了。下一个 agent 只能看到 GitHub 上的东西，所以：

- **不在 `main` 上直接改。** 开工先建分支；云端会话已经分配了分支就用那个。
- **小步提交，马上推送。** 每完成一个能编译的小步骤，就 commit 并 `git push -u origin <分支>`，不要攒到最后一起推。
- **维护交接文件。** 后端主线分支 `backend-core` 的进度统一记在 [docs/progress.md](docs/progress.md)（已完成表格、“进行中”和认领规则：开工前写“谁在做、几点开始”并马上推送，两小时内有人认领的包不要重做）。其他分支在 `docs/progress/<分支名>.md` 记录进度，分支名里的 `/` 换成 `-`。每完成一步就更新，和代码一起提交。格式：

  ```markdown
  # <分支名>
  目标：……
  已完成：……
  进行中：……
  下一步：……
  坑和决定：……
  ```

## 自动保存

`.claude/hooks/autosave.sh` 兜底（在 `.claude/settings.json` 里注册为 PostToolUse 钩子）：云端会话里每次改完文件，它把整个工作区（包括没提交、没跟踪的文件）做成快照，强制推送到 GitHub 的 `autosave/<分支名>`。当前分支的历史和暂存区不动，所以照常自己提交。

- 只在云端会话（`CLAUDE_CODE_REMOTE=true`）生效；在分离头指针、合并或变基进行中时跳过。
- 设环境变量 `CLAUDE_AUTOSAVE=0` 关闭。日志在 `.git/autosave.log`。
- 快照会推送所有没被 `.gitignore` 忽略的文件，密钥不要放进仓库目录。
- 分支合并后删掉对应的 `autosave/<分支名>`。

## 接手别人的工作

1. 用户指定了分支就用那个；没指定就 `git fetch origin`，再用 `git branch -r --sort=-committerdate | head` 找最近有动静的分支。
2. 如果有 `origin/autosave/<分支名>`，说明上个会话可能留下了没推送的改动，先恢复：`.claude/hooks/autosave.sh --restore <分支名>`。它会切到分支、把快照里没提交的改动放回工作区；分支在快照之后又有新提交时会拒绝，需要手动处理。
3. 没有快照就直接 `git checkout <分支>`。然后读进度文件（`backend-core` 是 `docs/progress.md`，其他分支是 `docs/progress/<分支名>.md`）和 `git log --oneline -20`。
4. 先跑一遍构建和测试确认现状，再从"下一步"接着做。

## 常用命令

- 构建：`cargo build --workspace`
- 测试：`cargo test --workspace`
- 格式化：`cargo fmt --all`
- 检查：`cargo clippy --workspace --all-targets`
