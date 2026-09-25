"""
中文文字转音素：用 misaki 的 ZHG2P 代替 kokoro-onnx 自带的、基于 espeak-ng 的通用
phonemize 流程。espeak-ng 对中文要么产出乱码 (lang="cmn")，要么把声调用数字表示
(lang="cmn-latn-pinyin"，如 "ni2 hao2")——但数字不在 Kokoro 的音素表里，会被直接
过滤掉，导致合成出来的中文没有声调，听起来很奇怪。misaki 生成的音素自带声调符号
(→↓↗↘，分别对应一二三四声)，这些符号正好都在 Kokoro 的音素表里，不会被过滤掉。

中英文混说处理：ZHG2P 本身带一个 en_callable 参数，官方设计用来把混进中文里的
英文片段交给英文 G2P 处理，但实测这个接口在当前版本里不生效——misaki 自己源码里
也写着 "TODO: Interleaved English is brittle, needs improvement."：即使传了
en_callable，遇到英文单词 (比如 "APP"、"machine learning") 还是原样甩出来，被
Kokoro 当成英文字母逐个硬拼读，听起来非常怪 (电话测试里出现过的"助→Wu4"这类
诡异发音，根源就是这个——回复文本里混进的英文单词/缩写没有被正确转换)。
所以这里不依赖 ZHG2P 内部这个不稳定的机制，改成自己在外层先把文本按"连续英文
字母数字" vs "其余部分 (中文等)" 切分开：中文片段交给 misaki.zh，纯英文片段单独
交给 misaki.en (Kokoro 原生支持英文时用的就是这套引擎，生成的音素本来就在 Kokoro
的音素表里)，分别转换完再按原顺序拼起来。这样中英混说时，英文部分至少会读成
正确的英文音素 (会带一点中文语音的口音，因为最终还是用同一个中文语音的音色去
发声，但不会再是逐字母乱拼的怪声)。
"""
import re
import threading

from misaki import en, zh

# 注意：这里必须用 RLock（可重入锁），不能用普通 Lock。
# zh_text_to_phonemes() 会先拿锁，再在锁里调用 _get_zh_g2p()/_get_en_g2p()，
# 而这两个函数在第一次初始化时也要拿同一把锁——普通 Lock 不允许
# 同一个线程重复获取，会直接死锁（第一次实测时踩过这个坑）。
_lock = threading.RLock()
_zh_g2p = None
_en_g2p = None

# 匹配一段连续的英文字母/数字 (含撇号、连字符，比如 "don't"、"co-founder")。
_LATIN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9'\-]*")


def _get_zh_g2p():
    global _zh_g2p
    if _zh_g2p is None:
        with _lock:
            if _zh_g2p is None:
                _zh_g2p = zh.ZHG2P(version=None)
    return _zh_g2p


def _get_en_g2p():
    global _en_g2p
    if _en_g2p is None:
        with _lock:
            if _en_g2p is None:
                _en_g2p = en.G2P(british=False)
    return _en_g2p


def zh_text_to_phonemes(text: str) -> str:
    if not text.strip():
        return ""
    with _lock:
        parts = re.split(r"([A-Za-z0-9][A-Za-z0-9'\-]*)", text)
        out = []
        for seg in parts:
            if not seg:
                continue
            if _LATIN_RE.fullmatch(seg):
                phonemes, _ = _get_en_g2p()(seg)
            else:
                phonemes, _ = _get_zh_g2p()(seg)
            out.append(phonemes)
    return " ".join(out).strip()
