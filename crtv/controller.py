from __future__ import annotations

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
            self._play_current_channel()

    def on_left_clockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.MENU:
                self._move_menu(1)
                return
            self._move_vibe(1)

    def on_left_counterclockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.MENU:
                self._move_menu(-1)
                return
            self._move_vibe(-1)

    def on_right_clockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.VOLUME:
                self._adjust_volume(self.config.volume_step_pct)
            elif self.state.mode == UiMode.MENU:
                self._move_menu(1)
            else:
                self._move_channel(1)

    def on_right_counterclockwise(self) -> None:
        with self.lock:
            if self._wake_if_needed():
                return
            if self.state.mode == UiMode.VOLUME:
                self._adjust_volume(-self.config.volume_step_pct)
            elif self.state.mode == UiMode.MENU:
                self._move_menu(-1)
            else:
                self._move_channel(-1)

    def on_left_click(self) -> None:
        with self.lock:
            if self.state.mode == UiMode.BROWSE:
                self.state.mode = UiMode.VOLUME
            elif self.state.mode == UiMode.VOLUME:
                self.state.mode = UiMode.MENU
            elif self.state.mode == UiMode.MENU:
                self.state.mode = UiMode.BROWSE
            else:
                self._wake_from_standby()
                return
            self._update_status()

    def on_right_click(self) -> None:
        with self.lock:
            if self.state.mode == UiMode.STANDBY:
                self._wake_from_standby()
                return
            if self.state.mode == UiMode.MENU:
                self._activate_menu_item()
                return
            if self.state.mode == UiMode.VOLUME:
                self.state.muted = not self.state.muted
                self.player.mute(self.state.muted)
                self._update_status()
                return
            self.player.cycle_playlist(1)
            self._update_status("skip-next")

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

    def _adjust_volume(self, delta: int) -> None:
        self.state.volume = max(0, min(100, self.state.volume + delta))
        self.player.set_volume(self.state.volume)
        self.state.muted = False
        self.player.mute(False)
        self._update_status()

    def _move_menu(self, delta: int) -> None:
        size = len(self.state.available_menu_items)
        self.state.menu_index = (self.state.menu_index + delta) % size
        self._update_status()

    def _activate_menu_item(self) -> None:
        action = self.state.available_menu_items[self.state.menu_index]
        if action == "resume":
            self.state.mode = UiMode.BROWSE
        elif action == "volume":
            self.state.mode = UiMode.VOLUME
        elif action == "power-off-mode":
            self._enter_standby()
            return
        elif action == "shutdown-now":
            self._shutdown_device()
            return
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
        if self.state.mode == UiMode.MENU:
            parts.append(
                f"menu={self.state.available_menu_items[self.state.menu_index]}"
            )
        if self.state.power_save:
            parts.append("power=standby")
        battery = self.power.read_battery_snapshot()
        parts.append(f"battery={battery.battery_percent}")
        parts.append(f"plugged={battery.external_power}")
        self.state.status_line = " ".join(parts)

    def _enter_standby(self) -> None:
        self.player.pause()
        self.player.mute(True)
        self.power.enter_low_power_mode()
        self.state.mode = UiMode.STANDBY
        self.state.power_save = True
        self._update_status()

    def _wake_if_needed(self) -> bool:
        if self.state.mode != UiMode.STANDBY:
            return False
        self._wake_from_standby()
        return True

    def _wake_from_standby(self) -> None:
        self.power.exit_low_power_mode()
        self.player.mute(False)
        self.player.play()
        self.state.mode = UiMode.BROWSE
        self.state.power_save = False
        self._update_status("wake")

    def _shutdown_device(self) -> None:
        self.player.pause()
        self.player.mute(True)
        self.power.shutdown_now()
