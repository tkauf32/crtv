#!/bin/bash

set -a
source .env
set +a

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
