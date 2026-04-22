from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .config import AppConfig


@dataclass(frozen=True)
class BatterySnapshot:
    model: str = "unknown"
    battery_percent: str = "unknown"
    battery_voltage: str = "unknown"
    external_power: str = "unknown"
    charging_allowed: str = "unknown"
    output_enabled: str = "unknown"
    temperature: str = "unknown"


class BacklightController:
    def __init__(self, config: AppConfig):
        self.config = config
        self._backlight_dir = self._resolve_backlight_dir()
        self._bl_power = self._backlight_dir / "bl_power" if self._backlight_dir else None
        self._brightness = (
            self._backlight_dir / "brightness" if self._backlight_dir else None
        )
        self._saved_brightness: str | None = None

    def turn_off(self) -> None:
        self._save_brightness()
        self._write_brightness("0")
        if self._write_bl_power("1"):
            return
        self._run(self.config.display_off_command)

    def turn_on(self) -> None:
        if self._write_bl_power("0"):
            self._restore_brightness()
            return
        self._run(self.config.display_on_command)
        self._restore_brightness()

    def brightness_status(self) -> dict[str, int | bool | None]:
        max_brightness = self._read_int("max_brightness")
        current_brightness = self._read_int("brightness")
        if max_brightness is None or current_brightness is None or max_brightness <= 0:
            return {
                "supported": False,
                "brightness": None,
                "max_brightness": max_brightness,
                "brightness_pct": None,
            }
        brightness_pct = round((current_brightness * 100) / max_brightness)
        return {
            "supported": True,
            "brightness": current_brightness,
            "max_brightness": max_brightness,
            "brightness_pct": max(0, min(100, brightness_pct)),
        }

    def set_brightness_pct(self, brightness_pct: int) -> dict[str, int | bool | None]:
        status = self.brightness_status()
        if not status["supported"]:
            raise RuntimeError("brightness control unavailable: no backlight sysfs path found")
        max_brightness = int(status["max_brightness"])
        clamped = max(0, min(100, brightness_pct))
        raw_value = round((clamped * max_brightness) / 100)
        if clamped > 0:
            raw_value = max(1, raw_value)
        self._saved_brightness = str(raw_value)
        if not self._write_brightness(str(raw_value)):
            raise RuntimeError("failed to write backlight brightness")
        return self.brightness_status()

    def _resolve_backlight_dir(self) -> Path | None:
        if self.config.display_backlight_path is not None:
            if self.config.display_backlight_path.is_dir():
                return self.config.display_backlight_path
            return None

        base = Path("/sys/class/backlight")
        if not base.is_dir():
            return None
        for entry in sorted(base.iterdir()):
            if entry.is_dir():
                return entry
        return None

    def _write_bl_power(self, value: str) -> bool:
        if self._bl_power is None:
            return False
        try:
            self._bl_power.write_text(value, encoding="utf-8")
            return True
        except OSError:
            return False

    def _save_brightness(self) -> None:
        if self._brightness is None:
            return
        try:
            self._saved_brightness = self._brightness.read_text(encoding="utf-8").strip()
        except OSError:
            self._saved_brightness = None

    def _restore_brightness(self) -> None:
        if self._saved_brightness is None:
            return
        if self._write_brightness(self._saved_brightness):
            self._saved_brightness = None

    def _write_brightness(self, value: str) -> bool:
        if self._brightness is None:
            return False
        try:
            self._brightness.write_text(value, encoding="utf-8")
            return True
        except OSError:
            return False

    def _read_int(self, name: str) -> int | None:
        if self._backlight_dir is None:
            return None
        try:
            return int((self._backlight_dir / name).read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            return None

    @staticmethod
    def _run(command: tuple[str, ...]) -> None:
        if not command:
            return
        subprocess.run(command, check=False)


class PowerManager:
    def __init__(self, config: AppConfig):
        self.config = config
        self.backlight = BacklightController(config)
        self._last_snapshot = BatterySnapshot(model="uninitialized")
        self._last_snapshot_at = 0.0

    def enter_low_power_mode(self) -> None:
        self.backlight.turn_off()

    def exit_low_power_mode(self) -> None:
        self.backlight.turn_on()

    def brightness_status(self) -> dict[str, int | bool | None]:
        return self.backlight.brightness_status()

    def set_brightness_pct(self, brightness_pct: int) -> dict[str, int | bool | None]:
        return self.backlight.set_brightness_pct(brightness_pct)

    def apply_pisugar_policy(self) -> None:
        if not self.config.pisugar_enabled:
            return
        self._pisugar_set("set_soft_poweroff true")
        self._pisugar_set(
            f"set_soft_poweroff_shell {self.config.pisugar_soft_poweroff_shell}"
        )
        self._pisugar_set(
            f"set_button_enable single {1 if self.config.pisugar_button_single_enabled else 0}"
        )
        self._pisugar_set(
            f"set_button_enable double {1 if self.config.pisugar_button_double_enabled else 0}"
        )
        self._pisugar_set(
            f"set_button_enable long {1 if self.config.pisugar_button_long_enabled else 0}"
        )
        if self.config.pisugar_button_long_shell:
            self._pisugar_set(
                f"set_button_shell long {self.config.pisugar_button_long_shell}"
            )
        self._pisugar_set(
            f"set_anti_mistouch {'true' if self.config.pisugar_anti_mistouch_enabled else 'false'}"
        )
        self._pisugar_set(
            f"set_safe_shutdown_level {self.config.safe_shutdown_level}"
        )
        self._pisugar_set(
            f"set_safe_shutdown_delay {self.config.safe_shutdown_delay_seconds}"
        )

    def battery_status(self) -> str:
        snapshot = self.read_battery_snapshot()
        return (
            f"model={snapshot.model} battery={snapshot.battery_percent} "
            f"battery_v={snapshot.battery_voltage} plugged={snapshot.external_power} "
            f"allow_charging={snapshot.charging_allowed} output={snapshot.output_enabled} "
            f"temp={snapshot.temperature}"
        )

    def read_battery_snapshot(self) -> BatterySnapshot:
        if not self.config.pisugar_enabled:
            return BatterySnapshot(model="disabled")
        if time.monotonic() - self._last_snapshot_at < 5.0:
            return self._last_snapshot
        self._last_snapshot = BatterySnapshot(
            model=self._pisugar_get("get model"),
            battery_percent=self._pisugar_get("get battery"),
            battery_voltage=self._pisugar_get("get battery_v"),
            external_power=self._pisugar_get("get battery_power_plugged"),
            charging_allowed=self._pisugar_get("get battery_allow_charging"),
            output_enabled=self._pisugar_get("get battery_output_enabled"),
            temperature=self._pisugar_get("get temperature"),
        )
        self._last_snapshot_at = time.monotonic()
        return self._last_snapshot

    def prepare_soft_shutdown(self) -> None:
        if self.config.pisugar_enabled and self.config.pisugar_soft_poweroff_enabled:
            self._pisugar_set("set_soft_poweroff true")
            self._pisugar_set(
                f"set_soft_poweroff_shell {self.config.pisugar_soft_poweroff_shell}"
            )

    def shutdown_now(self) -> None:
        self.prepare_soft_shutdown()
        self._run(self.config.shutdown_command)

    def _run(self, command: tuple[str, ...]) -> None:
        if not command:
            return
        subprocess.run(command, check=False)

    def _pisugar_set(self, command: str) -> str:
        return self._pisugar_request(command)

    def _pisugar_get(self, command: str) -> str:
        return self._pisugar_request(command)

    def _pisugar_request(self, command: str) -> str:
        tcp = self._run_pisugar_tcp(command)
        if tcp is not None:
            return tcp
        socket_reply = self._run_pisugar_socket(command)
        if socket_reply is not None:
            return socket_reply
        return "pisugar-unavailable"

    def _run_pisugar_tcp(self, command: str) -> str | None:
        if not self.config.pisugar_tcp_command:
            return None
        cmd = [
            *self.config.pisugar_tcp_command,
            self.config.pisugar_host,
            str(self.config.pisugar_port),
        ]
        try:
            proc = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                input=f"{command}\n",
            )
        except OSError:
            return None
        return self._normalize_reply(proc)

    def _run_pisugar_socket(self, command: str) -> str | None:
        if not self.config.pisugar_socket_command:
            return None
        try:
            proc = subprocess.run(
                self.config.pisugar_socket_command,
                check=False,
                capture_output=True,
                text=True,
                input=f"{command}\n",
            )
        except OSError:
            return None
        return self._normalize_reply(proc)

    @staticmethod
    def _normalize_reply(proc: subprocess.CompletedProcess[str]) -> str:
        output = (proc.stdout or "").strip() or (proc.stderr or "").strip()
        if output:
            return output
        return f"rc={proc.returncode}"
