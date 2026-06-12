from __future__ import annotations

import json
import logging
import os
import socket
import subprocess
import threading
import time
from pathlib import Path

from .config import AppConfig
from .models import MediaItem


class MpvPlayer:
    AUDIO_COVER_ZOOM = -0.35
    AUDIO_COVER_ALIGN_Y = -0.12
    AUDIO_COVER_BOTTOM_MARGIN = 0.22
    NOW_PLAYING_DURATION_MS = 3_600_000
    NOW_PLAYING_FONT_SIZE = 20
    NOW_PLAYING_MARGIN_Y = 24

    def __init__(self, config: AppConfig):
        self.config = config
        self.process: subprocess.Popen[str] | None = None
        self._socket_lock = threading.Lock()
        self._monitor_stop = threading.Event()
        self._monitor_thread: threading.Thread | None = None
        self._last_media_marker: tuple[int | None, str | None] | None = None
        self._base_vf = ""
        self._audio_cover_active = False
        self._now_playing_text = ""
        self._menu_overlay_active = False

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
            "--audio-display=embedded-first",
            "--osc=no",
            "--osd-align-x=center",
            "--osd-align-y=center",
            "--osd-font-size=24",
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
        self._base_vf = self._build_vf_chain()
        self._last_media_marker = None
        self._start_monitor()

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
        with self._socket_lock:
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

    def get_property(self, name: str) -> object | None:
        response = self.command(["get_property", name])
        if not response or response.get("error") != "success":
            return None
        return response.get("data")

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
        self._refresh_current_media_state()

    def show_static(self) -> None:
        self.command(["loadfile", str(self.config.static_file), "replace"])
        self.command(["set_property", "loop-file", "inf"])
        self._refresh_current_media_state()

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

    def set_playlist_position(self, index: int) -> None:
        self.command(["set_property", "playlist-pos", index])
        self._refresh_current_media_state()

    def show_text(self, text: str, duration_ms: int = 2000) -> None:
        self.command(["show-text", text, duration_ms])

    def show_menu_text(self, text: str, duration_ms: int = 2000) -> None:
        self._menu_overlay_active = True
        self.command(["set_property", "options/osd-align-x", "center"])
        self.command(["set_property", "options/osd-align-y", "center"])
        self.command(["set_property", "options/osd-margin-y", 16])
        self.show_text(text, duration_ms=duration_ms)

    def restore_now_playing_overlay(self) -> None:
        self._menu_overlay_active = False
        if self._audio_cover_active and self._now_playing_text:
            self._show_now_playing_text(self._now_playing_text)
            return
        self.clear_text()

    def clear_text(self) -> None:
        self.command(["show-text", "", 0])

    def set_osd_font_size(self, size: int) -> None:
        self.command(["set_property", "options/osd-font-size", size])

    def terminate(self) -> None:
        self._monitor_stop.set()
        if self.process and self.process.poll() is None:
            self.command(["quit"])
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def _start_monitor(self) -> None:
        if self._monitor_thread and self._monitor_thread.is_alive():
            return
        self._monitor_stop.clear()
        self._monitor_thread = threading.Thread(
            target=self._monitor_current_media,
            name="mpv-media-monitor",
            daemon=True,
        )
        self._monitor_thread.start()

    def _monitor_current_media(self) -> None:
        while not self._monitor_stop.wait(1.0):
            if not self.process or self.process.poll() is not None:
                continue
            try:
                marker = (
                    self.get_property("playlist-pos"),
                    self.get_property("path"),
                )
            except OSError:
                continue
            if marker == self._last_media_marker or marker[1] is None:
                continue
            self._last_media_marker = marker
            try:
                self._refresh_current_media_state()
            except OSError:
                continue

    def _refresh_current_media_state(self) -> None:
        state = self._probe_current_media_state()
        if state is None:
            return
        self._last_media_marker = (state["playlist_pos"], state["path"])
        if self._is_audio_cover_mode(state["track_list"]):
            self._apply_audio_cover_layout()
            self._now_playing_text = self._format_now_playing_text(
                state["metadata"], state["media_title"]
            )
            self._audio_cover_active = True
            if not self._menu_overlay_active and self._now_playing_text:
                self._show_now_playing_text(self._now_playing_text)
            return
        self._apply_default_video_layout()
        self._audio_cover_active = False
        self._now_playing_text = ""
        if not self._menu_overlay_active:
            self.clear_text()

    def _probe_current_media_state(self) -> dict[str, object] | None:
        for _ in range(10):
            track_list = self.get_property("track-list")
            if isinstance(track_list, list):
                metadata = self.get_property("metadata")
                media_title = self.get_property("media-title")
                return {
                    "playlist_pos": self.get_property("playlist-pos"),
                    "path": self.get_property("path"),
                    "track_list": track_list,
                    "metadata": metadata if isinstance(metadata, dict) else {},
                    "media_title": media_title if isinstance(media_title, str) else "",
                }
            time.sleep(0.1)
        return None

    def _is_audio_cover_mode(self, track_list: list[object]) -> bool:
        has_audio = False
        has_attached_picture = False
        has_regular_video = False
        for raw_track in track_list:
            if not isinstance(raw_track, dict):
                continue
            track_type = raw_track.get("type")
            if track_type == "audio":
                has_audio = True
                continue
            if track_type != "video":
                continue
            if raw_track.get("attached-picture") or raw_track.get("attached_picture"):
                has_attached_picture = True
            else:
                has_regular_video = True
        return has_audio and has_attached_picture and not has_regular_video

    def _format_now_playing_text(self, metadata: dict[str, object], media_title: str) -> str:
        title = self._metadata_value(metadata, "title")
        artist = self._metadata_value(metadata, "artist")
        if title and artist and title.lower() != artist.lower():
            return f"{title}\n{artist}"
        if title:
            return title
        if artist:
            return artist
        return media_title.strip()

    def _metadata_value(self, metadata: dict[str, object], key: str) -> str:
        wanted = key.lower()
        for raw_key, value in metadata.items():
            if str(raw_key).strip().lower() != wanted:
                continue
            text = str(value).strip()
            if text:
                return text
        return ""

    def _apply_audio_cover_layout(self) -> None:
        self._apply_video_filters("")
        self.command(["set_property", "options/keepaspect", "yes"])
        self.command(["set_property", "video-zoom", self.AUDIO_COVER_ZOOM])
        self.command(["set_property", "video-align-x", 0])
        self.command(["set_property", "video-align-y", self.AUDIO_COVER_ALIGN_Y])
        self.command(["set_property", "video-margin-ratio-left", 0])
        self.command(["set_property", "video-margin-ratio-right", 0])
        self.command(["set_property", "video-margin-ratio-top", 0])
        self.command(
            [
                "set_property",
                "video-margin-ratio-bottom",
                self.AUDIO_COVER_BOTTOM_MARGIN,
            ]
        )

    def _apply_default_video_layout(self) -> None:
        self._apply_video_filters(self._base_vf)
        self.command(["set_property", "options/keepaspect", self.config.keep_aspect])
        self.command(["set_property", "video-zoom", 0])
        self.command(["set_property", "video-align-x", 0])
        self.command(["set_property", "video-align-y", 0])
        self.command(["set_property", "video-margin-ratio-left", 0])
        self.command(["set_property", "video-margin-ratio-right", 0])
        self.command(["set_property", "video-margin-ratio-top", 0])
        self.command(["set_property", "video-margin-ratio-bottom", 0])

    def _apply_video_filters(self, vf: str) -> None:
        if vf:
            self.command(["vf", "set", vf])
            return
        self.command(["vf", "set", ""])

    def _show_now_playing_text(self, text: str) -> None:
        self.command(["set_property", "options/osd-font-size", self.NOW_PLAYING_FONT_SIZE])
        self.command(["set_property", "options/osd-align-x", "center"])
        self.command(["set_property", "options/osd-align-y", "bottom"])
        self.command(["set_property", "options/osd-margin-y", self.NOW_PLAYING_MARGIN_Y])
        self.show_text(text, duration_ms=self.NOW_PLAYING_DURATION_MS)

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
