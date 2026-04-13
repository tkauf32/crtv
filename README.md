# crtv

Raspberry Pi offline-first mini TV player for a CRT-style display and two rotary knobs.

## Direction

The old shell-heavy flow is now considered legacy prototype code. The new target runtime is a long-lived Python service that owns:

- hardware input
- playback state
- content discovery
- channel navigation
- display/power mode

The first refactor pass lives in the `crtv/` package and uses one persistent `mpv` process over IPC instead of spawning fresh playback processes on each action.

## What Is Preserved

- Existing environment-variable configuration
- Existing `channels.json` structure and media paths
- Existing GPIO pin assignments:
  - top knob: `GPIO17/27/22`
  - bottom knob: `GPIO23/24/25`
- Existing mpv/CRT rendering direction
- Battery-management integration only through env-configured commands until exact PiSugar commands are confirmed on-device

## What Is Replaced

- Shell-script orchestration as the primary control path
- One-shot `switch` subprocesses for normal device operation
- Temp-file-based playback state coordination
- Separate control systems for `start`, `switch`, and `run`

## New Runtime

- `crtv_service.py`
- `python3 -m crtv.app`

`encoder_control.py` is now a compatibility wrapper around the new service entrypoint.

## Module Layout

- `crtv/config.py`: legacy env/config ingestion
- `crtv/models.py`: domain and runtime state
- `crtv/library.py`: offline media discovery from channel paths
- `crtv/player.py`: persistent mpv IPC playback and playlist control
- `crtv/power.py`: display power and battery hooks
- `crtv/input.py`: rotary decoding, debounce, false-turn rejection, click routing
- `crtv/controller.py`: central state machine for channel, volume, menu, and standby mode
- `crtv/app.py`: service bootstrap

## Controls

Current default service behavior:

- Top knob turn: change vibe
- Bottom knob turn in `browse`: change channel
- Top knob click: cycle `browse -> volume -> menu -> browse`
- Bottom knob turn in `volume`: adjust volume
- Bottom knob click in `browse`: skip to next clip in current channel
- Bottom knob click in `volume`: mute/unmute
- Bottom knob click in `menu`: activate menu action
- Menu includes `power-off-mode`, which pauses playback, mutes audio, and turns off the display without shutting the Pi down
- Menu also includes `shutdown-now`, which is the explicit full-shutdown path
- SSH/debug standby control is available through the running service:
  - `python3 -m crtv.app standby on`
  - `python3 -m crtv.app standby off`
  - `python3 -m crtv.app standby toggle`
  - `python3 -m crtv.app standby status`

Startup volume now defaults to `10%` unless overridden with `INITIAL_VOLUME`.

## Channel Config

`channels.json` still uses `vibes -> channels -> paths`.

`paths` entries can be:

- a directory containing media files
- a single file path
- a remote URL

The new library layer is offline-first. Remote/streaming sources remain supported structurally, but the redesign optimizes for local media on mounted storage.

## Migration

See [`docs/architecture.md`](/Users/tomkaufmann/crtv/docs/architecture.md) for preserve-vs-replace decisions, target architecture, and phased migration.

Legacy scripts remain in the repo only as reference and fallback during migration.

## PiSugar

The new power layer now expects the PiSugar command model documented in [`pisugar_commands_reference.md`](/Users/tomkaufmann/crtv/pisugar_commands_reference.md):

- status queries via `nc` to `127.0.0.1:8423`
- safe-shutdown configuration
- soft-poweroff shell configuration
- external power and battery status reads

Relevant env knobs:

- `PISUGAR_ENABLED`
- `PISUGAR_HOST`
- `PISUGAR_PORT`
- `PISUGAR_TCP_CMD`
- `PISUGAR_SOCKET_CMD`
- `PISUGAR_SOFT_POWEROFF_ENABLED`
- `PISUGAR_SOFT_POWEROFF_SHELL`
- `PISUGAR_SAFE_SHUTDOWN_LEVEL`
- `PISUGAR_SAFE_SHUTDOWN_DELAY`
- `SHUTDOWN_CMD`
- `DISPLAY_OFF_CMD`
- `DISPLAY_ON_CMD`
- `DISPLAY_BACKLIGHT_PATH`
- `CONTROL_SOCKET`
