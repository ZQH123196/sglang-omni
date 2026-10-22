---
name: upstream-sync
description: 把 main 更新到最新上游、把 my-deploy 部署层重放到最新上游的标准操作。当用户说「更新到上游」「同步上游」「拉一下上游」「把 my-deploy 更到最新」时执行本流程。
---

# 上游同步 SOP

## 分支约定

| 引用 | 角色 | 规则 |
|---|---|---|
| `upstream` | sgl-project/sglang-omni | 只读来源，禁止向其推送 |
| `origin` | 自己的 fork (ZQH123196) | `main` 只是镜像，`my-deploy` 才是工作分支 |
| `main` | 上游镜像 | **永远不含本地提交**，只能 `merge --ff-only upstream/main` |
| `my-deploy` | 部署层分支 | 同步后为 **main + 1 个压缩提交**；两次同步之间可追加部署修正提交，下次同步时一并压入 |

不变式（每次同步后自检）：

```bash
git log --oneline main..my-deploy   # 同步刚完成时恰好 1 条
git status --short                  # 必须为空
```

## 流程

### 1. 更新 main（纯快进，不做任何手工改动）

```bash
git checkout main
git fetch upstream --prune
git merge --ff-only upstream/main
```

失败即说明 main 有本地提交，先停下来问用户，不要 merge、不要 rebase。

### 2. 同步前预检（只读，不改工作区）

```bash
git log --oneline main..my-deploy                     # 自有提交（历史遗留可能多条）
git diff --stat main...my-deploy                      # 部署层碰了哪些文件
git merge-tree --write-tree --messages main my-deploy # 三方合并是否干净
```

- `merge-tree` 返回 commit-id 且无 `CONFLICT` → 文本层零冲突，记下这个 tree 作为校验基准。
- 有冲突 → 把冲突文件逐个报给用户，先确认处理口径再动手。

冲突面只看交集：`main..my-deploy` 改过的文件 ∩ 上游这轮改过的文件。同名文件不等于同行冲突，用 hunk 坐标判断：

```bash
git diff beb886aab..main -- <file> | grep -E '^@@'          # 上游改动区间（旧文件坐标）
git diff main...my-deploy -- <file> | grep -E '^@@'         # 部署层插入点（同一坐标系）
```

插入点落在上游各 hunk 之间即安全。

### 3. 重放（压缩成单提交）

标准口径是**压成一个提交**，不是 rebase。rebase 会让 `omni_scheduler.py` 这类被上游重写的文件在每个提交里反复解冲突。

```bash
git tag -a backup/my-deploy-YYYYMMDD my-deploy -m "重放前备份 (<旧 HEAD 短 sha>)"
git checkout my-deploy
git merge --squash main          # 得到正确三方合并树，停在不提交
git write-tree                   # 应与第 2 步 merge-tree 的 tree 一致
git reset --soft main            # 把树挂到 main 之上
git commit -F - <<'EOF'
chore(deploy): 部署层重放到 upstream/main(YYYY-MM-DD)

把 my-deploy 的部署层提交压缩为单个提交，重挂到 main@<sha>
之上。合并无冲突，两侧改动均保留。
...
EOF
```

**顺序不可颠倒**：必须在 `merge --squash` 之后才 `reset --soft main`。先 reset 会把旧分支整棵树塞进暂存区，等于反向回滚上游几百个提交（2026-10-22 踩过）。

### 4. 校验

```bash
# 树一致性
git rev-parse HEAD^{tree}        # == 第 2 步 merge-tree 的 tree

# 部署层内容等价：diff 里只应出现上游漂移，不应出现部署层丢失
git diff --stat backup/my-deploy-YYYYMMDD HEAD -- <部署层文件列表>

# 不变式
git log --oneline main..my-deploy
```

AST 级语义校验（本机通常无 venv，跑不了 import）：

- 语法：`ast.parse` 逐个解析改动的 py 文件
- 交叉引用：插入方法里 `self.X` 是否在类体 / `__init__` 中有定义
- 钩子挂载点：确认 `get_new_batch_prefill()` 这类被上游可能重写的方法仍存在
- 账本链路：写入端（`data[...]` / `req.<attr>`）与读取端（`getattr(req, ...)`）两端都在
- 依赖符号：调用到的 helper 是否仍有定义（历史坑：`2001d8645 重放遗留的 helper 名断裂`）

无 venv 就不要声称「已验证运行」，如实说明只做了静态校验，并提示上机跑一次 `bash start_tts.sh`。

### 5. 推送（先问）

压缩会产生分叉，`my-deploy` 需要强推：

```bash
git push --force-with-lease origin my-deploy
```

`main` 的快进推送无风险，可直接 `git push origin main`。推送前必须问用户。

## 已知现象

- `git fetch upstream` 会打印 `files` backend / 无法存引用 的警告，属正常，只影响个别远端分支引用，不影响 `upstream/main`。
- `start_tts.sh` 不做 `git pull`：部署机若在启动时拉取，压缩重写的历史会让 pull 撞分叉。同步一律人工执行。
- `CLAUDE.md` 是 `AGENTS.md` 的软链，改其一即可。
- backup tag 命名沿用 `backup/my-deploy-YYYYMMDD`，仓库里已有 `20261007` / `20261017` / `20261022`。

## 提交信息模板

```
chore(deploy): 部署层重放到 upstream/main(YYYY-MM-DD)

把 my-deploy 的部署层提交压缩为单个提交，重挂到 main@<sha>
（上游 YYYY-MM-DD 最新）之上。合并无冲突，两侧改动均保留。

带入的部署层能力：
- <按模块列>

压缩前的完整历史保留在 tag backup/my-deploy-YYYYMMDD。
```
