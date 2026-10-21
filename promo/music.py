"""合成宣传片的背景音乐，输出 out/music.wav（48 kHz 立体声）。

只依赖 numpy。速度 120 BPM，一小节 2 秒，正好对齐分镜的镜头切换。
改了分镜的转场时间，同步改下面的 CUES。
"""

import pathlib
import wave

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
SR = 48_000
DURATION = 20.0
BPM = 120
BEAT = 60 / BPM
N = int(SR * DURATION)
T = np.arange(N) / SR

# 镜头切换点（秒）：每个点前有一段上扬的“嗖”声，落点有一下轻击。
CUES = [3.5, 6.5, 10.0, 13.0]
# 品牌落版的重击点（秒）：鼓组在这里停下，只留和弦长音。
LOGO = 16.0

# 每小节一个和弦（MIDI 音高），A 小调走向，最后落到 C 大调。
CHORDS = [
    [57, 60, 64, 69],  # Am
    [53, 57, 60, 65],  # F
    [48, 55, 60, 64],  # C
    [55, 59, 62, 67],  # G
    [57, 60, 64, 69],  # Am
    [53, 57, 60, 65],  # F
    [48, 55, 60, 64],  # C
    [55, 59, 62, 67],  # G
    [53, 57, 60, 64],  # Fmaj7
    [48, 55, 62, 64],  # Cadd9
]
BAR = 4 * BEAT

rng = np.random.default_rng(7)


def hz(midi):
    return 440.0 * 2 ** ((np.asarray(midi) - 69) / 12)


def env_adsr(n, a, d, s, r):
    """n 个采样的 ADSR 包络，a/d/r 单位为秒。"""
    e = np.full(n, s, dtype=float)
    ia, idd, ir = int(a * SR), int(d * SR), int(r * SR)
    ia = min(ia, n)
    e[:ia] = np.linspace(0, 1, ia, endpoint=False)
    end_d = min(ia + idd, n)
    e[ia:end_d] = np.linspace(1, s, end_d - ia, endpoint=False)
    if ir > 0:
        ir = min(ir, n)
        e[n - ir:] *= np.linspace(1, 0, ir)
    return e


def place(buf, start, sig, gain=1.0):
    """把 sig 叠加到 buf 的 start 秒处。"""
    i = int(start * SR)
    if i >= len(buf):
        return
    j = min(len(buf), i + len(sig))
    buf[i:j] += gain * sig[: j - i]


def saw(freq, n, phase=0.0):
    p = (phase + np.arange(n) * freq / SR) % 1.0
    return 2 * p - 1


def stft_filter(x, mask_fn, size=2048, hop=512):
    """逐帧频域滤波：mask_fn(帧中心时间, 频率数组) 返回增益。"""
    win = np.hanning(size)
    freqs = np.fft.rfftfreq(size, 1 / SR)
    pad = np.concatenate([np.zeros(size), x, np.zeros(size)])
    out = np.zeros_like(pad)
    norm = np.zeros_like(pad)
    for i in range(0, len(pad) - size, hop):
        frame = pad[i:i + size] * win
        spec = np.fft.rfft(frame) * mask_fn((i + size / 2 - size) / SR, freqs)
        out[i:i + size] += np.fft.irfft(spec, size) * win
        norm[i:i + size] += win ** 2
    norm[norm < 1e-6] = 1
    return (out / norm)[size:size + len(x)]


def lowpass_mask(cut, slope=2.0):
    return lambda t, f: 1 / (1 + (f / max(cut(t), 20)) ** (2 * slope))


def fft_convolve(x, ir):
    n = len(x) + len(ir) - 1
    size = 1 << (n - 1).bit_length()
    y = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)
    return y[: len(x)]


def reverb_ir(seconds=2.8, seed=0):
    r = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = r.standard_normal(n) * np.exp(-t * 3.2)
    ir = stft_filter(ir, lowpass_mask(lambda _: 5200))
    ir[: int(0.012 * SR)] = 0
    return ir / np.sqrt(np.sum(ir ** 2))


def chord_at(t):
    return CHORDS[min(int(t // BAR), len(CHORDS) - 1)]


# ---------- 各声部 ----------

def pad():
    """去谐锯齿波长音，滤波器随时间缓慢打开。"""
    left = np.zeros(N)
    right = np.zeros(N)
    for b, chord in enumerate(CHORDS):
        start = b * BAR
        n = int((BAR + 0.6) * SR)
        e = env_adsr(n, 0.35, 0.4, 0.8, 0.6)
        for k, note in enumerate(chord):
            f = hz(note)
            for d, pan in ((-0.09, 0.2), (0.0, 0.5), (0.11, 0.8)):
                v = saw(f * 2 ** (d / 12), n, phase=rng.random()) * e / len(chord)
                place(left, start, v * (1 - pan))
                place(right, start, v * pan)
    cut = lambda t: 500 + 1900 * min(1.0, t / LOGO) + (1400 if t > LOGO else 0)
    return stft_filter(left, lowpass_mask(cut)), stft_filter(right, lowpass_mask(cut))


def kick_hits():
    hits = []
    t = 2 * BEAT
    while t < LOGO - 1e-6:
        hits.append(t)
        t += BEAT
    return hits


def kick(hits):
    out = np.zeros(N)
    n = int(0.45 * SR)
    tt = np.arange(n) / SR
    freq = 46 + 110 * np.exp(-tt * 38)
    body = np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.exp(-tt * 7.5)
    click = rng.standard_normal(n) * np.exp(-tt * 260) * 0.25
    k = body + click
    for h in hits:
        place(out, h, k)
    # 落版重击：更低、更长
    n2 = int(2.2 * SR)
    t2 = np.arange(n2) / SR
    boom = np.sin(2 * np.pi * np.cumsum(38 + 70 * np.exp(-t2 * 20)) / SR) * np.exp(-t2 * 2.2)
    place(out, LOGO, boom * 1.3)
    return out


def duck(hits):
    """侧链压缩包络：每次底鼓后把长音压下去再放开。"""
    g = np.ones(N)
    n = int(0.42 * SR)
    curve = 1 - 0.62 * np.exp(-np.arange(n) / SR * 9)
    for h in hits:
        i = int(h * SR)
        j = min(N, i + n)
        g[i:j] = np.minimum(g[i:j], curve[: j - i])
    return g


def bass():
    out = np.zeros(N)
    step = BEAT / 2
    n = int(step * SR)
    e = env_adsr(n, 0.004, 0.12, 0.55, 0.05)
    t = 2 * BEAT
    while t < LOGO - 1e-6:
        f = hz(chord_at(t)[0] - 12)
        tt = np.arange(n) / SR
        v = np.sin(2 * np.pi * f * tt) + 0.25 * saw(f, n)
        place(out, t, v * e)
        t += step
    return stft_filter(out, lowpass_mask(lambda _: 420))


def arp():
    """十六分音符琶音，带乒乓延迟。"""
    left = np.zeros(N)
    right = np.zeros(N)
    step = BEAT / 4
    n = int(0.22 * SR)
    tt = np.arange(n) / SR
    e = np.exp(-tt * 18) * np.minimum(1, tt / 0.003)
    pattern = [0, 1, 2, 3, 2, 1, 3, 2]
    t = 4 * BEAT * 2  # 第三小节进
    i = 0
    while t < LOGO - 1e-6:
        chord = chord_at(t)
        note = chord[pattern[i % len(pattern)]] + 12
        f = hz(note)
        tri = 2 * np.abs(saw(f, n)) - 1
        v = (0.7 * tri + 0.3 * np.sign(np.sin(2 * np.pi * f * tt))) * e
        lift = 0.6 + 0.4 * min(1, (t - 4) / 8)
        pan = 0.5 + 0.3 * np.sin(i * 0.9)
        place(left, t, v * (1 - pan) * lift)
        place(right, t, v * pan * lift)
        t += step
        i += 1
    delay = int(BEAT * 0.75 * SR)
    dl = np.zeros(N)
    dr = np.zeros(N)
    dl[delay:] += right[:-delay] * 0.35
    dr[delay * 2:] += left[:-delay * 2] * 0.25
    left, right = left + dl, right + dr
    cut = lowpass_mask(lambda t: 2200 + 2600 * min(1, max(0, (t - 4) / 10)))
    return stft_filter(left, cut), stft_filter(right, cut)


def hats():
    out = np.zeros(N)
    n = int(0.05 * SR)
    tt = np.arange(n) / SR
    t = 6.5 + BEAT / 2
    while t < LOGO - 1e-6:
        v = rng.standard_normal(n) * np.exp(-tt * 90)
        place(out, t, v)
        t += BEAT
    return stft_filter(out, lambda _, f: 1 / (1 + (7000 / np.maximum(f, 1)) ** 4))


def whoosh(cue, length=0.7, gain=1.0):
    n = int(length * SR)
    noise = rng.standard_normal(n)
    tt = np.arange(n) / SR
    t0 = cue - length

    def band(t, f):
        p = np.clip((t - t0) / length, 0, 1)
        center = 300 * (20 ** p)
        return np.exp(-((np.log2(np.maximum(f, 1) / center)) ** 2) / 0.9)

    full = np.zeros(N)
    place(full, t0, noise * (tt / length) ** 2.2)
    return stft_filter(full, band) * gain


def impact(cue, gain=0.5):
    out = np.zeros(N)
    n = int(0.6 * SR)
    tt = np.arange(n) / SR
    v = rng.standard_normal(n) * np.exp(-tt * 14)
    place(out, cue, v)
    return stft_filter(out, lowpass_mask(lambda _: 1800)) * gain


def shimmer():
    """落版后的高音泛音，铺一点亮度。"""
    out_l = np.zeros(N)
    out_r = np.zeros(N)
    n = N - int(LOGO * SR)
    tt = np.arange(n) / SR
    e = (1 - np.exp(-tt * 3)) * np.exp(-tt * 0.5)
    for k, note in enumerate([76, 79, 83, 88]):
        f = hz(note)
        v = np.sin(2 * np.pi * f * tt + k) * e * (0.5 + 0.5 * np.sin(2 * np.pi * (0.7 + 0.2 * k) * tt))
        place(out_l, LOGO, v * (0.3 + 0.1 * k))
        place(out_r, LOGO, v * (0.7 - 0.1 * k))
    return out_l, out_r


def main():
    hits = kick_hits()
    g = duck(hits)
    pl, pr = pad()
    al, ar = arp()
    b = bass()
    k = kick(hits)
    h = hats()
    sl, sr = shimmer()

    fx = np.zeros(N)
    for c in CUES:
        fx += whoosh(c, gain=0.22) + impact(c, gain=0.35)
    fx += whoosh(LOGO, length=1.4, gain=0.35) + impact(LOGO, gain=0.6)

    dry_l = 0.75 * pl * g + 0.70 * al + 0.30 * b * g + 0.42 * k + 0.45 * h + 0.6 * fx + 0.06 * sl
    dry_r = 0.75 * pr * g + 0.70 * ar + 0.30 * b * g + 0.42 * k + 0.45 * h + 0.6 * fx + 0.06 * sr

    send_l = 0.5 * pl + 0.5 * al + 0.5 * fx + 0.12 * sl
    send_r = 0.5 * pr + 0.5 * ar + 0.5 * fx + 0.12 * sr
    wet_l = fft_convolve(send_l, reverb_ir(seed=1))
    wet_r = fft_convolve(send_r, reverb_ir(seed=2))

    left = dry_l + 0.55 * wet_l
    right = dry_r + 0.55 * wet_r

    fade = np.ones(N)
    fi = int(0.04 * SR)
    fo = int(1.6 * SR)
    fade[:fi] = np.linspace(0, 1, fi)
    fade[-fo:] = np.linspace(1, 0, fo) ** 1.6
    mix = np.stack([left, right], axis=1) * fade[:, None]

    mix *= 0.7 / np.max(np.abs(mix))
    mix = np.tanh(mix * 1.2) / np.tanh(1.2)
    mix *= 0.89 / np.max(np.abs(mix))

    out = HERE / "out" / "music.wav"
    out.parent.mkdir(exist_ok=True)
    with wave.open(str(out), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((mix * 32767).astype("<i2").tobytes())
    print(out)


if __name__ == "__main__":
    main()
