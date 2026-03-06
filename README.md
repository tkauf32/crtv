# crtv
Raspberry Pi video streaming "dumb" crt tv player for background vibes. 

## Entrypoint
Use `./crt_player.sh` as the master entrypoint.

### Commands
- `./crt_player.sh list`
- `./crt_player.sh start [--channel 1|name|url] [--url <url>]`
- `./crt_player.sh switch [--channel 1|name|url] [--url <url>] [--random]`
- `./crt_player.sh run [--channel 1|name|url] [--url <url>]`
- `./crt_player.sh volume --up|--down [--step N]`

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
- `STATIC_REMOTE_SECONDS`, `STATIC_LOCAL_SECONDS`, `STATIC_VF_CHAIN`
- `CHANNELS_FILE`, `CHANNEL_INDEX_FILE`
- `LOG_LEVEL` (`debug`, `info`, `warn`, `error`, `off`)
- `LOG_FILE` (default `./logs/crt_player.log`)
- `LOG_FILE_LEVEL` (default `debug`)
- `LOG_TO_STDERR` (`1`/`0`)
- `AUTO_ADVANCE_ON_END` (`1`/`0`)
- `AUTO_ADVANCE_POLL_SECONDS` (default `0.5`)
- `RECOVER_TO_NEXT_ON_FAILURE` (`1`/`0`)
- `MAX_RECOVERY_CHANNEL_TRIES` (default `5`)
- `AUTO_RECOVER_SHELL` (`1`/`0`)
- `DEFAULT_START_CHANNEL`
- `KEY_NEXT`, `KEY_PREV`, `KEY_RANDOM`, `KEY_QUIT`
- `INPUT_EVENT_CMD`
- `AMIXER_BIN`, `AMIXER_CONTROL`, `VOLUME_STEP_PCT`
- `PROFILE`, `MPV_VO`, `MPV_GPU_CONTEXT`, `MPV_HWDEC`, `VF_CHAIN`

Example `.env` tuning:
```bash
# Keep local channels snappy but mask remote startup lag a bit more.
STATIC_LOCAL_SECONDS=0.8
STATIC_REMOTE_SECONDS=2.2

# Keep static framed like regular playback.
STATIC_VF_CHAIN='crop=ih*4/3:ih'

# One concise line at switch start/end.
LOG_LEVEL=info

# File logging (comprehensive history for debugging).
LOG_FILE=/home/tommy/crtv/logs/crt_player.log
LOG_FILE_LEVEL=debug
LOG_TO_STDERR=1

# Auto-switch to next channel when current program ends.
AUTO_ADVANCE_ON_END=1
AUTO_ADVANCE_POLL_SECONDS=0.5

# If a channel fails to load, try next channels automatically.
RECOVER_TO_NEXT_ON_FAILURE=1
MAX_RECOVERY_CHANNEL_TRIES=5
AUTO_RECOVER_SHELL=1
```

If `run` returns to shell right after starting, clear external input mode:
```bash
unset INPUT_EVENT_CMD
./crt_player.sh run
```

Volume controls over SSH:
```bash
./crt_player.sh volume --up --step 10
./crt_player.sh volume --down --step 5
```
