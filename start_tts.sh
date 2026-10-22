#!/usr/bin/env bash
# MOSS-TTS 生产启动脚本
# 代码同步不在这里做:my-deploy 是压缩重写的历史,启动时 git pull 会撞分叉。
# 需要同步时人工执行,见 .claude/skills/upstream-sync/SKILL.md。
# 自动检测 GPU 显存选择对应配置文件，也可手动覆盖: CONFIG=xxx bash start_tts.sh

# --- 环境准备 ---
# 强制优先加载系统自带的（更新的）C++ 基础库
export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
export MyWorkDir="/root/autodl-tmp"
export MODEL_ROOT_DIR="/root/autodl-fs/models"
# vocoder tokenizer 走本地权重目录，免去运行时连 HF Hub 下载；不设则回落仓库 id。
export MOSS_TTS_AUDIO_TOKENIZER="$MODEL_ROOT_DIR/OpenMOSS-Team/MOSS-Audio-Tokenizer"

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

# --- 启动服务 ---
# 不要加 --allowed-media-domain '*'：上游只支持精确域和 .后缀域，'*' 匹配不到任何
# 域名，反而会让所有远程参考音频报 "Domain X is not allowed"。留空即为放行全部
# （allow_remote_media_without_domains 默认 True，见 resource_connector.py:298）。
mkdir -p ./logs
LOG_FILE="./logs/server_$(date +%Y%m%d).log"

nohup sgl-omni serve \
  --model-path "$MODEL_ROOT_DIR/OpenMOSS-Team/Moss-TTS-v1.5" \
  --config "$CONFIG" \
  --log-level debug \
  --port 8000 \
  > "$LOG_FILE" 2>&1 &

echo "服务已启动 (PID $!), 日志: $LOG_FILE"
tail -f "$LOG_FILE"

# --- 常用运维命令 ---
# ps -ef | grep sgl-omni
# pkill -f sgl-omni
# sudo nvidia-smi --gpu-reset -i 0
