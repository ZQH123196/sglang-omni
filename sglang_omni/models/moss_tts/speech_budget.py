# SPDX-License-Identifier: Apache-2.0
"""Speech-length budget estimation for MOSS-TTS admission control.

Given the input text, estimate how many output frames (and therefore how much
KV cache) a request is likely to consume, based on per-language speaking
rates. The MOSS-TTS pipeline uses this estimate to admit a request only when
the KV pool can hold its estimated peak footprint, so the pool never
overflows and the upstream retract path is never triggered: short texts slip
in immediately, long texts wait in the queue until space frees up.

This module is self-contained on purpose (pure stdlib): it is imported by the
MOSS-TTS request builders and the AR scheduler backend, keeping the diff
surface against upstream tiny.
"""

from __future__ import annotations

import threading

__all__ = (
    "SUPPORTED_LANGUAGES",
    "SPEECH_RATE_PER_MIN",
    "UnsupportedLanguageError",
    "resolve_language",
    "detect_language",
    "estimate_output_frames",
    "SpeechRateCalibrator",
    "calibrator",
)

# 语言白名单。请求文本主要字符不属于这些语言时,直接报"不支持语言"错误。
SUPPORTED_LANGUAGES: tuple[str, ...] = (
    "zh",
    "ja",
    "ko",
    "vi",
    "hi",
    "ar",
    "es",
    "en",
    "fr",
)

# 各语言实际朗读语速(字符/分钟)。估算输出时长时统一乘 SAFETY_FACTOR 覆盖波动。
# 中文 300 按线上实测校准:6k 字符 ≈ 20 分钟音频。其余语言为典型朗读语速,
# 上线后可用真实请求的"实际生成帧数"标定,只改这张表即可。
SPEECH_RATE_PER_MIN: dict[str, float] = {
    "zh": 300.0,
    "ja": 300.0,
    "ko": 280.0,
    "vi": 200.0,
    "hi": 200.0,
    "ar": 220.0,
    "es": 250.0,
    "fr": 250.0,
    "en": 800.0,
}

# MOSS-TTS codec 帧率:1 小时音频 ≈ 4.5 万帧。
CODEC_FRAMES_PER_SEC = 12.5
SECONDS_PER_MIN = 60.0
# ±20% 波动余量:宁多勿少,避免超卖池子触发 retract。
SAFETY_FACTOR = 1.2


class UnsupportedLanguageError(ValueError):
    """请求文本不属于支持的语言白名单(不支持语言报错反馈)。"""


# 显式语言参数的别名表:调用方传 language 时,先经这里归一化。
# 覆盖语言代码、常见英文名与中文名;未收录的写法则报"不支持语言"。
_LANGUAGE_ALIASES: dict[str, str] = {
    "zh": "zh", "zh-cn": "zh", "zh-tw": "zh", "chinese": "zh", "中文": "zh",
    "汉语": "zh", "普通话": "zh",
    "ja": "ja", "jp": "ja", "japanese": "ja", "日语": "ja", "日本语": "ja",
    "ko": "ko", "kr": "ko", "korean": "ko", "韩语": "ko", "한국어": "ko",
    "vi": "vi", "vn": "vi", "vietnamese": "vi", "越南语": "vi",
    "hi": "hi", "hindi": "hi", "印地语": "hi", "印地文": "hi",
    "ar": "ar", "arabic": "ar", "阿拉伯语": "ar", "عربي": "ar",
    "es": "es", "es-es": "es", "es-mx": "es", "spanish": "es", "西班牙语": "es",
    "en": "en", "en-us": "en", "en-gb": "en", "english": "en", "英语": "en",
    "fr": "fr", "fr-fr": "fr", "french": "fr", "法语": "fr",
}


def resolve_language(spec: str) -> str:
    """把显式语言参数(代码/别名)归一化为白名单语言,未知则报错。

    显式语言优先于文本检测:西/法文本若全部是 ASCII(无重音),字符检测
    无法与英语区分,调用方通过 ``language`` 参数指定可避免按英语低估。
    """
    if not spec:
        raise UnsupportedLanguageError(
            "MOSS-TTS unsupported language: empty language spec"
        )
    key = spec.strip().lower()
    lang = _LANGUAGE_ALIASES.get(key)
    if lang is None:
        raise UnsupportedLanguageError(
            f"MOSS-TTS unsupported language: {spec!r}; supported: "
            f"{SUPPORTED_LANGUAGES}"
        )
    return lang


class SpeechRateCalibrator:
    """运行时语速标定器(按语言)。

    每个完成的请求把 (输入字符数, 实际生成帧数) 累计进来;某个语言累计
    达到 :attr:`MIN_SAMPLES` 个有效样本后,:meth:`effective_rate` 返回实测
    均值语速(字符/分钟),用于覆盖默认语速表——每次估算都实时查当前标定值,
    随负载自动适应。实测均值仍按"宁多勿少"原则:估算函数统一再乘
    :data:`SAFETY_FACTOR`(≈20% 波动余量)预留。

    累计求和求均值等价于按时长加权平均(长文本样本权重更高),比逐个样本
    平均更稳。``frames <= 0`` 的失败请求不参与统计,避免污染均值。
    """

    MIN_SAMPLES = 5

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._chars: dict[str, int] = {}
        self._frames: dict[str, int] = {}
        self._count: dict[str, int] = {}

    def observe(self, lang: str, chars: int, frames: int) -> None:
        """记录一个已完成请求的 (字符数, 实际生成帧数)。"""
        if frames <= 0 or chars <= 0:
            return
        with self._lock:
            self._chars[lang] = self._chars.get(lang, 0) + int(chars)
            self._frames[lang] = self._frames.get(lang, 0) + int(frames)
            self._count[lang] = self._count.get(lang, 0) + 1

    def effective_rate(self, lang: str) -> float | None:
        """实测均值语速(字符/分钟);样本不足 :attr:`MIN_SAMPLES` 返回 None。"""
        with self._lock:
            count = self._count.get(lang, 0)
            if count < self.MIN_SAMPLES:
                return None
            total_frames = self._frames.get(lang, 0)
            total_minutes = total_frames / (CODEC_FRAMES_PER_SEC * SECONDS_PER_MIN)
            if total_minutes <= 0:
                return None
            return self._chars[lang] / total_minutes

    def sample_count(self, lang: str) -> int:
        with self._lock:
            return self._count.get(lang, 0)

    def reset(self, lang: str | None = None) -> None:
        """清空全部或指定语言的标定统计(测试/运维用)。"""
        with self._lock:
            if lang is None:
                self._chars.clear()
                self._frames.clear()
                self._count.clear()
            else:
                self._chars.pop(lang, None)
                self._frames.pop(lang, None)
                self._count.pop(lang, None)


# 进程级单例:单进程 pipeline 内所有请求共享同一份标定统计。
calibrator = SpeechRateCalibrator()


def _calibrated_rate(lang: str) -> float:
    """取该语言的估算语速:标定均值(限幅)优先,否则默认表。"""
    default = SPEECH_RATE_PER_MIN[lang]
    measured = calibrator.effective_rate(lang)
    if measured is None:
        return default
    # 限幅:异常样本(超长/超短音频)拉偏时,不让标定值偏离默认表太远。
    return max(min(measured, default * 2.0), default * 0.5)


def _script_span(text: str) -> dict[str, int]:
    """统计文本中各 Unicode 脚本的字符数。

    优先级(顺序即优先级):日文假名 > 谚文 > 天城文 > 阿拉伯文 > 越南声调
    拉丁 > CJK 汉字 > 西/法重音拉丁;基础拉丁与常见标点记为中性的 ``base``,
    其余非 ASCII 字符记入 ``other``(用于识别白名单外的语言,如俄语/泰文)。
    """
    counts = {
        "ja": 0,
        "ko": 0,
        "hi": 0,
        "ar": 0,
        "vi": 0,
        "zh": 0,
        "accent": 0,
        "base": 0,
        "other": 0,
    }
    for ch in text:
        code = ord(ch)
        if 0x3040 <= code <= 0x30FF or 0x31F0 <= code <= 0x31FF:
            counts["ja"] += 1  # 平假名 / 片假名(含片假名扩展)
        elif 0x1100 <= code <= 0x11FF or 0xAC00 <= code <= 0xD7AF:
            counts["ko"] += 1  # 谚文字母 / 谚文音节
        elif 0x0900 <= code <= 0x097F:
            counts["hi"] += 1  # 天城文(印地语)
        elif 0x0600 <= code <= 0x06FF:
            counts["ar"] += 1  # 阿拉伯文
        elif 0x1EA0 <= code <= 0x1EF9:
            counts["vi"] += 1  # 越南语声调拉丁扩展
        elif 0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF:
            counts["zh"] += 1  # CJK 汉字(含扩展 A)
        elif 0x00C0 <= code <= 0x00FF:
            counts["accent"] += 1  # 西/法重音拉丁(两语言字符集相同,同档估算)
        elif 0x0020 <= code <= 0x007E or 0x00A0 <= code <= 0x00BF:
            counts["base"] += 1  # 基础拉丁 / 常见标点(中性)
        else:
            counts["other"] += 1
    return counts


def detect_language(text: str) -> str:
    """检测文本主导语言;不在白名单则抛 :class:`UnsupportedLanguageError`。

    规则:
    - 空文本视为英语档(估算为 0,不影响准入);
    - 纯 ASCII / 基础拉丁文本 → ``en``;
    - 出现重音拉丁且无其他决定性脚本 → ``es``(西班牙/法语同档,语速同为 250);
    - 其余取决定性脚本(假名/谚文/天城文/阿拉伯/越南/汉字)中字符数最多者;
    - 混合文本按出现的最重脚本估算,方向偏保守(宁多勿少);
    - 主要字符属于白名单外脚本(西里尔、泰文等)→ 抛"不支持语言"错误。
    """
    if not text or not text.strip():
        return "en"
    counts = _script_span(text)
    decisive = {
        key: counts[key]
        for key in ("ja", "ko", "hi", "ar", "vi", "zh", "accent")
    }
    total_decisive = sum(decisive.values())
    if total_decisive == 0:
        if counts["other"] > 0:
            raise UnsupportedLanguageError(
                "MOSS-TTS unsupported language: text is not in "
                f"{SUPPORTED_LANGUAGES}"
            )
        return "en"
    if decisive["accent"] > 0 and total_decisive == decisive["accent"]:
        return "es"
    return max(decisive, key=decisive.get)


def estimate_output_frames(text: str, lang: str | None = None) -> int:
    """估算文本最多生成多少输出帧(含 20% 波动余量)。

    公式:字符数 / 语速(字符/分) × 60 秒 × 12.5Hz × SAFETY_FACTOR。
    语速优先取运行时标定均值(≥5 个样本后生效),否则用默认表;每次调用
    实时查询,负载变化后自动跟随。
    """
    if lang is None:
        lang = detect_language(text)
    if lang not in SPEECH_RATE_PER_MIN:
        raise UnsupportedLanguageError(
            f"MOSS-TTS unsupported language: {lang!r}; supported: "
            f"{SUPPORTED_LANGUAGES}"
        )
    chars = len(text.strip())
    if chars == 0:
        return 0
    rate = _calibrated_rate(lang)
    minutes = chars / rate
    frames = int(
        minutes * SECONDS_PER_MIN * CODEC_FRAMES_PER_SEC * SAFETY_FACTOR
    )
    return max(frames, 1)
