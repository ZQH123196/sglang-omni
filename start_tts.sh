#!/usr/bin/env bash
# MOSS-TTS 生产启动脚本: 环境准备 + 模型本地化 + 按显存选配置, 服务本体交给 pm2 托管。
# 自动检测 GPU 显存选择对应配置文件，也可手动覆盖: CONFIG=xxx bash start_tts.sh

# --- 公共函数 ---
log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

mb() {
    awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1e6 }'
}

log "同步代码: git pull --rebase (GitHub 慢时会停在这一步)"
git pull --rebase
git switch my-deploy
log "代码同步完成, 当前分支: $(git rev-parse --abbrev-ref HEAD)"

# --- 环境准备 ---
# 强制优先加载系统自带的（更新的）C++ 基础库
export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
export MyWorkDir="/root/autodl-tmp"

# --- 模型本地化 ---
# 网盘冷读只有 100-200 MB/s，24GB 权重加载要两分钟级；本地盘 2 GB/s，十几秒。
# 本地副本由脚本托管：仅当网盘文件清单(路径+大小)变化时才重新同步，勿手工修改。
REMOTE_MODEL_ROOT="/root/autodl-fs/models"
LOCAL_MODEL_ROOT="$MyWorkDir/models"
MODEL_SUBDIR="OpenMOSS-Team"
REMOTE_MODELS="$REMOTE_MODEL_ROOT/$MODEL_SUBDIR"
LOCAL_MODELS="$LOCAL_MODEL_ROOT/$MODEL_SUBDIR"
SYNC_MARKER="$LOCAL_MODEL_ROOT/.sync_manifest"
COPY_PARALLEL="${COPY_PARALLEL:-8}"

MODEL_LIST=$(mktemp)
trap 'rm -f "$MODEL_LIST"' EXIT

manifest_of() {
    find "$1" -type f -printf '%P %s\n' | sort | md5sum | cut -d' ' -f1
}

signature_from_scan() {
    awk -F'\t' '{ print $2 " " $1 }' | sort | md5sum | cut -d' ' -f1
}

copy_one() {
    local entry="$1" size rel begin seconds
    size=${entry%%$'\t'*}
    rel=${entry#*$'\t'}
    begin=$(date +%s)
    printf '[%s] 开始 %s (%s)\n' "$(date '+%H:%M:%S')" "$rel" "$(mb "$size")"
    if install -D -p "$REMOTE_MODELS/$rel" "$LOCAL_MODELS/$rel"; then
        seconds=$(( $(date +%s) - begin ))
        printf '[%s] 完成 %s (用时 %ds)\n' "$(date '+%H:%M:%S')" "$rel" "$seconds"
    else
        printf '[%s] 失败 %s\n' "$(date '+%H:%M:%S')" "$rel" >&2
        return 1
    fi
}

if [ ! -d "$REMOTE_MODELS" ]; then
    log "错误: 找不到模型源目录 $REMOTE_MODELS"
    exit 1
fi

log "扫描网盘模型清单: $REMOTE_MODELS"
( cd "$REMOTE_MODELS" && find . -type f -printf '%s\t%P\n' ) > "$MODEL_LIST"
REMOTE_SIGNATURE=$(signature_from_scan < "$MODEL_LIST")
FILE_COUNT=$(wc -l < "$MODEL_LIST" | tr -d ' ')
TOTAL_BYTES=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$MODEL_LIST")
log "清单扫描完成: $FILE_COUNT 个文件, 共 $(mb "$TOTAL_BYTES")"

USE_LOCAL_MODELS=false
if [ -f "$SYNC_MARKER" ] && [ "$(cat "$SYNC_MARKER")" = "$REMOTE_SIGNATURE" ]; then
    USE_LOCAL_MODELS=true
    log "本地副本与网盘清单一致, 跳过同步"
elif [ -d "$LOCAL_MODELS" ] && [ "$(manifest_of "$LOCAL_MODELS")" = "$REMOTE_SIGNATURE" ]; then
    printf '%s\n' "$REMOTE_SIGNATURE" > "$SYNC_MARKER"
    USE_LOCAL_MODELS=true
    log "本地副本已是最新, 补写同步标记"
else
    mkdir -p "$LOCAL_MODEL_ROOT"
    AVAIL_BYTES=$(df --output=avail -B1 "$LOCAL_MODEL_ROOT" | tail -n 1)
    if [ "$TOTAL_BYTES" -ge "$AVAIL_BYTES" ]; then
        log "本地盘空间不足, 跳过同步: 需要 $(mb "$TOTAL_BYTES"), 可用 $(mb "$AVAIL_BYTES")"
    else
        log "开始并行复制: $FILE_COUNT 个文件, $(mb "$TOTAL_BYTES"), 并行度 $COPY_PARALLEL"
        export REMOTE_MODELS LOCAL_MODELS
        export -f mb copy_one
        rm -f "$SYNC_MARKER"
        rm -rf "$LOCAL_MODELS"
        mkdir -p "$LOCAL_MODELS"
        COPY_BEGIN=$(date +%s)
        sort -t$'\t' -k1,1 -rn "$MODEL_LIST" |
            xargs -d '\n' -P "$COPY_PARALLEL" -I{} bash -c 'copy_one "$1"' _ {}
        COPY_SECONDS=$(( $(date +%s) - COPY_BEGIN ))
        if [ "$(manifest_of "$LOCAL_MODELS")" = "$REMOTE_SIGNATURE" ]; then
            printf '%s\n' "$REMOTE_SIGNATURE" > "$SYNC_MARKER"
            USE_LOCAL_MODELS=true
            log "复制完成: 用时 ${COPY_SECONDS}s, 平均 $(awk -v b="$TOTAL_BYTES" -v s="$COPY_SECONDS" 'BEGIN { printf "%.1f", (s > 0) ? b / s / 1e6 : 0 }') MB/s, 校验通过"
        else
            log "模型同步校验失败, 本次回退网盘"
        fi
    fi
fi

if [ "$USE_LOCAL_MODELS" = true ]; then
    export MODEL_ROOT_DIR="$LOCAL_MODEL_ROOT"
    log "==> 模型来源: 本地盘 ($MODEL_ROOT_DIR/$MODEL_SUBDIR)"
else
    export MODEL_ROOT_DIR="$REMOTE_MODEL_ROOT"
    log "==> 模型来源: 网盘 ($MODEL_ROOT_DIR/$MODEL_SUBDIR) [本地副本不可用, 加载慢 2-3 分钟]"
fi
# vocoder tokenizer 跟随模型来源目录，免去运行时连 HF Hub 下载。
export MOSS_TTS_AUDIO_TOKENIZER="$MODEL_ROOT_DIR/$MODEL_SUBDIR/MOSS-Audio-Tokenizer"

cd "$MyWorkDir/sglang-omni"
# 依赖同步(清华镜像)。必须在 cd 之后执行,否则 uv 作用在调用者的 cwd 上。
log "同步依赖: uv sync"
uv sync --index https://pypi.tuna.tsinghua.edu.cn/simple
source .venv/bin/activate

# --- 按显存选择配置 ---
if [ -z "$CONFIG" ]; then
    if command -v nvidia-smi &> /dev/null; then
        # 按 MiB 整数比较,不换算成 GB:GB 除法会截断(81920 MiB → 79/80),
        # 80G 卡会掉进 `-gt 80` 不成立而误选 48G 配置。
        VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
        echo "检测到 GPU 显存: ${VRAM_MIB} MiB"

        if [ "$VRAM_MIB" -ge 80000 ]; then
            CONFIG="examples/configs/moss_tts_prod.yaml"
        elif [ "$VRAM_MIB" -ge 46000 ]; then
            CONFIG="examples/configs/moss_tts_48gb.yaml"
        elif [ "$VRAM_MIB" -ge 30000 ]; then
            CONFIG="examples/configs/moss_tts_32gb.yaml"
        else
            CONFIG="examples/configs/moss_tts_24gb.yaml"
        fi
    else
        echo "未检测到 nvidia-smi，使用 prod 配置"
        CONFIG="examples/configs/moss_tts_prod.yaml"
    fi
fi
log "使用配置: $CONFIG"
export CONFIG

# --- pm2 托管 ---
if ! command -v pm2 > /dev/null 2>&1; then
    if ! command -v npm > /dev/null 2>&1; then
        log "未找到 pm2, 也没有 npm 可用于安装。请先安装 Node.js/npm 后重试。"
        exit 1
    fi
    log "未找到 pm2, 使用 npmmirror 安装"
    npm install -g pm2 --registry=https://registry.npmmirror.com || {
        log "pm2 安装失败"
        exit 1
    }
fi

# pm2 自己的日志默认不轮转, debug 级别的输出会写满系统盘。
if ! pm2 describe pm2-logrotate > /dev/null 2>&1; then
    log "安装 pm2-logrotate (日志轮转)"
    npm_config_registry=https://registry.npmmirror.com pm2 install pm2-logrotate
fi

# 旧版脚本用 nohup 直接拉起的实例会占住 :8000, 先让它优雅退出(回收子进程要时间)。
if ! pm2 describe sglang-omni > /dev/null 2>&1 && pgrep -f "sgl-omni serve" > /dev/null; then
    log "停止旧的手工启动实例, 等待优雅退出 (最多 30s)"
    pkill -f "sgl-omni serve"
    for _ in $(seq 1 30); do
        pgrep -f "sgl-omni serve" > /dev/null || break
        sleep 1
    done
fi

# 每次重建进程, 保证参数/env 与本次显存选型一致, 并清零重启计数。
log "停止 pm2 中的旧实例 (优雅退出最多等 30s)"
pm2 delete sglang-omni > /dev/null 2>&1 || true
log "启动 pm2 进程: sglang-omni"
pm2 start ecosystem.config.cjs --update-env || exit 1
pm2 save
log "pm2 已接管, 下面是日志 (Ctrl-C 只退出日志追踪, 服务继续运行)"
pm2 logs sglang-omni

# --- 常用运维命令 ---
# pm2 status
# pm2 restart sglang-omni
# pm2 stop sglang-omni
# pm2 logs sglang-omni --lines 200
# pm2 flush
# rm /root/autodl-tmp/models/.sync_manifest   # 强制下次启动重新同步模型
# COPY_PARALLEL=16 bash start_tts.sh          # 调整复制并行度
# sudo nvidia-smi --gpu-reset -i 0
