#!/usr/bin/env bash
set -euo pipefail

# Defaults
RESOLUTION=240
VIDEO_URL="https://www.youtube.com/watch?v=GV8KGcFqeLc"
PROFILE="crt-lottes"

usage() {
  cat <<'EOF'
Usage: play.sh [-r resolution] [-u video_url] [-p profile] [-h]

Options:
  -r  Resolution (e.g. 240, 360, 480)
  -u  Video URL
  -p  MPV profile name (e.g. crt-lottes)
  -h  Show help
EOF
}

while getopts ":r:u:p:h" opt; do
  case "$opt" in
    r) RESOLUTION="$OPTARG" ;;
    u) VIDEO_URL="$OPTARG" ;;
    p) PROFILE="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
    :)  echo "Option -$OPTARG requires an argument." >&2; usage; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Optional: if user passes a bare URL as remaining arg, treat it as VIDEO_URL
if [[ $# -ge 1 ]]; then
  VIDEO_URL="$1"
fi

export DISPLAY=:0
export XAUTHORITY="$HOME/.Xauthority"

mpv --vo=gpu-next --gpu-context=x11egl --profile=fast --hwdec=drm-copy \
  --ytdl-format="bestvideo[vcodec^=avc1][height<=${RESOLUTION}][fps<=30]+bestaudio/best[vcodec^=avc1][height<=${RESOLUTION}]" \
  --vf="crop=ih*4/3:ih" \
  --fullscreen --profile="$PROFILE" \
  --interpolation=no \
  --cache=yes --demuxer-max-bytes=50MiB --demuxer-max-back-bytes=10MiB \
  --scale=bilinear --cscale=bilinear --dscale=bilinear \
  "$VIDEO_URL" \
  2>/dev/null
