# CRTV Architecture

## Preserve
- Environment variables already used for display, mpv, logging, media paths, and playback defaults.
- GPIO pin assignments:
  - Left knob: `GPIO17/27/22`
  - Right knob: `GPIO23/24/25`
- Existing `channels.json` content model and all current media paths.
- Battery-management integration only as configuration hooks. There is no concrete PiSugar command path in the current repo, so the new service keeps env-driven hooks instead of inventing fake hardcoded behavior.
- Existing mpv-focused rendering direction for CRT shader usage.

## Replace
- Shell-script orchestration for playback and switching.
- One-shot subprocess control for every knob action.
- Polling split across multiple scripts with state stored in temp files.
- Prototype-era distinction between `start`, `switch`, and `run` as separate control systems.

## Runtime Shape
- One long-lived Python service owns the device.
- One persistent `mpv` process is kept alive over IPC.
- Channel playback becomes a playlist operation, not a process restart.
- GPIO handlers dispatch into a central controller/state machine.
- Power mode is a first-class state that pauses playback, mutes audio, and turns the display off without fully shutting the Pi down.

## Module Layout
- `crtv/config.py`: env and legacy config ingestion.
- `crtv/models.py`: typed domain objects and runtime state.
- `crtv/library.py`: offline media discovery from configured channel paths.
- `crtv/player.py`: persistent mpv lifecycle and playlist control.
- `crtv/power.py`: display and battery-management hooks.
- `crtv/input.py`: rotary decoding, debounce, false-turn rejection, click routing.
- `crtv/controller.py`: central app state and knob behavior.
- `crtv/app.py`: service bootstrap and process lifetime.
- `crtv_service.py`: deployment entrypoint.

## Migration Phases
1. Stand up the new service in parallel with the prototype.
2. Move Raspberry Pi deployment to `crtv_service.py`.
3. Leave `crt_player.sh` and legacy Plex/YouTube helpers available only for fallback/reference.
4. Add a small local command socket if remote admin or diagnostics become necessary.
5. Add deeper battery integration once the exact PiSugar command contract is confirmed on-device.
