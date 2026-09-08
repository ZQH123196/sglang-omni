# source .venv/bin/activate
# source /etc/network_turbo autodl 翻墙，下运行过程中可能还要在 hf 下载模型。
# 下面的 export 跟上面的一模一样，只是方便用户复制此段重新跑而已

# 强制让系统优先加载系统自带的（更新的）C++ 基础库
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6:$LD_PRELOAD
export MyWorkDir="/root/autodl-tmp"
export MODEL_ROOT_DIR="/root/autodl-fs/models"
cd $MyWorkDir/sglang-omni
source .venv/bin/activate
MEM_ARGS="--mem-fraction-static 0.8" # 设定默认参数

if command -v nvidia-smi &> /dev/null; then
    # 获取第一块 GPU 的总显存大小（MB）
    VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
    # 转换为 GB
    VRAM_GB=$((VRAM_MB / 1024))
    echo "📊 自动检测到 NVIDIA GPU 显存: ${VRAM_GB} GB"

    if [ "$VRAM_GB" -gt 90 ]; then
        MEM_ARGS=""
        echo "💡 显存大于 90G，已自动省略 --mem-fraction-static 参数"
    elif [ "$VRAM_GB" -le 48 ]; then
        MEM_ARGS="--mem-fraction-static 0.6"
        echo "💡 显存判定结果：建议使用 0.6 显存配额"
    elif [ "$VRAM_GB" -le 80 ]; then
        MEM_ARGS="--mem-fraction-static 0.8"
        echo "💡 显存判定结果：建议使用 0.8 显存配额"
    fi
else
    echo "⚠️ 未检测到 nvidia-smi，将使用默认参数: --mem-fraction-static 0.8"
fi

echo "🚀 正在启动服务..."
mkdir -p ./logs # 确保日志目录存在，否则会报错
exec 3>&1                    # 预留终端输出通道
BASH_XTRACEFD=3              # 让命令回显只打到终端，不混进日志文件
set -x                       # 开启命令回显
# 注意：$MEM_ARGS 不加引号。当为空时，Bash 会自动忽略该位置，不会传空字符串。
# 注意，8000 端口不直接访问，外部要访问应该独立的 Python 服务以提供异步下载功能。
#
# 已知行为（无需报警）：启动后首次 vocode 会打印一条 ERROR：
#   "MOSS-TTS Delay packed codec decode failed; disabling the packed path
#    and falling back to standalone codec decode"
# 根因：sglang 0.5.16 的 FA3 fallback 不兼容 flash-attn-4 的 cute API
# （sglang 期待经典 FA2 顶层 varlen 符号，flash-attn-4 把它放在 cute 子模块下，
# 且签名/类型约定差异层层叠加）。vocoder 的 try/except 自动降级到 standalone
# SDPA decode，功能正常，音频可正常输出，仅 vocode 阶段吞吐略降。
# 实测对 MOSS-TTS 端到端吞吐影响 <5%（瓶颈在 LLM prefill/decode，不在 vocode）。
# 修复路径待定：等 sglang 出支持 Blackwell FA3 的版本，或 classic FA2 出 SM 12.0 轮子。
nohup sgl-omni serve \
  --model-path "$MODEL_ROOT_DIR/OpenMOSS-Team/Moss-TTS-v1.5" \
  --config examples/configs/moss_tts.yaml \
  $MEM_ARGS \
  --allowed-media-domain '*' \
  --log-level debug \
  --port 8000 \
  > ./logs/server_$(date +%Y%m%d).log 2>&1 &
set +x  # 关闭命令回显
tail -f ./logs/server_$(date +%Y%m%d).log
# tail -f ./logs/server_$(date +%Y%m%d).log
# ps -ef | grep sglang-omni
# pkill -f sglang-omni
# 重置指定ID的GPU，例如ID为0的GPU
# sudo nvidia-smi --gpu-reset -i 0
