#!/usr/bin/env python3
"""Peak, RMS and ring time of rendered voices (int16 WAV)."""
import sys, wave, struct, math, os

for path in sys.argv[1:]:
    with wave.open(path) as w:
        ch, sr, n = w.getnchannels(), w.getframerate(), w.getnframes()
        data = struct.unpack("<%dh" % (n * ch), w.readframes(n))
    mono = [abs(data[i]) / 32768.0 for i in range(0, len(data), ch)]
    peak = max(mono) if mono else 0
    first = mono[: sr // 2]
    rms = math.sqrt(sum(x * x for x in first) / max(len(first), 1))
    thr = 10 ** (-60 / 20)
    last = 0
    for i, x in enumerate(mono):
        if x > thr:
            last = i
    db = lambda v: 20 * math.log10(v) if v > 0 else -999
    print("%-10s peak %6.1f dB   rms(0.5s) %6.1f dB   rings %.2f s" % (
        os.path.basename(path)[:-4], db(peak), db(rms), last / sr))
