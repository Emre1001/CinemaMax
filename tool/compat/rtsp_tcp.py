#!/usr/bin/env python3
"""Minimaler RTSP-Server nur mit TCP-Interleaved (lehnt UDP mit 461 ab, wie viele Kameras/Server).

ffmpeg liefert RTP (MPEG-TS, PT 33) per UDP an 127.0.0.1:<rtp_in>; jeder Zuschauer bekommt die
Pakete als '$'-Rahmen über seine RTSP-Verbindung. Aufruf: rtsp_tcp.py <port> <rtp_in>
"""
import socket, sys, threading

PORT, RTP_IN = int(sys.argv[1]), int(sys.argv[2])
clients = []  # (conn, channel)
lock = threading.Lock()

SDP = ('v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Test\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\n'
       'm=video 0 RTP/AVP 33\r\na=rtpmap:33 MP2T/90000\r\na=control:track0\r\n')


def pump():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(('127.0.0.1', RTP_IN))
    while True:
        pkt = u.recv(65535)
        with lock:
            for c in list(clients):
                conn, ch = c
                try:
                    conn.sendall(b'$' + bytes([ch]) + len(pkt).to_bytes(2, 'big') + pkt)
                except OSError:
                    clients.remove(c)


def handle(conn):
    buf = b''
    ch = 0
    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buf += data
            while b'\r\n\r\n' in buf:
                head, buf = buf.split(b'\r\n\r\n', 1)
                lines = head.decode(errors='replace').split('\r\n')
                method = lines[0].split(' ')[0]
                hdr = {l.split(':', 1)[0].strip().lower(): l.split(':', 1)[1].strip() for l in lines[1:] if ':' in l}
                cseq = hdr.get('cseq', '0')
                out = f'RTSP/1.0 200 OK\r\nCSeq: {cseq}\r\n'
                body = ''
                if method == 'OPTIONS':
                    out += 'Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n'
                elif method == 'DESCRIBE':
                    body = SDP
                    out += f'Content-Type: application/sdp\r\nContent-Base: {lines[0].split(" ")[1]}/\r\n'
                elif method == 'SETUP':
                    t = hdr.get('transport', '')
                    if 'TCP' not in t.upper():
                        conn.sendall(f'RTSP/1.0 461 Unsupported Transport\r\nCSeq: {cseq}\r\n\r\n'.encode())
                        continue
                    if 'interleaved=' in t:
                        ch = int(t.split('interleaved=')[1].split('-')[0].split(';')[0])
                    out += f'Transport: RTP/AVP/TCP;unicast;interleaved={ch}-{ch + 1}\r\nSession: 12345678;timeout=60\r\n'
                elif method == 'PLAY':
                    out += 'Session: 12345678\r\nRange: npt=0.000-\r\n'
                    conn.sendall((out + '\r\n').encode())
                    with lock:
                        clients.append((conn, ch))
                    continue
                elif method == 'TEARDOWN':
                    conn.sendall((out + '\r\n').encode())
                    return
                if body:
                    out += f'Content-Length: {len(body)}\r\n'
                conn.sendall((out + '\r\n' + body).encode())
    except OSError:
        pass
    finally:
        with lock:
            for c in list(clients):
                if c[0] is conn:
                    clients.remove(c)
        conn.close()


threading.Thread(target=pump, daemon=True).start()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', PORT))
s.listen(8)
print(f'rtsp tcp on {PORT}', flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
