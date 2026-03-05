#!/usr/bin/env bash
set -euo pipefail

# Load defaults/secrets
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

usage() {
  cat <<'EOF'
Usage:
  tv.sh --show "Name" --season 1 --episode 1 [--profile crt-lottes]
  tv.sh --preset seinfeld --season 1 --episode 1
  TV_SHOW="Name" SEASON_NUM=1 EPISODE_NUM=1 tv.sh

Options:
  --show NAME
  --season N
  --episode N
  --profile NAME
  --preset NAME      loads presets/NAME.env (optional)
  --help
EOF
}

# Defaults if not set by .env
: "${PROFILE:=crt-lottes}"

PRESET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)    TV_SHOW="$2"; shift 2;;
    --season)  SEASON_NUM="$2"; shift 2;;
    --episode) EPISODE_NUM="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --preset)  PRESET="$2"; shift 2;;
    --help)    usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [[ -n "${PRESET}" ]]; then
  preset_file="presets/${PRESET}.env"
  if [[ -f "${preset_file}" ]]; then
    set -a
    source "${preset_file}"
    set +a
  else
    echo "Preset not found: ${preset_file}" >&2
    exit 1
  fi
fi

# Validate required
: "${PLEX_SERVER:?PLEX_SERVER is required (in .env or env var)}"
: "${PLEX_TOKEN:?PLEX_TOKEN is required (in .env or env var)}"
: "${TV_SHOW:?TV_SHOW is required}"
: "${SEASON_NUM:?SEASON_NUM is required}"
: "${EPISODE_NUM:?EPISODE_NUM is required}"

# --- your existing logic below ---
SHOW_KEY=$(
  curl -s "http://$PLEX_SERVER/library/sections/2/all?X-Plex-Token=$PLEX_TOKEN" \
  | grep -i "title=\"${TV_SHOW}\"" \
  | head -n 1 \
  | grep -o 'ratingKey="[0-9]\+"' \
  | head -n 1 \
  | grep -o '[0-9]\+'
)
echo "SHOW_KEY=$SHOW_KEY"

SEASON_KEY=$(
  curl -s "http://$PLEX_SERVER/library/metadata/$SHOW_KEY/children?X-Plex-Token=$PLEX_TOKEN" \
  | tr '<' '\n' \
  | grep '^Directory ' \
  | grep 'type="season"' \
  | grep "index=\"${SEASON_NUM}\"" \
  | head -n 1 \
  | grep -o 'ratingKey="[0-9]\+"' \
  | grep -o '[0-9]\+'
)

echo "SEASON_KEY=$SEASON_KEY"


EP_KEY=$(
  curl -s "http://$PLEX_SERVER/library/metadata/$SEASON_KEY/children?X-Plex-Token=$PLEX_TOKEN" \
  | tr '<' '\n' \
  | grep '^Video ' \
  | grep 'type="episode"' \
  | grep "index=\"${EPISODE_NUM}\"" \
  | head -n 1 \
  | grep -o 'ratingKey="[0-9]\+"' \
  | grep -o '[0-9]\+'
)

echo "EP_KEY=$EP_KEY"

PART_PATH=$(
  curl -s "http://$PLEX_SERVER/library/metadata/$EP_KEY?X-Plex-Token=$PLEX_TOKEN" \
  | tr '<' '\n' \
  | grep '^Part ' \
  | head -n 1 \
  | grep -o 'key="[^"]\+"' \
  | head -n 1 \
  | sed 's/key="//; s/"$//'
)

echo "PART_PATH=$PART_PATH"

STREAM_URL="http://$PLEX_SERVER$PART_PATH?X-Plex-Token=$PLEX_TOKEN"
echo "STREAM_URL=$STREAM_URL"

export DISPLAY=:0
export XAUTHORITY="$HOME/.Xauthority"

mpv --vo=gpu-next --gpu-context=x11egl --profile=fast --hwdec=drm-copy \
  --vf="crop=ih*4/3:ih" \
  --fullscreen --profile="${PROFILE:-crt-lottes}" \
  --interpolation=no \
  --cache=yes --demuxer-max-bytes=50MiB --demuxer-max-back-bytes=10MiB \
  --scale=bilinear --cscale=bilinear --dscale=bilinear \
  "$STREAM_URL" \
  2>/dev/null
