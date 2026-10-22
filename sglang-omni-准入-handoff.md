# sglang-omni MOSS-TTS 并发 6k 长文本 · 容量准入 Handoff

> 更新时间：2026-08-18 22:25
> 状态：准入已实现预留账本（守门尺子修正，本地未 commit）；日志去心跳改事件驱动 + 字段全名
> 分支：my-deploy（本地 HEAD `919cd66`，未 push；本次改动叠加在 919cd66 之上未 commit）

---

## 1. 背景与目标

- **项目**：生产部署 sglang-omni fork 的 MOSS-TTS v1.5（TTS 语音合成，delay 版 `MossTTSDelaySGLangModel`）
- **硬需求**：`max_running_requests=64` 并发 + 6k 长文本（6k = **6k 字符**），不接受降低并发数
- **核心目标**：池满时**排队**而非上游 retract 踢人；混合负载（>6k / <1k / 混杂）下按**入参动态估算** KV 需求做准入
- **前置 handoff**：`WorkBuddy/2026-08-18-10-07-24/sglang-omni-排查-handoff.md`（上午 500 崩溃排查）

---

## 2. 今日关键结论（事实驱动，按时间）

| 时间 | 结论 |
|---|---|
| 14:2x | `disable_radix_cache` 方向错误（74d5e29/fb29da9 放弃），已回退 `7f223c7`；**radix on 是 MOSS 正常模式**（同文本共享 prompt KV，实测每请求只 extend 1 token） |
| 14:30-14:40 | **转储 bug = 容量问题，非 fork 代码 bug**：48G 卡物理装不下 64×6k（KV 池+模型+vocoder 三方抢显存）；14:33 vocoder CUDA OOM（packed decode 需 1.8GiB，仅剩 1.64GiB） |
| 15:00 | 生产用 96G 卡（RTX Pro 6000）+ bf16，**不做 fp8 KV**（用户明确拒绝；fp8 是 48G 卡备胎） |
| 15:33 | 动态准入方案定型：9 语言白名单 + 语速估时长 → 帧数 → 准入预留；**独立 py 文件 + import 集成**（拉上游更新合并压力最低） |
| 21:48 | **0s 音频复现**：上游 `model_runner.py:64` `is_prefill_only → return`（MOSS-TTS 支持 #609 引入的原生缺陷），纯 prefill batch 时跳过首帧采样 → 全 0 embeds → 立即 EOS → 0s |
| 21:58 | **实锤：prefill.py 是死代码**——服务器 grep `.venv/.../sglang/srt/managers/scheduler.py` 的 `prefill_manager` **零命中**，上游 0.5.16 `get_new_batch_prefill` 不用 `self.prefill_manager` |
| 22:00 | 准入迁移到正确位置：`OmniScheduler.get_new_batch_prefill`（上游 `get_next_batch_to_run` 内部必然调用，OmniScheduler 覆写 = 必经之路设卡） |
| 22:18 | **压测观察 + 日志补齐**：①队列 9→0 不是 bug，是准入把放不下的挪到 `_speech_deferred`（metrics 的 `#queue-req` 只统计 `waiting_queue`，故"消失"）；②22:07:46 retract 根因=准入只对新 prefill 设卡，**未对 running 请求的未来 decode 增长做预留**——11 个 running 各需 ~24k tokens，11×24k≫池子，累积到 usage 0.99 必然 retract；③给准入加 ENABLED 横幅 + defer/rebalance 事件日志 |
| 22:25 | **守门尺子修正（预留账本）**：对齐"准入目的=池不溢出/不 retract，门口在 prefill 没错，错在尺子"。新增 `_speech_running_committed_future`：Σ(running 请求 `estimated_output - len(output_ids)`) = 已运行请求还没长完的输出帧；`effective_free = pool_available - running_committed_future` = 扣除 running 未来增长后的真空闲。准入条件从 `available >= need` 改为 `effective_free >= peak_footprint`，且循环内串行 `effective_free -= peak_footprint` 防同批超卖。rebalance 同步用 effective_free。日志：去掉 30s 心跳，改事件驱动（defer/rebalance/no-estimate 转换警告），字段全名（`pool_available`/`running_committed_future`/`effective_free`/`peak_footprint`/`reqs_with_estimate`/`reqs_without_estimate`，去掉 `est` 缩写） |

---

## 3. 当前代码状态（my-deploy，本地，未 push）

| commit | 内容 | 有效性 |
|---|---|---|
| `140861e` | `speech_budget.py` 新建（语言白名单+语速估算）+ `request_builders.py` 集成（preprocess 校验+挂字段） | ✅ 有效 |
| `663e3f0` | 运行时语速标定器 `SpeechRateCalibrator`（≥5 样本生效，覆盖默认表） | ✅ 有效 |
| `fcf4db1` | 标定器升级：滑动窗口 50 样本 + 偏离均值 >50% 离群剔除 | ✅ 有效 |
| `9b3fb20` | **0s 修复**：`post_prefill` 去掉 `is_prefill_only` 提前 return，始终采样第一帧（moss_tts + moss_tts_local） | ✅ 有效，必须保留 |
| `919cd66` | **准入迁移**：`omni_scheduler.py` 加容量准入（正确路径）+ 删除 `prefill.py` 死代码（已复原到 fork 原始状态，`git diff 7f223c7` 无差异） | ✅ 有效位置 |

---

## 4. 准入机制（919cd66，真正生效）

**接入点**：`OmniScheduler.get_new_batch_prefill`（上游 `get_next_batch_to_run` 内部调用，文件头注释 omni_scheduler.py:7-11 明示机制）

```
每轮调度:
  _rebalance_speech_deferred()      ← 池子释放后,把放得下的 deferred 放回 waiting_queue
  _defer_unadmittable_prefill_requests()  ← 遍历 waiting_queue:
      est = req._moss_speech_frames(无则放行)
      need = len(req.origin_input_ids) + est    # 输入实长 + 输出帧估算
      pool.available_size() < need → 挪出 waiting_queue 排队(不踢人)
  → 委托 _Upstream.get_new_batch_prefill
abort 时同步清理 _speech_deferred(防泄漏)
```

**估算公式**（speech_budget.py）：

```
输出帧 = 字符数 ÷ 语速(字符/分) × 60 × 12.5Hz × 1.2(20% 波动余量)
```

- 语言白名单：中/日/韩/越/印地/阿拉伯/西/英/法（Unicode 脚本检测，假名优先于 CJK；白名单外抛 `UnsupportedLanguageError` = 不支持语言报错反馈，preprocess 阶段拒绝，不占资源）
- 显式 `language` 参数优先（别名表含 en-us/zh-CN/中文 等），规避纯 ASCII 西/法文本误判英语
- 运行时标定：每语言最近 50 样本，剔除偏离均值 >50% 的离群（奔 max_new_tokens 上限/0 值），≥5 样本后按实测均值覆盖默认表；限幅 0.5×~2×默认值；每次估算实时查
- 数据流：preprocess 估算 → `payload.data["_moss_speech_frames"/"_moss_speech_lang"]` → build 时挂 `req._moss_speech_frames` → 准入读取 → 完成后 `calibrator.observe(lang, 字符数, 实际帧数)` 回喂

**配比（mem_fraction_static，脚本档位）**：
- 48G（测试卡）：**0.6**（给 vocoder 留 1.8GiB，14:33 曾 OOM）
- 96G（生产卡）：**0.75~0.8** 起步（bf16，官方 delay 配比 0.85 但需给 vocoder/激活留余量），按日志 pool 容量校准
- `max_running_requests=64` **不改**（池内活跃上限语义，超出的 waiting_queue 排队）

---

## 5. 关键文件 / 行号速查

| 文件 | 位置 | 说明 |
|---|---|---|
| `sglang_omni/models/moss_tts/speech_budget.py` | 新建 | 语言检测 / 语速表 / `SpeechRateCalibrator` / `estimate_output_frames` |
| `sglang_omni/models/moss_tts/request_builders.py` | preprocess 开头 | `_estimate_moss_tts_speech_frames` 语言校验+估算；`_moss_speech_frames` 写入 data；build 挂 req 属性；apply 完成回喂 observe |
| `sglang_omni/scheduling/omni_scheduler.py` | `get_new_batch_prefill` 前 | `_rebalance_speech_deferred` / `_defer_unadmittable_prefill_requests` / abort 清理 `_speech_deferred` |
| `sglang_omni/models/moss_tts/model_runner.py` | `post_prefill` :57 | 0s 修复：始终采样第一帧 |
| `sglang_omni/models/moss_tts_local/model_runner.py` | `post_prefill` :104 | 同上（同步） |
| `sglang_omni/scheduling/sglang_backend/prefill.py` | — | **已复原**（fork 原始状态） |

---

## 6. 下一步（按顺序）

1. **服务器拉 `919cd66` + 本次改动压测 64 并发 × 6k**（混合负载更好：>6k / <1k / 混杂）：
   - 启动后看 `speech-admit: capacity admission ENABLED` 横幅（证明覆写生效）
   - 看 `speech-admit defer: ...` 事件日志里的 `running_committed_future`/`effective_free`/`reqs_with_estimate`/`reqs_without_estimate`
   - **关键判断**：若 `reqs_without_estimate>0 且 reqs_with_estimate==0` → 打 WARNING = preprocess 没挂 `_moss_speech_frames`，准入没生效，先修 preprocess 挂载
   - **retract 是否消失**：预留账本生效后 `Retract requests` 应消失/大幅减少（effective_free 扣了 running 未来增长，不再超卖）
   - 0s 音频是否消失（9b3fb20 已修）
   - 排队延迟是否符合预期（长文本排队、短文本秒进）
2. 若 retract 仍多 → 检查估算是否低估（实际生成帧数 vs 估算），调标定/1.2 余量；或 `len(output_ids)` 与帧数单位是否对齐
3. **96G 生产卡验证**：`--mem-fraction-static 0.75~0.8`，看日志实际 pool 容量校准
4. push 远端 my-deploy（含本次改动）

---

## 7. 已知边界 / 风险

1. **准入预留按全量输入算**（radix 共享未扣除，`init_next_round_input` 在 omni_scheduler 层未调用）→ 同文本并发时预留偏保守、排队偏多。后续优化：准入层先 `init_next_round_input` 拿 `extend_range.length` 再算增量
2. **纯 ASCII 西/法文本**无显式 `language` 时按 en 800 档低估 → 规避：调用方传 `language` 参数
3. **64 并发 × 6k 全量驻留物理不可能**（输出帧每请求独立，bf16 下 ≈200GB+）→ 排队是预期行为，不是缺陷
4. **vocoder 显存**：mem_fraction 只管 AR 池，vocoder 峰值 ~1.8GiB 必须手动留（48G 卡 0.6 已含）
5. 标定器为进程内状态，重启清零重新收敛（默认表兜底，行为安全）

---

## 8. 未决问题

1. 919cd66 压测结果（retract 是否消失、0s 是否消失、排队延迟）
2. radix 共享与预留制的冲突优化（第 7.1 条）是否需要做
3. 生产最终形态：96G + bf16 + 0.75~0.8 配比 + 准入排队，延迟可接受性
4. 是否需要给准入加监控日志（defer 计数、平均等待时长）
