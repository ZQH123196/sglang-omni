#!/usr/bin/env bash
# MOSS-TTS 生产启动脚本: 环境准备 + 模型本地化 + 按显存选配置, 服务本体交给 pm2 托管。
# 自动检测 GPU 显存选择对应配置文件，也可手动覆盖: CONFIG=xxx bash start_tts.sh

git pull --rebase
git switch my-deploy

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

manifest_of() {
    find "$1" -type f -printf '%P %s\n' | sort | md5sum | cut -d' ' -f1
}

if [ ! -d "$REMOTE_MODELS" ]; then
    echo "错误: 找不到模型源目录 $REMOTE_MODELS" >&2
    exit 1
fi
REMOTE_SIGNATURE=$(manifest_of "$REMOTE_MODELS")

USE_LOCAL_MODELS=false
if [ -f "$SYNC_MARKER" ] && [ "$(cat "$SYNC_MARKER")" = "$REMOTE_SIGNATURE" ]; then
    USE_LOCAL_MODELS=true
elif [ -d "$LOCAL_MODELS" ] && [ "$(manifest_of "$LOCAL_MODELS")" = "$REMOTE_SIGNATURE" ]; then
    echo "$REMOTE_SIGNATURE" > "$SYNC_MARKER"
    USE_LOCAL_MODELS=true
    echo "本地副本已是最新, 跳过同步"
else
    NEED_BYTES=$(du -sb "$REMOTE_MODELS" | awk '{ print $1 }')
    mkdir -p "$LOCAL_MODEL_ROOT"
    AVAIL_BYTES=$(df --output=avail -B1 "$LOCAL_MODEL_ROOT" | tail -n 1)
    if [ "$NEED_BYTES" -ge "$AVAIL_BYTES" ]; then
        echo "本地盘空间不足, 跳过同步: 需要 $((NEED_BYTES / 1000000)) MB, 可用 $((AVAIL_BYTES / 1000000)) MB" >&2
    else
        echo "模型同步: 网盘 -> 本地 (约 $((NEED_BYTES / 1000000)) MB, 首次 2-3 分钟)"
        rm -f "$SYNC_MARKER"
        rm -rf "$LOCAL_MODELS"
        mkdir -p "$LOCAL_MODELS"
        ( cd "$REMOTE_MODELS" && find . -type f -print0 |
            xargs -0 -P 4 -I{} install -D -p "{}" "$LOCAL_MODELS/{}" )
        if [ "$(manifest_of "$LOCAL_MODELS")" = "$REMOTE_SIGNATURE" ]; then
            echo "$REMOTE_SIGNATURE" > "$SYNC_MARKER"
            USE_LOCAL_MODELS=true
            echo "模型同步完成, 校验通过"
        else
            echo "模型同步校验失败, 本次回退网盘" >&2
        fi
    fi
fi

if [ "$USE_LOCAL_MODELS" = true ]; then
    export MODEL_ROOT_DIR="$LOCAL_MODEL_ROOT"
    echo "==> 模型来源: 本地盘 ($MODEL_ROOT_DIR/$MODEL_SUBDIR)"
else
    export MODEL_ROOT_DIR="$REMOTE_MODEL_ROOT"
    echo "==> 模型来源: 网盘 ($MODEL_ROOT_DIR/$MODEL_SUBDIR) [本地副本不可用, 加载慢 2-3 分钟]" >&2
fi
# vocoder tokenizer 跟随模型来源目录，免去运行时连 HF Hub 下载。
export MOSS_TTS_AUDIO_TOKENIZER="$MODEL_ROOT_DIR/$MODEL_SUBDIR/MOSS-Audio-Tokenizer"

cd "$MyWorkDir/sglang-omni"
# 依赖同步(清华镜像)。必须在 cd 之后执行,否则 uv 作用在调用者的 cwd 上。
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
echo "使用配置: $CONFIG"
export CONFIG

# --- pm2 托管 ---
if ! command -v pm2 > /dev/null 2>&1; then
    if ! command -v npm > /dev/null 2>&1; then
        echo "未找到 pm2, 也没有 npm 可用于安装。请先安装 Node.js/npm 后重试。" >&2
        exit 1
    fi
    echo "未找到 pm2, 使用 npmmirror 安装"
    npm install -g pm2 --registry=https://registry.npmmirror.com || {
        echo "pm2 安装失败" >&2
        exit 1
    }
fi

# pm2 自己的日志默认不轮转, debug 级别的输出会写满系统盘。
pm2 describe pm2-logrotate > /dev/null 2>&1 ||
    npm_config_registry=https://registry.npmmirror.com pm2 install pm2-logrotate

# 旧版脚本用 nohup 直接拉起的实例会占住 :8000, 先让它优雅退出(回收子进程要时间)。
if ! pm2 describe sglang-omni > /dev/null 2>&1 && pgrep -f "sgl-omni serve" > /dev/null; then
    echo "停止旧的手工启动实例"
    pkill -f "sgl-omni serve"
    for _ in $(seq 1 30); do
        pgrep -f "sgl-omni serve" > /dev/null || break
        sleep 1
    done
fi

# 每次重建进程, 保证参数/env 与本次显存选型一致, 并清零重启计数。
pm2 delete sglang-omni > /dev/null 2>&1 || true
pm2 start ecosystem.config.cjs --update-env || exit 1
pm2 save

echo "服务已交给 pm2 管理, 按 Ctrl-C 只退出日志追踪(服务继续运行)"
pm2 logs sglang-omni

# --- 常用运维命令 ---
# pm2 status
# pm2 restart sglang-omni
# pm2 stop sglang-omni
# pm2 logs sglang-omni --lines 200
# pm2 flush
# rm /root/autodl-tmp/models/.sync_manifest   # 强制下次启动重新同步模型
# sudo nvidia-smi --gpu-reset -i 0
