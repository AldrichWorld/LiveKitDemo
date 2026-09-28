import logging
import re
from collections.abc import AsyncIterable

from dotenv import load_dotenv
from livekit import rtc
from livekit.agents import Agent, AgentSession, JobContext, ModelSettings, WorkerOptions, cli
from livekit.plugins import aliyun, silero

load_dotenv(".env.local")

logger = logging.getLogger("dashscope-voice-agent")

# 阿里云百炼 (DashScope) —— LLM / STT / TTS 全部走这一个账号的 API Key
# (DASHSCOPE_API_KEY 环境变量，在 .env.local 里配置，参见 aliyun.LLM/STT/TTS
# 的实现：三个类都会自动读取这个环境变量，不用在代码里显式传 api_key)。
#
# 区域说明：livekit-plugins-aliyun 的 LLM 类把 base_url 硬编码成了
# https://dashscope.aliyuncs.com/compatible-mode/v1 (国内/北京区域)。
# STT/TTS 走的是 wss://dashscope.aliyuncs.com/api-ws/v1/inference，同样是国内区域。
# 国内电话场景直接用国内区域的 API Key 即可；如果你的 Key 是国际站(Singapore)开的，
# 这里会直接鉴权失败，需要去百炼控制台确认 Key 所在区域。

# STT 型号：paraformer-realtime-v2 是 livekit-plugins-aliyun 的默认值，但官方
# 已经建议迁移到新一代模型。fun-asr-realtime 官方文档里明确写了支持中英文动态
# 切换识别，作为电话场景的首选；qwen3-asr-flash-realtime 是另一个新模型，值得
# 也测一遍对比准确率/延迟，自己实测后二选一。
STT_MODEL = "fun-asr-realtime"

# STT 的 language 参数是"语言提示"(language_hints)，不是硬性限制——传中文提示时
# 遇到夹杂的英文单词大概率也能识别，但如果整通电话基本讲英文，建议把这里改成 "en"
# 单独测一遍效果。livekit-plugins-aliyun 的 STT 在流式模式下必须显式传 language，
# 不支持自动检测。
STT_LANGUAGE = "zh"

# LLM 型号：qwen-plus 性价比均衡。预算紧张换 qwen-turbo，要更强推理换 qwen-max。
# (qwen-plus/turbo/max 不是"思考模型"，不会像本地 qwen3:8b 那样默认输出大段
# <think>...</think>，所以这里不需要之前 Ollama 版本里那个 reasoning_effort hack。)
LLM_MODEL = "qwen-plus"

# TTS 型号 + 音色：cosyvoice-v3-flash 主打低延迟流式。CosyVoice v3 的很多"中文"
# 音色其实是中英双语的 (比如默认音色 longanyang)，但英文发音总归不如专门的英文
# 音色地道，所以还是保留原来 Kokoro 版本那套"按实际要念的文本是中文还是英文,
# 动态切换音色"的思路，只是把两个音色都换成 DashScope 这边的:
#   - longxiaochun_v3: 女声,中文为主(带基本英文能力)
#   - loongannie_v3: 女声,美式英语
# 完整音色列表: https://help.aliyun.com/zh/model-studio/cosyvoice-voice-list
TTS_MODEL = "cosyvoice-v3-flash"
TTS_VOICE_ZH = "longxiaochun_v3"
TTS_VOICE_EN = "loongannie_v3"

# 判断一段文本是中文还是英文：只要出现汉字就当中文处理 (常见中英文混说场景里，
# 中文音色对夹杂的英文单词容错度还可以；纯英文才需要切到英文音色，否则中文音色
# 读纯英文会不够地道)。
_CJK_RE = re.compile(r"[一-鿿㐀-䶿]")


def _is_chinese(text: str) -> bool:
    return bool(_CJK_RE.search(text or ""))


def _make_tts(voice: str) -> aliyun.TTS:
    return aliyun.TTS(model=TTS_MODEL, voice=voice)


class Assistant(Agent):
    def __init__(self) -> None:
        super().__init__(
            instructions=(
                "你是一个通过电话接听的语音助手。请用简洁、口语化的方式回答，"
                "每次回复尽量不超过两句话。请跟着来电者使用的语言来回复："
                "对方说中文你就用中文回答，对方说英文你就用英文回答，不要混着两种语言"
                "写在同一句回复里 (语音合成引擎每次只能读好一种语言)。"
            )
        )
        self._tts_zh = _make_tts(TTS_VOICE_ZH)
        self._tts_en = _make_tts(TTS_VOICE_EN)

    async def tts_node(
        self, text: AsyncIterable[str], model_settings: ModelSettings
    ) -> AsyncIterable[rtc.AudioFrame]:
        # 和之前 Kokoro 版本同样的原因：LLM 不一定每次都严格遵守"跟着对方语言
        # 回复"的提示，所以不去猜用户上一句话的语言，而是在真正要合成语音这一步，
        # 直接看"实际要念出来的文本"本身是中文还是英文，保证语音和文本内容永远
        # 匹配。代价是要先把这一轮文本流缓冲完才能判断语言，会晚一点点开始出声。
        chunks: list[str] = []
        async for chunk in text:
            chunks.append(chunk)
        full_text = "".join(chunks).strip()

        target_tts = self._tts_zh if _is_chinese(full_text) else self._tts_en
        self.update_options(tts=target_tts)

        async def _replay() -> AsyncIterable[str]:
            yield full_text

        async for frame in Agent.default.tts_node(self, _replay(), model_settings):
            yield frame


async def entrypoint(ctx: JobContext):
    await ctx.connect()

    session = AgentSession(
        stt=aliyun.STT(
            model=STT_MODEL,
            language=STT_LANGUAGE,
        ),
        llm=aliyun.LLM(model=LLM_MODEL),
        tts=_make_tts(TTS_VOICE_ZH),  # 默认中文音色，开场白用这个
        vad=silero.VAD.load(),
    )

    await session.start(agent=Assistant(), room=ctx.room)
    await session.generate_reply(
        instructions="用一句话向刚接通电话的用户打招呼，并询问需要什么帮助。"
    )


if __name__ == "__main__":
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))
