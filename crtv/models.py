from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path


class UiMode(str, Enum):
    BROWSE = "browse"
    VOLUME = "volume"
    MENU = "menu"
    STANDBY = "standby"


@dataclass(frozen=True)
class EncoderPins:
    a: int
    b: int
    sw: int


@dataclass(frozen=True)
class MediaItem:
    path: str

    @property
    def exists(self) -> bool:
        if self.path.startswith(("http://", "https://", "file://")):
            return True
        return Path(self.path).exists()


@dataclass(frozen=True)
class Channel:
    number: int
    name: str
    paths: tuple[str, ...] = ()


@dataclass(frozen=True)
class Vibe:
    number: int
    name: str
    channels: tuple[Channel, ...] = ()


@dataclass
class RuntimeState:
    current_vibe_index: int = 0
    current_channel_index: int = 0
    clip_index: int = 0
    clip_count: int = 0
    volume: int = 65
    muted: bool = False
    standby: bool = False
    vibe_output_enabled: bool = True
    brightness_pct: int | None = None
    mode: UiMode = UiMode.BROWSE
    menu_index: int = 0
    menu_editing: bool = False
    timer_index: int = 0
    power_save: bool = False
    status_line: str = ""
    available_menu_items: list[str] = field(
        default_factory=lambda: ["brightness", "timer"]
    )
    timer_options: list[str] = field(
        default_factory=lambda: ["15m", "30m", "45m", "1h", "1.5h", "2h", "4h", "8h"]
    )
