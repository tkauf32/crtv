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
: "${CHANNEL_INDEX_FILE:=/tmp/crt_player_channel_index}"
: "${PROGRAM_INDEX_DIR:=/tmp/crt_player_program_index}"
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
  crt_player.sh start [--channel <index|name|url>] [--url <url_or_path>] [--resolution N] [--fps-cap N]
  crt_player.sh switch [--channel <index|name|url>] [--url <url_or_path>] [--random]
  crt_player.sh run [--channel <index|name|url>] [--url <url_or_path>]
  crt_player.sh volume --up|--down [--step <percent>]

Examples:
  ./crt_player.sh list
  ./crt_player.sh start --channel 1
  ./crt_player.sh switch            # next channel (auto-advance)
  ./crt_player.sh switch --random   # random channel from channels.json
  ./crt_player.sh switch --channel news
  ./crt_player.sh switch --url "https://www.youtube.com/watch?v=XXXXXXXXXXX"
  ./crt_player.sh run               # keyboard: n/p/r/1-9/q
  INPUT_EVENT_CMD='./scripts/input-events-stub.sh' ./crt_player.sh run
  ./crt_player.sh volume --up --step 10

Env:
  STATIC_FILE, MIN_STATIC_SECONDS, CHANNELS_FILE,
  STATIC_REMOTE_SECONDS, STATIC_LOCAL_SECONDS, STATIC_VF_CHAIN,
  AUTO_ADVANCE_ON_END, AUTO_ADVANCE_POLL_SECONDS,
  RECOVER_TO_NEXT_ON_FAILURE, MAX_RECOVERY_CHANNEL_TRIES, AUTO_RECOVER_SHELL,
  ENABLE_RANDOM_START, RANDOM_START_MIN_PCT, RANDOM_START_MAX_PCT, CHANNEL_INDEX_FILE, PROGRAM_INDEX_DIR,
  RESOLUTION, YTDL_MAX_FPS, PROFILE, MPV_VO, MPV_GPU_CONTEXT, MPV_HWDEC, VF_CHAIN,
  DISPLAY, XAUTHORITY, LOG_LEVEL, LOG_FILE, LOG_FILE_LEVEL, LOG_TO_STDERR, MPV_LOG_FILE, MPV_LOG_LEVEL,
  MPV_LOG_EXCERPT_LINES, SWITCH_LOCK_FILE, SWITCH_LOCK_WAIT_SECONDS, SWITCH_REQUEST_FILE,
  CHANNEL_OSD_ENABLED, CHANNEL_OSD_DURATION_MS, CHANNEL_OSD_FONT_SIZE, CHANNEL_OSD_MARGIN_Y,
  DEFAULT_START_CHANNEL, KEY_NEXT, KEY_PREV, KEY_RANDOM, KEY_QUIT, INPUT_EVENT_CMD,
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
  local channel_number="$1"

  is_true "$CHANNEL_OSD_ENABLED" || return 0
  is_int "$channel_number" || return 0

  mpv_send_json "$(jq -nc --argjson n "$CHANNEL_OSD_FONT_SIZE" '{"command":["set_property", "osd-font-size", $n]}')" || true
  mpv_send_json "$(jq -nc --arg v "center" '{"command":["set_property", "osd-align-x", $v]}')" || true
  mpv_send_json "$(jq -nc --arg v "top" '{"command":["set_property", "osd-align-y", $v]}')" || true
  mpv_send_json "$(jq -nc --argjson n "$CHANNEL_OSD_MARGIN_Y" '{"command":["set_property", "osd-margin-y", $n]}')" || true
  mpv_send_json "$(jq -nc --arg msg "CH ${channel_number}" --argjson ms "$CHANNEL_OSD_DURATION_MS" '{"command":["show-text", $msg, $ms] }')" || true
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
  local from_index="${2:-0}"
  local request_token="${3:-}"
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
    [[ "$from_index" -gt 0 ]] && remember_channel_index "$from_index"
    [[ "$from_index" -gt 0 ]] && show_channel_overlay "$from_index"
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

  mapfile -t numbers < <(list_active_channel_numbers 2>/dev/null)
  if (( ${#numbers[@]} == 0 )); then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 1
  fi

  max_tries="$MAX_RECOVERY_CHANNEL_TRIES"
  is_int "$max_tries" || max_tries=5
  (( max_tries > 0 )) || max_tries=1
  (( max_tries <= ${#numbers[@]} )) || max_tries="${#numbers[@]}"

  if (( from_index > 0 )); then
    idx="$from_index"
  else
    idx="$(cat "$CHANNEL_INDEX_FILE" 2>/dev/null || echo 0)"
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
    candidate_target="$(channel_url_by_index "$idx" 2>/dev/null || true)"
    [[ -n "$candidate_target" ]] || continue
    log_msg warn "recovery attempt=$tries channel_index=$idx"
    if switch_channel_attempt "$candidate_target" "$request_token"; then
      remember_channel_index "$idx"
      show_channel_overlay "$idx"
      log_msg warn "recovered playback on channel_index=$idx"
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
  switch_with_recovery "$target" 0
}

channels_filter='if type=="array" then . elif type=="object" and (.channels|type=="array") then .channels else [] end'
active_channels_filter="${channels_filter} | map(select((.disabled // false) | not))"
numbered_active_channels_filter='
  '"${active_channels_filter}"'
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

channel_count() {
  channel_file_check
  jq -er "${active_channels_filter} | length" "$CHANNELS_FILE"
}

list_active_channel_numbers() {
  channel_file_check
  jq -r "${numbered_active_channels_filter} | sort_by(.number) | .[].number" "$CHANNELS_FILE"
}

program_state_file_for_channel() {
  local channel_number="$1"
  mkdir -p "$PROGRAM_INDEX_DIR" >/dev/null 2>&1 || true
  printf '%s/channel_%s.index\n' "$PROGRAM_INDEX_DIR" "$channel_number"
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

channel_url_by_index() {
  local idx="$1"
  local entry_json=""
  local entry_type=""
  local channel_number=""
  local program_count=0
  local program_state_file=""
  local current_program=0
  local next_program=1
  local program_json=""
  local resolved=""
  channel_file_check

  entry_json="$(jq -ce --argjson idx "$idx" "
    ${numbered_active_channels_filter}
    | map(select(.number == \$idx))
    | if length == 0 then empty else .[0].value end
  " "$CHANNELS_FILE" 2>/dev/null || true)"

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

  program_count="$(printf '%s\n' "$entry_json" | jq -er '.programs | length' 2>/dev/null || echo 0)"
  if (( program_count > 0 )); then
    channel_number="$(printf '%s\n' "$entry_json" | jq -er --argjson fallback "$idx" '.number // $fallback' 2>/dev/null || echo "$idx")"
    program_state_file="$(program_state_file_for_channel "$channel_number")"

    if [[ -f "$program_state_file" ]]; then
      current_program="$(cat "$program_state_file" 2>/dev/null || echo 0)"
      is_int "$current_program" || current_program=0
    fi

    next_program=$(( (current_program % program_count) + 1 ))
    printf '%s\n' "$next_program" > "$program_state_file"

    program_json="$(printf '%s\n' "$entry_json" | jq -ce --argjson n "$next_program" '.programs[$n-1]' 2>/dev/null || true)"
    [[ -n "$program_json" ]] || return 1
    resolved="$(resolve_program_entry "$program_json" || true)"
    [[ -n "$resolved" ]] || return 1
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
    idx="$(jq -er --argjson idx "$selector" "
      ${numbered_active_channels_filter}
      | map(select(.number == \$idx))
      | if length == 0 then empty else .[0].number end
    " "$CHANNELS_FILE" 2>/dev/null || true)"
  else
    idx="$(jq -er --arg name "$selector" "
      ${numbered_active_channels_filter}
      | map(select((.value|type == \"object\") and (.value.name? != null) and ((.value.name|ascii_downcase) == (\$name|ascii_downcase))))
      | if length == 0 then empty else .[0].number end
    " "$CHANNELS_FILE" 2>/dev/null || true)"

    if [[ -z "$idx" ]]; then
      idx="$(jq -er --arg maybe "$selector" "
        ${numbered_active_channels_filter}
        | map(select(
            ((.value|type) == \"string\" and .value == \$maybe)
            or ((.value|type) == \"object\" and (.value.url? == \$maybe))
          ))
        | if length == 0 then empty else .[0].number end
      " "$CHANNELS_FILE" 2>/dev/null || true)"
    fi
  fi

  [[ -n "$idx" ]] || return 1
  printf '%s\n' "$idx"
}

get_next_channel_index() {
  local numbers=()
  local current=0
  local next=""

  mapfile -t numbers < <(list_active_channel_numbers 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No channels found in $CHANNELS_FILE"

  if [[ -f "$CHANNEL_INDEX_FILE" ]]; then
    current="$(cat "$CHANNEL_INDEX_FILE" 2>/dev/null || echo 0)"
    is_int "$current" || current=0
  fi

  for next in "${numbers[@]}"; do
    if (( next > current )); then
      printf '%s\n' "$next" > "$CHANNEL_INDEX_FILE"
      printf '%s\n' "$next"
      return 0
    fi
  done

  next="${numbers[0]}"
  printf '%s\n' "$next" > "$CHANNEL_INDEX_FILE"
  printf '%s\n' "$next"
}

get_prev_channel_index() {
  local numbers=()
  local current=1
  local prev=""

  mapfile -t numbers < <(list_active_channel_numbers 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No channels found in $CHANNELS_FILE"

  if [[ -f "$CHANNEL_INDEX_FILE" ]]; then
    current="$(cat "$CHANNEL_INDEX_FILE" 2>/dev/null || echo 1)"
    is_int "$current" || current=1
  fi

  for (( i=${#numbers[@]}-1; i>=0; i-- )); do
    prev="${numbers[$i]}"
    if (( prev < current )); then
      printf '%s\n' "$prev" > "$CHANNEL_INDEX_FILE"
      printf '%s\n' "$prev"
      return 0
    fi
  done

  prev="${numbers[$((${#numbers[@]}-1))]}"
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
    | (.value.number // (.key + 1)) as \$num
    | .value as \$v
    | if (\$v|type) == \"string\" then
        \"\(\$num)\t-\t\(\$v)\"
      elif (\$v|type) == \"object\" then
        if (\$v.disabled // false) then
          \"\(\$num)\t\((\$v.name // \"-\"))\t[disabled]\"
        elif ((\$v.programs // []) | length) > 0 then
          \"\(\$num)\t\((\$v.name // \"-\"))\tprograms=\((\$v.programs | length))\"
        else
          \"\(\$num)\t\((\$v.name // \"-\"))\t\((\$v.url // \$v.cmd // \"\"))\"
        end
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
    if is_int "$channel"; then
      if idx="$(resolve_channel_selector_to_index "$channel" 2>/dev/null)"; then
        RESOLVED_CHANNEL_INDEX="$idx"
        RESOLVED_TARGET="$(channel_url_by_index "$idx")"
        return 0
      fi
      return 1
    fi

    if idx="$(resolve_channel_selector_to_index "$channel" 2>/dev/null)"; then
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
  switch_with_recovery "$target" "$idx" || true
}

read_keyboard_event() {
  local key=""
  if ! IFS= read -rsn1 -t "${1:-0.1}" key; then
    return 1
  fi
  printf '%s\n' "$key"
}

switch_random_channel() {
  local numbers=()
  local pick=0
  mapfile -t numbers < <(list_active_channel_numbers 2>/dev/null)
  (( ${#numbers[@]} > 0 )) || die "No channels found in $CHANNELS_FILE"
  pick="$(rand_int_between 1 "${#numbers[@]}")"
  switch_and_remember_index "${numbers[$((pick-1))]}"
}

switch_from_selector_or_url() {
  local selector="$1"
  local target idx

  if [[ "$selector" =~ ^[0-9]+$ ]]; then
    idx="$selector"
    switch_and_remember_index "$idx"
    return 0
  fi

  if idx="$(resolve_channel_selector_to_index "$selector" 2>/dev/null)"; then
    switch_and_remember_index "$idx"
    return 0
  fi

  target="$selector"
  switch_with_recovery "$target" 0 || true
}

run_controller() {
  local initial_done=0
  local event cmd arg idx
  local input_mode="keyboard"
  local eof_state=""
  local last_eof_state=""
  local poll_sleep="$AUTO_ADVANCE_POLL_SECONDS"
  local key_timeout="0.1"
  local input_fd=""
  local input_pid=""

  ensure_shell

  if resolve_target "$CHANNEL" "$URL"; then
    [[ -n "$RESOLVED_TARGET" ]] && switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_CHANNEL_INDEX:-0}" || true
    initial_done=1
  fi

  if [[ "$initial_done" -eq 0 ]]; then
    if idx="$(resolve_channel_selector_to_index "$DEFAULT_START_CHANNEL" 2>/dev/null)"; then
      switch_and_remember_index "$idx"
    else
      idx="$(get_next_channel_index)"
      switch_and_remember_index "$idx"
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

  echo "Controls: ${KEY_NEXT}=next ${KEY_PREV}=prev ${KEY_RANDOM}=random 1-9=channel ${KEY_QUIT}=quit"
  while true; do
    event=""

    if is_true "$AUTO_RECOVER_SHELL"; then
      if ! socket_live; then
        log_msg error "mpv socket unavailable; restarting shell and recovering channel"
        ensure_shell
        switch_and_remember_index "$(get_next_channel_index)"
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
      log_msg info "program ended; auto-advancing to next channel"
      switch_and_remember_index "$(get_next_channel_index)"
    fi
    last_eof_state="$eof_state"

    [[ -n "$event" ]] || continue
    cmd="${event%%:*}"
    arg="${event#*:}"

    if [[ "$event" == "$KEY_QUIT" ]] || [[ "$cmd" == "quit" ]]; then
      break
    elif [[ "$event" == "$KEY_NEXT" ]] || [[ "$cmd" == "next" ]]; then
      switch_and_remember_index "$(get_next_channel_index)"
    elif [[ "$event" == "$KEY_PREV" ]] || [[ "$cmd" == "prev" ]]; then
      switch_and_remember_index "$(get_prev_channel_index)"
    elif [[ "$event" == "$KEY_RANDOM" ]] || [[ "$cmd" == "random" ]]; then
      switch_random_channel
    elif [[ "$event" =~ ^[1-9]$ ]]; then
      switch_and_remember_index "$event"
    elif [[ "$cmd" == "channel" ]] && [[ -n "$arg" ]]; then
      switch_from_selector_or_url "$arg"
    elif [[ "$cmd" == "url" ]] && [[ -n "$arg" ]]; then
      switch_with_recovery "$arg" 0 || true
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
CHANNEL=""
URL=""
RANDOM_SWITCH=0
NO_RECOVER=0
VOLUME_DIR=""
VOLUME_STEP="$VOLUME_STEP_PCT"

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
    --no-recover)
      NO_RECOVER=1
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

log_msg debug "command=${COMMAND} channel=${CHANNEL:-} url=${URL:-} random=${RANDOM_SWITCH}"

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
    if resolve_target "$CHANNEL" "$URL"; then
      [[ -n "$RESOLVED_TARGET" ]] && switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_CHANNEL_INDEX:-0}" "$REQUEST_TOKEN"
    fi
    ;;
  switch)
    need_cmd mpv
    need_cmd socat
    need_cmd jq
    need_cmd flock
    REQUEST_TOKEN="$(new_switch_request_token)"
    set_switch_request_token "$REQUEST_TOKEN"
    if [[ "$RANDOM_SWITCH" -eq 1 ]]; then
      mapfile -t RANDOM_CHANNEL_NUMBERS < <(list_active_channel_numbers 2>/dev/null)
      (( ${#RANDOM_CHANNEL_NUMBERS[@]} > 0 )) || die "No channels found in $CHANNELS_FILE"
      RANDOM_CHANNEL_PICK="$(rand_int_between 1 "${#RANDOM_CHANNEL_NUMBERS[@]}")"
      RESOLVED_CHANNEL_INDEX="${RANDOM_CHANNEL_NUMBERS[$((RANDOM_CHANNEL_PICK-1))]}"
      RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_CHANNEL_INDEX")"
    elif [[ -z "$CHANNEL" && -z "$URL" ]]; then
      RESOLVED_CHANNEL_INDEX="$(get_next_channel_index)"
      RESOLVED_TARGET="$(channel_url_by_index "$RESOLVED_CHANNEL_INDEX")"
    else
      resolve_target "$CHANNEL" "$URL" || true
      if [[ -z "$RESOLVED_TARGET" ]]; then
        if [[ -n "$CHANNEL" ]] && is_int "$CHANNEL"; then
          die "Channel index out of range: $CHANNEL (use './crt_player.sh list')"
        fi
        die "switch requires --channel or --url"
      fi
    fi
    if [[ "$NO_RECOVER" -eq 1 ]]; then
      if switch_channel_attempt "$RESOLVED_TARGET" "$REQUEST_TOKEN"; then
        if [[ -n "${RESOLVED_CHANNEL_INDEX:-}" ]]; then
          remember_channel_index "$RESOLVED_CHANNEL_INDEX"
          show_channel_overlay "$RESOLVED_CHANNEL_INDEX"
        fi
      else
        exit "$?"
      fi
    else
      switch_with_recovery "$RESOLVED_TARGET" "${RESOLVED_CHANNEL_INDEX:-0}" "$REQUEST_TOKEN"
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
