#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$DIR/livekit-server.pid" ]; then
  kill "$(cat "$DIR/livekit-server.pid")" 2>/dev/null && echo "livekit-server 已停止"
  rm -f "$DIR/livekit-server.pid"
fi
if [ -f "$DIR/meet-frontend.pid" ]; then
  kill "$(cat "$DIR/meet-frontend.pid")" 2>/dev/null && echo "演示前端已停止"
  rm -f "$DIR/meet-frontend.pid"
fi
