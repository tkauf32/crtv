#!/usr/bin/env bash
set -euo pipefail

# crt_player.sh
#
# New IPC-driven CRT player script with:
# - One persistent mpv instance (IPC socket)
# - Static bumper between channel switches (same mpv process)
# - JSON channel map (index/name/url)
# - Optional random start seek after loading target
#
# Key env vars:
#   STATIC_FILE                Path to static bumper video.
#                              Default: <script_dir>/assets/static.mp4
#   MIN_STATIC_SECONDS         Minimum static bumper duration before target load.
#                              Default: 1.8
#   CHANNELS_FILE              Channel map JSON path.
#                              Default: <script_dir>/channels.json
#   ENABLE_RANDOM_START        Random start policy: auto|1|0 (default: auto)
#                              auto => on for http(s) URLs, off for local paths
#   RANDOM_START_MIN_PCT       Default: 20
#   RANDOM_START_MAX_PCT       Default: 80
#   CHANNEL_INDEX_FILE         Tracks current list position for auto-next switch
#
# Channel map JSON supported shapes:
#   ["url1", {"name":"news","url":"https://..."}]
#   {"channels": ["url1", {"name":"news","url":"https://..."}]}
# Extended object form also supports:
#   {"name":"plex-random","cmd":"./plex-api/channel.sh --print-url-only"}
#
# Commands:
#   ./crt_player.sh list
#   ./crt_player.sh start [--channel 1|name|url] [--url url]
#   ./crt_player.sh switch --channel 3
#   ./crt_player.sh switch --channel "news"
#   ./crt_player.sh switch --url "https://..."
#   ./crt_player.sh run [--channel 1]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

if [[ -d "${SCRIPT_DIR}/assets" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -d "${SCRIPT_DIR}/../assets" ]]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
elif [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${PROFILE:=crt-lottes}"
: "${MPV_VO:=gpu}"
: "${MPV_GPU_CONTEXT:=x11egl}"
: "${MPV_HWDEC:=auto}"
: "${VF_CHAIN:=crop=ih*4/3:ih}"
: "${DISPLAY:=:0}"
: "${XAUTHORITY:=${HOME}/.Xauthority}"
: "${TV_SOCK:=/tmp/crt_player.sock}"
: "${STATIC_FILE:=${REPO_ROOT}/assets/static.mp4}"
: "${MIN_STATIC_SECONDS:=1.8}"
: "${CHANNELS_FILE:=${REPO_ROOT}/channels.json}"
: "${RESOLUTION:=240}"
: "${YTDL_MAX_FPS:=30}"
: "${ENABLE_RANDOM_START:=auto}"
: "${RANDOM_START_MIN_PCT:=20}"
: "${RANDOM_START_MAX_PCT:=80}"
: "${CHANNEL_INDEX_FILE:=/tmp/crt_player_channel_index}"
: "${TARGET_READY_TIMEOUT_SECONDS:=8}"
: "${DEFAULT_START_CHANNEL:=1}"
: "${KEY_NEXT:=n}"
: "${KEY_PREV:=p}"
: "${KEY_RANDOM:=r}"
: "${KEY_QUIT:=q}"
: "${INPUT_EVENT_CMD:=}"

usage() {
  cat <<'USAGE'
Usage:
  crt_player.sh list
  crt_player.sh start [--channel <index|name|url>] [--url <url_or_path>] [--resolution N] [--fps-cap N]
  crt_player.sh switch [--channel <index|name|url>] [--url <url_or_path>] [--random]
  crt_player.sh run [--channel <index|name|url>] [--url <url_or_path>]

Examples:
  ./crt_player.sh list
  ./crt_player.sh start --channel 1
  ./crt_player.sh switch            # next channel (auto-advance)
  ./crt_player.sh switch --random   # random channel from channels.json
  ./crt_player.sh switch --channel news
  ./crt_player.sh switch --url "https://www.youtube.com/watch?v=XXXXXXXXXXX"
  ./crt_player.sh run               # keyboard: n/p/r/1-9/q
  INPUT_EVENT_CMD='./scripts/input-events-stub.sh' ./crt_player.sh run

Env:
  STATIC_FILE, MIN_STATIC_SECONDS, CHANNELS_FILE,
  ENABLE_RANDOM_START, RANDOM_START_MIN_PCT, RANDOM_START_MAX_PCT, CHANNEL_INDEX_FILE,
  RESOLUTION, YTDL_MAX_FPS, PROFILE, MPV_VO, MPV_GPU_CONTEXT, MPV_HWDEC, VF_CHAIN,
  DISPLAY, XAUTHORITY, DEFAULT_START_CHANNEL, KEY_NEXT, KEY_PREV, KEY_RANDOM, KEY_QUIT, INPUT_EVENT_CMD
USAGE
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

trim() {
  awk '{$1=$1; print}'
}

upsert_mpv_arg() {
  local key="$1"
  local value="${2-}"
  local new_arg
  local found=0
  local i

  if [[ -n "$value" ]]; then
    new_arg="--${key}=${value}"
  else
    new_arg="--${key}"
  fi

  for i in "${!MPV_ARGS[@]}"; do
    case "${MPV_ARGS[$i]}" in
      --"${key}"|--"${key}"=*)
        MPV_ARGS[$i]="$new_arg"
        found=1
        ;;
    esac
  done

  if [[ "$found" -eq 0 ]]; then
    MPV_ARGS+=("$new_arg")
  fi
}

build_ytdl_format() {
  local fps_filter=""

  if [[ -n "${YTDL_MAX_FPS}" ]]; then
    fps_filter="[fps<=${YTDL_MAX_FPS}]"
  fi

  printf 'bestvideo[vcodec^=avc1][height<=%s]%s+bestaudio/best[vcodec^=avc1][height<=%s]%s' \
    "$RESOLUTION" "$fps_filter" "$RESOLUTION" "$fps_filter"
}

build_mpv_args() {
  MPV_ARGS=(
    "--vo=${MPV_VO}"
    "--gpu-context=${MPV_GPU_CONTEXT}"
    "--profile=fast"
    "--hwdec=${MPV_HWDEC}"
    "--vf=${VF_CHAIN}"
    "--vd-lavc-threads=2"
    "--vd-lavc-skiploopfilter=all"
    "--vd-lavc-fast"
    "--fullscreen"
    "--profile=${PROFILE}"
    "--interpolation=no"
    "--video-sync=audio"
    "--cache=yes"
    "--demuxer-max-bytes=50MiB"
    "--demuxer-max-back-bytes=10MiB"
    "--scale=bilinear"
    "--cscale=bilinear"
    "--dscale=bilinear"
    "--idle=yes"
  )

  upsert_mpv_arg "input-ipc-server" "$TV_SOCK"
  upsert_mpv_arg "ytdl-format" "$(build_ytdl_format)"
}

mpv_send_json() {
  local json="$1"
  printf '%s\n' "$json" | socat - UNIX-CONNECT:"$TV_SOCK" >/dev/null 2>&1
}

mpv_get_property() {
  local prop="$1"
  local req
  local resp

  req="$(jq -nc --arg p "$prop" '{"command":["get_property", $p]}')"
  resp="$(printf '%s\n' "$req" | socat -T 1 - UNIX-CONNECT:"$TV_SOCK" 2>/dev/null || true)"

  printf '%s\n' "$resp" \
    | jq -r 'select(type == "object" and .error == "success") | .data' \
    | tail -n1
}

ensure_socket_clean() {
  if [[ -S "$TV_SOCK" ]]; then
    if ! socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
      rm -f "$TV_SOCK"
    fi
  fi
}

ensure_shell() {
  ensure_socket_clean
  export DISPLAY XAUTHORITY

  if [[ ! -S "$TV_SOCK" ]]; then
    build_mpv_args
    upsert_mpv_arg "loop-file" "inf"

    mpv "${MPV_ARGS[@]}" "$STATIC_FILE" >/dev/null 2>&1 &
    disown || true

    for _ in {1..60}; do
      [[ -S "$TV_SOCK" ]] || {
        sleep 0.1
        continue
      }
      if socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done

    die "mpv shell not responding on socket $TV_SOCK"
  fi
}

apply_runtime_source_options() {
  local target="$1"

  if is_remote_source "$target"; then
    mpv_send_json "$(jq -nc --arg f "$(build_ytdl_format)" '{"command":["set_property", "options/ytdl-format", $f]}')" || true
  fi
}

is_remote_source() {
  local src="$1"
  [[ "$src" =~ ^https?:// ]]
}

normalize_target() {
  local src="$1"
  local base_dir

  if [[ "$src" =~ ^https?:// ]] || [[ "$src" =~ ^file:// ]]; then
    printf '%s\n' "$src"
    return 0
  fi

  if [[ "$src" == /* ]]; then
    printf '%s\n' "$src"
    return 0
  fi

  base_dir="$(cd "$(dirname "$CHANNELS_FILE")" && pwd)"
  printf '%s/%s\n' "$base_dir" "$src"
}

should_random_start() {
  local src="$1"
  local mode

  mode="$(printf '%s' "$ENABLE_RANDOM_START" | tr '[:upper:]' '[:lower:]')"

  case "$mode" in
    1|true|yes|on)
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    auto|"")
      if is_remote_source "$src"; then
        return 0
      fi
      return 1
      ;;
    *)
      die "ENABLE_RANDOM_START must be one of: auto, 1, 0"
      ;;
  esac
}

validate_random_bounds() {
  is_int "$RANDOM_START_MIN_PCT" || die "RANDOM_START_MIN_PCT must be an integer"
  is_int "$RANDOM_START_MAX_PCT" || die "RANDOM_START_MAX_PCT must be an integer"

  (( RANDOM_START_MIN_PCT >= 0 && RANDOM_START_MIN_PCT <= 100 )) || die "RANDOM_START_MIN_PCT must be in 0..100"
  (( RANDOM_START_MAX_PCT >= 0 && RANDOM_START_MAX_PCT <= 100 )) || die "RANDOM_START_MAX_PCT must be in 0..100"
  (( RANDOM_START_MAX_PCT > RANDOM_START_MIN_PCT )) || die "RANDOM_START_MAX_PCT must be > RANDOM_START_MIN_PCT"
}

rand_int_between() {
  local min="$1"
  local max="$2"
  echo $(( min + RANDOM % (max - min + 1) ))
}

maybe_random_seek() {
  local target="$1"
  local seek_pct

  if ! should_random_start "$target"; then
    return 0
  fi

  validate_random_bounds
  seek_pct="$(rand_int_between "$RANDOM_START_MIN_PCT" "$RANDOM_START_MAX_PCT")"

  sleep 0.25
  mpv_send_json "$(jq -nc --argjson n "$seek_pct" '{"command":["seek", $n, "absolute-percent"]}')" || true
}

wait_for_target_ready() {
  local steps
  local paused
  local ptime

  steps="$(awk "BEGIN { printf \"%d\", (${TARGET_READY_TIMEOUT_SECONDS} * 5) }")"
  (( steps > 0 )) || return 0

  for _ in $(seq 1 "$steps"); do
    paused="$(mpv_get_property "paused-for-cache" || true)"
    ptime="$(mpv_get_property "playback-time" || true)"

    if [[ "$paused" == "false" ]] && [[ "$ptime" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      if awk "BEGIN { exit !(${ptime} > 0.05) }"; then
        return 0
      fi
    fi

    sleep 0.2
  done

  return 1
}

switch_channel() {
  local target="$1"
  target="$(normalize_target "$target")"

  ensure_shell
  apply_runtime_source_options "$target"

  mpv_send_json "$(jq -nc --arg vf "" '{"command":["vf", "set", $vf]}')"
  mpv_send_json "$(jq -nc --arg f "$STATIC_FILE" '{"command":["loadfile", $f, "replace"]}')"
  mpv_send_json "$(jq -nc '{"command":["set_property", "loop-file", "inf"]}')"

  sleep "$MIN_STATIC_SECONDS"

  mpv_send_json "$(jq -nc --arg u "$target" '{"command":["loadfile", $u, "replace"]}')"
  mpv_send_json "$(jq -nc '{"command":["set_property", "loop-file", "no"]}')"

  sleep 0.20
  mpv_send_json "$(jq -nc --arg vf "$VF_CHAIN" '{"command":["vf", "set", $vf]}')"

  wait_for_target_ready || true
  maybe_random_seek "$target"
}

channels_filter='if type=="array" then . elif type=="object" and (.channels|type=="array") then .channels else [] end'

channel_file_check() {
  [[ -f "$CHANNELS_FILE" ]] || die "Channels file not found: $CHANNELS_FILE"
}

channel_count() {
  channel_file_check
  jq -er "${channels_filter} | length" "$CHANNELS_FILE"
}

channel_url_by_index() {
  local idx="$1"
  local entry_type=""
  local cmd=""
  local resolved=""
  channel_file_check

  entry_type="$(jq -er --argjson idx "$idx" "
    ${channels_filter}
    | .[\$idx-1] as \$v
    | if \$v == null then empty else (\$v|type) end
  " "$CHANNELS_FILE" 2>/dev/null || true)"

  [[ -n "$entry_type" ]] || return 1

  if [[ "$entry_type" == "string" ]]; then
    jq -er --argjson idx "$idx" "${channels_filter} | .[\$idx-1]" "$CHANNELS_FILE" 2>/dev/null
    return 0
  fi

  resolved="$(jq -er --argjson idx "$idx" "${channels_filter} | .[\$idx-1].url // empty" "$CHANNELS_FILE" 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  cmd="$(jq -er --argjson idx "$idx" "${channels_filter} | .[\$idx-1].cmd // empty" "$CHANNELS_FILE" 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then
    resolved="$(bash -lc "$cmd" 2>/dev/null | head -n1 | trim || true)"
    [[ -n "$resolved" ]] || die "Channel $idx cmd returned no URL/path"
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

resolve_channel_selector_to_index() {
  local selector="$1"
  local idx=""

  channel_file_check

  if is_int "$selector"; then
    idx="$(jq -er --argjson idx "$selector" "${channels_filter} | if .[\$idx-1] == null then empty else \$idx end" "$CHANNELS_FILE" 2>/dev/null || true)"
  else
    idx="$(jq -er --arg name "$selector" "
      ${channels_filter}
      | to_entries
      | map(select((.value|type == \"object\") and (.value.name? != null) and ((.value.name|ascii_downcase) == (\$name|ascii_downcase))))
      | if length == 0 then empty else (.[0].key + 1) end
    " "$CHANNELS_FILE" 2>/dev/null || true)"

    if [[ -z "$idx" ]]; then
      idx="$(jq -er --arg maybe "$selector" "
        ${channels_filter}
        | to_entries
        | map(select(((.value|type) == \"string\" and .value == \$maybe) or ((.value|type) == \"object\" and (.value.url? == \$maybe))))
        | if length == 0 then empty else (.[0].key + 1) end
      " "$CHANNELS_FILE" 2>/dev/null || true)"
    fi
  fi

  [[ -n "$idx" ]] || return 1
  printf '%s\n' "$idx"
}

get_next_channel_index() {
  local count
  local current=0
  local next

  count="$(channel_count)"
  (( count > 0 )) || die "No channels found in $CHANNELS_FILE"

  if [[ -f "$CHANNEL_INDEX_FILE" ]]; then
    current="$(cat "$CHANNEL_INDEX_FILE" 2>/dev/null || echo 0)"
    is_int "$current" || current=0
  fi

  next=$(( (current % count) + 1 ))
  printf '%s\n' "$next" > "$CHANNEL_INDEX_FILE"
  printf '%s\n' "$next"
}

get_prev_channel_index() {
  local count
  local current=1
  local prev

  count="$(channel_count)"
  (( count > 0 )) || die "No channels found in $CHANNELS_FILE"

  if [[ -f "$CHANNEL_INDEX_FILE" ]]; then
    current="$(cat "$CHANNEL_INDEX_FILE" 2>/dev/null || echo 1)"
    is_int "$current" || current=1
  fi

  prev=$(( ((current - 2 + count) % count) + 1 ))
  printf '%s\n' "$prev" > "$CHANNEL_INDEX_FILE"
  printf '%s\n' "$prev"
}

remember_channel_index() {
  local idx="$1"
  is_int "$idx" || return 0
  printf '%s\n' "$idx" > "$CHANNEL_INDEX_FILE"
}

list_channels() {
  channel_file_check

  jq -r "
    ${channels_filter}
    | to_entries[]
    | (.key + 1) as \$idx
    | .value as \$v
    | if (\$v|type) == \"string\" then
        \"\(\$idx)\t-\t\(\$v)\"
      elif (\$v|type) == \"object\" then
        \"\(\$idx)\t\((\$v.name // \"-\"))\t\((\$v.url // \$v.cmd // \"\"))\"
      else
        empty
      end
  " "$CHANNELS_FILE"
}

RESOLVED_TARGET=""
RESOLVED_CHANNEL_INDEX=""

resolve_target() {
  local channel="${1-}"
  local url="${2-}"
  local idx

  RESOLVED_TARGET=""
  RESOLVED_CHANNEL_INDEX=""

  if [[ -n "$url" ]]; then
    RESOLVED_TARGET="$url"
    return 0
  fi

  if [[ -n "$channel" ]]; then
    if idx="$(resolve_channel_selector_to_index "$channel" 2>/dev/null || true)"; then
      RESOLVED_CHANNEL_INDEX="$idx"
      RESOLVED_TARGET="$(channel_url_by_index "$idx")"
      return 0
    fi

    # Fallback: treat --channel value as direct URL/path
    RESOLVED_TARGET="$channel"
    return 0
  fi

  return 1
}

switch_and_remember_index() {
  local idx="$1"
  local target
  target="$(channel_url_by_index "$idx")"
  remember_channel_index "$idx"
  switch_channel "$target"
}

read_keyboard_event() {
  local key=""
  if ! IFS= read -rsn1 key; then
    return 1
  fi
  printf '%s\n' "$key"
}

switch_random_channel() {
  local count idx
  count="$(channel_count)"
  (( count > 0 )) || die "No channels found in $CHANNELS_FILE"
  idx="$(rand_int_between 1 "$count")"
  switch_and_remember_index "$idx"
}

switch_from_selector_or_url() {
  local selector="$1"
  local target idx

  if [[ "$selector" =~ ^[0-9]+$ ]]; then
    idx="$selector"
    switch_and_remember_index "$idx"
    return 0
  fi

  if idx="$(resolve_channel_selector_to_index "$selector" 2>/dev/null || true)"; then
    switch_and_remember_index "$idx"
    return 0
  fi

  target="$selector"
  switch_channel "$target"
}

run_controller() {
  local initial_done=0
  local event cmd arg idx

  ensure_shell

  if resolve_target "$CHANNEL" "$URL"; then
    [[ -n "$RESOLVED_TARGET" ]] && switch_channel "$RESOLVED_TARGET"
    [[ -n "$RESOLVED_CHANNEL_INDEX" ]] && remember_channel_index "$RESOLVED_CHANNEL_INDEX"
    initial_done=1
  fi

  if [[ "$initial_done" -eq 0 ]]; then
    if idx="$(resolve_channel_selector_to_index "$DEFAULT_START_CHANNEL" 2>/dev/null || true)"; then
      switch_and_remember_index "$idx"
    else
      idx="$(get_next_channel_index)"
      switch_and_remember_index "$idx"
    fi
  fi

  if [[ -n "$INPUT_EVENT_CMD" ]]; then
    while IFS= read -r event; do
      cmd="${event%%:*}"
      arg="${event#*:}"
      case "$cmd" in
        next) switch_and_remember_index "$(get_next_channel_index)" ;;
        prev) switch_and_remember_index "$(get_prev_channel_index)" ;;
        random) switch_random_channel ;;
        channel) [[ -n "$arg" ]] && switch_from_selector_or_url "$arg" ;;
        url) [[ -n "$arg" ]] && switch_channel "$arg" ;;
        quit) break ;;
      esac
    done < <(bash -lc "$INPUT_EVENT_CMD")
    return 0
  fi

  echo "Controls: ${KEY_NEXT}=next ${KEY_PREV}=prev ${KEY_RANDOM}=random 1-9=channel ${KEY_QUIT}=quit"
  while true; do
    event="$(read_keyboard_event || true)"
    [[ -n "$event" ]] || continue

    if [[ "$event" == "$KEY_QUIT" ]]; then
      break
    elif [[ "$event" == "$KEY_NEXT" ]]; then
      switch_and_remember_index "$(get_next_channel_index)"
    elif [[ "$event" == "$KEY_PREV" ]]; then
      switch_and_remember_index "$(get_prev_channel_index)"
    elif [[ "$event" == "$KEY_RANDOM" ]]; then
      switch_random_channel
    elif [[ "$event" =~ ^[1-9]$ ]]; then
      switch_and_remember_index "$event"
    fi
  done
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || {
  usage
  exit 1
}
shift || true

CHANNEL=""
URL=""
RANDOM_SWITCH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --url)
      URL="${2:-}"
      shift 2
      ;;
    --resolution)
      RESOLUTION="${2:-}"
      shift 2
      ;;
    --fps-cap)
      YTDL_MAX_FPS="${2:-}"
      shift 2
      ;;
    --random)
      RANDOM_SWITCH=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown arg: $1"
      ;;
  esac
done

need_cmd mpv
need_cmd socat
need_cmd jq

case "$COMMAND" in
  list)
    list_channels
    ;;
  start)
    ensure_shell
    if resolve_target "$CHANNEL" "$URL"; then
      [[ -n "$RESOLVED_TARGET" ]] && switch_channel "$RESOLVED_TARGET"
      [[ -n "$RESOLVED_CHANNEL_INDEX" ]] && remember_channel_index "$RESOLVED_CHANNEL_INDEX"
    fi
    ;;
  switch)
    if [[ "$RANDOM_SWITCH" -eq 1 ]]; then
      count="$(channel_count)"
      (( count > 0 )) || die "No channels found in $CHANNELS_FILE"
      RESOLVED_CHANNEL_INDEX="$(rand_int_between 1 "$count")"
      RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_CHANNEL_INDEX")"
      remember_channel_index "$RESOLVED_CHANNEL_INDEX"
    elif [[ -z "$CHANNEL" && -z "$URL" ]]; then
      RESOLVED_CHANNEL_INDEX="$(get_next_channel_index)"
      RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_CHANNEL_INDEX")"
    else
      resolve_target "$CHANNEL" "$URL" || true
      [[ -n "$RESOLVED_TARGET" ]] || die "switch requires --channel or --url"
      [[ -n "$RESOLVED_CHANNEL_INDEX" ]] && remember_channel_index "$RESOLVED_CHANNEL_INDEX"
    fi
    switch_channel "$RESOLVED_TARGET"
    ;;
  run)
    run_controller
    ;;
  help)
    usage
    ;;
  *)
    die "Unknown command: $COMMAND"
    ;;
esac
