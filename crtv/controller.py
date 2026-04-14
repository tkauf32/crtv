from __future__ import annotations

import logging
import threading

from .config import AppConfig
from .library import ContentLibrary
from .models import RuntimeState, UiMode
from .player import MpvPlayer
from .power import PowerManager


class TvController:
    def __init__(
        self,
        config: AppConfig,
        library: ContentLibrary,
        player: MpvPlayer,
        power: PowerManager,
    ):
        self.config = config
        self.library = library
        self.player = player
        self.power = power
        self.state = RuntimeState(volume=config.initial_volume)
        self.lock = threading.Lock()

    def start(self) -> None:
        with self.lock:
            self.power.apply_pisugar_policy()
            self.player.ensure_running()
            self.player.set_volume(self.state.volume)
            self._sync_brightness_state()
            self._play_current_channel()

    def enter_standby(self) -> dict[str, str | bool]:
        with self.lock:
            self._enter_standby_locked()
            return self._standby_status_unlocked()

    def exit_standby(self) -> dict[str, str | bool]:
        with self.lock:
            self._exit_standby_locked(prefix="wake")
            return self._standby_status_unlocked()

    def toggle_standby(self) -> dict[str, str | bool]:
        with self.lock:
            if self.state.standby:
                self._exit_standby_locked(prefix="wake")
            else:
                self._enter_standby_locked()
            return self._standby_status_unlocked()

    def standby_status(self) -> dict[str, str | bool]:
        with self.lock:
            return self._standby_status_unlocked()

    def set_brightness_pct(self, brightness_pct: int) -> dict[str, int | bool | None]:
        with self.lock:
            status = self.power.set_brightness_pct(brightness_pct)
            self._sync_brightness_state()
            logging.info("brightness set to %s%%", status["brightness_pct"])
            self._update_status("brightness")
            return self._brightness_status_unlocked()

    def brightness_status(self) -> dict[str, int | bool | None]:
        with self.lock:
            return self._brightness_status_unlocked()

    def set_volume_pct(self, volume: int) -> dict[str, int | bool]:
        with self.lock:
            self._set_volume_locked(volume)
            return self._volume_status_unlocked()

    def volume_status(self) -> dict[str, int | bool]:
        with self.lock:
            return self._volume_status_unlocked()

    def _standby_status_unlocked(self) -> dict[str, str | bool]:
        return {
            "standby": self.state.standby,
            "mode": self.state.mode.value,
            "status_line": self.state.status_line,
        }

    def _brightness_status_unlocked(self) -> dict[str, int | bool | None]:
        status = self.power.brightness_status()
        return {
            "supported": status["supported"],
            "brightness_pct": status["brightness_pct"],
            "brightness": status["brightness"],
            "max_brightness": status["max_brightness"],
            "standby": self.state.standby,
        }

    def _volume_status_unlocked(self) -> dict[str, int | bool]:
        return {
            "volume": self.state.volume,
            "muted": self.state.muted,
            "standby": self.state.standby,
        }

    def on_left_clockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.MENU:
                return
            self._move_vibe(1)

    def on_left_counterclockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.MENU:
                return
            self._move_vibe(-1)

    def on_right_clockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.MENU:
                if self.state.menu_editing:
                    self._adjust_menu_value(1)
                else:
                    self._move_menu(1)
            else:
                self._move_channel(1)

    def on_right_counterclockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.MENU:
                if self.state.menu_editing:
                    self._adjust_menu_value(-1)
                else:
                    self._move_menu(-1)
            else:
                self._move_channel(-1)

    def on_left_click(self) -> None:
        with self.lock:
            if self.state.mode == UiMode.STANDBY:
                self._exit_standby_locked(prefix="wake")
                return
            self._update_status()

    def on_right_click(self) -> None:
        with self.lock:
            if self.state.mode == UiMode.STANDBY:
                self._exit_standby_locked(prefix="wake")
                return
            if self.state.mode == UiMode.MENU:
                self._toggle_menu_edit()
                return
            self._open_menu()

    def on_standby_button(self) -> None:
        with self.lock:
            if self.state.mode == UiMode.MENU:
                self._menu_back()
                return
            if self.state.mode == UiMode.STANDBY:
                self._exit_standby_locked(prefix="wake")
                return
            self._enter_standby_locked()

    def _move_vibe(self, delta: int) -> None:
        self.state.current_vibe_index = (self.state.current_vibe_index + delta) % self.library.vibe_count()
        self.state.current_channel_index = 0
        self.state.clip_index = 0
        self._play_current_channel()

    def _move_channel(self, delta: int) -> None:
        channel_count = self.library.channel_count(self.state.current_vibe_index)
        self.state.current_channel_index = (self.state.current_channel_index + delta) % channel_count
        self.state.clip_index = 0
        self._play_current_channel()

    def _set_volume_locked(self, volume: int) -> None:
        self.state.volume = max(0, min(100, volume))
        self.player.set_volume(self.state.volume)
        self.state.muted = False
        self.player.mute(False)
        self._update_status()

    def _move_menu(self, delta: int) -> None:
        size = len(self.state.available_menu_items)
        self.state.menu_index = max(0, min(size - 1, self.state.menu_index + delta))
        self._update_status()

    def _open_menu(self) -> None:
        self.state.mode = UiMode.MENU
        self.state.menu_editing = False
        self._update_status("menu-open")

    def _toggle_menu_edit(self) -> None:
        self.state.menu_editing = not self.state.menu_editing
        self._update_status("menu-edit" if self.state.menu_editing else "menu-view")

    def _menu_back(self) -> None:
        if self.state.menu_editing:
            self.state.menu_editing = False
            self._update_status("menu-view")
            return
        self.state.mode = UiMode.BROWSE
        self._update_status("menu-close")

    def _adjust_menu_value(self, delta: int) -> None:
        item = self.state.available_menu_items[self.state.menu_index]
        if item == "brightness":
            current = self.state.brightness_pct or 0
            self.power.set_brightness_pct(
                max(0, min(100, current + delta * self.config.brightness_step_pct))
            )
            self._sync_brightness_state()
            logging.info("menu brightness set to %s%%", self.state.brightness_pct)
        elif item == "timer":
            size = len(self.state.timer_options)
            self.state.timer_index = max(0, min(size - 1, self.state.timer_index + delta))
        self._update_status()

    def _play_current_channel(self) -> None:
        items = self.library.channel_items(
            self.state.current_vibe_index,
            self.state.current_channel_index,
        )
        self.player.set_playlist(items, start_index=self.state.clip_index)
        self._update_status()

    def _update_status(self, prefix: str | None = None) -> None:
        vibe = self.library.vibes[self.state.current_vibe_index]
        channel = vibe.channels[self.state.current_channel_index]
        parts = []
        if prefix:
            parts.append(prefix)
        parts.append(f"mode={self.state.mode.value}")
        parts.append(f"vibe={vibe.number}:{vibe.name}")
        parts.append(f"channel={channel.number}:{channel.name}")
        parts.append(f"volume={self.state.volume}")
        if self.state.brightness_pct is not None:
            parts.append(f"brightness={self.state.brightness_pct}")
        if self.state.mode == UiMode.MENU:
            current_item = self.state.available_menu_items[self.state.menu_index]
            parts.append(f"menu={current_item}")
            parts.append(f"menu_state={'edit' if self.state.menu_editing else 'view'}")
            if current_item == "timer":
                parts.append(f"timer={self.state.timer_options[self.state.timer_index]}")
        if self.state.standby:
            parts.append("power=standby")
        battery = self.power.read_battery_snapshot()
        parts.append(f"battery={battery.battery_percent}")
        parts.append(f"plugged={battery.external_power}")
        self.state.status_line = " ".join(parts)
        self._update_osd(prefix)

    def _update_osd(self, prefix: str | None = None) -> None:
        if self.state.mode != UiMode.MENU:
            return
        self.player.show_text(self._render_menu_osd(prefix), duration_ms=4000)

    def _render_menu_osd(self, prefix: str | None = None) -> str:
        current_item = self.state.available_menu_items[self.state.menu_index]
        header = r"{\an5\fs18\1c&H9AD9FF&\bord2\shad1\pos(400,120)}MENU"
        carousel = self._render_menu_carousel()
        detail_lines = []
        if current_item == "brightness":
            detail_lines.append(f"BRIGHTNESS  {self.state.brightness_pct or 0}%")
        elif current_item == "timer":
            detail_lines.append(f"TIMER  {self.state.timer_options[self.state.timer_index]}")
        detail_lines.append("EDIT MODE" if self.state.menu_editing else "NAV MODE")
        if prefix:
            detail_lines.append(prefix.upper())
        detail = (
            r"{\an5\fs15\1c&HFFFFFF&\bord2\shad1\pos(400,260)}"
            + r"\N".join(self._escape_ass(line) for line in detail_lines)
        )
        return "".join([header, carousel, detail])

    def _render_menu_carousel(self) -> str:
        base_x = 400
        y = 190
        spacing = 180
        parts = []
        for idx, item in enumerate(self.state.available_menu_items):
            distance = idx - self.state.menu_index
            x = base_x + (distance * spacing)
            label = self._escape_ass(item.upper())
            if distance == 0:
                parts.append(
                    rf"{{\an5\fs28\1c&HFFFFFF&\bord3\shad1\pos({x},{y})}}[ {label} ]"
                )
            elif abs(distance) == 1:
                parts.append(
                    rf"{{\an5\fs18\1c&H8A8A8A&\bord2\shad1\pos({x},{y})}}{label}"
                )
            else:
                parts.append(
                    rf"{{\an5\fs14\1c&H555555&\bord1\shad0\pos({x},{y})}}{label}"
                )
        return "".join(parts)

    @staticmethod
    def _escape_ass(value: str) -> str:
        return value.replace("\\", r"\\").replace("{", r"\{").replace("}", r"\}")

    def _sync_brightness_state(self) -> None:
        status = self.power.brightness_status()
        self.state.brightness_pct = (
            int(status["brightness_pct"]) if status["brightness_pct"] is not None else None
        )

    def _enter_standby_locked(self) -> None:
        if self.state.standby:
            self._update_status("standby")
            return
        logging.info("entering standby")
        self.player.pause()
        logging.info("audio stopped")
        self.player.mute(True)
        logging.info("audio muted")
        self.power.enter_low_power_mode()
        logging.info("display off")
        self.state.vibe_output_enabled = False
        logging.info("vibe disabled")
        self.state.mode = UiMode.STANDBY
        self.state.standby = True
        self.state.power_save = True
        self._update_status()

    def _wake_if_needed(self) -> bool:
        if self.state.mode != UiMode.STANDBY:
            return False
        self._exit_standby_locked(prefix="wake")
        return True

    def _exit_standby_locked(self, prefix: str | None = None) -> None:
        if not self.state.standby:
            self._update_status(prefix)
            return
        logging.info("exiting standby")
        self.power.exit_low_power_mode()
        logging.info("display on")
        self.player.mute(self.state.muted)
        logging.info("audio %s", "muted" if self.state.muted else "unmuted")
        self.player.play()
        logging.info("audio started")
        self.state.vibe_output_enabled = True
        logging.info("vibe enabled")
        self.state.mode = UiMode.BROWSE
        self.state.standby = False
        self.state.power_save = False
        self._update_status(prefix)

    def _shutdown_device(self) -> None:
        self.player.pause()
        self.player.mute(True)
        self.power.shutdown_now()
