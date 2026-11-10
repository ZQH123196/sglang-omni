# 更新到上游（人读版）

本文件放在仓库根目录，是给人看的操作手册。`docs/` 目录完全属于上游，我们不维护、不阅读、不关心其中内容；找部署流程只看本文件。Agent 执行时读 `.claude/skills/upstream-sync/SKILL.md`，两份流程需保持一致；不一致时以本文件为准并同步修正 SKILL.md。

## 定位（先读这一段）

- 本 fork 是**纯部署**用途。只做让服务在部署机上跑通的适配，不做上游开发。
- **永不向上游提交任何东西**：不向 `upstream` 推送、不发 PR、不提 issue、不把部署层回灌上游。`upstream` 只读。
- **不遵循原项目的开发/贡献要求**：上游的编码规范、日志语言、类型约束、CI / pre-commit、测试与文档约定，都是写给「向上游贡献代码」的人的，对部署适配无约束力。唯一标准是部署能跑、行为正确、改动可追溯。
- 所有自有变更只落在 `my-deploy`（对应 `origin/my-deploy`）。`main` 永远是上游镜像，不含任何本地提交。
- 上游目录（`docs/` 等）在同步时被覆盖属预期，不要在那里做部署适配。

## 分支约定

| 引用 | 角色 | 规则 |
|---|---|---|
| `upstream` | sgl-project/sglang-omni | 只读来源，禁止推送 |
| `origin` | 自己的 fork (ZQH123196) | `main` 只是镜像，`my-deploy` 才是工作分支 |
| `main` | 上游镜像 | 永远不含本地提交，只能 `merge --ff-only upstream/main` |
| `my-deploy` | 部署层分支 | 同步后为 **main + 1 个压缩提交**；两次同步之间可追加部署修正提交，下次同步时一并压入 |

不变式（每次同步后自检）：

```bash
git log --oneline main..my-deploy   # 同步刚完成时恰好 1 条
git status --short                  # 必须为空
```

## 流程

### 0. （可选）重放前压缩自有变更

**酌情做，不影响正确性。** 第 3 步本来就会把所有自有提交压成一个；这一步只是先把两次同步之间攒下的多个部署修正提交收敛成 1 个，便于 review `main...my-deploy` 的部署层 diff、让备份更清爽。提交少、diff 清楚时可以跳过。

**必须在 `main` 快进之前做**，且 base 必须是压缩前的旧上游基线：

```bash
git status --short                      # 必须为空, 别把未提交改动混进去
git checkout my-deploy
OLD_MAIN=$(git rev-parse main)          # 记下旧上游基线
git tag -a backup/pre-sync-YYYYMMDD my-deploy -m "压缩前备份 (<旧 HEAD 短 sha>)"
git reset --soft "$OLD_MAIN"            # 只移 HEAD, index/worktree 不变
git commit -m "chore(deploy): 压缩部署层变更(YYYY-MM-DD)"
git log --oneline "$OLD_MAIN"..my-deploy   # 恰好 1 条
git diff --stat "$OLD_MAIN"..HEAD          # 部署层改动应与压缩前一致
```

**坑**：`main` 一旦快进到新上游，就**不能**再 `git reset --soft main` 来压缩。那会把旧部署树（不含新上游内容）挂到新基线上提交，等于反向回滚上游几百个提交（2026-10-22 踩过）。若 `main` 已快进，改用上面记录的 `OLD_MAIN` 这个 sha 作为 base，或者干脆跳过本步直接走第 3 步。

### 1. 更新 main（纯快进，不做任何手工改动）

```bash
git checkout main
git fetch upstream --prune
git merge --ff-only upstream/main
```

失败即说明 `main` 有本地提交，先停下来查清楚，不要 merge、不要 rebase。

### 2. 同步前预检（只读，不改工作区）

```bash
git log --oneline main..my-deploy                     # 自有提交（做过第 0 步则为 1 条）
git diff --stat main...my-deploy                      # 部署层碰了哪些文件
git merge-tree --write-tree --messages main my-deploy # 三方合并是否干净
```

- `merge-tree` 返回 commit-id 且无 `CONFLICT` → 文本层零冲突，记下这个 tree 作为校验基准。
- 有冲突 → 把冲突文件逐个列出来，先确认处理口径再动手。

冲突面只看交集：`main..my-deploy` 改过的文件 ∩ 上游这轮改过的文件。同名文件不等于同行冲突，用 hunk 坐标判断：

```bash
git diff <旧基线sha>..main -- <file> | grep -E '^@@'   # 上游改动区间（旧文件坐标）
git diff main...my-deploy -- <file> | grep -E '^@@'    # 部署层插入点（同一坐标系）
```

`<旧基线sha>` 取第 0 步记录的 `OLD_MAIN`；若跳过第 0 步，用 `git merge-base my-deploy main` 取（`main` 快进后它仍指向分叉点）。插入点落在上游各 hunk 之间即安全。

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
...
EOF
```

**顺序不可颠倒**：必须在 `merge --squash` 之后才 `reset --soft main`。先 reset 会把旧分支整棵树塞进暂存区，等于反向回滚上游几百个提交。

### 4. 校验

```bash
git rev-parse HEAD^{tree}        # == 第 2 步 merge-tree 的 tree
git diff --stat backup/my-deploy-YYYYMMDD HEAD -- <部署层文件列表>
git log --oneline main..my-deploy
```

AST 级静态校验（本机通常无 venv，跑不了 import）：

- 语法：`ast.parse` 逐个解析改动的 py 文件。
- 交叉引用：插入方法里 `self.X` 是否在类体 / `__init__` 中有定义。
- 钩子挂载点：`get_new_batch_prefill()` 这类被上游可能重写的方法仍存在。
- 账本链路：写入端（`data[...]` / `req.<attr>`）与读取端（`getattr(req, ...)`）两端都在。
- 依赖符号：调用到的 helper 是否仍有定义（历史坑：`2001d8645 重放遗留的 helper 名断裂`）。

无 venv 就不要声称「已验证运行」，如实说明只做了静态校验，并提示上机跑一次 `bash start_tts.sh`。

### 5. 推送（先问）

压缩会产生分叉，`my-deploy` 需要强推：

```bash
git push --force-with-lease origin my-deploy
```

`main` 的快进推送无风险，可直接 `git push origin main`。**任何推送前都要先向操作者确认。** 绝不向 `upstream` 推送。

## 提交信息模板

```
chore(deploy): 部署层重放到 upstream/main(YYYY-MM-DD)

把 my-deploy 的部署层提交压缩为单个提交，重挂到 main@<sha>
（上游 YYYY-MM-DD 最新）之上。合并无冲突，两侧改动均保留。

带入的部署层能力：
- <按模块列>

压缩前的完整历史保留在 tag backup/my-deploy-YYYYMMDD。
```

## 已知现象

- `git fetch upstream` 会打印 `files` backend / 无法存引用 的警告，属正常，只影响个别远端分支引用，不影响 `upstream/main`。
- `start_tts.sh` 不做 `git pull`：部署机若在启动时拉取，压缩重写的历史会让 pull 撞分叉。同步一律人工执行。
- `CLAUDE.md` 是 `AGENTS.md` 的软链，改其一即可。
- backup tag 命名沿用 `backup/my-deploy-YYYYMMDD`，仓库里已有 `20261007` / `20261017` / `20261022`。
- `docs/` 属上游，同步时被覆盖是正常的，不要在里面写部署说明。
- `Voxt/docs/MLXAudioDependency.md` 里有一套「普通 merge 保留祖先、不要 squash」的说法，那是 Voxt 子项目自己的结论，与本仓库口径相反，别混用。
