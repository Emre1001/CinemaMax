#!/usr/bin/env python3
"""Probe-APK auf einem Gerät/Emulator ausführen und Ergebnisse sammeln.

  run_android.py <apk> <ausgabe.txt> [serial]

Liest „COMPAT …“ aus dem Logcat. Bei „COMPAT SHOT <name>“ (Probe mit --dart-define=SHOTS=true) werden zwei
Bildschirmfotos verglichen: ändert sich nichts, ist das Bild eingefroren.
"""
import hashlib, io, subprocess, sys, time
from PIL import Image

apk, out = sys.argv[1:3]
adb = ['adb'] + (['-s', sys.argv[3]] if len(sys.argv) > 3 else [])
P = 'com.cinemamax.cinemamax'
subprocess.run(adb + ['install', '-r', '-g', apk], capture_output=True)
subprocess.run(adb + ['shell', 'am', 'force-stop', P])
subprocess.run(adb + ['logcat', '-c'])
subprocess.run(adb + ['shell', 'am', 'start', '-n', P + '/.MainActivity'], capture_output=True)


def shot():
    png = subprocess.run(adb + ['exec-out', 'screencap', '-p'], capture_output=True).stdout
    # Ganzer Bildschirm, verkleinert: Testvideos (Zeit oben links) und echte Sender (Bild irgendwo, Hochformat)
    im = Image.open(io.BytesIO(png)).convert('RGB').resize((96, 54))
    return hashlib.md5(im.tobytes()).hexdigest()


log = subprocess.Popen(adb + ['logcat', '-s', 'flutter:I', 'AndroidRuntime:E'], stdout=subprocess.PIPE, text=True)
start = time.time()
with open(out, 'w') as f:
    for line in log.stdout:
        if 'FATAL EXCEPTION' in line:
            f.write('COMPAT CRASH ' + line.strip() + '\n')
            break
        if 'COMPAT' not in line:
            continue
        msg = line[line.index('COMPAT'):].rstrip()
        if msg.startswith('COMPAT SHOT'):
            name = msg.split(' ', 2)[2]
            time.sleep(0.5)
            a = shot()
            time.sleep(2.5)
            b = shot()
            msg = f'COMPAT {"PASS" if a != b else "FAIL"} [bild] {name} :: {"Bild bewegt sich" if a != b else "STANDBILD"}'
        f.write(msg + '\n')
        f.flush()
        if msg.startswith('COMPAT DONE') or time.time() - start > 1800:
            break
log.kill()
