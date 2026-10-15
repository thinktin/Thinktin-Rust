# CLAUDE.md

给在这个仓库里工作的 Claude 看。项目介绍见 [README](README.md)，架构见 [docs/architecture-v3.md](docs/architecture-v3.md)，任务分解见 [docs/wbs.md](docs/wbs.md)。

## 防止工作丢失

云端会话随时可能因为用量限额等原因中断，容器闲置后会被回收，没推送的代码就丢了。下一个 agent 只能看到 GitHub 上的东西，所以：

- **不在 `main` 上直接改。** 开工先建分支；云端会话已经分配了分支就用那个。
- **小步提交，马上推送。** 每完成一个能编译的小步骤，就 commit 并 `git push -u origin <分支>`，不要攒到最后一起推。
- **维护交接文件。** 每个分支在 `docs/progress/<分支名>.md` 记录进度，分支名里的 `/` 换成 `-`。每完成一步就更新，和代码一起提交。格式：

  ```markdown
  # <分支名>
  目标：……
  已完成：……
  进行中：……
  下一步：……
  坑和决定：……
  ```

## 接手别人的工作

1. 用户指定了分支就用那个；没指定就 `git fetch origin`，再用 `git branch -r --sort=-committerdate | head` 找最近有动静的分支。
2. `git checkout <分支>`，读 `docs/progress/<分支名>.md` 和 `git log --oneline -20`。
3. 先跑一遍构建和测试确认现状，再从"下一步"接着做。

## 常用命令

- 构建：`cargo build --workspace`
- 测试：`cargo test --workspace`
- 格式化：`cargo fmt --all`
- 检查：`cargo clippy --workspace --all-targets`
