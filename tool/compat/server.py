#!/usr/bin/env python3
"""Mock-IPTV-Server für den Kompatibilitätstest (tool/compat_probe.dart).

Dateien mit Range, Live-MPEG-TS (geloopt und echt kodiert), Live-HLS, Header-Pflicht, Weiterleitungen,
Sonderzeichen, selbst signiertes https, Xtream-API, Stalker-Portal, Playlists und XMLTV.
Aufruf: server.py <media-dir> <port> [tls-port]   (Zertifikat: <media-dir>/cert.pem, key.pem)
"""
import json, os, re, ssl, subprocess, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MEDIA = sys.argv[1]
PORT = int(sys.argv[2])
TLS_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 0


def hostbase(handler):
    return 'http://' + (handler.headers.get('Host') or f'127.0.0.1:{PORT}')


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *a):
        sys.stderr.write('%s %s\n' % (self.command, self.path))

    # ---------- Hilfen ----------
    def send_bytes(self, data, ctype='application/octet-stream', code=200):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def send_json(self, obj, prefix=''):
        self.send_bytes((prefix + json.dumps(obj)).encode(), 'application/json')

    def send_file(self, path, ctype=None):
        if not os.path.isfile(path):
            return self.send_bytes(b'not found', 'text/plain', 404)
        size = os.path.getsize(path)
        ctype = ctype or guess(path)
        rng = self.headers.get('Range')
        start, end, code = 0, size - 1, 200
        if rng:
            m = re.match(r'bytes=(\d*)-(\d*)', rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                else:
                    start = size - int(m.group(2))
                if start >= size:
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                code = 206
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if code == 206:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        if self.command == 'HEAD':
            return
        with open(path, 'rb') as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def live_ts(self):
        """Endloser MPEG-TS-Strom ohne Länge aus einer geloopten Datei, etwa in Echtzeit."""
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp2t')
        self.send_header('Connection', 'close')
        self.end_headers()
        data = open(os.path.join(MEDIA, 'film.ts'), 'rb').read()
        rate = len(data) / 20.0  # 20 s Film
        try:
            while True:
                for i in range(0, len(data), 18800):
                    self.wfile.write(data[i:i + 18800])
                    time.sleep(18800 / rate * 0.9)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def live_encode(self):
        """Echter Live-Strom: ffmpeg kodiert laufend, Zeitstempel steigen stetig (wie ein IPTV-Sender)."""
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp2t')
        self.send_header('Connection', 'close')
        self.end_headers()
        p = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-re', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25',
                              '-f', 'lavfi', '-i', 'sine=frequency=500:sample_rate=48000', '-c:v', 'libx264', '-preset', 'ultrafast',
                              '-g', '50', '-c:a', 'aac', '-f', 'mpegts', '-'], stdout=subprocess.PIPE)
        try:
            while True:
                chunk = p.stdout.read(18800)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            p.kill()
        self.close_connection = True

    def live_hls(self, base):
        """Gleitendes HLS-Fenster aus den VOD-Segmenten, ohne ENDLIST."""
        seq = int(time.time() / 4)
        lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:4', f'#EXT-X-MEDIA-SEQUENCE:{seq}']
        for s in range(seq, seq + 4):
            if s % 5 == 0 and s != seq:
                lines.append('#EXT-X-DISCONTINUITY')
            lines += ['#EXTINF:4.000000,', f'{base}/media/hls/v1_{s % 5:03d}.ts']
        self.send_bytes(('\n'.join(lines) + '\n').encode(), 'application/vnd.apple.mpegurl')

    # ---------- Xtream ----------
    def xtream(self, q):
        if q.get('username') != 'u' or q.get('password') != 'p#w':
            return self.send_json({'user_info': {'auth': 0}})
        a = q.get('action')
        if a is None:
            return self.send_json({'user_info': {'auth': 1, 'status': 'Active', 'exp_date': str(int(time.time()) + 86400 * 30),
                                                 'active_cons': '0', 'max_connections': '2'},
                                   'server_info': {'url': '127.0.0.1', 'port': str(PORT)}})
        data = {
            'get_live_categories': [{'category_id': '1', 'category_name': 'DE | Test'}],
            'get_live_streams': [
                {'stream_id': 1, 'name': 'Test TS', 'category_id': '1', 'stream_icon': '', 'epg_channel_id': 'test.de', 'tv_archive': 1, 'tv_archive_duration': '2'},
                {'stream_id': 2, 'name': 'Test 2', 'category_id': '1', 'stream_icon': None, 'epg_channel_id': None},
            ],
            'get_vod_categories': [{'category_id': '5', 'category_name': 'Filme'}],
            # leere Endung: muss als .mp4 enden
            'get_vod_streams': {'0': {'stream_id': 10, 'name': 'Film MP4', 'category_id': '5', 'container_extension': '', 'rating': '7.5', 'added': '1700000000'},
                                '1': {'stream_id': 11, 'name': 'Film MKV', 'category_id': '5', 'container_extension': 'mkv'}},
            'get_series_categories': [{'category_id': '9', 'category_name': 'DE | SERIEN'}],
            'get_series': [{'series_id': 100, 'name': 'Serie', 'category_id': '9', 'cover': ''}],
            'get_series_info': {'info': {'name': 'Serie', 'plot': 'Test'},
                                'episodes': {'1': [{'id': 1001, 'season': 1, 'episode_num': 1, 'title': 'Folge 1', 'container_extension': 'mp4'},
                                                   {'id': 1002, 'season': 1, 'episode_num': '2', 'title': 'Folge 2', 'container_extension': None}]}},
            'get_vod_info': {'info': {'plot': 'Film', 'genre': 'Test'}, 'movie_data': {'stream_id': 10}},
            'get_short_epg': {'epg_listings': []},
        }.get(a, [])
        # PHP-Warnung vor dem JSON wie bei manchen Panels, sonst BOM
        return self.send_json(data, '<br /><b>Warning</b>: x in y<br />' if a == 'get_live_streams' else '﻿')

    def stalker(self, q):
        a = q.get('action')
        if a == 'handshake':
            return self.send_json({'js': {'token': 'TOKEN1'}})
        if self.headers.get('Authorization', '') != 'Bearer TOKEN1':
            return self.send_bytes(b'Authorization failed.', 'text/plain', 200)
        base = hostbase(self)
        t = q.get('type')
        if a == 'get_profile':
            return self.send_json({'js': {'id': 1}})
        if t == 'itv' and a == 'get_genres':
            return self.send_json({'js': [{'id': '*', 'title': 'All'}, {'id': '3', 'title': 'News'}]})
        if t == 'itv' and a == 'get_all_channels':
            return self.send_json({'js': {'data': [{'id': '7', 'name': 'Stalker TV', 'tv_genre_id': '3', 'cmd': 'ffmpeg http://localhost/ch/7_', 'logo': ''}]}})
        if a == 'create_link':
            if t == 'itv':
                return self.send_json({'js': {'cmd': f'ffmpeg {base}/live.ts?play_token=x'}})
            return self.send_json({'js': {'cmd': f'ffmpeg {base}/media/film.mp4'}})
        if t in ('vod', 'series') and a == 'get_categories':
            return self.send_json({'js': [{'id': '*', 'title': 'All'}, {'id': '4', 'title': 'Kino'}]})
        if t == 'vod' and a == 'get_ordered_list':
            return self.send_json({'js': {'total_items': 1, 'max_page_items': 14, 'data': [{'id': '55', 'name': 'Stalker Film', 'cmd': 'eyJ0eXBlIjoibW92aWUifQ==', 'screenshot_uri': '/s.jpg'}]}})
        return self.send_json({'js': []})

    # ---------- Router ----------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(u.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        base = hostbase(self)
        if path.startswith('/media/'):
            return self.send_file(os.path.join(MEDIA, path[7:]))
        if path == '/live.ts':
            return self.live_ts()
        if path == '/live2.ts':
            return self.live_encode()
        if path == '/live/hls/index.m3u8':
            return self.live_hls(base)
        if path == '/noext/film':
            return self.send_file(os.path.join(MEDIA, 'film.mp4'), 'application/octet-stream')
        if path == '/noext/hls':
            # HLS ohne .m3u8 und mit falschem Typ
            text = open(os.path.join(MEDIA, 'hls/master.m3u8')).read().replace('v0.m3u8', f'{base}/media/hls/v0.m3u8').replace('v1.m3u8', f'{base}/media/hls/v1.m3u8')
            return self.send_bytes(text.encode(), 'text/plain')
        if path == '/noext/live':
            return self.live_ts()
        if path.startswith('/ua/'):
            if self.headers.get('User-Agent') != 'CinemaTest/1.0':
                return self.send_bytes(b'forbidden', 'text/plain', 403)
            return self.send_file(os.path.join(MEDIA, path[4:]))
        if path.startswith('/ref/'):
            if self.headers.get('Referer') != 'http://ref.example/':
                return self.send_bytes(b'forbidden', 'text/plain', 403)
            return self.send_file(os.path.join(MEDIA, path[5:]))
        if path.startswith('/redir/'):
            self.send_response(302)
            self.send_header('Location', '/media/' + path[7:])
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/Film Über [2020].mp4':
            return self.send_file(os.path.join(MEDIA, 'film.mp4'))
        if path.endswith('player_api.php'):
            return self.xtream(q)
        if path.endswith('get.php'):
            if q.get('username') != 'u':
                return self.send_bytes(b'', 'text/plain', 403)
            return self.send_bytes(playlist(base).encode(), 'audio/x-mpegurl')
        if path == '/xmltv.php':
            return self.send_bytes(xmltv().encode(), 'application/xml')
        m = re.match(r'^/(live|movie|series|timeshift)/u/p#w/(.+)$', path)
        if m:
            kind, rest = m.groups()
            if kind == 'live':
                if rest.endswith('.m3u8'):
                    return self.live_hls(base)
                # Sender 1: echt kodiert (stetige Zeitstempel), sonst geloopte Datei
                return self.live_encode() if rest.startswith('1.') else self.live_ts()
            if kind == 'timeshift':
                return self.send_file(os.path.join(MEDIA, 'film.ts'))
            return self.send_file(os.path.join(MEDIA, 'film_hevc_ac3.mkv' if rest.endswith('.mkv') else 'film.mp4'))
        if path in ('/portal.php', '/stalker_portal/server/load.php'):
            return self.stalker(q)
        if path == '/list.m3u':
            return self.send_bytes(playlist(base).encode(), 'audio/x-mpegurl')
        return self.send_bytes(b'not found', 'text/plain', 404)


def guess(p):
    ext = p.rsplit('.', 1)[-1].lower()
    return {'mp4': 'video/mp4', 'mkv': 'video/x-matroska', 'webm': 'video/webm', 'avi': 'video/x-msvideo', 'ts': 'video/mp2t',
            'mov': 'video/quicktime', 'flv': 'video/x-flv', 'mp3': 'audio/mpeg', 'm3u8': 'application/vnd.apple.mpegurl',
            'mpd': 'application/dash+xml', 'm4s': 'video/iso.segment', 'jpg': 'image/jpeg'}.get(ext, 'application/octet-stream')


def playlist(base):
    return f'''#EXTM3U url-tvg="{base}/xmltv.php"
#EXTINF:-1 tvg-id="test.de" group-title="DE | Live",Live TS
{base}/live.ts
#EXTINF:-1 group-title="DE | Live",Live HLS
{base}/live/hls/index.m3u8
#EXTINF:-1 group-title="DE | Live",Mit UA
#EXTVLCOPT:http-user-agent=CinemaTest/1.0
{base}/ua/film.ts
#EXTINF:-1 group-title="Filme",Film MP4
{base}/media/film.mp4
#EXTINF:-1 group-title="DE | SERIEN",Serie S01 E01
{base}/media/film.mkv
'''


def xmltv():
    now = time.gmtime()
    start = time.strftime('%Y%m%d%H0000 +0000', now)
    stop = time.strftime('%Y%m%d%H0000 +0000', time.gmtime(time.time() + 7200))
    return f'''<?xml version="1.0"?><tv><channel id="test.de"/><programme start="{start}" stop="{stop}" channel="test.de"><title>Testsendung &#228;</title></programme></tv>'''


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == '__main__':
    httpd = Server(('0.0.0.0', PORT), H)
    if TLS_PORT:
        tls = Server(('0.0.0.0', TLS_PORT), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.path.join(MEDIA, 'cert.pem'), os.path.join(MEDIA, 'key.pem'))
        tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
        threading.Thread(target=tls.serve_forever, daemon=True).start()
    print(f'serving {MEDIA} on {PORT} (tls {TLS_PORT})', flush=True)
    httpd.serve_forever()
