"""Erzeugt den Startton (assets/sound/intro.ogg): Luftzug, tiefer Einschlag, heller Akkord.

Reines Python (kein numpy). Hall und Kodierung macht ffmpeg:
    python3 tool/make_intro_sound.py
"""
import math, random, struct, subprocess, wave, os

SR = 44100
DUR = 2.6
N = int(SR * DUR)
L = [0.0] * N
R = [0.0] * N
random.seed(7)

def add(i, l, r):
    if 0 <= i < N:
        L[i] += l
        R[i] += r

# 1) Luftzug 0-0,55 s: Rauschen durch Tiefpass, dessen Grenzfrequenz steigt
lp = 0.0
for i in range(int(0.62 * SR)):
    t = i / SR
    env = (t / 0.55) ** 2 if t < 0.55 else max(0.0, 1 - (t - 0.55) / 0.07)
    cutoff = 200 + 2600 * (t / 0.55) ** 1.6
    a = 1 - math.exp(-2 * math.pi * min(cutoff, 8000) / SR)
    lp += a * (random.uniform(-1, 1) - lp)
    pan = 0.5 + 0.35 * math.sin(t * 6)
    add(i, lp * env * 0.14 * (1 - pan + 0.5), lp * env * 0.14 * (pan + 0.5))

# 2) Einschlag bei 0,55 s: Sub-Bass mit fallender Tonhöhe + kurzer Klick
t0 = int(0.55 * SR)
phase = 0.0
for i in range(int(1.6 * SR)):
    t = i / SR
    f = 46 + 50 * math.exp(-t * 18)
    phase += 2 * math.pi * f / SR
    # weich ausklingen lassen, sonst knackt das Ende
    env = math.exp(-t * 2.6) * min(1.0, t / 0.004) * min(1.0, (1.6 - t) / 0.3)
    s = math.sin(phase) * env * 0.9 + math.sin(phase * 2) * env * 0.12
    click = random.uniform(-1, 1) * math.exp(-t * 400) * 0.25
    add(t0 + i, s + click, s + click)

# 3) Akkord ab 0,8 s (A-Dur add9), leicht verstimmt, links/rechts verteilt, langsam ein-/ausblenden
t1 = int(0.8 * SR)
notes = [(220.0, 0.0), (329.63, -0.4), (440.0, 0.35), (554.37, -0.25), (659.25, 0.45), (987.77, -0.5)]
for i in range(int(1.8 * SR)):
    t = i / SR
    env = min(1.0, t / 0.18) * math.exp(-t * 1.5) * min(1.0, (1.8 - t) / 0.3)
    l = r = 0.0
    for k, (f, pan) in enumerate(notes):
        v = (math.sin(2 * math.pi * f * t) + 0.6 * math.sin(2 * math.pi * f * 1.004 * t + k)) * (0.24 / (1 + k * 0.2))
        l += v * (1 - pan) / 1.5
        r += v * (1 + pan) / 1.5
    # kurzer heller Glanz am Anfang
    sh = math.sin(2 * math.pi * 1975.5 * t) * math.exp(-t * 7) * 0.05
    add(t1 + i, (l + sh) * env, (r + sh) * env)

# Ausblenden + Normalisieren auf -3 dB
for i in range(N):
    fade = min(1.0, (N - i) / (0.25 * SR))
    L[i] *= fade
    R[i] *= fade
peak = max(max(abs(x) for x in L), max(abs(x) for x in R))
g = 0.707 / peak
os.makedirs('build', exist_ok=True)
raw = 'build/intro_raw.wav'
with wave.open(raw, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(b''.join(struct.pack('<hh', int(L[i] * g * 32767), int(R[i] * g * 32767)) for i in range(N)))

# Hall (zwei Echos) und Ogg-Vorbis
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', raw,
                '-af', 'aecho=0.8:0.6:60|130:0.25|0.15,alimiter=limit=0.89',
                '-c:a', 'libvorbis', '-q:a', '5', 'assets/sound/intro.ogg'], check=True)
print('assets/sound/intro.ogg')
