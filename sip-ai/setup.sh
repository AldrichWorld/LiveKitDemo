#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
cd "$DIR"

echo "==> 检查 Docker"
if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 Docker。请先安装并打开 Docker Desktop: https://www.docker.com/products/docker-desktop/"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker 没有在运行，请先打开 Docker Desktop App，等它启动完成后重新运行本脚本。"
  exit 1
fi

echo "==> 检查 Docker host networking 支持 (SIP/RTP 需要用到)"
if ! docker run --rm --network host alpine true >/dev/null 2>&1; then
  echo "警告: 这台 Docker 似乎不支持 --network host。"
  echo "请在 Docker Desktop -> Settings -> Resources -> Network 里勾选 'Enable host networking'，然后重启 Docker Desktop 再重试。"
  exit 1
fi

echo "==> 探测本机局域网 IP"
# Docker Desktop 在 macOS 上的 "host networking" 实际上是虚拟机内部的网络栈，容器自己
# 看不到 Mac 真实网卡的地址，SIP/媒体信令里必须显式指定这个地址 (nat_1_to_1_ip)，
# 否则容器会把虚拟机内部地址 (192.168.65.x 之类) 写进 SDP/Via/Contact，导致 SIP 客户端
# (baresip) 收到后认不出来，没法正确应答 (表现为 "no ACK received for 200 OK")。
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
echo "本机局域网 IP: $LAN_IP"

echo "==> 把探测到的局域网 IP 写入 trunk.json"
python3 - "$LAN_IP" <<'PYEOF3'
import json, sys
lan_ip = sys.argv[1]

with open("trunk.json") as f:
    trunk = json.load(f)
addrs = set(trunk["trunk"].get("allowed_addresses", []))
addrs.update({"127.0.0.1", lan_ip})
trunk["trunk"]["allowed_addresses"] = sorted(addrs)
with open("trunk.json", "w") as f:
    json.dump(trunk, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF3

echo "==> 停止阶段一里单独运行的 livekit-server (避免和 Docker 里的 7880 端口冲突)"
[ -f "$ROOT/livekit-server.pid" ] && kill "$(cat "$ROOT/livekit-server.pid")" 2>/dev/null || true
rm -f "$ROOT/livekit-server.pid"

echo "==> 启动 redis + livekit-server (docker compose)"
# --remove-orphans: 清理掉旧版本里 docker-compose.yaml 曾经定义过的 "sip" 容器 (现在
# livekit-sip 改成原生编译运行了，不再用 Docker 跑)
docker compose up -d --force-recreate --remove-orphans

echo "==> 等待 LiveKit server 就绪..."
for i in $(seq 1 30); do
  if curl -sS -m 2 http://127.0.0.1:7880 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> 检查 / 安装编译 livekit-sip 所需的工具 (Go, libopus 等)"
if ! command -v go >/dev/null 2>&1; then
  brew install go
fi
for pkg in pkg-config opus opusfile libsoxr; do
  brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done

echo "==> 获取 livekit-sip 源码 (改成原生编译运行, 不再用 Docker 跑, 见 README 的排错说明)"
if [ ! -d "$DIR/livekit-sip-src/.git" ]; then
  rm -rf "$DIR/livekit-sip-src"
  git clone --depth 1 https://github.com/livekit/sip.git "$DIR/livekit-sip-src"
else
  ( cd "$DIR/livekit-sip-src" && git fetch --depth 1 origin main && git reset --hard origin/main )
fi

echo "==> 编译 livekit-sip (原生 macOS 二进制, 第一次会比较慢, 后面会有 Go 的编译缓存)"
(
  cd "$DIR/livekit-sip-src"
  export PKG_CONFIG_PATH="$(brew --prefix opus)/lib/pkgconfig:$(brew --prefix opusfile)/lib/pkgconfig:$(brew --prefix libsoxr)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  CGO_ENABLED=1 go build -o "$DIR/livekit-sip" ./cmd/livekit-sip
)

echo "==> 生成 livekit-sip 的配置文件"
# use_external_ip 关掉，改用 nat_1_to_1_ip 显式指定局域网 IP —— 原生跑之后 Go 本来就能
# 正确看到 Mac 真实的网络接口了，这里继续显式指定只是为了保险、方便排错。
cat > "$DIR/sip-config.yaml" <<EOF
api_key: 'devkey'
api_secret: 'secret'
ws_url: 'ws://127.0.0.1:7880'
redis:
  address: '127.0.0.1:6379'
sip_port: 5060
rtp_port: 10000-20000
use_external_ip: false
nat_1_to_1_ip: '${LAN_IP}'
media_nat_1_to_1_ip: '${LAN_IP}'
logging:
  level: debug
EOF

echo "==> 停止可能已在运行的旧 livekit-sip 原生进程"
[ -f "$DIR/livekit-sip.pid" ] && kill "$(cat "$DIR/livekit-sip.pid")" 2>/dev/null || true

echo "==> 启动 livekit-sip (原生, 后台运行)"
nohup "$DIR/livekit-sip" --config="$DIR/sip-config.yaml" > "$DIR/sip-server.log" 2>&1 &
echo $! > "$DIR/livekit-sip.pid"
sleep 2
if ! kill -0 "$(cat "$DIR/livekit-sip.pid")" 2>/dev/null; then
  echo "警告: livekit-sip 好像没启动成功, 看看 $DIR/sip-server.log 里的报错"
fi

echo "==> 检查 / 安装 lk CLI (livekit-cli)"
if ! command -v lk >/dev/null 2>&1; then
  brew install livekit-cli
fi

echo "==> 清理旧的 inbound SIP trunk / dispatch rule (保证用最新的 trunk.json 生效)"
python3 - <<'PYEOF2'
import json, subprocess
url = ["--url", "ws://127.0.0.1:7880", "--api-key", "devkey", "--api-secret", "secret"]

def run(args):
    return subprocess.run(["lk"] + args, capture_output=True, text=True)

r = run(["sip", "dispatch", "list", "--json"] + url)
try:
    rules = (json.loads(r.stdout) or {}).get("items", [])
except Exception:
    rules = []
for rule in rules:
    if isinstance(rule, dict) and rule.get("name") == "Local dispatch rule":
        rid = rule.get("sipDispatchRuleId")
        if rid:
            run(["sip", "dispatch", "delete", rid] + url)

r = run(["sip", "inbound", "list", "--json"] + url)
try:
    trunks = (json.loads(r.stdout) or {}).get("items", [])
except Exception:
    trunks = []
for t in trunks:
    if isinstance(t, dict) and t.get("name") == "Local test trunk":
        tid = t.get("sipTrunkId")
        if tid:
            run(["sip", "inbound", "delete", tid] + url)
PYEOF2

echo "==> 创建 inbound SIP trunk"
lk sip inbound create trunk.json --url ws://127.0.0.1:7880 --api-key devkey --api-secret secret

echo "==> 创建 dispatch rule (把呼入的电话路由到 phone-call-room 房间)"
lk sip dispatch create dispatch-rule.json --url ws://127.0.0.1:7880 --api-key devkey --api-secret secret

echo "==> 安装 baresip (命令行 SIP 客户端, 用于本地模拟拨号测试, 不需要账号注册)"
if ! command -v baresip >/dev/null 2>&1; then
  brew install baresip
fi
mkdir -p "$HOME/.baresip"
if [ ! -f "$HOME/.baresip/config" ]; then
  ( baresip -f "$HOME/.baresip" </dev/null >/tmp/baresip-prime.log 2>&1 & BPID=$!; sleep 2; kill $BPID 2>/dev/null || true; wait $BPID 2>/dev/null || true )
fi
echo "baresip 不支持用 127.0.0.1 回环地址拨号, 用局域网 IP ($LAN_IP) 代替"
# 去掉旧的 Local Test 行 (可能用的是过期的 IP), 再写入新的
if [ -f "$HOME/.baresip/accounts" ]; then
  grep -v "^Local Test " "$HOME/.baresip/accounts" > "$HOME/.baresip/accounts.tmp" || true
  mv "$HOME/.baresip/accounts.tmp" "$HOME/.baresip/accounts"
fi
echo "Local Test <sip:1000@${LAN_IP}:5060;transport=udp>;regint=0" >> "$HOME/.baresip/accounts"

echo "==> 构建带补丁的 Speaches 镜像 (修复 Kokoro 中文语音的 zh/cmn 语言代码 bug, 见 Dockerfile.speaches)"
docker build -t speaches-zh-fix -f Dockerfile.speaches .

echo "==> 启动 Speaches (本地 TTS: Kokoro, OpenAI 兼容 API, 端口 8000)"
docker rm -f speaches >/dev/null 2>&1 || true
docker run \
  --rm \
  --detach \
  --publish 8000:8000 \
  --name speaches \
  --volume hf-hub-cache:/home/ubuntu/.cache/huggingface/hub \
  speaches-zh-fix

echo "==> 等待 Speaches 就绪..."
for i in $(seq 1 30); do
  if curl -sS -m 2 http://localhost:8000/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> 检查/安装 uv (用来下载 Speaches 的 TTS 模型)"
if ! command -v uvx >/dev/null 2>&1; then
  brew install uv
fi

echo "==> 下载 TTS 模型 Kokoro (第一次会比较慢)"
export SPEACHES_BASE_URL="http://localhost:8000"
uvx speaches-cli model download speaches-ai/Kokoro-82M-v1.0-ONNX

echo "==> 准备 FunASR (本地 STT, Fun-ASR-Nano 模型, 端口 8001)"
if [ ! -d "$DIR/funasr-venv" ]; then
  python3 -m venv "$DIR/funasr-venv"
fi
source "$DIR/funasr-venv/bin/activate"
pip install -q --upgrade pip
pip install -q torch torchaudio
pip install -q funasr fastapi uvicorn python-multipart

echo "==> 停止可能已在运行的旧 funasr-server 进程"
[ -f "$DIR/funasr-server.pid" ] && kill "$(cat "$DIR/funasr-server.pid")" 2>/dev/null || true

echo "==> 启动 funasr-server (后台运行，Fun-ASR-Nano 模型已下载并缓存好了，启动很快)"
# Fun-ASR-Nano 比 SenseVoice 新，架构是 SenseVoice 编码器 + Qwen3-0.6B，专门针对
# 中英文混说 (code-switching) 场景做过优化，CPU 上大约 3.6x 实时速度，够用。
# (模型文件较大，第一次下载时网络不稳定重试过几次，现已确认下载完整、可正常加载。)
nohup funasr-server --host 127.0.0.1 --port 8001 --model fun-asr-nano --device cpu \
  > "$DIR/funasr-server.log" 2>&1 &
echo $! > "$DIR/funasr-server.pid"
deactivate

echo "==> 等待 funasr-server 就绪..."
for i in $(seq 1 180); do
  if curl -sS -m 2 http://localhost:8001/v1/audio/transcriptions -F "model=fun-asr-nano" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "==> 检查 / 安装 Ollama (本地 LLM)"
if ! command -v ollama >/dev/null 2>&1; then
  brew install ollama
fi
brew services start ollama >/dev/null 2>&1 || true
sleep 2
echo "==> 下载 Ollama 模型 qwen3:8b (Qwen3, 阿里通义千问, 本地跑; 比 2.5 代新, 中文表达更好)"
ollama pull qwen3:8b

echo "==> 准备 Python 虚拟环境并安装 Agent 依赖"
cd "$DIR/agent"
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q --upgrade pip
# --upgrade: 强制升级到 requirements.txt 允许范围内的最新版本，
# 修复旧版 livekit-plugins-openai 的 TTS "no audio frames were pushed" bug
pip install -q --upgrade -r requirements.txt
echo "==> 已安装的 livekit-agents / livekit-plugins-openai 版本:"
pip show livekit-agents livekit-plugins-openai 2>/dev/null | grep -E "^Name|^Version"

echo "==> 停止可能已在运行的旧 agent 进程"
[ -f "$DIR/agent.pid" ] && kill "$(cat "$DIR/agent.pid")" 2>/dev/null || true

echo "==> 启动语音 Agent (后台运行)"
nohup python agent.py dev > "$DIR/agent.log" 2>&1 &
echo $! > "$DIR/agent.pid"
deactivate
sleep 3

echo ""
echo "================================================================"
echo " 全部启动完成！"
echo ""
echo " 用 baresip 拨打这个地址来模拟来电 (新开一个 Terminal 窗口):"
echo "   baresip -f ~/.baresip"
echo " 起来后在 > 提示符下输入:"
echo "   d sip:1000@${LAN_IP}:5060"
echo " 挂断按 b, 退出按 q"
echo ""
echo " 电话接通后会路由进房间 phone-call-room，本地语音 Agent 会自动接听"
echo " (STT: FunASR/Fun-ASR-Nano, LLM: Ollama qwen3:8b (reasoning_effort=none), TTS: Speaches/Kokoro+misaki)"
echo ""
echo " 日志:"
echo "   tail -f $DIR/sip-server.log      # SIP 网桥日志 (原生进程)"
echo "   docker compose logs -f livekit   # LiveKit server 日志"
echo "   tail -f $DIR/funasr-server.log   # FunASR 日志"
echo "   tail -f $DIR/agent.log           # 语音 Agent 日志"
echo ""
echo " 停止全部: bash $DIR/stop.sh"
echo "================================================================"
