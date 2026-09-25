import logging
import re
from collections.abc import AsyncIterable

from dotenv import load_dotenv
from livekit import rtc
from livekit.agents import Agent, AgentSession, JobContext, ModelSettings, WorkerOptions, cli
from livekit.plugins import openai, silero

load_dotenv(".env.local")

logger = logging.getLogger("local-voice-agent")

# 本地 FunASR (STT, OpenAI 兼容 API, funasr-server 起在 8001 端口)
# Fun-ASR-Nano 比 SenseVoice 新，架构是 SenseVoice 编码器 + Qwen3-0.6B，
# 专门针对中英文混说 (code-switching) 场景优化过，CPU 上约 3.6x 实时速度。
FUNASR_URL = "http://localhost:8001/v1"
STT_MODEL = "fun-asr-nano"

# 本地 Speaches (TTS, OpenAI 兼容 API, 端口 8000)
# Kokoro 这个模型是按语言分语音的：一个语音只服务一种语言，中文语音读英文、
# 英文语音读中文都会发音不准/很怪，甚至会卡很久 (见下面 Assistant.tts_node 的说明)。
# 所以这里准备两套语音，按"实际要念出来的这句回复文本"动态切换。
SPEACHES_URL = "http://localhost:8000/v1"
TTS_MODEL = "speaches-ai/Kokoro-82M-v1.0-ONNX"
TTS_VOICE_ZH = "zf_xiaoxiao"  # Kokoro 官方内置的普通话女声之一
TTS_VOICE_EN = "af_heart"    # Kokoro 官方内置的英语女声之一
# 注意: 如果 af_heart 这个语音名跟你本地 speaches 提供的语音列表对不上，
# 用 `curl http://localhost:8000/v1/audio/voices` 查一下实际可用的名字改这里。

# 本地 Ollama (LLM, OpenAI 兼容 API, 跑 Qwen)
# qwen3:8b 比之前的 qwen2.5:7b 新一代，中文表达能力更好，体积相近 (Q4 约 5.2GB)，
# 32GB 内存的机器跑起来跟 2.5 代差不多吃得消。
OLLAMA_URL = "http://localhost:11434/v1"
OLLAMA_MODEL = "qwen3:8b"

# 判断一段文本是中文还是英文：只要出现汉字就当中文处理 (常见中英文混说场景里，
# 中文语音+misaki 音素化对夹杂的英文单词容错度还可以；纯英文才需要切到英文语音，
# 否则中文语音读英文会非常不准)。
_CJK_RE = re.compile(r"[一-鿿㐀-䶿]")


def _is_chinese(text: str) -> bool:
    return bool(_CJK_RE.search(text or ""))


def _make_tts(voice: str) -> openai.TTS:
    return openai.TTS(
        base_url=SPEACHES_URL,
        model=TTS_MODEL,
        voice=voice,
        api_key="not-needed",
        response_format="wav",
    )


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
        # 之前的版本是根据"用户刚才说的是中文还是英文"提前切语音，但 LLM 不一定
        # 每次都严格遵守"跟着对方语言回复"的提示——真实测试里出现过用户说英文、
        # LLM 却用中文回复的情况，这时候如果 TTS 已经提前切到了英文语音，就会变成
        # "用英文语音去读中文文本"，Kokoro 会把这段中文交给 espeak 走英文的音素化
        # 路径处理，结果不是发音诡异，就是卡很久甚至像坏掉了一样(用户反馈"疯了")。
        # 所以改成在这里 (真正要合成语音的这一步) 直接看"实际要念出来的文本"本身
        # 是中文还是英文，而不是去猜用户上一句话的语言，这样语音和文本内容永远是
        # 匹配的。代价是要先把这一轮的文本流缓冲完才能判断语言，会晚一点点开始出声
        # (通常也就一两句话，问题不大)。
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
        stt=openai.STT(
            base_url=FUNASR_URL,
            model=STT_MODEL,
            api_key="not-needed",
        ),
        llm=openai.LLM.with_ollama(
            model=OLLAMA_MODEL,
            base_url=OLLAMA_URL,
            # qwen3 系列默认会先输出一大段 <think>...</think> 内心独白再正式回答，
            # 电话语音场景绝对不能要这个 (会被 TTS 整段读出来，还很慢)。
            # reasoning_effort="none" 会被 livekit-plugins-openai 转成请求里的
            # reasoning_effort 字段，Ollama 的 OpenAI 兼容接口认这个字段，
            # 收到后会在其内置的 qwen3 模板里插入一个空的 <think></think>，
            # 从结构上就不给模型输出思考内容的机会 (不是"建议它别想"，是根本没机会想)。
            reasoning_effort="none",
        ),
        tts=_make_tts(TTS_VOICE_ZH),  # 默认中文语音，开场白用这个
        vad=silero.VAD.load(),
    )

    await session.start(agent=Assistant(), room=ctx.room)
    await session.generate_reply(
        instructions="用一句话向刚接通电话的用户打招呼，并询问需要什么帮助。"
    )


if __name__ == "__main__":
    cli.run_app(WorkerOptions(entrypoint_fnc=entrypoint))
