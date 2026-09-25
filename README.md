# 本地 LiveKit 测试/演示环境

这个文件夹里已经准备好了一键启动脚本，用于在你的 Mac 上本地跑起 LiveKit server（dev 模式）+ 官方 Meet 演示前端。

## 为什么需要你手动跑一下

我（Claude）可以在这台 Mac 上读写文件，但出于安全限制，不能直接在你的真实终端里帮你敲命令、装软件、起后台服务。所以这一步需要你自己在 Terminal 里运行一条命令，之后的启动、克隆代码、装依赖都是全自动的。

## 使用步骤

1. 打开 Terminal（或 iTerm），运行：

   ```bash
   bash ~/Projects/livekit-test/setup.sh
   ```

   这个脚本会自动：
   - 检查/通过 Homebrew 安装 `livekit-server`（如果没有 Homebrew，会提示你先装）
   - 检查/安装 Node.js、pnpm
   - 后台启动 `livekit-server --dev`（监听 `ws://localhost:7880`，默认调试用的 API Key/Secret 是 `devkey` / `secret`）
   - 克隆官方演示前端 livekit-examples/meet 到 `meet/` 子目录，自动配置好 `.env.local`
   - 后台启动演示前端（`http://localhost:3000`）

2. 脚本跑完后，在浏览器打开 http://localhost:3000 ，输入一个房间名即可测试音视频通话（可以开两个浏览器标签页/两台设备模拟两人通话）。

3. 测试完想停止服务，运行：

   ```bash
   bash ~/Projects/livekit-test/stop.sh
   ```

## 连接信息（给你自己的 App/SDK 用）

| 项目 | 值 |
|---|---|
| Server URL | ws://localhost:7880 |
| API Key | devkey |
| API Secret | secret |

--dev 模式仅用于本地测试，未做鉴权/生产加固，不要暴露到公网。如果想让局域网内其它设备（比如手机）也能连，把 setup.sh 里的 `livekit-server --dev` 改成 `livekit-server --dev --bind 0.0.0.0`，然后用这台 Mac 的局域网 IP 替代 localhost。

## 日志与排错

- LiveKit server 日志：livekit-server.log
- 演示前端日志：meet-frontend.log
- 如果端口被占用或启动失败，看这两个日志文件里的报错信息。

## 如果你更想用 Docker

也可以用官方 Docker 镜像替代 Homebrew 安装方式（需要先装好 Docker Desktop）：

```bash
docker run --rm -p 7880:7880 -p 7881:7881 -p 7882:7882/udp \
  livekit/livekit-server --dev
```

其余（演示前端、连接信息）用法一致。
