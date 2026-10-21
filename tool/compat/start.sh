#!/usr/bin/env bash
# Testmedien erzeugen (einmalig) und alle Testserver starten: HTTP/HTTPS (8765/8766), RTMP (1935),
# SRT (9000), UDP an 127.0.0.1:5000, RTSP über UDP (VLC, 8557; 8554 belegt der Android-Emulator) und RTSP nur TCP (8556).
#   tool/compat/start.sh <arbeitsordner>
# Danach: tool/compat_probe.dart (siehe dort) auf Linux oder per tool/compat/run_android.py.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${1:?Arbeitsordner angeben}"
M="$W/media"
mkdir -p "$M"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

if [ ! -f "$M/done" ]; then
  cd "$M"
  ff -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 20 \
     -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 50 -c:a aac -b:a 128k base.mp4
  ff -i base.mp4 -c copy -movflags +faststart film.mp4
  ff -i base.mp4 -c:v libx265 -preset ultrafast -c:a ac3 film_hevc_ac3.mkv 2>/dev/null
  ff -i base.mp4 -t 10 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -c:a libopus film.webm
  ff -i base.mp4 -c:v mpeg4 -q:v 5 -c:a libmp3lame film.avi
  ff -i base.mp4 -c copy film.ts
  ff -i base.mp4 -c:v mpeg2video -q:v 4 -c:a mp2 sd_mpeg2.ts
  ff -i base.mp4 -c copy film.mov
  ff -i base.mp4 -c copy -f flv film.flv
  ff -f lavfi -i sine=frequency=600:sample_rate=44100 -t 15 -c:a libmp3lame radio.mp3
  ff -i base.mp4 -map 0:v -map 0:a -map 0:a -c:v copy -c:a aac -metadata:s:a:0 language=eng -metadata:s:a:1 language=deu film_multi.mkv
  ln -sf film_multi.mkv film.mkv
  mkdir -p hls hlsfmp4 dash
  ff -i base.mp4 -filter_complex "[0:v]split=2[a][b];[b]scale=640:360[b2]" -map "[a]" -map 0:a -map "[b2]" -map 0:a \
     -c:v libx264 -preset veryfast -g 50 -c:a aac -b:v:0 2500k -b:v:1 600k -f hls -hls_time 4 -hls_playlist_type vod \
     -var_stream_map "v:0,a:0 v:1,a:1" -master_pl_name master.m3u8 -hls_segment_filename "hls/v%v_%03d.ts" hls/v%v.m3u8
  ff -i base.mp4 -c copy -f hls -hls_time 4 -hls_playlist_type vod -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \
     -hls_segment_filename "hlsfmp4/s%03d.m4s" hlsfmp4/index.m3u8
  ff -i base.mp4 -c copy -f dash -seg_duration 4 dash/manifest.mpd
  openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 -subj "/CN=localhost" 2>/dev/null
  touch done
  cd - >/dev/null
fi

python3 -I "$HERE/server.py" "$M" 8765 8766 > "$W/server.log" 2>&1 &
python3 -I "$HERE/rtsp_tcp.py" 8556 5100 > "$W/rtsp_tcp.log" 2>&1 &
ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i "$M/film.ts" -c copy -f rtp_mpegts rtp://127.0.0.1:5100 > /dev/null 2>&1 &
# RTMP und SRT bedienen je einen Zuschauer, danach neu
(while true; do ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i "$M/film.flv" -c copy -f flv -listen 1 rtmp://0.0.0.0:1935/live/test; sleep 0.3; done) &
(while true; do ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i "$M/film.ts" -c copy -f mpegts "srt://0.0.0.0:9000?mode=listener"; sleep 0.3; done) &
ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i "$M/film.ts" -c copy -f mpegts "udp://127.0.0.1:5000?pkt_size=1316" > /dev/null 2>&1 &
setsid cvlc -I dummy -q "$M/film.mp4" --loop --sout '#rtp{sdp=rtsp://0.0.0.0:8557/test}' --sout-keep > /dev/null 2>&1 &
echo "Testserver laufen (Medien: $M)"
wait
