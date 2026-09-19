#!/usr/bin/env bash
# MOSS-TTS 生产启动脚本
# 自动检测 GPU 显存选择对应配置文件，也可手动覆盖: CONFIG=xxx bash start_tts.sh

# --- 环境准备 ---
# 强制优先加载系统自带的（更新的）C++ 基础库
export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
export MyWorkDir="/root/autodl-tmp"
export MODEL_ROOT_DIR="/root/autodl-fs/models"
# vocoder tokenizer 走本地权重目录，免去运行时连 HF Hub 下载；不设则回落仓库 id。
export MOSS_TTS_AUDIO_TOKENIZER="$MODEL_ROOT_DIR/OpenMOSS-Team/MOSS-Audio-Tokenizer"

cd "$MyWorkDir/sglang-omni"
source .venv/bin/activate

# --- 按显存选择配置 ---
if [ -z "$CONFIG" ]; then
    if command -v nvidia-smi &> /dev/null; then
        VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
        VRAM_GB=$((VRAM_GB / 1024))
        echo "检测到 GPU 显存: ${VRAM_GB} GB"

        if [ "$VRAM_GB" -gt 80 ]; then
            CONFIG="examples/configs/moss_tts_prod.yaml"
        elif [ "$VRAM_GB" -gt 32 ]; then
            CONFIG="examples/configs/moss_tts_48gb.yaml"
        else
            CONFIG="examples/configs/moss_tts_32gb.yaml"
        fi
    else
        echo "未检测到 nvidia-smi，使用 prod 配置"
        CONFIG="examples/configs/moss_tts_prod.yaml"
    fi
fi
echo "使用配置: $CONFIG"

# --- 启动服务 ---
mkdir -p ./logs
LOG_FILE="./logs/server_$(date +%Y%m%d).log"

nohup sgl-omni serve \
  --model-path "$MODEL_ROOT_DIR/OpenMOSS-Team/Moss-TTS-v1.5" \
  --config "$CONFIG" \
  --allowed-media-domain '*' \
  --log-level debug \
  --port 8000 \
  > "$LOG_FILE" 2>&1 &

echo "服务已启动 (PID $!), 日志: $LOG_FILE"
tail -f "$LOG_FILE"

# --- 常用运维命令 ---
# ps -ef | grep sgl-omni
# pkill -f sgl-omni
# sudo nvidia-smi --gpu-reset -i 0
