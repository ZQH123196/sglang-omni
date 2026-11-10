// pm2 只托管 sgl-omni 本体; git pull / uv sync / 显存选型由 start_tts.sh 在启动前完成,
// 避免崩溃自动重启时重复同步依赖。路径等参数从 start_tts.sh 导出的环境变量读取。
const path = require("node:path");

const workDir = process.env.MyWorkDir;
const modelRootDir = process.env.MODEL_ROOT_DIR;
const configPath = process.env.CONFIG;
if (!workDir || !modelRootDir || !configPath) {
  throw new Error("MyWorkDir/MODEL_ROOT_DIR/CONFIG 未设置, 请通过 start_tts.sh 启动");
}

const repoDir = path.join(workDir, "sglang-omni");

module.exports = {
  apps: [
    {
      name: "sglang-omni",
      cwd: repoDir,
      script: path.join(repoDir, ".venv", "bin", "sgl-omni"),
      // 不要加 --allowed-media-domain '*': 上游只认精确域和 .后缀域, '*' 会让所有远程
      // 参考音频报 "Domain X is not allowed"; 不传该参数即放行全部远程域名。
      args: [
        "serve",
        "--model-path",
        path.join(modelRootDir, "OpenMOSS-Team", "Moss-TTS-v1.5"),
        "--config",
        configPath,
        // "--log-level",
        // "debug",
        "--port",
        "8000",
      ],
      interpreter: "none",
      env: {
        LD_PRELOAD: process.env.LD_PRELOAD,
        MOSS_TTS_AUDIO_TOKENIZER: process.env.MOSS_TTS_AUDIO_TOKENIZER,
        // 端口被占时直接失败, 不要静默换端口让 pm2 和调用方看到假健康。
        SGLANG_OMNI_STRICT_PORT: "1",
      },
      // pm2 默认 1.6s 后就 SIGKILL; launcher 回收子进程最多需要 STOP_GRACE_S=15s。
      kill_timeout: 30000,
      kill_signal: "SIGINT",
      // OOM 之类确定性失败停在 errored 暴露问题, 而不是无限重启抢显存。
      max_restarts: 5,
      restart_delay: 5000,
      time: true,
    },
  ],
};
