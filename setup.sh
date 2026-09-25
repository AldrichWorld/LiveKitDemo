#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "==> 检查 Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "未检测到 Homebrew。请先安装 Homebrew: https://brew.sh"
  echo '安装命令: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi

echo "==> 安装 livekit-server (Homebrew)"
if ! brew list livekit &>/dev/null; then
  brew update
  brew install livekit
fi
echo "livekit-server 版本: $(livekit-server --version)"

echo "==> 检查 Node.js"
if ! command -v node >/dev/null 2>&1; then
  echo "未检测到 Node.js，正在通过 Homebrew 安装..."
  brew install node
fi

echo "==> 检查 pnpm"
if ! command -v pnpm >/dev/null 2>&1; then
  echo "安装 pnpm..."
  npm install -g pnpm
fi

echo "==> 检查 git-lfs (Meet 演示仓库的背景图用到了 LFS)"
if ! command -v git-lfs >/dev/null 2>&1; then
  brew install git-lfs
fi
git lfs install --skip-repo

echo "==> 停止可能已在运行的旧进程"
[ -f "$DIR/livekit-server.pid" ] && kill "$(cat "$DIR/livekit-server.pid")" 2>/dev/null || true
[ -f "$DIR/meet-frontend.pid" ] && kill "$(cat "$DIR/meet-frontend.pid")" 2>/dev/null || true

echo "==> 启动 livekit-server --dev (后台运行)"
nohup livekit-server --dev > "$DIR/livekit-server.log" 2>&1 &
echo $! > "$DIR/livekit-server.pid"
sleep 2
if ! kill -0 "$(cat "$DIR/livekit-server.pid")" 2>/dev/null; then
  echo "livekit-server 启动失败，请查看 $DIR/livekit-server.log"
  exit 1
fi
echo "livekit-server 已启动 (PID $(cat "$DIR/livekit-server.pid"))，监听 ws://localhost:7880"

echo "==> 准备 LiveKit Meet 演示前端 (每次都重新克隆，确保 checkout 完整不损坏)"
rm -rf "$DIR/meet"
git clone https://github.com/livekit-examples/meet.git "$DIR/meet"
cd "$DIR/meet"
git lfs pull

if [ ! -f "lib/client-utils.ts" ]; then
  echo "错误: clone 后仍然缺少源码文件，请检查上面的 git 输出，网络或磁盘空间可能有问题"
  exit 1
fi

cat > .env.local <<ENV
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret
LIVEKIT_URL=ws://localhost:7880
ENV

rm -rf node_modules .next
pnpm install

echo "==> 启动演示前端 pnpm dev (后台运行)"
nohup pnpm dev > "$DIR/meet-frontend.log" 2>&1 &
echo $! > "$DIR/meet-frontend.pid"
sleep 3

echo ""
echo "================================================"
echo " 全部启动完成！"
echo " LiveKit Server:  ws://localhost:7880"
echo "   API Key:    devkey"
echo "   API Secret: secret"
echo " 演示页面:  http://localhost:3000"
echo ""
echo " 日志文件: $DIR/livekit-server.log , $DIR/meet-frontend.log"
echo " 停止服务: bash $DIR/stop.sh"
echo "================================================"
