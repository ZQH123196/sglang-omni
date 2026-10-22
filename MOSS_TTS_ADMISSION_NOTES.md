# MOSS-TTS 长文本容量准入 — 设计说明

## 背景与问题

生产场景：6000+ 中文字符长文本 TTS，高并发，非流式，H200 部署。

早期上游版本存在以下限制叠加导致服务不可用：
1. `MAX_SPEECH_INPUT_CHARS=4096` → 超长文本直接 HTTP 400 拒绝
2. `MOSS_TTS_DEFAULT_CONTEXT_LENGTH=8192` → KV 窗口不够 prefill 长文本
3. `max_prefill_tokens=min(context,8192)` → prefill chunk 截断
4. `MOSS_TTS_DEFAULT_MAX_NEW_TOKENS=4096` → 生成帧数被截断（6K 中文 ≈ 37500 帧）
5. `post_prefill` 跳过纯 prefill batch 的首帧采样 → 并发满时产出 0s 音频
6. 无准入控制 → 并发打满 KV cache → 级联失败

## 当前解决状态（2026-10-17 rebase 后）

| 原始问题 | 当前解法 | 位置 | 是否仍需自定义代码 |
|---|---|---|---|
| 输入字符限制 | 上游 `max_speech_input_chars=None`，无字符限制 | `moss_tts/config.py:105` | **已不需要** |
| Context 窗口过小 | 上游 `resolve_moss_tts_context_length()` 从模型 config.json 读取（Qwen3-8B=32768） | `hf_loading.py` | **已不需要** |
| max_prefill_tokens 过小 | YAML 显式设 35000 | `moss_tts_prod.yaml` | 配置项，非代码 |
| max_new_tokens 截断 | `MOSS_TTS_DEFAULT_MAX_NEW_TOKENS=35000` | `request_builders.py` | **自定义，必要** |
| 不支持的语言进队列 | `speech_budget` 白名单在 preprocess 阶段抛 `UnsupportedLanguageError` | `request_builders.py` + `speech_budget.py` | **自定义，保留** |
| 语速估算偏差 | `SpeechRateCalibrator` 按语言回喂实际帧数 | `speech_budget.py` | **自定义，保留** |
| post_prefill 0s 音频 | ~~移除 `is_prefill_only` 早返回~~ → **已让位上游**，靠 `max_running_requests` 控并发 | `model_runner.py` | 已移除，见「同步记录」 |
| 无准入控制 → KV 打爆 | 容量预留 + 语速标定 + rebalance 账本，**重挂到上游新版 `get_new_batch_prefill` 开头** | `omni_scheduler.py` + `speech_budget.py` | **自定义，核心设计，保留** |

## 自定义架构三层

### 第一层：引擎容量（YAML 配置）

```yaml
# examples/configs/moss_tts_prod.yaml
stages:
  tts_engine:
    gpu_memory_fraction: 0.60
    engine:
      max_running_requests: 64
      max_prefill_tokens: 35000
```

- `gpu_memory_fraction`：AR 阶段能占整卡的比例，决定 KV 池大小，也是账本的分母；显式写死，不依赖上游默认
- `max_running_requests`：引擎调度池大小，决定最大同时 in-flight 请求数
- `max_prefill_tokens`：允许一次 prefill 消化多少 token（6K 中文 ≈ 6K-12K tokens + ref audio）
- `context_length`：由模型 metadata 自动推导（32768），无需覆盖

`MOSS_TTS_DEFAULT_MAX_NEW_TOKENS=35000`（request_builders.py）：当客户端不传 `max_new_tokens` 时的生成帧上限。6K 中文字在 25fps 下约需 37500 帧，所以天花板必须 ≥ 文本预估帧数。若客户端总传 `token_count` 则可降回 4096。

### 显存预算与上游 #2859 的默认值（2026-10-22 起）

colocated 布局分三段预算：preprocessing `0.10` + AR `0.60` + vocoder `0.18` = `0.88`，剩 12% 留给图捕获与激活。

上游 `#2859`（`53ea26787`，随 2026-10-22 同步进入）同时改了四件事：AR 预算 `0.72 → 0.60`、
MOSS factory 默认开 async decode（batch ≥2 生效、`async_decode_mode: nonstream`）、
colocated 下 prefill 精确长度图 1–512、vocoder 单段图 ≤128 帧。

**我们的取舍：三项默认全保留，0.60 显式钉进两份 YAML。** 依据是本仓库的生产场景就是高并发非流式，
正好落在该 PR 收益最大的一档（H100 实测非流式 c64 吞吐 21.63 → 34.38 req/s，+58.9%；c1 仅 +10%）。
代价同源：启动 +40s、峰值显存 +3.7GiB、图捕获从 152 涨到 19236 次（每个 prefill 长度一张图）。

容量变化（账本的分母）：
- 80G 卡：AR `0.72 × 80 = 57.6G` → `0.60 × 80 = 48.0G`
- 48G 卡：`34.6G` → `28.8G`

账本按池子实时余额放行，池子缩小**不会溢出**，但会直接表现为 `speech-admit defer` 变多、排队变长。
`max_running_requests`（64 / 8）与语速表、`SAFETY_FACTOR` 是按旧池子调的，缩池后需复测。

**若某档要换回容量**：只关图不会自动回到 0.72，必须两者都改。

```yaml
stages:
  tts_engine:
    gpu_memory_fraction: 0.72
    engine:
      cuda_graph_backend_prefill: disabled
```

48G 档并发仅 8，吃不到 lookahead 收益却同样付容量与启动成本；该档出现频繁 defer 时应优先走上面这条。

**不用担心的**：lookahead 让 `len(req.output_ids)` 落后半步，账本 `remaining = 估算 − 已解码`
因此每请求多留约 1 帧，方向保守（64 并发合计 ≈64 token）；`nonstream` 模式下流式与混合批次
完全同步，流式延迟曲线不变。

### 第二层：准入控制（omni_scheduler + speech_budget）

**speech_budget.py — 输出帧数估算器**

不是"调节语速"，是"预估一段文本将消耗多少 KV 空间"。按语言维护 `chars_per_frame` 比值：
- 默认值来自基准测试
- 运行时观察已完成请求（输入字符数, 实际生成帧数），≥5 样本后自动修正
- 滑动窗口 50 样本，剔除偏离均值 50% 的离群值
- 持久化到 `./.cache`，重启复用
- 白名单校验在 `preprocess_moss_tts_payload` 入口，白名单外抛 `UnsupportedLanguageError`，请求不进调度、不占队列与池子

**omni_scheduler.py — 容量预留账本**

- 请求进入 `get_new_batch_prefill` 前，按估算帧数 + 输入 token 数预留 KV 空间
- 预留不够 → defer（放入等待队列），不浪费引擎调度 slot
- 请求完成/abort → 释放预留，触发 rebalance 事件把 deferred 请求放回
- 利用 radix tree 前缀命中计算真实增量（ref audio 相同则不重复预留）

**为什么非要有这层**：上游不看 KV 池的实时余量（其 `omni_scheduler.py` 里 `available_size()`
命中 0 次），只有两道粗粒度闸门——`max_running_requests` 管**行数**，`request_kv_capacity_error`
管**单个请求**的 `input_len + max_new_tokens <= max_req_len`（自 `dde550c23`，2026-05-18 就有，
不是本轮新增）。两者都不阻止"64 个并发各自要生成数万帧"的**叠加**占用，所以 `prod` 配 64 并发
跑长文本时必须靠账本兜住。

**同步时怎么挂**：账本与上游的 prefill coalesce 是两个正交关注点，不冲突。新版只在
上游 `get_new_batch_prefill` 的**最前面**加 2 行，其余全部委托上游：

```python
self._rebalance_speech_deferred()
self._defer_unadmittable_prefill_requests()
waiting = self.prefill_coalesce_waiting_requests(running_batch)   # 上游原样
```

顺序要求：账本先跑，把不放行的请求移出 `waiting_queue`，上游 coalesce 的"最老请求截止期"
才只度量真正待批的请求。以后重放**必须保持账本在这三行之前**，挂在 `else` 分支或
`_Upstream` 调用之后都会让预留失效。

### 第三层：post_prefill 首帧修复（已让位上游）

上游两个 `model_runner.py` 的 `post_prefill` 中：
```python
if schedule_batch.is_prefill_only:
    return  # ← BUG: 跳过首帧采样
```
并发打满时纯 prefill batch 高频出现，跳过后导致 pending_feedback_queue 为空 → 全 0 embeds → 垃圾 logits → argmax 命中 im_end → 立即 EOS → 0s 音频。

**2026-10-17 起本分支采用上游实现，不再修改此处**；上游至今仍有该早返回（`8220d2207` 只改了 `custom_prefill_forward`，没碰 `post_prefill`）。所以该故障模式重新可见，唯一兜法是 `max_running_requests`：纯 prefill batch 是并发打满的产物，把并发上限留在不触发它的区间（48G 档 8、prod 档 64）。注意上游 `fa4e6d1f1` 的 prefill coalesce 正是为了一次攒够多个请求放 prefill，纯 prefill batch 不会因此变少。

原修复：删除两处 early return，见 `backup/my-deploy-20261017`。

## 历史决策备忘

以下值曾被设为 35000，现已回退到上游默认。若未来上游 regression 可参考恢复：

- `MAX_SPEECH_INPUT_CHARS`（schema.py:79）：原上游 4096，曾改 35000。
  现在 MOSS-TTS 通过 `config.py: max_speech_input_chars=None` 完全跳过字符检查。
  **若未来上游取消 None 分支或改了逻辑，且需要支持 6K+ 中文，需重新提高此值。**

- `MOSS_TTS_DEFAULT_CONTEXT_LENGTH`（hf_loading.py:21）：原上游 8192，曾改 35000。
  现在模型 config.json 报 32768，fallback 永不触发。
  **若上游模型换了 config 格式导致 metadata 失效，此值会被使用。**
  更可靠的做法是通过 YAML `engine.context_length: 35000` 或 CLI `--context-length` 显式覆盖。

## 配置文件对照

| 场景 | 配置文件 | 关键参数 |
|---|---|---|
| A100-80G / H100 / H200 (80G+) | `moss_tts_prod.yaml` | gpu_fraction=0.60, max_running=64, prefill=35000 |
| A6000 (48G) | `moss_tts_48gb.yaml` | gpu_fraction=0.60, max_running=8, prefill=16384 |
| RTX 5090 (32G) | `moss_tts_32gb.yaml`（上游） | single-process, concurrency=1 |
| RTX 4090 (24G) 及以下 | `moss_tts_24gb.yaml`（上游） | single-process, concurrency=1 |

分档由 `start_tts.sh` 按 `nvidia-smi` 报的 **MiB** 判定：`>=80000` prod、`>=46000` 48gb、
`>=30000` 32gb、其余 24gb。用 MiB 而不是 GB 是因为整除截断会把 80G 卡（81920 MiB）算成
79/80 GB，从而误落到 48G 配置。

## 部署注意

- 启动脚本 `start_tts.sh` 仅做环境准备 + `sgl-omni serve --config <选配的yaml>`
- `MOSS_TTS_AUDIO_TOKENIZER` 环境变量指向本地 codec 权重目录（脚本中 export）
- sglang 0.5.19+ 已原生支持所需 flash-attn 路径，旧 Blackwell 兼容 workaround 不再需要

### 已核实事实：模型目录大小写不是问题，勿再上报

- `start_tts.sh:42` 写的 `OpenMOSS-Team/Moss-TTS-v1.5` 与服务器上真实目录名一致。依据：该
  脚本已用于生产部署并通过 6k 长文本并发测试（提交 `6be9e057b`）；若大小写对不上，加载
  模型那一刻就会失败，跑不到并发。
- `docs/cookbook` 与两份 YAML 里的 `MOSS-TTS-v1.5` 是 HuggingFace Hub 上的规范 repo id，
  不是我们镜像到 `$MODEL_ROOT_DIR` 后的目录名。目录名由我们自己的下载方式决定。
- YAML 的 `model_path` 在 `start_tts.sh` 这条启动路径上是死值，`--model-path` 覆盖它。
  生效值与不生效值拼写不同，不构成缺陷。
- 方法论约束（写给后续审查）：仓库里看不到那台服务器的文件系统。任何"路径大小写不匹配会
  导致启动失败"的结论，必须以服务器 `ls` 的实际结果为依据；仅凭仓库内两处文本拼写不一致
  就上报该问题，属于无效推断，不要再提。

## 同步记录（2026-10-17，上游基线 `beb886aab`）

上游自上次重放的基线 `4a3e962a9` 前进 173 个 commit。本次原则：**结构让位上游，只留数字配置与上游确实没有的能力。**

### 让位上游（本分支已删除的自定义代码）

| 内容 | 让位给 | 后果 |
|---|---|---|
| `get_new_batch_prefill` 内的 prefill coalesce 改写 | `fa4e6d1f1` 拆分出的 `is_prefill_expected` / `prefill_coalesce_waiting_requests` / `prefill_coalesce_holds` | 无功能损失；上游实现还带 `81ad9eb1b` 的 session 行复用 |
| `post_prefill` 首帧修复（`moss_tts` 与 `moss_tts_local` 两处） | 上游保留 `is_prefill_only` 早返回 | 0s 音频故障模式重新可见，靠 `max_running_requests` 兜 |

### 未让位：KV 容量预留账本（重挂保留）

账本（`_speech_effective_free` 等 6 个 helper + `_speech_deferred` 队列 + rebalance + abort 清理）
与上游的 coalesce 重构是**正交**的，不构成冲突，因此不需要让位。上游也没有等价物——它不看
池子实时余量（`available_size()` 命中 0 次），只有行数上限与单请求上限两道粗闸门。
它按上游新结构重挂在上游 `get_new_batch_prefill` 开头，挂载契约见「第二层」。

**一次错误决策的记录**：同步过程中曾因"`_resolve_token_count` 在本分支上是未定义名、
`_estimate_moss_tts_speech_frames` 必抛 `NameError`"而推断这套账本从未生效，并据此删除了它。
该推断无效——`backup/my-deploy-20261007` 与 `backup/my-deploy-remote-eab5768` 里 helper 仍是
私有名且定义齐全，账本挂载调用也在，是已通过 6k 长文本并发的生产树；断的只有
`ef14c12bd` 重放之后的这一棵。**"这个 commit 上跑不通"不等于"这个功能没生效过"，
更不构成删除核心功能的理由。** 已恢复。

### 修掉的一个静默回归

`ef14c12bd` 那次重放把 `_resolve_token_count` / `_resolve_optional_text` 的调用带进了新树，
而上游在 `4a3e962a9` 已把这两个 helper 改为公开名 `resolve_token_count` / `resolve_optional_text`。
调用点位于本分支新增函数内部，git 按纯新增处理、**不报冲突**，于是 `NameError` 一直潜伏到运行期：
白名单校验、帧数估算、以及依赖估算的整条账本，在 `my-deploy`（`89ddd0895`）上都是坏的。

> 教训：**每次重放后必须核对本分支新增代码所引用的上游符号名，git 没报冲突不等于没断。**

### 保留（上游没有的能力）

- KV 容量预留账本 + rebalance（`omni_scheduler.py`，重挂 2 行）
- 语言白名单 + `UnsupportedLanguageError`（preprocess 入口，不进调度）
- `estimate_output_frames` 帧数估算与 `SpeechRateCalibrator` 回喂（`_moss_speech_frames` 供账本计费，`_moss_speech_lang` 供完成回喂）
- `MOSS_TTS_DEFAULT_MAX_NEW_TOKENS=35000`（已核实上游 `c31c04f18` 未改动 `raw_max_new_tokens is None` 这条默认值分支）
- `MOSS_TTS_AUDIO_TOKENIZER` 环境变量注入 codec 权重路径
- 两个 YAML 与 `start_tts.sh` 的显存分档（本分支自有文件，与上游无交集）

### 同步后与上游的差异面

`moss_tts/model_runner.py` 与 `moss_tts_local/model_runner.py` **与上游 0 差异**（首帧修复已让位）。
`omni_scheduler.py` 相对上游只有账本的 +250 行纯新增，含 `get_new_batch_prefill` 开头的 2 行挂载，
不删改任何上游行。其余自定义集中在 `request_builders.py`、`speech_budget.py`、`audio_tokenizer.py`（env）
与自有的 YAML / 启动脚本 / 文档。
