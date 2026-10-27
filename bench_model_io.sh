#!/usr/bin/env bash
# 模型盘 I/O 诊断: O_DIRECT 绕过 page cache, 多次运行结果应一致。
# 用法: bash bench_model_io.sh

set -u

SRC_ROOT="/root/autodl-fs/models/OpenMOSS-Team"
MODEL_DIR="$SRC_ROOT/Moss-TTS-v1.5"
TOKENIZER_DIR="$SRC_ROOT/MOSS-Audio-Tokenizer"
LOCAL_ROOT="/root/autodl-tmp"
LOG_DIR="$LOCAL_ROOT/sglang-omni/logs"
RUNS=3
READ_MIB=1024

BENCH_FILE=""
cleanup() {
    if [ -n "$BENCH_FILE" ]; then rm -f "$BENCH_FILE"; fi
}
trap cleanup EXIT

fmt_mb() {
    awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1e6 }'
}

rate_mbps() {
    awk '{ for (i = 1; i <= NF; i++) {
               if ($i == "MB/s") { print $(i-1); exit }
               if ($i == "GB/s") { print $(i-1) * 1000; exit }
           } }'
}

bench_direct() {
    local label="$1" file="$2" i out rc rate
    local -a rates=()
    printf -- '-- %s (O_DIRECT, %dx, 每次 %d MiB) --\n' "$label" "$RUNS" "$READ_MIB" >&2
    for i in $(seq 1 "$RUNS"); do
        out=$(dd if="$file" of=/dev/null bs=1M count="$READ_MIB" iflag=direct 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '   O_DIRECT 不可用: %s\n' "$(printf '%s\n' "$out" | tail -n 1)" >&2
            return 1
        fi
        rate=$(printf '%s\n' "$out" | tail -n 1 | rate_mbps)
        if [ -z "$rate" ]; then
            printf '   无法解析: %s\n' "$(printf '%s\n' "$out" | tail -n 1)" >&2
            return 1
        fi
        rates+=("$rate")
        printf '   run%d: %s MB/s\n' "$i" "$rate" >&2
    done
    printf '%s\n' "${rates[@]}" | sort -n | sed -n '2p'
}

echo "===== 0. 内存与挂载 ====="
awk '/^(MemTotal|MemAvailable|Cached):/ { printf "%-14s %10.0f MB\n", $1, $2 * 1024 / 1e6 }' /proc/meminfo
df -Th "$LOCAL_ROOT" /root/autodl-fs 2>/dev/null

echo
echo "===== 1. 文件 ====="
BIG=$(find "$MODEL_DIR" -name '*.safetensors' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n 1 | cut -f2-)
if [ -z "$BIG" ]; then
    echo "ERROR: $MODEL_DIR 下没有 .safetensors" >&2
    exit 1
fi
TOTAL=$(du -sb "$MODEL_DIR" "$TOKENIZER_DIR" 2>/dev/null | awk '{ s += $1 } END { printf "%.0f\n", s }')
BIG_BYTES=$(stat -c %s "$BIG")
printf '基准文件: %s (%s)\n' "$BIG" "$(fmt_mb "$BIG_BYTES")"
printf '模型合计: %s\n' "$(fmt_mb "$TOTAL")"

echo
echo "===== 2. 网盘读取（可重复） ====="
NET_MEDIAN=$(bench_direct "autodl-fs 网盘" "$BIG") || NET_MEDIAN=""
printf '网盘中位数: %s MB/s\n' "${NET_MEDIAN:-不可用}"

echo
echo "===== 3. 拷贝到本地盘（迁移成本） ====="
BENCH_FILE="$LOCAL_ROOT/_io_bench.safetensors"
AVAIL=$(df --output=avail -B1 "$LOCAL_ROOT" | tail -n 1)
if [ "$BIG_BYTES" -ge "$AVAIL" ]; then
    echo "跳过: 本地可用 $(fmt_mb "$AVAIL") < 文件 $(fmt_mb "$BIG_BYTES")"
    BENCH_FILE=""
else
    START_NS=$(date +%s%N)
    if cp "$BIG" "$BENCH_FILE"; then
        END_NS=$(date +%s%N)
        sync
        MS=$(( (END_NS - START_NS) / 1000000 ))
        awk -v size="$(fmt_mb "$BIG_BYTES")" -v b="$BIG_BYTES" -v ms="$MS" \
            'BEGIN { printf "   %s 用时 %.1f s, 约 %.1f MB/s\n", size, ms/1000, b/(ms/1000)/1e6 }'
    else
        echo "   拷贝失败"
        rm -f "$BENCH_FILE"
        BENCH_FILE=""
    fi
fi

echo
echo "===== 4. 本地盘读取（可重复） ====="
LOCAL_MEDIAN=""
if [ -n "$BENCH_FILE" ]; then
    LOCAL_MEDIAN=$(bench_direct "autodl-tmp 本地盘" "$BENCH_FILE") || LOCAL_MEDIAN=""
fi
printf '本地盘中位数: %s MB/s\n' "${LOCAL_MEDIAN:-不可用}"

echo
echo "===== 5. 折算（模型合计全量冷读） ====="
if [ -n "$NET_MEDIAN" ]; then
    awk -v b="$TOTAL" -v r="$NET_MEDIAN" 'BEGIN { printf "   网盘:   %8.1f MB/s → %.1f 分钟\n", r, b/(r*1e6)/60 }'
else
    echo "   网盘:   无可用数据"
fi
if [ -n "$LOCAL_MEDIAN" ]; then
    awk -v b="$TOTAL" -v r="$LOCAL_MEDIAN" 'BEGIN { printf "   本地盘: %8.1f MB/s → %.1f 秒\n", r, b/(r*1e6) }'
else
    echo "   本地盘: 无可用数据"
fi

echo
echo "===== 6. 启动日志分段 ====="
LOG=$(ls -t "$LOG_DIR"/server_*.log 2>/dev/null | head -n 1)
if [ -z "$LOG" ]; then
    echo "没找到 $LOG_DIR/server_*.log"
else
    echo "$LOG"
    grep -nE "Loading MOSS-TTS processor|Load weight|Capture cuda graph|max_total_num_tokens|warmup|server is ready|Pipeline .* started" "$LOG" | tail -n 40
fi
