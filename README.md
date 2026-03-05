# crtv
Raspberry Pi video streaming "dumb" crt tv player for background vibes. 

## Entrypoint
Use `./crt_player.sh` as the master entrypoint.

### Commands
- `./crt_player.sh list`
- `./crt_player.sh start [--channel 1|name|url] [--url <url>]`
- `./crt_player.sh switch [--channel 1|name|url] [--url <url>] [--random]`
- `./crt_player.sh run [--channel 1|name|url] [--url <url>]`

`run` starts/ensures the mpv shell, tunes the initial channel, then listens for control input.

## Keyboard Controls (`run`)
- `n`: next channel
- `p`: previous channel
- `r`: random channel
- `1`-`9`: direct channel index
- `q`: quit controller loop

## Hardware Input Stub
`run` supports a pluggable line-based event source through `INPUT_EVENT_CMD`.

Example:
```bash
INPUT_EVENT_CMD='./scripts/input-events-stub.sh' ./crt_player.sh run
```

Event lines the command should emit to stdout:
- `next`
- `prev`
- `random`
- `channel:<index|name|url>`
- `url:<url_or_path>`
- `quit`

## Env-First Defaults
Important env vars:
- `TV_SOCK`, `STATIC_FILE`, `MIN_STATIC_SECONDS`
- `CHANNELS_FILE`, `CHANNEL_INDEX_FILE`
- `DEFAULT_START_CHANNEL`
- `KEY_NEXT`, `KEY_PREV`, `KEY_RANDOM`, `KEY_QUIT`
- `INPUT_EVENT_CMD`
- `PROFILE`, `MPV_VO`, `MPV_GPU_CONTEXT`, `MPV_HWDEC`, `VF_CHAIN`
