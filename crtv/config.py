from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from .models import Channel, EncoderPins, Vibe


def _truthy(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        os.environ.setdefault(key, value)


@dataclass(frozen=True)
class AppConfig:
    repo_root: Path
    channels_file: Path
    log_file: Path
    mpv_log_file: Path
    mpv_socket: Path
    static_file: Path
    display: str
    xauthority: str
    mpv_profile: str
    mpv_vo: str
    mpv_gpu_context: str
    mpv_hwdec: str
    keep_aspect: str
    downsample_height: int
    crop_filter: str
    crop_x_pct: int
    enable_crop_filter: bool
    volume_step_pct: int
    brightness_step_pct: int
    initial_brightness_pct: int
    target_ready_timeout_seconds: float
    auto_random_start: bool
    random_start_min_pct: int
    random_start_max_pct: int
    top_encoder: EncoderPins
    bottom_encoder: EncoderPins
    standby_button_pin: int
    standby_button_enabled: bool
    standby_button_hold_seconds: float
    button_bounce: float
    pin_bounce: float
    detent_transitions: int
    detent_cooldown_seconds: float
    ads1115_enabled: bool
    ads1115_bus: int
    ads1115_address: int
    ads1115_channel: int
    ads1115_inverted: bool
    ads1115_raw_min: int | None
    ads1115_raw_max: int | None
    ads1115_zero_raw_threshold: int
    ads1115_min_span: int
    ads1115_log_floor_db: float
    ads1115_zero_threshold_pct: int
    ads1115_poll_seconds: float
    ads1115_deadband_pct: int
    alsa_init_enabled: bool
    alsa_master_volume_pct: int
    audio_highpass_enabled: bool
    audio_highpass_cutoff_hz: int
    display_off_command: tuple[str, ...]
    display_on_command: tuple[str, ...]
    display_backlight_path: Path | None
    shutdown_command: tuple[str, ...]
    control_socket: Path
    pisugar_host: str
    pisugar_port: int
    pisugar_enabled: bool
    pisugar_tcp_command: tuple[str, ...]
    pisugar_socket_command: tuple[str, ...]
    pisugar_soft_poweroff_enabled: bool
    pisugar_soft_poweroff_shell: str
    pisugar_button_single_enabled: bool
    pisugar_button_double_enabled: bool
    pisugar_button_long_enabled: bool
    pisugar_button_long_shell: str
    pisugar_anti_mistouch_enabled: bool
    safe_shutdown_level: int
    safe_shutdown_delay_seconds: int
    initial_volume: int

    @property
    def default_power_command(self) -> tuple[str, ...]:
        return self.display_off_command


def split_command(value: str | None) -> tuple[str, ...]:
    if not value:
        return ()
    return tuple(part for part in value.split(" ") if part)


def load_config(repo_root: Path) -> AppConfig:
    _load_env_file(repo_root / ".env")
    _load_env_file(repo_root / "plex-api" / ".env")

    return AppConfig(
        repo_root=repo_root,
        channels_file=Path(os.environ.get("CHANNELS_FILE", repo_root / "channels.json")),
        log_file=Path(os.environ.get("LOG_FILE", repo_root / "logs" / "crtv_service.log")),
        mpv_log_file=Path(os.environ.get("MPV_LOG_FILE", repo_root / "logs" / "mpv.log")),
        mpv_socket=Path(os.environ.get("TV_SOCK", "/tmp/crt_player.sock")),
        static_file=Path(os.environ.get("STATIC_FILE", repo_root / "assets" / "static.mp4")),
        display=os.environ.get("DISPLAY", ":0"),
        xauthority=os.environ.get("XAUTHORITY", str(Path.home() / ".Xauthority")),
        mpv_profile=os.environ.get("PROFILE", "crt-lottes"),
        mpv_vo=os.environ.get("MPV_VO", "gpu"),
        mpv_gpu_context=os.environ.get("MPV_GPU_CONTEXT", "x11egl"),
        mpv_hwdec=os.environ.get("MPV_HWDEC", "auto"),
        keep_aspect=os.environ.get("KEEP_ASPECT", "no"),
        downsample_height=int(os.environ.get("DOWNSAMPLE_HEIGHT", "240")),
        crop_filter=os.environ.get("CROP_FILTER", ""),
        crop_x_pct=int(os.environ.get("CROP_X_PCT", "55")),
        enable_crop_filter=_truthy(os.environ.get("ENABLE_CROP_FILTER"), default=False),
        volume_step_pct=int(os.environ.get("VOLUME_STEP_PCT", "10")),
        brightness_step_pct=int(os.environ.get("BRIGHTNESS_STEP_PCT", "20")),
        initial_brightness_pct=int(os.environ.get("INITIAL_BRIGHTNESS_PCT", "35")),
        target_ready_timeout_seconds=float(
            os.environ.get("TARGET_READY_TIMEOUT_SECONDS", "8")
        ),
        auto_random_start=_truthy(os.environ.get("ENABLE_RANDOM_START"), default=True),
        random_start_min_pct=int(os.environ.get("RANDOM_START_MIN_PCT", "20")),
        random_start_max_pct=int(os.environ.get("RANDOM_START_MAX_PCT", "80")),
        top_encoder=EncoderPins(a=17, b=27, sw=22),
        bottom_encoder=EncoderPins(a=23, b=24, sw=25),
        standby_button_pin=int(os.environ.get("STANDBY_BUTTON_PIN", "16")),
        standby_button_enabled=_truthy(
            os.environ.get("STANDBY_BUTTON_ENABLED"), default=True
        ),
        standby_button_hold_seconds=float(
            os.environ.get("STANDBY_BUTTON_HOLD_SECONDS", "1.5")
        ),
        button_bounce=float(os.environ.get("BUTTON_BOUNCE", "0.05")),
        pin_bounce=float(os.environ.get("PIN_BOUNCE", "0.001")),
        detent_transitions=int(os.environ.get("DETENT_TRANSITIONS", "4")),
        detent_cooldown_seconds=float(os.environ.get("DETENT_COOLDOWN_SECONDS", "0.12")),
        ads1115_enabled=_truthy(os.environ.get("ADS1115_ENABLED"), default=True),
        ads1115_bus=int(os.environ.get("ADS1115_BUS", "1")),
        ads1115_address=int(os.environ.get("ADS1115_ADDRESS", "0x48"), 0),
        ads1115_channel=int(os.environ.get("ADS1115_CHANNEL", "3")),
        ads1115_inverted=_truthy(os.environ.get("ADS1115_INVERTED"), default=True),
        ads1115_raw_min=(
            int(os.environ["ADS1115_RAW_MIN"])
            if os.environ.get("ADS1115_RAW_MIN")
            else None
        ),
        ads1115_raw_max=(
            int(os.environ["ADS1115_RAW_MAX"])
            if os.environ.get("ADS1115_RAW_MAX")
            else None
        ),
        ads1115_zero_raw_threshold=int(
            os.environ.get("ADS1115_ZERO_RAW_THRESHOLD", "90")
        ),
        ads1115_min_span=int(os.environ.get("ADS1115_MIN_SPAN", "32")),
        ads1115_log_floor_db=float(os.environ.get("ADS1115_LOG_FLOOR_DB", "-40")),
        ads1115_zero_threshold_pct=int(os.environ.get("ADS1115_ZERO_THRESHOLD_PCT", "3")),
        ads1115_poll_seconds=float(os.environ.get("ADS1115_POLL_SECONDS", "0.20")),
        ads1115_deadband_pct=int(os.environ.get("ADS1115_DEADBAND_PCT", "2")),
        alsa_init_enabled=_truthy(os.environ.get("ALSA_INIT_ENABLED"), default=True),
        alsa_master_volume_pct=int(os.environ.get("ALSA_MASTER_VOLUME_PCT", "100")),
        audio_highpass_enabled=_truthy(
            os.environ.get("AUDIO_HIGHPASS_ENABLED"), default=True
        ),
        audio_highpass_cutoff_hz=int(os.environ.get("AUDIO_HIGHPASS_CUTOFF_HZ", "120")),
        display_off_command=split_command(
            os.environ.get("DISPLAY_OFF_CMD", "vcgencmd display_power 0")
        ),
        display_on_command=split_command(
            os.environ.get("DISPLAY_ON_CMD", "vcgencmd display_power 1")
        ),
        display_backlight_path=(
            Path(os.environ["DISPLAY_BACKLIGHT_PATH"])
            if os.environ.get("DISPLAY_BACKLIGHT_PATH")
            else None
        ),
        shutdown_command=split_command(os.environ.get("SHUTDOWN_CMD", "sudo shutdown now")),
        control_socket=Path(os.environ.get("CONTROL_SOCKET", "/tmp/crtv-control.sock")),
        pisugar_host=os.environ.get("PISUGAR_HOST", "127.0.0.1"),
        pisugar_port=int(os.environ.get("PISUGAR_PORT", "8423")),
        pisugar_enabled=_truthy(os.environ.get("PISUGAR_ENABLED"), default=True),
        pisugar_tcp_command=split_command(os.environ.get("PISUGAR_TCP_CMD", "nc -q 0")),
        pisugar_socket_command=split_command(
            os.environ.get("PISUGAR_SOCKET_CMD", "nc -U /tmp/pisugar-server.sock")
        ),
        pisugar_soft_poweroff_enabled=_truthy(
            os.environ.get("PISUGAR_SOFT_POWEROFF_ENABLED"), default=True
        ),
        pisugar_soft_poweroff_shell=os.environ.get(
            "PISUGAR_SOFT_POWEROFF_SHELL", "sudo shutdown now"
        ),
        pisugar_button_single_enabled=_truthy(
            os.environ.get("PISUGAR_BUTTON_SINGLE_ENABLED"), default=False
        ),
        pisugar_button_double_enabled=_truthy(
            os.environ.get("PISUGAR_BUTTON_DOUBLE_ENABLED"), default=False
        ),
        pisugar_button_long_enabled=_truthy(
            os.environ.get("PISUGAR_BUTTON_LONG_ENABLED"), default=True
        ),
        pisugar_button_long_shell=os.environ.get(
            "PISUGAR_BUTTON_LONG_SHELL", "sudo shutdown now"
        ),
        pisugar_anti_mistouch_enabled=_truthy(
            os.environ.get("PISUGAR_ANTI_MISTOUCH_ENABLED"), default=True
        ),
        safe_shutdown_level=int(os.environ.get("PISUGAR_SAFE_SHUTDOWN_LEVEL", "3")),
        safe_shutdown_delay_seconds=int(
            os.environ.get("PISUGAR_SAFE_SHUTDOWN_DELAY", "30")
        ),
        initial_volume=int(os.environ.get("INITIAL_VOLUME", "10")),
    )


def load_vibes(config: AppConfig) -> list[Vibe]:
    payload = json.loads(config.channels_file.read_text(encoding="utf-8"))
    vibes: list[Vibe] = []
    for vibe_index, raw_vibe in enumerate(payload.get("vibes", []), start=1):
        if not isinstance(raw_vibe, dict) or raw_vibe.get("disabled", False):
            continue
        channels: list[Channel] = []
        for channel_index, raw_channel in enumerate(raw_vibe.get("channels", []), start=1):
            if not isinstance(raw_channel, dict) or raw_channel.get("disabled", False):
                continue
            raw_paths = raw_channel.get("paths")
            paths: tuple[str, ...]
            if isinstance(raw_paths, list):
                paths = tuple(str(item) for item in raw_paths)
            elif raw_channel.get("path"):
                paths = (str(raw_channel["path"]),)
            else:
                paths = ()
            channels.append(
                Channel(
                    number=int(raw_channel.get("number", channel_index)),
                    name=str(raw_channel.get("name", f"channel-{channel_index}")),
                    paths=paths,
                )
            )
        if channels:
            vibes.append(
                Vibe(
                    number=int(raw_vibe.get("number", vibe_index)),
                    name=str(raw_vibe.get("name", f"vibe-{vibe_index}")),
                    channels=tuple(channels),
                )
            )
    return vibes
