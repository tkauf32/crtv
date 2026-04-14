from __future__ import annotations

import json
import logging
import os
import socket
import subprocess
import time
from pathlib import Path

from .config import AppConfig
from .models import MediaItem


class MpvPlayer:
    def __init__(self, config: AppConfig):
        self.config = config
        self.process: subprocess.Popen[str] | None = None

    def ensure_running(self) -> None:
        if self.process and self.process.poll() is None and self.config.mpv_socket.exists():
            return

        if self.config.mpv_socket.exists():
            try:
                self.config.mpv_socket.unlink()
            except OSError:
                pass

        self.config.log_file.parent.mkdir(parents=True, exist_ok=True)
        self.config.mpv_log_file.parent.mkdir(parents=True, exist_ok=True)

        env = os.environ.copy()
        env["DISPLAY"] = self.config.display
        env["XAUTHORITY"] = self.config.xauthority
        self._normalize_alsa_volume()

        args = [
            "mpv",
            f"--input-ipc-server={self.config.mpv_socket}",
            f"--profile={self.config.mpv_profile}",
            f"--vo={self.config.mpv_vo}",
            f"--gpu-context={self.config.mpv_gpu_context}",
            f"--hwdec={self.config.mpv_hwdec}",
            "--fullscreen",
            "--idle=yes",
            "--force-window=yes",
            "--keep-open=no",
            "--cache=yes",
            "--gapless-audio=weak",
            "--prefetch-playlist=yes",
            "--audio-display=no",
            "--osc=no",
            f"--keepaspect={self.config.keep_aspect}",
            f"--log-file={self.config.mpv_log_file}",
        ]
        af = self._build_af_chain()
        if af:
            args.append(f"--af={af}")
        vf = self._build_vf_chain()
        if vf:
            args.append(f"--vf={vf}")
        self.process = subprocess.Popen(
            args,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self._wait_for_socket()

    def _normalize_alsa_volume(self) -> None:
        if not self.config.alsa_init_enabled:
            return
        target = max(0, min(100, self.config.alsa_master_volume_pct))
        try:
            subprocess.run(
                ["amixer", "sset", "Master", f"{target}%"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            logging.info("alsa master volume normalized to %s%%", target)
        except OSError as exc:
            logging.warning("failed to normalize alsa master volume: %s", exc)

    def _wait_for_socket(self) -> None:
        deadline = time.monotonic() + self.config.target_ready_timeout_seconds
        while time.monotonic() < deadline:
            if self.config.mpv_socket.exists():
                try:
                    self.command(["get_property", "mpv-version"])
                    return
                except OSError:
                    pass
            time.sleep(0.1)
        raise RuntimeError(f"mpv IPC socket did not become ready: {self.config.mpv_socket}")

    def _send(self, payload: dict) -> dict | None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1.0)
            client.connect(str(self.config.mpv_socket))
            client.sendall(json.dumps(payload).encode("utf-8") + b"\n")
            raw = client.recv(65536)
        if not raw:
            return None
        line = raw.decode("utf-8").strip().splitlines()[-1]
        return json.loads(line)

    def command(self, command: list[object]) -> dict | None:
        self.ensure_running()
        return self._send({"command": command})

    def set_playlist(self, items: list[MediaItem], start_index: int = 0) -> None:
        if not items:
            self.show_static()
            return
        self.command(["playlist-clear"])
        self.command(["loadfile", items[0].path, "replace"])
        for item in items[1:]:
            self.command(["loadfile", item.path, "append"])
        self.command(["set_property", "loop-file", "no"])
        self.command(["set_property", "loop-playlist", "inf"])
        self.command(["set_property", "pause", False])
        if start_index > 0:
            self.command(["set_property", "playlist-pos", start_index])

    def show_static(self) -> None:
        self.command(["loadfile", str(self.config.static_file), "replace"])
        self.command(["set_property", "loop-file", "inf"])

    def play(self) -> None:
        self.command(["set_property", "pause", False])

    def pause(self) -> None:
        self.command(["set_property", "pause", True])

    def set_volume(self, volume: int) -> None:
        self.command(["set_property", "volume", volume])

    def mute(self, value: bool) -> None:
        self.command(["set_property", "mute", value])

    def cycle_playlist(self, delta: int) -> None:
        self.command(["playlist-next" if delta > 0 else "playlist-prev", "force"])

    def show_text(self, text: str, duration_ms: int = 2000) -> None:
        self.command(["show-text", text, duration_ms])

    def terminate(self) -> None:
        if self.process and self.process.poll() is None:
            self.command(["quit"])
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def _build_vf_chain(self) -> str:
        filters: list[str] = []
        if self.config.downsample_height > 0:
            filters.append(f"scale=-2:{self.config.downsample_height}:flags=bilinear")
        if self.config.enable_crop_filter:
            if self.config.crop_filter:
                filters.append(self.config.crop_filter)
            else:
                filters.append(
                    f"crop=ih*4/3:ih:(iw-ih*4/3)*({self.config.crop_x_pct}/100):0"
                )
        return ",".join(filters)

    def _build_af_chain(self) -> str:
        filters: list[str] = []
        if self.config.audio_highpass_enabled:
            filters.append(f"lavfi=[highpass=f={self.config.audio_highpass_cutoff_hz}]")
        return ",".join(filters)
