#!/bin/bash

set -a
source .env
set +a

MOVIE_KEY=$(
  curl -s "http://$PLEX_SERVER/library/sections/1/all?X-Plex-Token=$PLEX_TOKEN" \
  | grep -i "title=\"${MOVIE}\"" \
  | head -n 1 \
  | grep -o 'ratingKey="[0-9]\+"' \
  | head -n 1 \
  | grep -o '[0-9]\+'
)
echo "MOVIE_KEY=$MOVIE_KEY"
