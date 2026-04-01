from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass

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


class PowerManager:
    def __init__(self, config: AppConfig):
        self.config = config
        self._last_snapshot = BatterySnapshot(model="uninitialized")
        self._last_snapshot_at = 0.0

    def enter_low_power_mode(self) -> None:
        self._run(self.config.display_off_command)

    def exit_low_power_mode(self) -> None:
        self._run(self.config.display_on_command)

    def apply_pisugar_policy(self) -> None:
        if not self.config.pisugar_enabled:
            return
        self._pisugar_set("set_soft_poweroff true")
        self._pisugar_set(
            f"set_soft_poweroff_shell {self.config.pisugar_soft_poweroff_shell}"
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
