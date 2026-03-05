#!/usr/bin/env bash
set -euo pipefail

# ---- load .env for secrets/defaults ----
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

: "${PLEX_SERVER:?PLEX_SERVER required}"
: "${PLEX_TOKEN:?PLEX_TOKEN required}"
: "${PLEX_TV_SECTION:=2}"
: "${PROFILE:=crt-lottes}"
: "${MPV_VO:=gpu}"
: "${MPV_GPU_CONTEXT:=x11egl}"
: "${MPV_HWDEC:=auto}"
: "${TV_SOCK:=/tmp/tv.sock}"
: "${STATIC_FILE:=$HOME/crt/assets/static.mp4}"
: "${STATIC_MS:=600}"

usage() {
  cat <<'EOF'
tv.sh (shows only)

Examples:
  tv.sh --show "Seinfeld" --season 3 --episode 5
  tv.sh --preset seinfeld --season 3 --episode 5

Options:
  --show NAME
  --season N
  --episode N
  --resolution        pixel value
  --randomize-start   start at random % (range from .env)
  --shell             start/ensure mpv TV shell (idle fullscreen)
  --switch            switch channel via IPC (no new mpv window)
  --print-url-only    resolve URL and print it (no mpv)
  --preset NAME       loads presets/NAME.env
  --profile NAME
  --help
EOF
}

PRESET=""
RESOLUTION=""
RANDOMIZE_START="${RANDOMIZE_START_DEFAULT:-0}"
PRINT_URL_ONLY=0
SHELL_ONLY=0
SWITCH_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)    TV_SHOW="$2"; shift 2;;
    --season)  SEASON_NUM="$2"; shift 2;;
    --episode) EPISODE_NUM="$2"; shift 2;;
    --resolution) RESOLUTION="$2"; shift 2;;
    --randomize-start) RANDOMIZE_START=1; shift;;
    --shell)   SHELL_ONLY=1; shift;;
    --switch)  SWITCH_MODE=1; shift;;
    --print-url-only) PRINT_URL_ONLY=1; shift;;
    --preset)  PRESET="$2"; shift 2;;
    --profile) PROFILE="$2"; shift 2;;
    --help)    usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -n "$PRESET" ]]; then
  preset_file="presets/${PRESET}.env"
  [[ -f "$preset_file" ]] || { echo "Preset not found: $preset_file" >&2; exit 1; }
  set -a
  source "$preset_file"
  set +a
fi

VF_CHAIN="crop=ih*4/3:ih"

if [[ -n "${RESOLUTION}" ]]; then
  # Downscale to low internal resolution
  VF_CHAIN+=",scale=-2:${RESOLUTION}:flags=bilinear"
  # Soft upscale back to screen (analog feel)
  VF_CHAIN+=",scale=iw:ih:flags=bilinear"
  # Slight analog softness | can be heavy on the pi
  # VF_CHAIN+=",gblur=sigma=0.6"
  # Subtle broadcast noise
  VF_CHAIN+=",noise=alls=4:allf=t"
fi


rand_int_between() {
  local min="$1" max="$2"
  # inclusive min/max
  echo $(( min + RANDOM % (max - min + 1) ))
}

sanitize_pct_range() {
  local min="$1" max="$2"

  [[ "$min" =~ ^[0-9]+$ ]] || { echo "RANDOM_START_MIN_PCT must be int" >&2; exit 1; }
  [[ "$max" =~ ^[0-9]+$ ]] || { echo "RANDOM_START_MAX_PCT must be int" >&2; exit 1; }

  (( min >= 0 && min <= 100 )) || { echo "RANDOM_START_MIN_PCT out of range (0-100)" >&2; exit 1; }
  (( max >= 0 && max <= 100 )) || { echo "RANDOM_START_MAX_PCT out of range (0-100)" >&2; exit 1; }
  (( min < max )) || { echo "RANDOM_START_MIN_PCT must be < RANDOM_START_MAX_PCT" >&2; exit 1; }
}


if [[ "$SHELL_ONLY" == "1" ]]; then
  # shell-only mode doesn't require show/season/episode
  :
else
  # any mode that resolves content needs these
  : "${TV_SHOW:?TV_SHOW required}"
  : "${SEASON_NUM:?SEASON_NUM required}"
  : "${EPISODE_NUM:?EPISODE_NUM required}"
fi

plex_get() {
  curl -fsS "http://${PLEX_SERVER}$1${1//*\?*/&}${1//*\?*/}X-Plex-Token=${PLEX_TOKEN}"
}
# ^ keeps token appending simple-ish; if you prefer clarity, just inline curl like you have now.

mpv_send() {
  local json="$1"
  printf '%s\n' "$json" | socat - UNIX-CONNECT:"$TV_SOCK" >/dev/null
}

ensure_shell() {
  export DISPLAY=:0
  export XAUTHORITY="$HOME/.Xauthority"

  # Clean stale socket
  if [[ -S "$TV_SOCK" ]]; then
    if ! socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
      rm -f "$TV_SOCK"
    fi
  fi

  # If no live socket, start the mpv shell using the EXACT play_url() settings
  if [[ ! -S "$TV_SOCK" ]]; then
    # IMPORTANT: start mpv using play_url() (canonical args)
    # Loop static forever so the TV is never black
    mpv_args_loop_static=1
    play_url "$STATIC_FILE" &
    disown || true

    # Wait until connectable
    for _ in {1..50}; do
      [[ -S "$TV_SOCK" ]] || { sleep 0.1; continue; }
      if socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done

    echo "ERROR: mpv shell not responding on $TV_SOCK" >&2
    exit 1
  fi
}

switch_channel() {
  local url="$1"
  ensure_shell

  # Make sure static is "clean"
  mpv_send "{\"command\": [\"vf\", \"set\", \"\"]}"

  # 1) Static immediately + loop
  mpv_send "{\"command\": [\"loadfile\", \"$STATIC_FILE\", \"replace\"]}"
  mpv_send "{\"command\": [\"set_property\", \"loop-file\", \"inf\"]}"
  sleep "$(awk "BEGIN{print ${STATIC_MS}/1000}")"

  # 2) Load the target URL
  mpv_send "{\"command\": [\"loadfile\", \"$url\", \"replace\"]}"
  mpv_send "{\"command\": [\"set_property\", \"loop-file\", \"no\"]}"

  # Give mpv a moment to open the stream
  sleep 0.20

  # 3) IMPORTANT: replace vf chain (do NOT append)
  mpv_send "{\"command\": [\"vf\", \"set\", \"$VF_CHAIN\"]}"

  # 4) Random start
  if [[ "${RANDOMIZE_START}" == "1" ]]; then
    : "${RANDOM_START_MIN_PCT:=20}"
    : "${RANDOM_START_MAX_PCT:=80}"
    sanitize_pct_range "${RANDOM_START_MIN_PCT}" "${RANDOM_START_MAX_PCT}"

    local start_pct
    start_pct="$(rand_int_between "${RANDOM_START_MIN_PCT}" "${RANDOM_START_MAX_PCT}")"
    echo "Random start: ${start_pct}%"

    sleep 0.25
    mpv_send "{\"command\": [\"seek\", ${start_pct}, \"absolute-percent\"]}"
  fi
}

resolve_stream_url_show() {
  local show="$1" season="$2" episode="$3"

  local show_key season_key ep_key part_path

  show_key=$(
    curl -s "http://${PLEX_SERVER}/library/sections/${PLEX_TV_SECTION}/all?X-Plex-Token=${PLEX_TOKEN}" \
    | grep -i "title=\"${show}\"" \
    | head -n 1 \
    | grep -o 'ratingKey="[0-9]\+"' \
    | head -n 1 \
    | grep -o '[0-9]\+'
  )

  [[ -n "${show_key:-}" ]] || { echo "Could not find show: ${show}" >&2; return 1; }

  season_key=$(
    curl -s "http://${PLEX_SERVER}/library/metadata/${show_key}/children?X-Plex-Token=${PLEX_TOKEN}" \
    | tr '<' '\n' \
    | grep '^Directory ' \
    | grep 'type="season"' \
    | grep "index=\"${season}\"" \
    | head -n 1 \
    | grep -o 'ratingKey="[0-9]\+"' \
    | grep -o '[0-9]\+'
  )

  [[ -n "${season_key:-}" ]] || { echo "Could not find season ${season} for ${show}" >&2; return 1; }

  ep_key=$(
    curl -s "http://${PLEX_SERVER}/library/metadata/${season_key}/children?X-Plex-Token=${PLEX_TOKEN}" \
    | tr '<' '\n' \
    | grep '^Video ' \
    | grep 'type="episode"' \
    | grep "index=\"${episode}\"" \
    | head -n 1 \
    | grep -o 'ratingKey="[0-9]\+"' \
    | grep -o '[0-9]\+'
  )

  [[ -n "${ep_key:-}" ]] || { echo "Could not find episode ${episode} for ${show} S${season}" >&2; return 1; }

  part_path=$(
    curl -s "http://${PLEX_SERVER}/library/metadata/${ep_key}?X-Plex-Token=${PLEX_TOKEN}" \
    | tr '<' '\n' \
    | grep '^Part ' \
    | head -n 1 \
    | grep -o 'key="[^"]\+"' \
    | head -n 1 \
    | sed 's/key="//; s/"$//'
  )

  [[ -n "${part_path:-}" ]] || { echo "Could not find Part path for episode key ${ep_key}" >&2; return 1; }

  echo "http://${PLEX_SERVER}${part_path}?X-Plex-Token=${PLEX_TOKEN}"
}

play_url() {
  local url="$1"

  export DISPLAY=:0
  export XAUTHORITY="$HOME/.Xauthority"

  local mpv_args=(
    --vo="${MPV_VO}" 
    --gpu-context="${MPV_GPU_CONTEXT}" 
    --profile=fast 
    --hwdec="${MPV_HWDEC}"
    --vf="${VF_CHAIN}"
    --vd-lavc-threads=2
    --vd-lavc-skiploopfilter=all
    --vd-lavc-fast
    --fullscreen --profile="${PROFILE}"
    --interpolation=no
    --video-sync=audio
    --cache=yes 
    --demuxer-max-bytes=50MiB 
    --demuxer-max-back-bytes=10MiB
    --scale=bilinear
    --cscale=bilinear
    --dscale=bilinear
    ${mpv_args_loop_static:+--loop-file=inf}
  )

  if [[ "${RANDOMIZE_START}" == "1" ]]; then
    : "${RANDOM_START_MIN_PCT:=20}"
    : "${RANDOM_START_MAX_PCT:=80}"
    sanitize_pct_range "${RANDOM_START_MIN_PCT}" "${RANDOM_START_MAX_PCT}"
    local start_pct
    start_pct="$(rand_int_between "${RANDOM_START_MIN_PCT}" "${RANDOM_START_MAX_PCT}")"
    echo "Random start: ${start_pct}%"
    mpv_args+=( --start="${start_pct}%" )
  fi

  mpv_args+=( --input-ipc-server="${TV_SOCK}" --idle=yes )
  mpv "${mpv_args[@]}" "$url" 2>/dev/null

}


# --- Mode dispatch ---
if [[ "${SHELL_ONLY}" == "1" ]]; then
  ensure_shell
  exit 0
fi

STREAM_URL="$(resolve_stream_url_show "$TV_SHOW" "$SEASON_NUM" "$EPISODE_NUM")"

if [[ "${PRINT_URL_ONLY}" == "1" ]]; then
  echo "$STREAM_URL"
  exit 0
fi

if [[ "${SWITCH_MODE}" == "1" ]]; then
  echo "STREAM_URL=$STREAM_URL"
  switch_channel "$STREAM_URL"
  exit 0
fi

echo "STREAM_URL=$STREAM_URL"
play_url "$STREAM_URL"

# STREAM_URL="$(resolve_stream_url_show "$TV_SHOW" "$SEASON_NUM" "$EPISODE_NUM")"

# if [[ "${PRINT_URL_ONLY:-0}" == "1" ]]; then
#   echo "$STREAM_URL"
#   exit 0
# fi

# echo "STREAM_URL=$STREAM_URL"
# play_url "$STREAM_URL"
