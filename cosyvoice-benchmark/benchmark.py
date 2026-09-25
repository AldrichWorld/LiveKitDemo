import os
import sys
import time

sys.path.append('third_party/Matcha-TTS')

from cosyvoice.cli.cosyvoice import AutoModel

print('Loading model...')
t0 = time.perf_counter()
cosyvoice = AutoModel(model_dir='pretrained_models/Fun-CosyVoice3-0.5B')
t1 = time.perf_counter()
print('Model load time: {:.1f}s'.format(t1 - t0))

prompt_wav_path = os.path.expanduser('~/Desktop/kokoro_zh_voices/zf_xiaoxiao.wav')
prompt_text = '谢谢你的帮助，我周末喜欢去爬山，你叫什么名字？'

target_text = '谢谢你的夸奖，我随时都可以为你服务，你还有别的问题吗？'

print('Synthesizing...')
t2 = time.perf_counter()
chunks = []
for out in cosyvoice.inference_zero_shot(target_text, prompt_text, prompt_wav_path, stream=False):
    chunks.append(out['tts_speech'])
t3 = time.perf_counter()

synth_time = t3 - t2
total_samples = sum(c.shape[-1] for c in chunks)
audio_duration = total_samples / cosyvoice.sample_rate

import torch
import torchaudio
full_audio = chunks[0] if len(chunks) == 1 else torch.cat(chunks, dim=-1)
out_path = os.path.expanduser('~/Desktop/cosyvoice_benchmark_output.wav')
torchaudio.save(out_path, full_audio, cosyvoice.sample_rate)

rtf = synth_time / audio_duration
print('---RESULTS---')
print('Synthesis wall time: {:.2f}s'.format(synth_time))
print('Audio duration: {:.2f}s'.format(audio_duration))
print('Real-time factor (wall/audio): {:.2f}'.format(rtf))
if rtf < 1.0:
    print('FASTER than real-time -> usable for live phone calls')
else:
    print('SLOWER than real-time -> not usable as-is')
print('Output saved to: ' + out_path)
