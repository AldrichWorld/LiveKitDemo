#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$DIR/agent.pid" ]; then
  kill "$(cat "$DIR/agent.pid")" 2>/dev/null && echo "语音 Agent 已停止"
  rm -f "$DIR/agent.pid"
fi

if [ -f "$DIR/funasr-server.pid" ]; then
  kill "$(cat "$DIR/funasr-server.pid")" 2>/dev/null && echo "FunASR 已停止"
  rm -f "$DIR/funasr-server.pid"
fi

if [ -f "$DIR/livekit-sip.pid" ]; then
  kill "$(cat "$DIR/livekit-sip.pid")" 2>/dev/null && echo "livekit-sip (原生进程) 已停止"
  rm -f "$DIR/livekit-sip.pid"
fi

docker rm -f speaches >/dev/null 2>&1 && echo "Speaches 已停止"

cd "$DIR"
docker compose down && echo "redis / livekit 已停止"

echo "(Ollama 是长期后台服务，没有一并停止；如需停止: brew services stop ollama)"
