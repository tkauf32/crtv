# crtv
Raspberry Pi CRT video player built around two rotary encoders.

## Model
The control model is now:

- Top encoder: `vibes`
- Second encoder: `programs` across the selected vibe
- Organization only: `channels` inside each vibe group related media directories

Programs are individual files discovered by flattening all channel `path` and `paths` entries inside the selected vibe. When a program ends, the player can auto-advance within the current vibe.

## Entrypoint
Use `./crt_player.sh` as the master entrypoint.

### Commands
- `./crt_player.sh list`
- `./crt_player.sh start [--vibe <index|name>] [--channel <index|name>] [--url <url>]`
- `./crt_player.sh switch [--vibe <index|name>] [--channel <index|name>] [--url <url>] [--random]`
- `./crt_player.sh run [--vibe <index|name>] [--channel <index|name>] [--url <url>]`
- `./crt_player.sh volume --up|--down [--step N]`

## Channel Config
`channels.json` now uses a `vibes -> channels -> paths` structure.

Example:
```json
{
  "vibes": [
    {
      "number": 1,
      "name": "focus",
      "channels": [
        {
          "number": 1,
          "name": "study-lofi",
          "paths": [
            "/home/tommy/crtv/local-media/focus/study-lofi"
          ]
        }
      ]
    },
    {
      "number": 4,
      "name": "television",
      "channels": [
        {
          "number": 1,
          "name": "sitcoms",
          "paths": [
            "/mnt/usb/television/sitcoms"
          ]
        }
      ]
    }
  ]
}
```

`paths` entries can be:
- A directory containing media files
- A single file path
- A remote URL

Program ordering is deterministic by default. Set `PROGRAM_ORDER_RANDOM=1` in `.env` if you want directory-backed channels shuffled whenever they are resolved.

## Input Events
`run` supports an optional line-based `INPUT_EVENT_CMD`.

Supported events:
- `next`
- `prev`
- `random`
- `vibe-next`
- `vibe-prev`
- `vibe:<index|name>`
- `channel:<index|name>`
- `program-next`
- `program-prev`
- `url:<url_or_path>`
- `quit`

## Env
Important env vars:
- `CHANNELS_FILE`
- `VIBE_INDEX_FILE`
- `CHANNEL_INDEX_DIR`
- `PROGRAM_INDEX_DIR`
- `PROGRAM_ORDER_RANDOM`
- `DOWNSAMPLE_HEIGHT`
- `ENABLE_CROP_FILTER`
- `CROP_X_PCT`
- `CROP_FILTER`
- `ENABLE_RANDOM_START`
- `DEFAULT_START_VIBE`
- `DEFAULT_START_CHANNEL`
- `AUTO_ADVANCE_ON_END`
- `AUTO_ADVANCE_POLL_SECONDS`
- `STATIC_FILE`
- `LOG_FILE`
- `MPV_LOG_FILE`

## Hardware
- Encoder 1 on `GPIO17/27/22` changes vibes.
- Encoder 2 on `GPIO23/24/25` changes programs inside the current vibe.

## Defaults
- Crop-to-fill is on by default so the screen fills vertically.
- The crop is slightly right-biased by default with `CROP_X_PCT=55`.
- Playback downsampling stays on by default with `DOWNSAMPLE_HEIGHT=240`.
- Random clip starts are on by default.

## Current Sample Vibes
The sample config currently starts with:
- `focus`
- `relax`
- `meditate`
- `television`
- `seasonal`
- `ambience`
- `nature`
- `music`
- `fantasy`
- `mixed`
