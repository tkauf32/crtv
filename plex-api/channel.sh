#!/usr/bin/env bash
set -euo pipefail

# ---- load .env for defaults ----
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

: "${TV_SOCK:=/tmp/tv.sock}"
: "${STATIC_FILE:=$HOME/crt/assets/static.mp4}"
: "${STATIC_MS:=600}"

send() {
  printf '%s\n' "$1" | socat - UNIX-CONNECT:"$TV_SOCK" >/dev/null
}

ensure_shell() {
  export DISPLAY=:0
  export XAUTHORITY="$HOME/.Xauthority"

  # If socket exists but nobody is listening, remove it
  if [[ -S "$TV_SOCK" ]]; then
    if ! socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
      rm -f "$TV_SOCK"
    fi
  fi

  # Start mpv shell if needed
  if [[ ! -S "$TV_SOCK" ]]; then
    nohup mpv \
      --fullscreen \
      --idle=yes \
      --really-quiet \
      --input-ipc-server="$TV_SOCK" \
      --vo="${MPV_VO:-gpu}" \
      --gpu-context="${MPV_GPU_CONTEXT:-x11egl}" \
      --hwdec="${MPV_HWDEC:-auto}" \
      >/dev/null 2>&1 &

    # Wait for socket to become connectable
    for _ in {1..30}; do
      [[ -S "$TV_SOCK" ]] || { sleep 0.1; continue; }
      if socat -T 0.2 - UNIX-CONNECT:"$TV_SOCK" </dev/null >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done

    echo "ERROR: mpv shell didn't come up (socket not responding): $TV_SOCK" >&2
    exit 1
  fi
}

play_static() {
  # loop static while we resolve
  send "{\"command\": [\"loadfile\", \"$STATIC_FILE\", \"replace\"]}"
  send "{\"command\": [\"set_property\", \"loop-file\", \"inf\"]}"
}

play_url() {
  local url="$1"
  send "{\"command\": [\"loadfile\", \"$url\", \"replace\"]}"
}

main() {
  ensure_shell
  play_static
  sleep "$(awk "BEGIN{print ${STATIC_MS}/1000}")"

  # Resolve using your existing tv.sh logic (presets/env/etc)
  url="$(./tv.sh --print-url-only "$@")"
  play_url "$url"
}

main "$@"
