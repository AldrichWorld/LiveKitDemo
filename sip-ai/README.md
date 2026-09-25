# 本地电话拨入 + AI 语音接听（Phase 2）

在 Phase 1（房间 Demo）的基础上，这一部分加了：
- LiveKit SIP 网桥（`livekit-sip`，从源码原生编译成 macOS 二进制运行，原因见下面"排错"），让软电话可以"打电话"进 LiveKit 房间
- 一个本地语音 AI Agent，自动接听并对话——全部用本地/免费模型，不需要任何外部 API Key：
  - STT（语音转文字）：[FunASR](https://github.com/modelscope/FunASR)（阿里达摩院，SenseVoice 模型，中英文效果都不错）
  - LLM（对话大模型）：[Ollama](https://ollama.com/) 跑 **Qwen2.5**（阿里通义千问，7B，本地跑）
  - TTS（文字转语音）：[Speaches](https://speaches.ai/)（Kokoro 模型）

## 前置条件

- 已经跑完 Phase 1（`../setup.sh`），确认过 `http://localhost:3000` 的视频会议 demo 能用
- 装好 **Docker Desktop** 并打开它（`redis` + `livekit-server` 用 Docker 跑；`livekit-sip` 现在是原生编译运行，不用 Docker，见下面"排错"）
- Docker Desktop 里勾选了 **"Enable host networking"**（Settings -> Resources -> Network），`livekit-server` 需要用到。脚本会自动检测，如果不支持会提示你去开启。
- 需要能编译 Go 程序：脚本会自动用 Homebrew 装 **Go** 和 `livekit-sip` 依赖的 C 库（`opus`/`opusfile`/`libsoxr`/`pkg-config`），第一次编译需要一点时间；如果你的 Mac 上还没装过 Xcode 命令行工具（`xcode-select --install`），系统可能会弹出安装提示，装完再重跑就行。
- 磁盘空间和耐心：FunASR 依赖 PyTorch（几百 MB~1GB+），加上 SenseVoice、Kokoro、Qwen2.5:7b 几个模型权重，第一次跑完整套下载可能有 5-10GB，根据网速可能要花一段时间。

## 一键启动

```bash
bash ~/Projects/livekit-test/sip-ai/setup.sh
```

这个脚本会自动：
1. 探测本机局域网 IP（`livekit-sip` 的 SDP/Via/Contact 要用它，见"排错"）
2. 停掉 Phase 1 里单独跑的 `livekit-server`（避免端口冲突，改由 Docker Compose 里的 LiveKit 接管，同样是 `ws://localhost:7880` / `devkey` / `secret`，Meet 那个 demo 页面不用改配置，一样能连）
3. 用 Docker Compose 拉起 `redis` + `livekit-server`
4. 用 Homebrew 装 Go / opus 等依赖，拉取 `livekit/sip` 源码并编译成原生 macOS 二进制，后台启动（配置文件 `sip-config.yaml`，每次重跑都会用最新探测到的局域网 IP 重新生成）
5. 用 `lk` CLI 创建一个本地测试用的 inbound SIP trunk（不限号码，只允许 `127.0.0.1` 和本机局域网 IP 拨入）和一条 dispatch rule（呼入统一路由到 `phone-call-room` 房间）
6. 通过 Homebrew 安装 **baresip**（命令行 SIP 客户端，用来模拟"打电话"，配置成不需要注册账号）
7. 跑起来 **Speaches** 容器，下载 Kokoro TTS 模型
8. 建一个独立的 Python 虚拟环境装 **FunASR**，起一个 OpenAI 兼容的本地 STT 服务（`funasr-server`，端口 8001，模型用 `sensevoice`），第一次启动会自动下载 SenseVoice 模型权重
9. 检查/安装 **Ollama**，下载 `qwen2.5:7b` 模型
10. 建 Python 虚拟环境，装好 `livekit-agents`，后台启动语音 Agent（STT 接 FunASR，LLM 接 Ollama/Qwen，TTS 接 Speaches/Kokoro）

## 测试步骤

> 之前试过用 Linphone 图形界面软电话，但它新版本强制要求账号"注册成功"才能进主界面，而我们的本地 SIP 网桥（`livekit-sip`）设计上就不支持账号注册（它是电话中继桥接器，不是完整 PBX），两者卡死循环，所以换成了命令行的 **baresip**，配置里用 `regint=0` 关掉注册，直接拨号。

1. 新开一个 Terminal 窗口，运行：

   ```bash
   baresip -f ~/.baresip
   ```

2. 等它启动完，在 `>` 提示符下输入：

   ```
   d sip:1000@<你的局域网 IP>:5060
   ```

   （`setup.sh` 跑完会打印这个 IP，比如 `d sip:1000@192.168.8.217:5060`；baresip 不支持拨
   `127.0.0.1` 回环地址。）

   回车呼叫。

3. 几秒内应该能听到本地 AI Agent 用语音打招呼（需要 Mac 的麦克风权限，第一次运行 baresip 时系统可能会弹出授权提示，允许即可）。跟它说中文或英文都可以，SenseVoice 转文字 -> Qwen2.5 生成回复 -> Kokoro 念出来。

4. 挂断电话按 `b`，退出 baresip 按 `q`。

## 想换模型大小

- **Qwen 模型**：Mac 内存/算力富余可以换更大的，比如 `qwen2.5:14b`；如果想要更快响应可以换小一点，比如 `qwen2.5:3b`。改 `setup.sh` 里的 `ollama pull qwen2.5:7b` 和 `agent/agent.py` 里的 `OLLAMA_MODEL` 常量，保持两处一致即可，改完重跑 `setup.sh`（`ollama pull` 换模型名会自动下载新的，不会重复下载已存在的）。
- **FunASR 模型**：`sensevoice` 是多语言通用模型；如果只需要中文/英文可以换成 `paraformer`（中文场景通常更准）。改 `setup.sh` 里 `funasr-server --model` 和 `agent/agent.py` 里的 `STT_MODEL` 常量。
- **TTS 语音**：Kokoro 是按语言分语音的，一个语音只服务一种语言。`agent/agent.py` 里的 `TTS_VOICE`
  现在用的是中文女声 `zf_xiaoxiao`；其它中文语音还有 `zf_xiaobei`/`zf_xiaoni`/`zf_xiaoyi`（女）、
  `zm_yunjian`/`zm_yunxi`/`zm_yunxia`/`zm_yunyang`（男）；如果想用英文语音，换回 `af_heart` 之类的
  `af_*`/`am_*` 语音即可，但那样合成中文文本就会是空白音频（见下面排错"已知问题 3"）。

## 排错

- **已知问题 1：TTS 报错 "no audio frames were pushed for text"（agent.log 里能看到）**
  - 根因：`livekit-plugins-openai` 早期版本判断"服务器返回的是不是 SSE 流"是看 `model` 参数是不是
    `tts-1`/`tts-1-hd`，不是 `speaches-ai/Kokoro-82M-v1.0-ONNX` 就默认按 SSE 格式解析，而 Speaches
    实际上直接返回了原始音频字节，于是解析失败、拿不到任何音频帧。这个问题在
    `livekit-agents`/`livekit-plugins-openai` 1.8.2 里已经修复（改成按响应的 `Content-Type` 判断，
    而不是按 model 名字判断）。
  - 修复：`requirements.txt` 已经改成 `livekit-agents[openai,silero]>=1.8.2,<2.0.0`，`setup.sh` 里
    也把 `pip install -q -r requirements.txt` 改成了 `pip install -q --upgrade -r requirements.txt`，
    这样重跑 `setup.sh` 会自动升级到修复后的版本（如果你之前跑过、`.venv` 里装的是旧版本，之前不会
    自动升级，所以必须带 `--upgrade` 才会生效）。
  - 验证：`setup.sh` 跑完会打印 `pip show livekit-agents livekit-plugins-openai` 的结果，确认
    `Version` 是 `1.8.2` 或更高。

- **已知问题 2：SIP 呼叫接通后又断开，SIP 日志里显示 "no ACK received for 200 OK"**（现在已经通过"不用 Docker 跑 livekit-sip"从根上解决，这里记录一下排查过程，供参考）
  - 第一步定位：用 `tcpdump` 抓包 + baresip 的 `-s` SIP trace 发现，`livekit-sip` 发给 baresip 的
    SDP/Via/Contact 里用的地址是 `192.168.65.x`（Docker Desktop 内部虚拟机的网段），不是 Mac 真实
    网卡的局域网地址。这是因为 Docker Desktop 在 macOS 上的"host networking"并不是 Linux 上那种
    真正共享主机网络栈的 host networking，而只是共享了 Docker Desktop 自己内部那个 Linux 虚拟机的
    网络栈，容器自己看不到 Mac 真实的 `192.168.x.x` 网段。
  - 第一次尝试（不够）：改成用 `nat_1_to_1_ip` / `media_nat_1_to_1_ip` 显式指定 Mac 的局域网 IP，
    确认了这能让 SDP/Via/Contact 里的地址正确变成 `192.168.8.217`，但呼叫依然 "no ACK received"。
  - 真正根因：继续用 baresip 的 `-s` SIP trace 细看才发现，baresip 其实**根本没有收到过** 200 OK
    这条消息本身——只收到了后来从另一个端口发来的 BYE。也就是说不是地址内容错了，而是 Docker
    Desktop 的 "host networking" 对 UDP 的双向转发本身不可靠，尤其是"容器用收到请求时的同一个源
    端口回包"这种模式，经常在虚拟机的网络桥接层被吞掉。这是 Docker Desktop for Mac 的已知限制，配置
    调不出来。
  - 最终修复：不再用 Docker 跑 `livekit-sip`。`setup.sh` 现在会用 Homebrew 装 Go 和 `opus`/
    `opusfile`/`libsoxr`（`livekit-sip` 依赖的音频编解码库），把 `livekit/sip` 仓库源码 clone 下来，
    `CGO_ENABLED=1 go build` 编译出一个原生 macOS 二进制（`livekit-sip`），用一份本地
    `sip-config.yaml`（同样带着自动探测到的 `nat_1_to_1_ip`）后台启动，日志写到 `sip-server.log`。
    原生进程直接用 Mac 自己真实的网络栈收发 UDP，不再经过 Docker Desktop 那层虚拟机桥接，问题
    就不存在了。`redis` 和 `livekit-server` 继续留在 Docker 里（它们走 TCP/WebSocket，没有这个坑）。
  - 如果你的 Mac 换了网络（比如接了不同的 Wi-Fi），直接重跑 `setup.sh` 就会自动用新的 IP 重新生成
    `sip-config.yaml` 和 `trunk.json`，不需要手动编辑任何文件。

- **已知问题 3：TTS 合成中文一直失败，分两个层次**
  - **3a. 用英语语音（`af_heart` 等 `af_*`/`am_*`）合成中文文本**：Speaches 返回 HTTP 200，但响应体
    是 0 字节——不报错，就是什么都没生成，`livekit-agents` 那边看到的是 "no audio frames were
    pushed"。原因很直接：Kokoro 是按语言分语音的，英语语音不认识中文文本。
    验证方法：
    ```bash
    curl http://localhost:8000/v1/audio/speech -H "Content-Type: application/json" \
      --output /tmp/test_zh.wav \
      -d '{"input":"你好，请问需要什么帮助？","model":"speaches-ai/Kokoro-82M-v1.0-ONNX","voice":"af_heart"}'
    ls -la /tmp/test_zh.wav   # 这里会是 0 字节
    ```
    第一步修复：`agent/agent.py` 的 `TTS_VOICE` 换成中文语音 `zf_xiaoxiao`（八个内置普通话语音之一：
    `zf_xiaobei`/`zf_xiaoni`/`zf_xiaoxiao`/`zf_xiaoyi`/`zm_yunjian`/`zm_yunxi`/`zm_yunxia`/
    `zm_yunyang`），Agent 的 system prompt 也改成了统一用中文回答（避免用中文语音去读英文，发音会不准）。
  - **3b. 换成中文语音（`zf_xiaoxiao` 等）之后，合成请求直接连接中断**（`curl: (18) transfer closed
    with outstanding read data remaining`）。这才是真正的根因，是 **Speaches 项目自己的一个 bug**：
    `docker logs speaches` 能看到 `RuntimeError: language "zh" is not supported by the espeak
    backend`。Speaches 给所有中文语音（`zf_*`/`zm_*`）标注的语言代码是 `"zh"`，直接把这个字符串传给
    espeak-ng 做音素转换，但 espeak-ng 实际认的普通话语言代码是 `"cmn"`，不是 `"zh"`，所以只要用中文
    语音必然会撞上这个错误，跟选哪个具体的中文语音无关。
  - 修复：新增了 `Dockerfile.speaches`，在官方 `ghcr.io/speaches-ai/speaches:latest-cpu` 镜像基础上
    构建时打一行补丁，把 Kokoro 中文语音注册表里的 `language="zh"` 全部改成 `language="cmn"`（补丁里带
    了 `grep` 断言：如果以后上游镜像结构变了导致改不到，构建会直接报错失败，而不是悄悄不生效）。
    `setup.sh` 现在会先 `docker build` 这个补丁镜像（`speaches-zh-fix`），再用它启动 Speaches 容器，
    所以每次重跑 `setup.sh` 这个修复都还在，不会因为容器重建就丢失。
  - 如果你想同时支持中英文自然发音（而不是全部统一用中文回答），需要按每句回复文本的语言动态切换
    `voice`（现在没做，是可以加的功能，跟我说一声）。

- `tail -f sip-ai/sip-server.log` — 看 SIP 网桥（原生进程）有没有收到呼叫
- `docker compose logs -f livekit` — 看房间/参与者事件
- `tail -f sip-ai/funasr-server.log` — 看 FunASR 是否正常启动/识别
- `tail -f sip-ai/agent.log` — 看语音 Agent 有没有正常加入房间、STT/LLM/TTS 有没有报错
- 如果编译 `livekit-sip` 失败：大概率是缺 Xcode 命令行工具（跑一下 `xcode-select --install`）或者
  Homebrew 的 `opus`/`opusfile`/`libsoxr` 没装上，重跑一下 `setup.sh` 里对应那几行看报错
- 如果 baresip 拨号没反应：确认 `sip-server.log` 里 `livekit-sip` 有没有正常启动（没有 panic/报错），
  以及没有其它程序占用 5060/UDP 端口
- 单独测试各个本地服务是否正常：
  ```bash
  # FunASR (STT)
  curl http://localhost:8001/v1/audio/transcriptions -F "model=sensevoice" -F "file=@some.wav"

  # Speaches (TTS)
  curl http://localhost:8000/v1/audio/speech -H "Content-Type: application/json" \
    --output /tmp/test.wav -d '{"input":"hello","model":"speaches-ai/Kokoro-82M-v1.0-ONNX","voice":"af_heart"}'

  # Ollama (LLM)
  ollama run qwen2.5:7b "你好"
  ```

## 停止

```bash
bash ~/Projects/livekit-test/sip-ai/stop.sh
```

## 关于"真实电话号码"

这一套全部是本地模拟（软电话 -> 本地 SIP 网桥），不涉及真实电话网络。如果以后想让真实手机号码拨进来，需要额外购买一个 SIP 中继服务（比如 Twilio、Telnyx），把公网号码路由到这里的 trunk —— 这一步涉及注册账号和付费，需要你自己开通，我可以在你开通后帮你接后续配置。
