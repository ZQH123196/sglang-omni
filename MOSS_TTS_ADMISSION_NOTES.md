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

## 当前解决状态（2026-09-20 rebase 后）

| 原始问题 | 当前解法 | 位置 | 是否仍需自定义代码 |
|---|---|---|---|
| 输入字符限制 | 上游 `max_speech_input_chars=None`，无字符限制 | `moss_tts/config.py:105` | **已不需要** |
| Context 窗口过小 | 上游 `resolve_moss_tts_context_length()` 从模型 config.json 读取（Qwen3-8B=32768） | `hf_loading.py` | **已不需要** |
| max_prefill_tokens 过小 | YAML 显式设 35000 | `moss_tts_prod.yaml` | 配置项，非代码 |
| max_new_tokens 截断 | `MOSS_TTS_DEFAULT_MAX_NEW_TOKENS=35000` | `request_builders.py:34` | **自定义，必要** |
| post_prefill 0s 音频 | 移除 `is_prefill_only` 早返回 | `model_runner.py` / `moss_tts_local/model_runner.py` | **自定义，上游 bug 未修** |
| 无准入控制 → KV 打爆 | 容量预留 + 语速标定 + rebalance | `omni_scheduler.py` + `speech_budget.py` | **自定义，核心设计** |

## 自定义架构三层

### 第一层：引擎容量（YAML 配置）

```yaml
# examples/configs/moss_tts_prod.yaml
stages:
  tts_engine:
    engine:
      max_running_requests: 64
      max_prefill_tokens: 35000
```

- `max_running_requests`：引擎调度池大小，决定最大同时 in-flight 请求数
- `max_prefill_tokens`：允许一次 prefill 消化多少 token（6K 中文 ≈ 6K-12K tokens + ref audio）
- `context_length`：由模型 metadata 自动推导（32768），无需覆盖

`MOSS_TTS_DEFAULT_MAX_NEW_TOKENS=35000`（request_builders.py）：当客户端不传 `max_new_tokens` 时的生成帧上限。6K 中文字在 25fps 下约需 37500 帧，所以天花板必须 ≥ 文本预估帧数。若客户端总传 `token_count` 则可降回 4096。

### 第二层：准入控制（omni_scheduler + speech_budget）

**speech_budget.py — 输出帧数估算器**

不是"调节语速"，是"预估一段文本将消耗多少 KV 空间"。按语言维护 `chars_per_frame` 比值：
- 默认值来自基准测试
- 运行时观察已完成请求（输入字符数, 实际生成帧数），≥5 样本后自动修正
- 滑动窗口 50 样本，剔除偏离均值 50% 的离群值
- 持久化到 `./.cache`，重启复用

**omni_scheduler.py — 容量预留账本**

- 请求进入 `get_new_batch_prefill` 前，按估算帧数 + 输入 token 数预留 KV 空间
- 预留不够 → defer（放入等待队列），不浪费引擎调度 slot
- 请求完成/abort → 释放预留，触发 rebalance 事件把 deferred 请求放回
- 利用 radix tree 前缀命中计算真实增量（ref audio 相同则不重复预留）

### 第三层：post_prefill 首帧修复

上游两个 `model_runner.py` 的 `post_prefill` 中：
```python
if schedule_batch.is_prefill_only:
    return  # ← BUG: 跳过首帧采样
```
并发打满时纯 prefill batch 高频出现，跳过后导致 pending_feedback_queue 为空 → 全 0 embeds → 垃圾 logits → argmax 命中 im_end → 立即 EOS → 0s 音频。

修复：删除 early return，prefill 后始终采样第一帧。**上游至今仍有此 bug（2026-09-20 确认）。**

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
| H200 (90G+) | `moss_tts_prod.yaml` | max_running=64, prefill=35000 |
| A6000 (48G) | `moss_tts_48gb.yaml` | max_running=8, prefill=16384 |
| RTX 5090 (32G) | `moss_tts_32gb.yaml`（上游） | single-process, concurrency=1 |
| RTX 4090 (24G) | `moss_tts_24gb.yaml`（上游） | single-process, concurrency=1 |

## 部署注意

- 启动脚本 `start_tts.sh` 仅做环境准备 + `sgl-omni serve --config <选配的yaml>`
- `MOSS_TTS_AUDIO_TOKENIZER` 环境变量指向本地 codec 权重目录（脚本中 export）
- sglang 0.5.19+ 已原生支持所需 flash-attn 路径，旧 Blackwell 兼容 workaround 不再需要
