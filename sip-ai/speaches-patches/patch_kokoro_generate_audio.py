"""
构建 speaches-zh-fix 镜像时运行一次：把 generate_audio() 改成中文语音走
misaki 音素转换、其他语言维持原样 (走 kokoro-onnx 自带的 espeak-ng 流程)。
"""
path = "/home/ubuntu/speaches/src/speaches/executors/kokoro/utils.py"
with open(path, encoding="utf-8") as f:
    content = f.read()

old = (
    "    voice_language = next(v.language for v in VOICES if v.name == voice)\n"
    "    start = time.perf_counter()\n"
    "    async for audio_data, _ in kokoro_tts.create_stream(text, voice, lang=voice_language, speed=speed):\n"
)
new = (
    "    voice_language = next(v.language for v in VOICES if v.name == voice)\n"
    "    start = time.perf_counter()\n"
    "    if voice_language.startswith(\"cmn\") or voice_language == \"zh\":\n"
    "        from speaches.zh_g2p import zh_text_to_phonemes\n"
    "        stream_text = zh_text_to_phonemes(text)\n"
    "        use_phonemes = True\n"
    "    else:\n"
    "        stream_text = text\n"
    "        use_phonemes = False\n"
    "    async for audio_data, _ in kokoro_tts.create_stream(\n"
    "        stream_text, voice, lang=voice_language, speed=speed, is_phonemes=use_phonemes\n"
    "    ):\n"
)
assert old in content, "marker not found in kokoro/utils.py -- upstream file structure changed, patch needs updating"
if "zh_text_to_phonemes" not in content:
    content = content.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print("patched generate_audio() to use misaki for Chinese voices")
else:
    print("already patched")
