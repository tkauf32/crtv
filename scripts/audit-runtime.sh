#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

CHANNELS_FILE="${CHANNELS_FILE:-${ROOT}/channels.json}"
STATIC_FILE="${STATIC_FILE:-${ROOT}/assets/static.mp4}"
CONTROL_SOCKET="${CONTROL_SOCKET:-/tmp/crtv-control.sock}"
TV_SOCK="${TV_SOCK:-/tmp/crt_player.sock}"
DISPLAY_VALUE="${DISPLAY:-}"
XAUTHORITY_VALUE="${XAUTHORITY:-${HOME}/.Xauthority}"

pass() {
  printf 'PASS %s\n' "$*"
}

warn() {
  printf 'WARN %s\n' "$*"
}

fail() {
  printf 'FAIL %s\n' "$*"
}

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "command ${cmd}: $(command -v "$cmd")"
  else
    fail "missing command ${cmd}"
  fi
}

check_optional_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "optional command ${cmd}: $(command -v "$cmd")"
  else
    warn "optional command missing: ${cmd}"
  fi
}

check_path() {
  local path="$1"
  local label="$2"
  if [[ -e "$path" ]]; then
    pass "${label}: ${path}"
  else
    fail "${label} missing: ${path}"
  fi
}

printf '== CRTV runtime audit ==\n'
printf 'repo=%s\n' "${ROOT}"
printf 'channels=%s\n' "${CHANNELS_FILE}"
printf 'static=%s\n' "${STATIC_FILE}"
printf 'display=%s\n' "${DISPLAY_VALUE:-<unset>}"
printf 'xauthority=%s\n' "${XAUTHORITY_VALUE}"
printf 'tv_sock=%s\n' "${TV_SOCK}"
printf 'control_socket=%s\n' "${CONTROL_SOCKET}"
printf '\n'

printf '== Required commands ==\n'
check_cmd python3
check_cmd mpv
check_cmd amixer
check_cmd nc
printf '\n'

printf '== Optional diagnostics ==\n'
check_optional_cmd vcgencmd
check_optional_cmd systemctl
check_optional_cmd i2cdetect
check_optional_cmd raspi-config
printf '\n'

printf '== Python modules ==\n'
python3 - <<'PY'
mods = [
    ("gpiozero", True),
    ("smbus2", False),
    ("smbus", False),
]
for name, required in mods:
    try:
        __import__(name)
        print(f"PASS python module {name}")
    except Exception:
        level = "FAIL" if required else "WARN"
        print(f"{level} python module {name} unavailable")
PY
printf '\n'

printf '== Repo files ==\n'
check_path "${CHANNELS_FILE}" "channels file"
check_path "${STATIC_FILE}" "static file"
check_path "${ROOT}/crtv_service.py" "service entrypoint"
check_path "${ROOT}/deploy/crtv.service" "systemd unit template"
printf '\n'

printf '== Media paths from channels.json ==\n'
python3 - "${CHANNELS_FILE}" <<'PY'
import json
import sys
from pathlib import Path

channels_file = Path(sys.argv[1])
payload = json.loads(channels_file.read_text(encoding="utf-8"))
seen = set()
for vibe in payload.get("vibes", []):
    for channel in vibe.get("channels", []):
        for raw_path in channel.get("paths", []):
            if raw_path in seen:
                continue
            seen.add(raw_path)
            if raw_path.startswith(("http://", "https://", "file://")):
                print(f"PASS remote media path {raw_path}")
                continue
            path = Path(raw_path)
            if path.exists():
                print(f"PASS media path {raw_path}")
            else:
                print(f"FAIL media path missing {raw_path}")
PY
printf '\n'

printf '== Display environment ==\n'
if [[ -n "${DISPLAY_VALUE}" ]]; then
  pass "DISPLAY set to ${DISPLAY_VALUE}"
else
  warn "DISPLAY unset; X11 mpv defaults may not work"
fi

if [[ -f "${XAUTHORITY_VALUE}" ]]; then
  pass "XAUTHORITY file present"
else
  warn "XAUTHORITY file missing: ${XAUTHORITY_VALUE}"
fi

if [[ -d /sys/class/backlight ]]; then
  pass "/sys/class/backlight present"
else
  warn "/sys/class/backlight missing; brightness control may be unsupported"
fi
printf '\n'

printf '== I2C / GPIO hints ==\n'
if [[ -e /dev/i2c-1 ]]; then
  pass "/dev/i2c-1 present"
else
  warn "/dev/i2c-1 missing; ADS1115 support will not work until I2C is enabled"
fi

if groups | grep -Eq '(^|[[:space:]])gpio($|[[:space:]])'; then
  pass "current user is in gpio group"
else
  warn "current user is not in gpio group"
fi
printf '\n'

printf 'Audit complete.\n'
