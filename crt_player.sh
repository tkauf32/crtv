#!/usr/bin/env bash
set -euo pipefail

# crt_player.sh
#
# New IPC-driven CRT player script with:
# - One persistent mpv instance (IPC socket)
# - Static bumper between channel switches (same mpv process)
# - JSON vibe map (vibes -> channels -> directory-backed program paths)
# - Optional random start seek after loading target
#
# Key env vars:
#   STATIC_FILE                Path to static bumper video.
#                              Default: <script_dir>/assets/static.mp4
#   MIN_STATIC_SECONDS         Minimum static bumper duration before target load.
#                              Default: 1.8
#   CHANNELS_FILE              Vibe/channel JSON path.
#                              Default: <script_dir>/channels.json
#   ENABLE_RANDOM_START        Random start policy: auto|1|0 (default: auto)
#                              auto => on for http(s) URLs, off for local paths
#   RANDOM_START_MIN_PCT       Default: 20
#   RANDOM_START_MAX_PCT       Default: 80
#   VIBE_INDEX_FILE            Tracks current tuned vibe number
#   CHANNEL_INDEX_DIR          Tracks current tuned channel per vibe
#   PROGRAM_ORDER_RANDOM      Randomize directory-backed program order: 1|0
#
# Vibe map JSON supported shape:
#   {
#     "vibes": [
#       {
#         "number": 1,
#         "name": "focus",
#         "channels": [
#           {"number": 1, "name": "study-lofi", "paths": ["/mnt/media/focus/study-lofi"]}
#         ]
#       }
#     ]
#   }
#
# Commands:
#   ./crt_player.sh list
#   ./crt_player.sh start [--vibe focus] [--channel 1] [--url url]
#   ./crt_player.sh switch --vibe 1
#   ./crt_player.sh switch --vibe focus --channel 2
#   ./crt_player.sh switch --program-next
#   ./crt_player.sh switch --program-prev --vibe focus --channel 2
#   ./crt_player.sh switch --url "https://..."
#   ./crt_player.sh run [--vibe focus] [--channel 1]

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

if [[ -f "${REPO_ROOT}/plex-api/.env" ]]; then
  set -a
  source "${REPO_ROOT}/plex-api/.env"
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
: "${STATIC_REMOTE_SECONDS:=${MIN_STATIC_SECONDS}}"
: "${STATIC_LOCAL_SECONDS:=${MIN_STATIC_SECONDS}}"
: "${CHANNELS_FILE:=${REPO_ROOT}/channels.json}"
: "${RESOLUTION:=240}"
: "${YTDL_MAX_FPS:=30}"
: "${ENABLE_RANDOM_START:=auto}"
: "${RANDOM_START_MIN_PCT:=20}"
: "${RANDOM_START_MAX_PCT:=80}"
: "${VIBE_INDEX_FILE:=/tmp/crt_player_vibe_index}"
: "${CHANNEL_INDEX_DIR:=/tmp/crt_player_channel_index}"
: "${PROGRAM_INDEX_DIR:=/tmp/crt_player_program_index}"
: "${PROGRAM_ORDER_RANDOM:=0}"
: "${TARGET_READY_TIMEOUT_SECONDS:=8}"
: "${LOG_LEVEL:=info}"
: "${LOG_FILE:=${REPO_ROOT}/logs/crt_player.log}"
: "${LOG_FILE_LEVEL:=debug}"
: "${LOG_TO_STDERR:=1}"
: "${MPV_LOG_FILE:=${REPO_ROOT}/logs/mpv.log}"
: "${MPV_LOG_LEVEL:=all=info,ytdl_hook=debug}"
: "${MPV_LOG_EXCERPT_LINES:=80}"
: "${AUTO_ADVANCE_ON_END:=1}"
: "${AUTO_ADVANCE_POLL_SECONDS:=0.5}"
: "${RECOVER_TO_NEXT_ON_FAILURE:=1}"
: "${MAX_RECOVERY_CHANNEL_TRIES:=5}"
: "${AUTO_RECOVER_SHELL:=1}"
: "${SWITCH_LOCK_FILE:=/tmp/crt_player_switch.lock}"
: "${SWITCH_LOCK_WAIT_SECONDS:=30}"
: "${SWITCH_REQUEST_FILE:=/tmp/crt_player_switch.request}"
: "${CHANNEL_OSD_ENABLED:=1}"
: "${CHANNEL_OSD_DURATION_MS:=5000}"
: "${CHANNEL_OSD_FONT_SIZE:=24}"
: "${CHANNEL_OSD_MARGIN_Y:=54}"
: "${DEFAULT_START_VIBE:=1}"
: "${DEFAULT_START_CHANNEL:=1}"
: "${KEY_NEXT:=n}"
: "${KEY_PREV:=p}"
: "${KEY_RANDOM:=r}"
: "${KEY_QUIT:=q}"
: "${INPUT_EVENT_CMD:=}"
: "${STATIC_VF_CHAIN:=${VF_CHAIN}}"
: "${AMIXER_BIN:=/usr/bin/amixer}"
: "${AMIXER_CONTROL:=Master}"
: "${VOLUME_STEP_PCT:=10}"

usage() {
  cat <<'USAGE'
Usage:
  crt_player.sh list
  crt_player.sh start [--vibe <index|name>] [--channel <index|name>] [--url <url_or_path>] [--resolution N] [--fps-cap N]
  crt_player.sh switch [--vibe <index|name>] [--channel <index|name>] [--url <url_or_path>] [--random] [--program-next|--program-prev]
  crt_player.sh run [--vibe <index|name>] [--channel <index|name>] [--url <url_or_path>]
  crt_player.sh volume --up|--down [--step <percent>]

Examples:
  ./crt_player.sh list
  ./crt_player.sh start --vibe focus --channel 1
  ./crt_player.sh switch            # next channel in current vibe
  ./crt_player.sh switch --random   # random vibe/channel from channels.json
  ./crt_player.sh switch --vibe television --channel sitcoms
  ./crt_player.sh switch --program-next
  ./crt_player.sh switch --url "https://www.youtube.com/watch?v=XXXXXXXXXXX"
  ./crt_player.sh run               # keyboard: n/p/r/1-9/q
  INPUT_EVENT_CMD='./scripts/input-events-stub.sh' ./crt_player.sh run
  ./crt_player.sh volume --up --step 10

Env:
  STATIC_FILE, MIN_STATIC_SECONDS, CHANNELS_FILE,
  STATIC_REMOTE_SECONDS, STATIC_LOCAL_SECONDS, STATIC_VF_CHAIN,
  AUTO_ADVANCE_ON_END, AUTO_ADVANCE_POLL_SECONDS,
  RECOVER_TO_NEXT_ON_FAILURE, MAX_RECOVERY_CHANNEL_TRIES, AUTO_RECOVER_SHELL,
  ENABLE_RANDOM_START, RANDOM_START_MIN_PCT, RANDOM_START_MAX_PCT, VIBE_INDEX_FILE, CHANNEL_INDEX_DIR, PROGRAM_INDEX_DIR, PROGRAM_ORDER_RANDOM,
  RESOLUTION, YTDL_MAX_FPS, PROFILE, MPV_VO, MPV_GPU_CONTEXT, MPV_HWDEC, VF_CHAIN,
  DISPLAY, XAUTHORITY, LOG_LEVEL, LOG_FILE, LOG_FILE_LEVEL, LOG_TO_STDERR, MPV_LOG_FILE, MPV_LOG_LEVEL,
  MPV_LOG_EXCERPT_LINES, SWITCH_LOCK_FILE, SWITCH_LOCK_WAIT_SECONDS, SWITCH_REQUEST_FILE,
  CHANNEL_OSD_ENABLED, CHANNEL_OSD_DURATION_MS, CHANNEL_OSD_FONT_SIZE, CHANNEL_OSD_MARGIN_Y,
  DEFAULT_START_VIBE, DEFAULT_START_CHANNEL, KEY_NEXT, KEY_PREV, KEY_RANDOM, KEY_QUIT, INPUT_EVENT_CMD,
  AMIXER_BIN, AMIXER_CONTROL, VOLUME_STEP_PCT
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

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

trim() {
  awk '{$1=$1; print}'
}

log_level_num() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    debug) echo 10 ;;
    info) echo 20 ;;
    warn) echo 30 ;;
    error) echo 40 ;;
    off) echo 99 ;;
    *) echo 20 ;;
  esac
}

LOG_FILE_READY=0
init_log_file() {
  [[ "$LOG_FILE_READY" -eq 1 ]] && return 0
  mkdir -p "$(dirname "$LOG_FILE")" >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$MPV_LOG_FILE")" >/dev/null 2>&1 || true
  touch "$LOG_FILE" >/dev/null 2>&1 || return 1
  LOG_FILE_READY=1
}

log_msg() {
  local level="$1"
  shift || true
  local cfg_num lvl_num file_cfg_num
  cfg_num="$(log_level_num "$LOG_LEVEL")"
  file_cfg_num="$(log_level_num "$LOG_FILE_LEVEL")"
  lvl_num="$(log_level_num "$level")"

  if (( lvl_num >= file_cfg_num )); then
    if init_log_file; then
      printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$LOG_FILE"
    fi
  fi

  if is_true "$LOG_TO_STDERR" && (( lvl_num >= cfg_num )); then
    printf '[%s] %s: %s\n' "$(date '+%H:%M:%S')" "$level" "$*" >&2
  fi
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
    "--keep-open=yes"
    "--demuxer-max-bytes=50MiB"
    "--demuxer-max-back-bytes=10MiB"
    "--scale=bilinear"
    "--cscale=bilinear"
    "--dscale=bilinear"
    "--idle=yes"
  )

  upsert_mpv_arg "input-ipc-server" "$TV_SOCK"
  upsert_mpv_arg "ytdl-format" "$(build_ytdl_format)"
  upsert_mpv_arg "log-file" "$MPV_LOG_FILE"
  upsert_mpv_arg "msg-level" "$MPV_LOG_LEVEL"
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

mpv_get_property_json() {
  local prop="$1"
  local req
  local resp

  req="$(jq -nc --arg p "$prop" '{"command":["get_property", $p]}')"
  resp="$(printf '%s\n' "$req" | socat -T 1 - UNIX-CONNECT:"$TV_SOCK" 2>/dev/null || true)"

  printf '%s\n' "$resp" \
    | jq -rc 'select(type == "object" and .error == "success") | .data' \
    | tail -n1
}

new_switch_request_token() {
  printf '%s-%s\n' "$$" "$(date +%s%N)"
}

set_switch_request_token() {
  local token="$1"
  printf '%s\n' "$token" > "$SWITCH_REQUEST_FILE"
}

is_switch_request_current() {
  local token="$1"
  local current=""
  [[ -n "$token" ]] || return 0
  [[ -f "$SWITCH_REQUEST_FILE" ]] || return 0
  current="$(cat "$SWITCH_REQUEST_FILE" 2>/dev/null || true)"
  [[ "$current" == "$token" ]]
}

sleep_interruptible() {
  local seconds="$1"
  local token="${2:-}"
  local steps=0

  if ! awk "BEGIN { exit !(${seconds} > 0) }"; then
    return 0
  fi

  steps="$(awk "BEGIN { printf \"%d\", ((${seconds}) * 20) + 0.999 }")"
  (( steps > 0 )) || steps=1

  for _ in $(seq 1 "$steps"); do
    is_switch_request_current "$token" || return 1
    sleep 0.05
  done
}

log_mpv_excerpt() {
  local lines="${1:-$MPV_LOG_EXCERPT_LINES}"
  local entry

  [[ -f "$MPV_LOG_FILE" ]] || return 0
  is_int "$lines" || lines=80
  (( lines > 0 )) || lines=80

  while IFS= read -r entry; do
    log_msg debug "mpv: ${entry}"
  done < <(tail -n "$lines" "$MPV_LOG_FILE" 2>/dev/null || true)
}

log_failure_diagnostics() {
  local target="$1"
  local paused ptime eof path cache_state tracks

  paused="$(mpv_get_property "paused-for-cache" || true)"
  ptime="$(mpv_get_property "playback-time" || true)"
  eof="$(mpv_get_property "eof-reached" || true)"
  path="$(mpv_get_property "path" || true)"
  cache_state="$(mpv_get_property_json "demuxer-cache-state" || true)"
  tracks="$(mpv_get_property_json "track-list" || true)"

  log_msg error "switch diagnostics target=${target} paused-for-cache=${paused:-na} playback-time=${ptime:-na} eof=${eof:-na} path=${path:-na}"
  [[ -n "$cache_state" ]] && log_msg debug "switch diagnostics demuxer-cache-state=${cache_state}"
  [[ -n "$tracks" ]] && log_msg debug "switch diagnostics track-list=${tracks}"
  log_mpv_excerpt "$MPV_LOG_EXCERPT_LINES"
}

ensure_socket_clean() {
  if [[ -S "$TV_SOCK" ]]; then
    if ! socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
      rm -f "$TV_SOCK"
    fi
  fi
}

socket_live() {
  [[ -S "$TV_SOCK" ]] || return 1
  socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1
}

ensure_shell() {
  ensure_socket_clean
  export DISPLAY XAUTHORITY

  if [[ ! -S "$TV_SOCK" ]]; then
    build_mpv_args
    upsert_mpv_arg "loop-file" "inf"

    mpv "${MPV_ARGS[@]}" "$STATIC_FILE" >/dev/null 2>&1 &
    disown || true
    log_msg info "started mpv shell sock=${TV_SOCK}"

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
  local request_token="${1:-}"
  local steps
  local paused
  local ptime

  steps="$(awk "BEGIN { printf \"%d\", (${TARGET_READY_TIMEOUT_SECONDS} * 5) }")"
  (( steps > 0 )) || return 0

  for _ in $(seq 1 "$steps"); do
    is_switch_request_current "$request_token" || return 2
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

static_duration_for_target() {
  local target="$1"
  if is_remote_source "$target"; then
    printf '%s\n' "$STATIC_REMOTE_SECONDS"
  else
    printf '%s\n' "$STATIC_LOCAL_SECONDS"
  fi
}

play_static_now() {
  mpv_send_json "$(jq -nc --arg vf "$STATIC_VF_CHAIN" '{"command":["vf", "set", $vf]}')" || true
  mpv_send_json "$(jq -nc --arg f "$STATIC_FILE" '{"command":["loadfile", $f, "replace"]}')" || true
  mpv_send_json "$(jq -nc '{"command":["set_property", "loop-file", "inf"]}')" || true
}

show_channel_overlay() {
  local vibe_number="$1"
  local channel_number="$2"

  is_true "$CHANNEL_OSD_ENABLED" || return 0
  is_int "$vibe_number" || return 0
  is_int "$channel_number" || return 0

  mpv_send_json "$(jq -nc --argjson n "$CHANNEL_OSD_FONT_SIZE" '{"command":["set_property", "osd-font-size", $n]}')" || true
  mpv_send_json "$(jq -nc --arg v "center" '{"command":["set_property", "osd-align-x", $v]}')" || true
  mpv_send_json "$(jq -nc --arg v "top" '{"command":["set_property", "osd-align-y", $v]}')" || true
  mpv_send_json "$(jq -nc --argjson n "$CHANNEL_OSD_MARGIN_Y" '{"command":["set_property", "osd-margin-y", $n]}')" || true
  mpv_send_json "$(jq -nc --arg msg "V${vibe_number} CH ${channel_number}" --argjson ms "$CHANNEL_OSD_DURATION_MS" '{"command":["show-text", $msg, $ms] }')" || true
}

switch_channel_attempt() {
  local target="$1"
  local request_token="${2:-}"
  local static_seconds
  local source_kind="local"
  local switch_started_at
  local ready_status="ready"
  local wait_ok=0
  target="$(normalize_target "$target")"

  if ! is_remote_source "$target" && [[ ! -f "$target" ]]; then
    log_msg error "target missing path=${target}"
    return 1
  fi

  static_seconds="$(static_duration_for_target "$target")"
  switch_started_at="$SECONDS"

  if is_remote_source "$target"; then
    source_kind="remote"
  fi

  ensure_shell
  apply_runtime_source_options "$target"
  is_switch_request_current "$request_token" || return 2

  log_msg info "switch begin source=${source_kind} static=${static_seconds}s"
  play_static_now

  sleep_interruptible "$static_seconds" "$request_token" || return 2

  is_switch_request_current "$request_token" || return 2
  mpv_send_json "$(jq -nc --arg u "$target" '{"command":["loadfile", $u, "replace"]}')" || true
  mpv_send_json "$(jq -nc '{"command":["set_property", "loop-file", "no"]}')" || true

  sleep_interruptible 0.20 "$request_token" || return 2
  mpv_send_json "$(jq -nc --arg vf "$VF_CHAIN" '{"command":["vf", "set", $vf]}')" || true

  if wait_for_target_ready "$request_token"; then
    wait_ok=1
  else
    case "$?" in
      2) return 2 ;;
      *) ready_status="timeout" ;;
    esac
  fi

  if [[ "$wait_ok" -ne 1 ]]; then
    play_static_now
    log_msg warn "target failed readiness path=${target}; restored static"
    log_failure_diagnostics "$target"
    log_msg info "switch end status=${ready_status} elapsed=$((SECONDS - switch_started_at))s"
    return 1
  fi

  maybe_random_seek "$target"
  log_msg info "switch end status=${ready_status} elapsed=$((SECONDS - switch_started_at))s"
  return 0
}

switch_with_recovery() {
  local target="$1"
  local from_vibe="${2:-0}"
  local from_channel="${3:-0}"
  local request_token="${4:-}"
  local tries max_tries idx candidate_target
  local lock_fd
  local numbers=()
  local pos=-1
  local rc=1

  exec {lock_fd}> "$SWITCH_LOCK_FILE" || die "Unable to open switch lock: $SWITCH_LOCK_FILE"
  if ! flock -w "$SWITCH_LOCK_WAIT_SECONDS" "$lock_fd"; then
    exec {lock_fd}>&-
    die "Timed out waiting for switch lock: $SWITCH_LOCK_FILE"
  fi

  if switch_channel_attempt "$target" "$request_token"; then
    if [[ "$from_vibe" -gt 0 && "$from_channel" -gt 0 ]]; then
      remember_vibe_index "$from_vibe"
      remember_channel_index "$from_vibe" "$from_channel"
      show_channel_overlay "$from_vibe" "$from_channel"
    fi
    rc=0
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return "$rc"
  else
    case "$?" in
      2)
        flock -u "$lock_fd" || true
        exec {lock_fd}>&-
        return 2
        ;;
    esac
  fi

  if ! is_true "$RECOVER_TO_NEXT_ON_FAILURE"; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 1
  fi

  mapfile -t numbers < <(list_active_channel_numbers_for_vibe "$from_vibe" 2>/dev/null)
  if (( ${#numbers[@]} == 0 )); then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 1
  fi

  max_tries="$MAX_RECOVERY_CHANNEL_TRIES"
  is_int "$max_tries" || max_tries=5
  (( max_tries > 0 )) || max_tries=1
  (( max_tries <= ${#numbers[@]} )) || max_tries="${#numbers[@]}"

  if (( from_channel > 0 )); then
    idx="$from_channel"
  else
    idx="$(current_channel_index_for_vibe "$from_vibe" 2>/dev/null || echo 0)"
    is_int "$idx" || idx=0
  fi

  for i in "${!numbers[@]}"; do
    if (( numbers[$i] == idx )); then
      pos="$i"
      break
    fi
  done

  for tries in $(seq 1 "$max_tries"); do
    is_switch_request_current "$request_token" || {
      flock -u "$lock_fd" || true
      exec {lock_fd}>&-
      return 2
    }
    if (( ${#numbers[@]} == 0 )); then
      break
    fi
    pos=$(( (pos + 1 + ${#numbers[@]}) % ${#numbers[@]} ))
    idx="${numbers[$pos]}"
    candidate_target="$(channel_url_by_index "$from_vibe" "$idx" 2>/dev/null || true)"
    [[ -n "$candidate_target" ]] || continue
    log_msg warn "recovery attempt=$tries vibe_index=$from_vibe channel_index=$idx"
    if switch_channel_attempt "$candidate_target" "$request_token"; then
      remember_vibe_index "$from_vibe"
      remember_channel_index "$from_vibe" "$idx"
      show_channel_overlay "$from_vibe" "$idx"
      log_msg warn "recovered playback on vibe_index=$from_vibe channel_index=$idx"
      rc=0
      flock -u "$lock_fd" || true
      exec {lock_fd}>&-
      return "$rc"
    else
      case "$?" in
        2)
          flock -u "$lock_fd" || true
          exec {lock_fd}>&-
          return 2
          ;;
      esac
    fi
  done

  log_msg error "switch failed and recovery exhausted"
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return 1
}

switch_channel() {
  local target="$1"
  switch_with_recovery "$target" 0 0
}

vibes_filter='if type=="object" and (.vibes|type=="array") then .vibes else [] end'
active_vibes_filter="${vibes_filter} | map(select((.disabled // false) | not))"
numbered_active_vibes_filter='
  '"${active_vibes_filter}"'
  | to_entries
  | map({
      list_index: (.key + 1),
      number: (.value.number // (.key + 1)),
      name: (.value.name // "-"),
      value: .value
    })
'

channel_file_check() {
  [[ -f "$CHANNELS_FILE" ]] || die "Channels file not found: $CHANNELS_FILE"
}

vibe_count() {
  channel_file_check
  jq -er "${active_vibes_filter} | length" "$CHANNELS_FILE"
}

list_active_vibe_numbers() {
  channel_file_check
  jq -r "${numbered_active_vibes_filter} | sort_by(.number) | .[].number" "$CHANNELS_FILE"
}

vibe_entry_by_index() {
  local vibe_idx="$1"
  channel_file_check

  jq -ce --argjson vibe "$vibe_idx" "
    ${numbered_active_vibes_filter}
    | map(select(.number == \$vibe))
    | if length == 0 then empty else .[0].value end
  " "$CHANNELS_FILE" 2>/dev/null || true
}

list_active_channel_numbers_for_vibe() {
  local vibe_idx="$1"
  channel_file_check

  jq -r --argjson vibe "$vibe_idx" "
    ${numbered_active_vibes_filter}
    | map(select(.number == \$vibe))
    | if length == 0 then [] else .[0].value.channels // [] end
    | map(select((.disabled // false) | not))
    | to_entries
    | map(.value.number // (.key + 1))
    | unique
    | sort
    | .[]
  " "$CHANNELS_FILE"
}

channel_state_file_for_vibe() {
  local vibe_idx="$1"
  mkdir -p "$CHANNEL_INDEX_DIR" >/dev/null 2>&1 || true
  printf '%s/vibe_%s.index\n' "$CHANNEL_INDEX_DIR" "$vibe_idx"
}

program_state_file_for_channel() {
  local vibe_idx="$1"
  local channel_number="$2"
  mkdir -p "$PROGRAM_INDEX_DIR" >/dev/null 2>&1 || true
  printf '%s/vibe_%s_channel_%s.index\n' "$PROGRAM_INDEX_DIR" "$vibe_idx" "$channel_number"
}

channel_entry_by_index() {
  local vibe_idx="$1"
  local channel_idx="$2"
  channel_file_check

  jq -ce --argjson vibe "$vibe_idx" --argjson channel "$channel_idx" "
    ${numbered_active_vibes_filter}
    | map(select(.number == \$vibe))
    | if length == 0 then empty else .[0].value end
    | (.channels // [])
    | map(select((.disabled // false) | not))
    | to_entries
    | map({
        number: (.value.number // (.key + 1)),
        value: .value
      })
    | map(select(.number == \$channel))
    | if length == 0 then empty else .[0].value end
  " "$CHANNELS_FILE" 2>/dev/null || true
}

channel_number_from_entry() {
  local entry_json="$1"
  local fallback="$2"

  printf '%s\n' "$entry_json" \
    | jq -er --argjson fallback "$fallback" '.number // $fallback' 2>/dev/null \
    || printf '%s\n' "$fallback"
}

resolve_program_entry() {
  local program_json="$1"
  local entry_type=""
  local resolved=""
  local cmd=""

  entry_type="$(printf '%s\n' "$program_json" | jq -er 'type' 2>/dev/null || true)"
  [[ -n "$entry_type" ]] || return 1

  if [[ "$entry_type" == "string" ]]; then
    printf '%s\n' "$program_json" | jq -er '.' 2>/dev/null
    return 0
  fi

  resolved="$(printf '%s\n' "$program_json" | jq -er '.url // empty' 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  cmd="$(printf '%s\n' "$program_json" | jq -er '.cmd // empty' 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then
    resolved="$(bash -lc "$cmd" 2>/dev/null | head -n1 | trim || true)"
    [[ -n "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
    return 0
  fi

  return 1
}

append_program_targets_for_source() {
  local source="$1"

  if [[ "$source" =~ ^https?:// ]] || [[ "$source" =~ ^file:// ]]; then
    printf '%s\n' "$source"
    return 0
  fi

  source="$(normalize_target "$source")"

  if [[ -d "$source" ]]; then
    find -L "$source" -maxdepth 1 -type f | sort
    return 0
  fi

  if [[ -f "$source" ]]; then
    printf '%s\n' "$source"
  fi
}

channel_program_targets() {
  local entry_json="$1"
  local path_sources=()
  local targets=()
  local source=""
  local program_json=""
  local resolved=""

  mapfile -t path_sources < <(
    printf '%s\n' "$entry_json" \
      | jq -r '
          if .paths? != null then
            (.paths | if type == "array" then .[] else . end)
          elif .path? != null then
            .path
          else
            empty
          end
        ' 2>/dev/null
  )

  if (( ${#path_sources[@]} > 0 )); then
    for source in "${path_sources[@]}"; do
      [[ -n "$source" ]] || continue
      while IFS= read -r resolved; do
        [[ -n "$resolved" ]] && targets+=("$resolved")
      done < <(append_program_targets_for_source "$source")
    done
  else
    while IFS= read -r program_json; do
      [[ -n "$program_json" ]] || continue
      resolved="$(resolve_program_entry "$program_json" || true)"
      [[ -n "$resolved" ]] && targets+=("$resolved")
    done < <(printf '%s\n' "$entry_json" | jq -cr '.programs[]? // empty' 2>/dev/null)
  fi

  (( ${#targets[@]} > 0 )) || return 1

  if is_true "$PROGRAM_ORDER_RANDOM"; then
    command -v shuf >/dev/null 2>&1 || die "PROGRAM_ORDER_RANDOM=1 requires shuf"
    printf '%s\n' "${targets[@]}" | shuf
  else
    printf '%s\n' "${targets[@]}"
  fi
}

channel_has_program_catalog() {
  local vibe_idx="$1"
  local channel_idx="$2"
  local entry_json=""
  local targets=()

  entry_json="$(channel_entry_by_index "$vibe_idx" "$channel_idx")"
  [[ -n "$entry_json" ]] || return 1

  mapfile -t targets < <(channel_program_targets "$entry_json" 2>/dev/null || true)
  (( ${#targets[@]} > 0 ))
}

read_program_index() {
  local vibe_idx="$1"
  local channel_number="$2"
  local program_count="$3"
  local state_file=""
  local current_program=1

  state_file="$(program_state_file_for_channel "$vibe_idx" "$channel_number")"
  if [[ -f "$state_file" ]]; then
    current_program="$(cat "$state_file" 2>/dev/null || echo 1)"
  fi

  is_int "$current_program" || current_program=1
  (( current_program >= 1 )) || current_program=1
  (( current_program <= program_count )) || current_program=$(( ((current_program - 1) % program_count) + 1 ))

  printf '%s\n' "$current_program"
}

write_program_index() {
  local vibe_idx="$1"
  local channel_number="$2"
  local program_index="$3"
  local state_file=""

  state_file="$(program_state_file_for_channel "$vibe_idx" "$channel_number")"
  printf '%s\n' "$program_index" > "$state_file"
}

channel_url_by_index() {
  local vibe_idx="$1"
  local channel_idx="$2"
  local program_delta="${3:-0}"
  local entry_json=""
  local entry_type=""
  local channel_number=""
  local current_program=1
  local next_program=1
  local resolved=""
  local targets=()
  channel_file_check

  entry_json="$(channel_entry_by_index "$vibe_idx" "$channel_idx")"

  [[ -n "$entry_json" ]] || return 1
  entry_type="$(printf '%s\n' "$entry_json" | jq -er 'type' 2>/dev/null || true)"

  if [[ "$entry_type" == "string" ]]; then
    printf '%s\n' "$entry_json" | jq -er '.' 2>/dev/null
    return 0
  fi

  resolved="$(printf '%s\n' "$entry_json" | jq -er '.url // empty' 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  mapfile -t targets < <(channel_program_targets "$entry_json" 2>/dev/null || true)
  if (( ${#targets[@]} > 0 )); then
    channel_number="$(channel_number_from_entry "$entry_json" "$channel_idx")"
    current_program="$(read_program_index "$vibe_idx" "$channel_number" "${#targets[@]}")"

    if [[ "$program_delta" =~ ^-?[0-9]+$ ]] && (( program_delta != 0 )); then
      next_program=$(( ((current_program - 1 + program_delta) % ${#targets[@]} + ${#targets[@]}) % ${#targets[@]} + 1 ))
    else
      next_program="$current_program"
    fi

    write_program_index "$vibe_idx" "$channel_number" "$next_program"
    printf '%s\n' "${targets[$((next_program - 1))]}"
    return 0
  fi

  return 1
}

resolve_vibe_selector_to_index() {
  local selector="$1"
  local idx=""

  channel_file_check

  if is_int "$selector"; then
    idx="$(jq -er --argjson idx "$selector" "
      ${numbered_active_vibes_filter}
      | map(select(.number == \$idx))
      | if length == 0 then empty else .[0].number end
    " "$CHANNELS_FILE" 2>/dev/null || true)"
  else
    idx="$(jq -er --arg name "$selector" "
      ${numbered_active_vibes_filter}
      | map(select((.value|type == \"object\") and (.value.name? != null) and ((.value.name|ascii_downcase) == (\$name|ascii_downcase))))
      | if length == 0 then empty else .[0].number end
    " "$CHANNELS_FILE" 2>/dev/null || true)"
  fi

  [[ -n "$idx" ]] || return 1
  printf '%s\n' "$idx"
}

resolve_channel_selector_to_index() {
  local vibe_idx="$1"
  local selector="$2"
  local idx=""

  channel_file_check

  if is_int "$selector"; then
    idx="$(jq -er --argjson vibe "$vibe_idx" --argjson idx "$selector" "
      ${numbered_active_vibes_filter}
      | map(select(.number == \$vibe))
      | if length == 0 then empty else .[0].value end
      | (.channels // [])
      | map(select((.disabled // false) | not))
      | to_entries
      | map({
          number: (.value.number // (.key + 1)),
          value: .value
        })
      | map(select(.number == \$idx))
      | if length == 0 then empty else .[0].number end
    " "$CHANNELS_FILE" 2>/dev/null || true)"
  else
    idx="$(jq -er --argjson vibe "$vibe_idx" --arg name "$selector" "
      ${numbered_active_vibes_filter}
      | map(select(.number == \$vibe))
      | if length == 0 then empty else .[0].value end
      | (.channels // [])
      | map(select((.disabled // false) | not))
      | to_entries
      | map({
          number: (.value.number // (.key + 1)),
          value: .value
        })
      | map(select((.value|type == \"object\") and (.value.name? != null) and ((.value.name|ascii_downcase) == (\$name|ascii_downcase))))
      | if length == 0 then empty else .[0].number end
    " "$CHANNELS_FILE" 2>/dev/null || true)"
  fi

  [[ -n "$idx" ]] || return 1
  printf '%s\n' "$idx"
}

remember_vibe_index() {
  local idx="$1"
  is_int "$idx" || return 0
  printf '%s\n' "$idx" > "$VIBE_INDEX_FILE"
}

current_vibe_index() {
  local idx=""
  if [[ -f "$VIBE_INDEX_FILE" ]]; then
    idx="$(cat "$VIBE_INDEX_FILE" 2>/dev/null || true)"
  fi
  is_int "$idx" || return 1
  printf '%s\n' "$idx"
}

remember_channel_index() {
  local vibe_idx="$1"
  local channel_idx="$2"
  local state_file=""

  is_int "$vibe_idx" || return 0
  is_int "$channel_idx" || return 0
  state_file="$(channel_state_file_for_vibe "$vibe_idx")"
  printf '%s\n' "$channel_idx" > "$state_file"
}

current_channel_index_for_vibe() {
  local vibe_idx="$1"
  local idx=""
  local state_file=""

  state_file="$(channel_state_file_for_vibe "$vibe_idx")"
  if [[ -f "$state_file" ]]; then
    idx="$(cat "$state_file" 2>/dev/null || true)"
  fi

  is_int "$idx" || return 1
  printf '%s\n' "$idx"
}

current_selection() {
  local vibe_idx="${1:-}"
  local channel_idx=""
  local channels=()

  if [[ -z "$vibe_idx" ]]; then
    vibe_idx="$(current_vibe_index || true)"
  fi
  if [[ -z "$vibe_idx" ]]; then
    mapfile -t channels < <(list_active_vibe_numbers 2>/dev/null)
    (( ${#channels[@]} > 0 )) || return 1
    vibe_idx="${channels[0]}"
  fi

  mapfile -t channels < <(list_active_channel_numbers_for_vibe "$vibe_idx" 2>/dev/null)
  (( ${#channels[@]} > 0 )) || return 1

  channel_idx="$(current_channel_index_for_vibe "$vibe_idx" || true)"
  if [[ -z "$channel_idx" ]]; then
    channel_idx="${channels[0]}"
  fi

  if ! printf '%s\n' "${channels[@]}" | grep -qx "$channel_idx"; then
    channel_idx="${channels[0]}"
  fi

  printf '%s %s\n' "$vibe_idx" "$channel_idx"
}

get_next_vibe_index() {
  local numbers=()
  local current=0
  local next=""

  mapfile -t numbers < <(list_active_vibe_numbers 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No vibes found in $CHANNELS_FILE"

  current="$(current_vibe_index || true)"
  is_int "$current" || current=0

  for next in "${numbers[@]}"; do
    if (( next > current )); then
      remember_vibe_index "$next"
      printf '%s\n' "$next"
      return 0
    fi
  done

  next="${numbers[0]}"
  remember_vibe_index "$next"
  printf '%s\n' "$next"
}

get_prev_vibe_index() {
  local numbers=()
  local current=1
  local prev=""

  mapfile -t numbers < <(list_active_vibe_numbers 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No vibes found in $CHANNELS_FILE"

  current="$(current_vibe_index || true)"
  is_int "$current" || current=1

  for (( i=${#numbers[@]}-1; i>=0; i-- )); do
    prev="${numbers[$i]}"
    if (( prev < current )); then
      remember_vibe_index "$prev"
      printf '%s\n' "$prev"
      return 0
    fi
  done

  prev="${numbers[$((${#numbers[@]}-1))]}"
  remember_vibe_index "$prev"
  printf '%s\n' "$prev"
}

get_next_channel_index() {
  local vibe_idx="$1"
  local numbers=()
  local current=0
  local next=""

  mapfile -t numbers < <(list_active_channel_numbers_for_vibe "$vibe_idx" 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No channels found for vibe ${vibe_idx} in $CHANNELS_FILE"

  current="$(current_channel_index_for_vibe "$vibe_idx" || true)"
  is_int "$current" || current=0

  for next in "${numbers[@]}"; do
    if (( next > current )); then
      remember_channel_index "$vibe_idx" "$next"
      printf '%s\n' "$next"
      return 0
    fi
  done

  next="${numbers[0]}"
  remember_channel_index "$vibe_idx" "$next"
  printf '%s\n' "$next"
}

get_prev_channel_index() {
  local vibe_idx="$1"
  local numbers=()
  local current=1
  local prev=""

  mapfile -t numbers < <(list_active_channel_numbers_for_vibe "$vibe_idx" 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No channels found for vibe ${vibe_idx} in $CHANNELS_FILE"

  current="$(current_channel_index_for_vibe "$vibe_idx" || true)"
  is_int "$current" || current=1

  for (( i=${#numbers[@]}-1; i>=0; i-- )); do
    prev="${numbers[$i]}"
    if (( prev < current )); then
      remember_channel_index "$vibe_idx" "$prev"
      printf '%s\n' "$prev"
      return 0
    fi
  done

  prev="${numbers[$((${#numbers[@]}-1))]}"
  remember_channel_index "$vibe_idx" "$prev"
  printf '%s\n' "$prev"
}

list_channels() {
  channel_file_check

  jq -r "
    ${active_vibes_filter}
    | to_entries[]
    | (.value.number // (.key + 1)) as \$vibe_num
    | .value as \$vibe
    | \"VIBE\t\(\$vibe_num)\t\((\$vibe.name // \"-\"))\",
      (
        (\$vibe.channels // [])
        | map(select((.disabled // false) | not))
        | to_entries[]
        | (.value.number // (.key + 1)) as \$channel_num
        | .value as \$channel
        | if (\$channel.paths? != null) or (\$channel.path? != null) then
            \"  CH\t\(\$channel_num)\t\((\$channel.name // \"-\"))\tpaths\"
          elif ((\$channel.programs // []) | length) > 0 then
            \"  CH\t\(\$channel_num)\t\((\$channel.name // \"-\"))\tlegacy-programs=\((\$channel.programs | length))\"
          else
            \"  CH\t\(\$channel_num)\t\((\$channel.name // \"-\"))\t\((\$channel.url // \$channel.cmd // \"\"))\"
          end
      )
  " "$CHANNELS_FILE"
}

RESOLVED_TARGET=""
RESOLVED_VIBE_INDEX=""
RESOLVED_CHANNEL_INDEX=""

resolve_target() {
  local vibe="${1-}"
  local channel="${2-}"
  local url="${3-}"
  local vibe_idx=""
  local channel_idx=""
  local selection=""

  RESOLVED_TARGET=""
  RESOLVED_VIBE_INDEX=""
  RESOLVED_CHANNEL_INDEX=""

  if [[ -n "$url" ]]; then
    RESOLVED_TARGET="$url"
    return 0
  fi

  if [[ -n "$vibe" ]]; then
    if vibe_idx="$(resolve_vibe_selector_to_index "$vibe" 2>/dev/null)"; then
      :
    elif is_int "$vibe"; then
      return 1
    else
      return 1
    fi
  else
    vibe_idx="$(current_vibe_index || true)"
  fi

  if [[ -n "$channel" ]]; then
    [[ -n "$vibe_idx" ]] || selection="$(current_selection)"
    if [[ -z "$vibe_idx" && -n "$selection" ]]; then
      vibe_idx="${selection%% *}"
    fi

    if channel_idx="$(resolve_channel_selector_to_index "$vibe_idx" "$channel" 2>/dev/null)"; then
      RESOLVED_VIBE_INDEX="$vibe_idx"
      RESOLVED_CHANNEL_INDEX="$channel_idx"
      RESOLVED_TARGET="$(channel_url_by_index "$vibe_idx" "$channel_idx")"
      return 0
    fi

    return 1
  fi

  selection="$(current_selection "$vibe_idx" || true)"
  [[ -n "$selection" ]] || return 1

  RESOLVED_VIBE_INDEX="${selection%% *}"
  RESOLVED_CHANNEL_INDEX="${selection##* }"
  RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX")"
  return 0
}

switch_and_remember_selection() {
  local vibe_idx="$1"
  local channel_idx="$2"
  local target
  target="$(channel_url_by_index "$vibe_idx" "$channel_idx")"
  switch_with_recovery "$target" "$vibe_idx" "$channel_idx" || true
}

switch_program_relative() {
  local delta="$1"
  local selection=""
  local vibe_idx=""
  local channel_idx=""
  local target=""

  selection="$(current_selection || true)"
  if [[ -z "$selection" ]]; then
    log_msg warn "program switch ignored: no current selection"
    return 1
  fi

  vibe_idx="${selection%% *}"
  channel_idx="${selection##* }"

  if ! channel_has_program_catalog "$vibe_idx" "$channel_idx"; then
    log_msg warn "program switch ignored: vibe=${vibe_idx} channel=${channel_idx} has no program catalog"
    return 1
  fi

  target="$(channel_url_by_index "$vibe_idx" "$channel_idx" "$delta" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    log_msg warn "program switch ignored: vibe=${vibe_idx} channel=${channel_idx} has no program catalog"
    return 1
  fi

  switch_with_recovery "$target" "$vibe_idx" "$channel_idx" || true
}

read_keyboard_event() {
  local key=""
  if ! IFS= read -rsn1 -t "${1:-0.1}" key; then
    return 1
  fi
  printf '%s\n' "$key"
}

switch_random_channel() {
  local vibe_numbers=()
  local channel_numbers=()
  local pick=0
  local vibe_idx=""

  mapfile -t vibe_numbers < <(list_active_vibe_numbers 2>/dev/null)
  (( ${#vibe_numbers[@]} > 0 )) || die "No vibes found in $CHANNELS_FILE"
  pick="$(rand_int_between 1 "${#vibe_numbers[@]}")"
  vibe_idx="${vibe_numbers[$((pick-1))]}"

  mapfile -t channel_numbers < <(list_active_channel_numbers_for_vibe "$vibe_idx" 2>/dev/null)
  (( ${#channel_numbers[@]} > 0 )) || die "No channels found for vibe ${vibe_idx} in $CHANNELS_FILE"
  pick="$(rand_int_between 1 "${#channel_numbers[@]}")"
  switch_and_remember_selection "$vibe_idx" "${channel_numbers[$((pick-1))]}"
}

switch_channel_relative() {
  local delta="$1"
  local selection=""
  local vibe_idx=""
  local channel_idx=""

  selection="$(current_selection || true)"
  [[ -n "$selection" ]] || return 1
  vibe_idx="${selection%% *}"

  if (( delta > 0 )); then
    channel_idx="$(get_next_channel_index "$vibe_idx")"
  else
    channel_idx="$(get_prev_channel_index "$vibe_idx")"
  fi

  switch_and_remember_selection "$vibe_idx" "$channel_idx"
}

switch_vibe_relative() {
  local delta="$1"
  local vibe_idx=""
  local selection=""
  local channel_idx=""

  if (( delta > 0 )); then
    vibe_idx="$(get_next_vibe_index)"
  else
    vibe_idx="$(get_prev_vibe_index)"
  fi

  selection="$(current_selection "$vibe_idx" || true)"
  [[ -n "$selection" ]] || return 1
  channel_idx="${selection##* }"
  switch_and_remember_selection "$vibe_idx" "$channel_idx"
}

switch_from_selector_or_url() {
  local selector="$1"
  local selection=""
  local vibe_idx=""
  local target=""
  local idx=""

  selection="$(current_selection || true)"
  [[ -n "$selection" ]] || return 1
  vibe_idx="${selection%% *}"

  if [[ "$selector" =~ ^[0-9]+$ ]]; then
    idx="$selector"
    switch_and_remember_selection "$vibe_idx" "$idx"
    return 0
  fi

  if idx="$(resolve_channel_selector_to_index "$vibe_idx" "$selector" 2>/dev/null)"; then
    switch_and_remember_selection "$vibe_idx" "$idx"
    return 0
  fi

  target="$selector"
  switch_with_recovery "$target" 0 0 || true
}

run_controller() {
  local initial_done=0
  local event cmd arg idx selection vibe_idx channel_idx
  local input_mode="keyboard"
  local eof_state=""
  local last_eof_state=""
  local poll_sleep="$AUTO_ADVANCE_POLL_SECONDS"
  local key_timeout="0.1"
  local input_fd=""
  local input_pid=""

  ensure_shell

  if resolve_target "$VIBE" "$CHANNEL" "$URL"; then
    [[ -n "$RESOLVED_TARGET" ]] && switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_VIBE_INDEX:-0}" "${RESOLVED_CHANNEL_INDEX:-0}" || true
    initial_done=1
  fi

  if [[ "$initial_done" -eq 0 ]]; then
    resolve_target "${DEFAULT_START_VIBE:-}" "${DEFAULT_START_CHANNEL:-}" "" || true
    if [[ -n "$RESOLVED_TARGET" ]]; then
      switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_VIBE_INDEX:-0}" "${RESOLVED_CHANNEL_INDEX:-0}" || true
    else
      selection="$(current_selection || true)"
      [[ -n "$selection" ]] || die "No initial vibe/channel selection available"
      vibe_idx="${selection%% *}"
      channel_idx="${selection##* }"
      switch_and_remember_selection "$vibe_idx" "$channel_idx"
    fi
  fi

  if ! awk "BEGIN { exit !(${poll_sleep} > 0) }"; then
    poll_sleep="0.5"
  fi
  key_timeout="$poll_sleep"

  if [[ -n "$INPUT_EVENT_CMD" ]]; then
    # External input command can feed events from hardware. If it exits,
    # fall back to keyboard control instead of ending run mode.
    coproc INPUT_PROC { bash -lc "$INPUT_EVENT_CMD"; }
    input_fd="${INPUT_PROC[0]:-}"
    input_pid="${INPUT_PROC_PID:-}"
    if [[ -n "$input_fd" ]]; then
      input_mode="external"
      log_msg info "input mode=external cmd='${INPUT_EVENT_CMD}'"
    fi
  fi

  echo "Controls: ${KEY_NEXT}=next-channel ${KEY_PREV}=prev-channel ${KEY_RANDOM}=random 1-9=channel ${KEY_QUIT}=quit"
  while true; do
    event=""

    if is_true "$AUTO_RECOVER_SHELL"; then
      if ! socket_live; then
        log_msg error "mpv socket unavailable; restarting shell and recovering selection"
        ensure_shell
        selection="$(current_selection || true)"
        if [[ -n "$selection" ]]; then
          vibe_idx="${selection%% *}"
          channel_idx="${selection##* }"
          switch_and_remember_selection "$vibe_idx" "$channel_idx"
        fi
      fi
    fi

    if [[ "$input_mode" == "external" ]] && [[ -n "$input_fd" ]]; then
      if IFS= read -r -t "$poll_sleep" -u "$input_fd" event; then
        :
      else
        if [[ -n "$input_pid" ]] && ! kill -0 "$input_pid" 2>/dev/null; then
          log_msg warn "input event command exited; falling back to keyboard mode"
          input_mode="keyboard"
        fi
      fi
    else
      event="$(read_keyboard_event "$key_timeout" || true)"
    fi

    eof_state="$(mpv_get_property "eof-reached" || true)"
    if is_true "$AUTO_ADVANCE_ON_END" && [[ "$eof_state" == "true" ]] && [[ "$last_eof_state" != "true" ]]; then
      log_msg info "program ended; auto-advancing within current channel"
      switch_program_relative 1
    fi
    last_eof_state="$eof_state"

    [[ -n "$event" ]] || continue
    cmd="${event%%:*}"
    arg="${event#*:}"

    if [[ "$event" == "$KEY_QUIT" ]] || [[ "$cmd" == "quit" ]]; then
      break
    elif [[ "$event" == "$KEY_NEXT" ]] || [[ "$cmd" == "next" ]]; then
      switch_channel_relative 1
    elif [[ "$event" == "$KEY_PREV" ]] || [[ "$cmd" == "prev" ]]; then
      switch_channel_relative -1
    elif [[ "$event" == "$KEY_RANDOM" ]] || [[ "$cmd" == "random" ]]; then
      switch_random_channel
    elif [[ "$cmd" == "vibe-next" ]]; then
      switch_vibe_relative 1
    elif [[ "$cmd" == "vibe-prev" ]]; then
      switch_vibe_relative -1
    elif [[ "$cmd" == "vibe" ]] && [[ -n "$arg" ]]; then
      if idx="$(resolve_vibe_selector_to_index "$arg" 2>/dev/null)"; then
        selection="$(current_selection "$idx" || true)"
        [[ -n "$selection" ]] || continue
        switch_and_remember_selection "$idx" "${selection##* }"
      fi
    elif [[ "$cmd" == "program-next" ]]; then
      switch_program_relative 1
    elif [[ "$cmd" == "program-prev" ]]; then
      switch_program_relative -1
    elif [[ "$event" =~ ^[1-9]$ ]]; then
      selection="$(current_selection || true)"
      [[ -n "$selection" ]] || continue
      switch_and_remember_selection "${selection%% *}" "$event"
    elif [[ "$cmd" == "channel" ]] && [[ -n "$arg" ]]; then
      switch_from_selector_or_url "$arg"
    elif [[ "$cmd" == "url" ]] && [[ -n "$arg" ]]; then
      switch_with_recovery "$arg" 0 0 || true
    fi
  done
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || {
  usage
  exit 1
}
shift || true

REQUEST_TOKEN=""
VIBE=""
CHANNEL=""
URL=""
RANDOM_SWITCH=0
NO_RECOVER=0
PROGRAM_NEXT=0
PROGRAM_PREV=0
VOLUME_DIR=""
VOLUME_STEP="$VOLUME_STEP_PCT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vibe)
      VIBE="${2:-}"
      shift 2
      ;;
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
    --no-recover)
      NO_RECOVER=1
      shift
      ;;
    --program-next)
      PROGRAM_NEXT=1
      shift
      ;;
    --program-prev)
      PROGRAM_PREV=1
      shift
      ;;
    --up)
      VOLUME_DIR="up"
      shift
      ;;
    --down)
      VOLUME_DIR="down"
      shift
      ;;
    --step)
      VOLUME_STEP="${2:-}"
      shift 2
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

if [[ "$PROGRAM_NEXT" -eq 1 && "$PROGRAM_PREV" -eq 1 ]]; then
  die "Use only one of --program-next or --program-prev"
fi

log_msg debug "command=${COMMAND} vibe=${VIBE:-} channel=${CHANNEL:-} url=${URL:-} random=${RANDOM_SWITCH}"

case "$COMMAND" in
  list)
    need_cmd jq
    list_channels
    ;;
  start)
    need_cmd mpv
    need_cmd socat
    need_cmd jq
    need_cmd flock
    REQUEST_TOKEN="$(new_switch_request_token)"
    set_switch_request_token "$REQUEST_TOKEN"
    ensure_shell
    if resolve_target "$VIBE" "$CHANNEL" "$URL"; then
      [[ -n "$RESOLVED_TARGET" ]] && switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_VIBE_INDEX:-0}" "${RESOLVED_CHANNEL_INDEX:-0}" "$REQUEST_TOKEN"
    fi
    ;;
  switch)
    need_cmd mpv
    need_cmd socat
    need_cmd jq
    need_cmd flock
    REQUEST_TOKEN="$(new_switch_request_token)"
    set_switch_request_token "$REQUEST_TOKEN"
    if [[ "$PROGRAM_NEXT" -eq 1 || "$PROGRAM_PREV" -eq 1 ]]; then
      if [[ "$RANDOM_SWITCH" -eq 1 ]]; then
        die "--program-next/--program-prev cannot be combined with --random"
      fi
      if [[ -n "$URL" ]]; then
        die "--program-next/--program-prev cannot be combined with --url"
      fi

      if [[ -n "$VIBE" ]]; then
        RESOLVED_VIBE_INDEX="$(resolve_vibe_selector_to_index "$VIBE" 2>/dev/null || true)"
        [[ -n "$RESOLVED_VIBE_INDEX" ]] || die "Unknown vibe selector: $VIBE"
      fi

      if [[ -n "$CHANNEL" ]]; then
        if [[ -z "$RESOLVED_VIBE_INDEX" ]]; then
          selection="$(current_selection || true)"
          [[ -n "$selection" ]] || die "No current selection available"
          RESOLVED_VIBE_INDEX="${selection%% *}"
        fi
        if idx="$(resolve_channel_selector_to_index "$RESOLVED_VIBE_INDEX" "$CHANNEL" 2>/dev/null)"; then
          RESOLVED_CHANNEL_INDEX="$idx"
        elif is_int "$CHANNEL"; then
          die "Channel index out of range for vibe ${RESOLVED_VIBE_INDEX}: $CHANNEL (use './crt_player.sh list')"
        else
          die "Unknown channel selector in vibe ${RESOLVED_VIBE_INDEX}: $CHANNEL"
        fi
      else
        selection="$(current_selection "${RESOLVED_VIBE_INDEX:-}" || true)"
        [[ -n "$selection" ]] || die "No current selection available"
        RESOLVED_VIBE_INDEX="${selection%% *}"
        RESOLVED_CHANNEL_INDEX="${selection##* }"
      fi

      [[ -n "$RESOLVED_CHANNEL_INDEX" ]] || die "No current channel selected for program switching"
      channel_has_program_catalog "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX" || die "Vibe ${RESOLVED_VIBE_INDEX} channel ${RESOLVED_CHANNEL_INDEX} has no playable program catalog"

      if [[ "$PROGRAM_NEXT" -eq 1 ]]; then
        RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX" 1)"
      else
        RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX" -1)"
      fi
      [[ -n "$RESOLVED_TARGET" ]] || die "Vibe ${RESOLVED_VIBE_INDEX} channel ${RESOLVED_CHANNEL_INDEX} has no playable programs"
    elif [[ "$RANDOM_SWITCH" -eq 1 ]]; then
      mapfile -t RANDOM_VIBE_NUMBERS < <(list_active_vibe_numbers 2>/dev/null)
      (( ${#RANDOM_VIBE_NUMBERS[@]} > 0 )) || die "No vibes found in $CHANNELS_FILE"
      RANDOM_VIBE_PICK="$(rand_int_between 1 "${#RANDOM_VIBE_NUMBERS[@]}")"
      RESOLVED_VIBE_INDEX="${RANDOM_VIBE_NUMBERS[$((RANDOM_VIBE_PICK-1))]}"
      mapfile -t RANDOM_CHANNEL_NUMBERS < <(list_active_channel_numbers_for_vibe "$RESOLVED_VIBE_INDEX" 2>/dev/null)
      (( ${#RANDOM_CHANNEL_NUMBERS[@]} > 0 )) || die "No channels found for vibe ${RESOLVED_VIBE_INDEX} in $CHANNELS_FILE"
      RANDOM_CHANNEL_PICK="$(rand_int_between 1 "${#RANDOM_CHANNEL_NUMBERS[@]}")"
      RESOLVED_CHANNEL_INDEX="${RANDOM_CHANNEL_NUMBERS[$((RANDOM_CHANNEL_PICK-1))]}"
      RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX")"
    elif [[ -z "$VIBE" && -z "$CHANNEL" && -z "$URL" ]]; then
      selection="$(current_selection || true)"
      [[ -n "$selection" ]] || die "No current selection available"
      RESOLVED_VIBE_INDEX="${selection%% *}"
      RESOLVED_CHANNEL_INDEX="$(get_next_channel_index "$RESOLVED_VIBE_INDEX")"
      RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX")"
    else
      resolve_target "$VIBE" "$CHANNEL" "$URL" || true
      if [[ -z "$RESOLVED_TARGET" ]]; then
        if [[ -n "$CHANNEL" ]] && is_int "$CHANNEL"; then
          die "Channel index out of range (use './crt_player.sh list')"
        fi
        die "switch requires --vibe, --channel, or --url"
      fi
    fi
    if [[ "$NO_RECOVER" -eq 1 ]]; then
      if switch_channel_attempt "$RESOLVED_TARGET" "$REQUEST_TOKEN"; then
        if [[ -n "${RESOLVED_VIBE_INDEX:-}" && -n "${RESOLVED_CHANNEL_INDEX:-}" ]]; then
          remember_vibe_index "$RESOLVED_VIBE_INDEX"
          remember_channel_index "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX"
          show_channel_overlay "$RESOLVED_VIBE_INDEX" "$RESOLVED_CHANNEL_INDEX"
        fi
      else
        exit "$?"
      fi
    else
      switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_VIBE_INDEX:-0}" "${RESOLVED_CHANNEL_INDEX:-0}" "$REQUEST_TOKEN"
    fi
    ;;
  run)
    need_cmd mpv
    need_cmd socat
    need_cmd jq
    need_cmd flock
    run_controller
    ;;
  volume)
    need_cmd "$AMIXER_BIN"
    is_int "$VOLUME_STEP" || die "--step must be an integer percent"
    if [[ "$VOLUME_DIR" == "up" ]]; then
      "$AMIXER_BIN" set "$AMIXER_CONTROL" "${VOLUME_STEP}%+"
      log_msg info "volume up step=${VOLUME_STEP}%"
    elif [[ "$VOLUME_DIR" == "down" ]]; then
      "$AMIXER_BIN" set "$AMIXER_CONTROL" "${VOLUME_STEP}%-"
      log_msg info "volume down step=${VOLUME_STEP}%"
    else
      die "volume requires --up or --down"
    fi
    ;;
  help)
    usage
    ;;
  *)
    die "Unknown command: $COMMAND"
    ;;
esac
